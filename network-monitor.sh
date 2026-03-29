#!/usr/bin/env bash
set -u

# network-monitor.sh - Latency, packet loss, and DNS monitoring with timeseries
# Version: 1.0.0
# Usage: ./network-monitor.sh [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

LOG_DIR="${SCRIPT_DIR}/logs/network-monitor"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RUN_START_TS=$(date +%s)
LOG_FILE="${LOG_DIR}/network_monitor_${TIMESTAMP}.log"
JSON_FILE="${LOG_DIR}/network_monitor_${TIMESTAMP}.json"
TIMESERIES_FILE="${LOG_DIR}/timeseries.jsonl"

# Defaults
TARGETS="1.1.1.1:Cloudflare,8.8.8.8:Google DNS,google.com:Google"
DNS_TARGETS="google.com,github.com,cloudflare.com"
PING_COUNT=5
WATCH_MODE=false
WATCH_INTERVAL=60
LATENCY_THRESHOLD=200 # ms — alert if avg > this
LOSS_THRESHOLD=10     # % — alert if packet loss > this
DNS_THRESHOLD=500     # ms — alert if DNS resolution > this
DRY_RUN=false
OUTPUT_JSON=false

# Results
ALERTS=0
STATUS="ok"
RESULTS_JSON="[]"

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_error() {
    echo -e "${RED}✗ Error:${NC} $1" >&2
    log_line "ERROR" "$1"
}
print_success() {
    echo -e "${GREEN}✓${NC} $1"
    log_line "OK" "$1"
}
print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
    log_line "WARN" "$1"
}
print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
    log_line "INFO" "$1"
}
print_section() {
    echo ""
    echo -e "${CYAN}━━━ $1 ━━━${NC}"
    echo ""
    log_line "SECTION" "$1"
}
log_line() { echo "[$(get_iso8601_timestamp)] $1: $2" >>"$LOG_FILE"; }

_get_epoch_ms() {
    local ts
    ts=$(date +%s%3N 2>/dev/null)
    # On macOS/BSD, %3N is literal — detect and fall back to seconds * 1000
    if echo "$ts" | grep -q '[^0-9]'; then
        echo $(($(date +%s) * 1000))
    else
        echo "$ts"
    fi
}

show_help() {
    cat <<'HELP'
network-monitor.sh - Latency, packet loss, and DNS monitoring with timeseries

USAGE:
    ./network-monitor.sh [OPTIONS]

OPTIONS:
    --targets <list>         Comma-separated "ip:label" pairs to ping
                             Default: 1.1.1.1:Cloudflare,8.8.8.8:Google DNS
    --dns <list>             Comma-separated hostnames for DNS resolution timing
    --count <n>              Ping count per target (default: 5)
    --watch                  Continuous monitoring mode
    --interval <secs>        Watch refresh interval in seconds (default: 60)
    --latency-threshold <ms> Alert if avg latency > N ms (default: 200)
    --loss-threshold <%>     Alert if packet loss > N% (default: 10)
    --dns-threshold <ms>     Alert if DNS resolution > N ms (default: 500)
    --dry-run                Show targets without running checks
    --json                   JSON summary output
    --help                   Show this help message

TIMESERIES:
    Results are appended to logs/network-monitor/timeseries.jsonl
    Use jq to query: jq 'select(.target=="1.1.1.1")' timeseries.jsonl

EXAMPLES:
    # Quick check
    ./network-monitor.sh

    # Watch mode, check every 30 seconds
    ./network-monitor.sh --watch --interval 30

    # Custom targets
    ./network-monitor.sh --targets "192.168.1.1:Gateway,1.1.1.1:Cloudflare"

    # Strict thresholds
    ./network-monitor.sh --latency-threshold 50 --loss-threshold 1

EXIT CODES:
    0  All within thresholds
    1  Threshold exceeded
    2  Fatal error
HELP
}

# ── Ping a target ─────────────────────────────────────────────────────────────

check_ping() {
    local target="$1"
    local label="$2"

    local ping_output
    ping_output=$(ping -c "$PING_COUNT" -W 3 "$target" 2>/dev/null)
    local ping_exit=$?

    if [ $ping_exit -ne 0 ] && [ -z "$ping_output" ]; then
        printf "  %-20s %-15s  ${RED}UNREACHABLE${NC}\n" "$label" "$target"
        ALERTS=$((ALERTS + 1))
        STATUS="alert"
        log_line "UNREACHABLE" "$target ($label)"
        return
    fi

    # Parse packet loss
    local loss
    loss=$(echo "$ping_output" | grep -oE '[0-9]+% packet loss' | grep -oE '[0-9]+' || echo 0)

    # Parse avg latency from "rtt min/avg/max/mdev" line
    local avg_ms
    avg_ms=$(echo "$ping_output" | grep -oE 'rtt min/avg/max.*= [0-9.]+/[0-9.]+' | grep -oE '/[0-9.]+/' | head -1 | tr -d '/' || echo 0)
    avg_ms=$(printf "%.1f" "${avg_ms:-0}" 2>/dev/null || echo "0")

    local status_color="$GREEN"
    local status_sym="✓"

    local loss_int
    loss_int=$(printf "%.0f" "${loss:-0}" 2>/dev/null || echo 0)
    local avg_int
    avg_int=$(printf "%.0f" "${avg_ms:-0}" 2>/dev/null || echo 0)

    if [ "$loss_int" -ge "$LOSS_THRESHOLD" ] || [ "$avg_int" -ge "$LATENCY_THRESHOLD" ]; then
        status_color="$RED"
        status_sym="✗"
        ALERTS=$((ALERTS + 1))
        STATUS="alert"
    elif [ "$loss_int" -gt 0 ] || [ "$avg_int" -gt $((LATENCY_THRESHOLD / 2)) ]; then
        status_color="$YELLOW"
        status_sym="⚠"
    fi

    printf "  %-20s %-15s  ${status_color}%s${NC}  avg=%sms  loss=%s%%\n" \
        "$label" "$target" "$status_sym" "$avg_ms" "${loss:-0}"

    log_line "PING" "$target avg=${avg_ms}ms loss=${loss:-0}%"

    # Append to timeseries
    local entry
    entry=$(printf '{"ts":"%s","target":"%s","label":"%s","avg_ms":%s,"loss_pct":%s}' \
        "$(get_iso8601_timestamp)" "$(json_escape "$target")" "$(json_escape "$label")" "${avg_ms:-0}" "${loss:-0}")
    echo "$entry" >>"$TIMESERIES_FILE"

    # Append to results JSON
    if [ "$RESULTS_JSON" = "[]" ]; then
        RESULTS_JSON="[$entry]"
    else
        RESULTS_JSON="${RESULTS_JSON%]},${entry}]"
    fi
}

# ── DNS resolution timing ─────────────────────────────────────────────────────

check_dns() {
    print_section "DNS Resolution"

    printf "  %-25s  %-8s  %s\n" "HOSTNAME" "TIME(ms)" "STATUS"
    printf "  %s\n" "$(printf '─%.0s' {1..50})"

    IFS=',' read -ra dns_list <<<"$DNS_TARGETS"
    for host in "${dns_list[@]}"; do
        host=$(echo "$host" | xargs)
        local start_ts end_ts elapsed_ms
        start_ts=$(_get_epoch_ms)
        host "$host" >/dev/null 2>&1
        end_ts=$(_get_epoch_ms)
        elapsed_ms=$((end_ts - start_ts))

        local color="$GREEN" sym="✓"
        if [ "$elapsed_ms" -ge "$DNS_THRESHOLD" ]; then
            color="$RED"
            sym="✗"
            ALERTS=$((ALERTS + 1))
            STATUS="alert"
        elif [ "$elapsed_ms" -ge $((DNS_THRESHOLD / 2)) ]; then
            color="$YELLOW"
            sym="⚠"
        fi

        printf "  %-25s  ${color}%-8s  %s${NC}\n" "$host" "${elapsed_ms}ms" "$sym"
        log_line "DNS" "$host=${elapsed_ms}ms"
    done
}

# ── Run checks ────────────────────────────────────────────────────────────────

run_checks() {
    ALERTS=0
    STATUS="ok"

    print_section "Ping / Latency"
    printf "  %-20s %-15s  %-4s  %-10s  %s\n" "LABEL" "TARGET" "OK" "AVG" "LOSS"
    printf "  %s\n" "$(printf '─%.0s' {1..60})"

    IFS=',' read -ra target_list <<<"$TARGETS"
    for entry in "${target_list[@]}"; do
        local target label
        if echo "$entry" | grep -q ':'; then
            target=$(echo "$entry" | cut -d: -f1)
            label=$(echo "$entry" | cut -d: -f2-)
        else
            target="$entry"
            label="$entry"
        fi
        check_ping "$target" "$label"
    done

    check_dns
}

# ── Parse args ────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
    --targets)
        TARGETS="$2"
        shift 2
        ;;
    --dns)
        DNS_TARGETS="$2"
        shift 2
        ;;
    --count)
        PING_COUNT="$2"
        shift 2
        ;;
    --watch)
        WATCH_MODE=true
        shift
        ;;
    --interval)
        WATCH_INTERVAL="$2"
        shift 2
        ;;
    --latency-threshold)
        LATENCY_THRESHOLD="$2"
        shift 2
        ;;
    --loss-threshold)
        LOSS_THRESHOLD="$2"
        shift 2
        ;;
    --dns-threshold)
        DNS_THRESHOLD="$2"
        shift 2
        ;;
    --dry-run)
        DRY_RUN=true
        shift
        ;;
    --json)
        OUTPUT_JSON=true
        shift
        ;;
    --help | -h)
        show_help
        exit 0
        ;;
    *)
        echo "Unknown option: $1" >&2
        show_help
        exit 2
        ;;
    esac
done

# ── Setup ─────────────────────────────────────────────────────────────────────

umask 077
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"
touch "$LOG_FILE" "$TIMESERIES_FILE"
chmod 600 "$LOG_FILE" "$TIMESERIES_FILE"

require_jq_if_json "$OUTPUT_JSON" || exit 2

if [ "$DRY_RUN" = true ]; then
    echo -e "${BOLD}━━━ Network Monitor (DRY RUN) ━━━${NC}"
    echo ""
    print_info "Would ping: $TARGETS"
    print_info "Would resolve: $DNS_TARGETS"
    print_info "Thresholds: latency>${LATENCY_THRESHOLD}ms loss>${LOSS_THRESHOLD}% dns>${DNS_THRESHOLD}ms"
    exit 0
fi

if [ "$WATCH_MODE" = true ]; then
    trap 'echo ""; print_info "Stopped."; exit 0' INT TERM
    while true; do
        clear
        echo -e "${BOLD}━━━ Network Monitor — $(date '+%Y-%m-%d %H:%M:%S') ━━━${NC}"
        echo -e "${BLUE}ℹ${NC} Thresholds: latency>${LATENCY_THRESHOLD}ms loss>${LOSS_THRESHOLD}% dns>${DNS_THRESHOLD}ms"
        run_checks
        echo ""
        print_info "Refreshing every ${WATCH_INTERVAL}s — Ctrl+C to stop | Timeseries: $TIMESERIES_FILE"
        sleep "$WATCH_INTERVAL"
    done
else
    echo -e "${BOLD}━━━ Network Monitor ━━━${NC}"
    echo ""
    print_info "Thresholds: latency>${LATENCY_THRESHOLD}ms loss>${LOSS_THRESHOLD}% dns>${DNS_THRESHOLD}ms"
    print_info "Timeseries: $TIMESERIES_FILE"
    run_checks
fi

# ── Summary ───────────────────────────────────────────────────────────────────

RUN_END_TS=$(date +%s)
DURATION_MS=$(((RUN_END_TS - RUN_START_TS) * 1000))

echo ""
if [ "$STATUS" = "ok" ]; then
    print_success "All targets within thresholds"
else
    print_warning "$ALERTS alert(s) — review above"
fi

if [ "$OUTPUT_JSON" = true ]; then
    jq -n \
        --arg script "network-monitor.sh" \
        --arg version "1.0.0" \
        --arg timestamp "$(get_iso8601_timestamp)" \
        --arg status "$STATUS" \
        --argjson duration_ms "$DURATION_MS" \
        --argjson alerts "$ALERTS" \
        --argjson results "$RESULTS_JSON" \
        '{
            script: $script,
            version: $version,
            timestamp: $timestamp,
            status: $status,
            duration_ms: $duration_ms,
            errors: [],
            result: {
                alerts: $alerts,
                targets: $results
            }
        }' >"$JSON_FILE"
    chmod 600 "$JSON_FILE"
    print_info "JSON: $JSON_FILE"
fi

[ "$STATUS" != "ok" ] && exit 1
exit 0
