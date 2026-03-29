#!/usr/bin/env bash
set -u

# system-monitor.sh - CPU, memory, disk, and process resource monitoring
# Version: 1.0.0
# Usage: ./system-monitor.sh [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

LOG_DIR="${SCRIPT_DIR}/logs/system-monitor"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RUN_START_TS=$(date +%s)
LOG_FILE="${LOG_DIR}/system_monitor_${TIMESTAMP}.log"
JSON_FILE="${LOG_DIR}/system_monitor_${TIMESTAMP}.json"

# Defaults
WATCH_MODE=false
WATCH_INTERVAL=10
TOP_N=10
CPU_THRESHOLD=80
MEM_THRESHOLD=85
DISK_THRESHOLD=90
LOAD_THRESHOLD=4
WEBHOOK_URL=""
DRY_RUN=false
OUTPUT_JSON=false

# Status
STATUS="ok"
ALERTS=()
ALERTS_JSON="[]"
ERRORS=0

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
    ERRORS=$((ERRORS + 1))
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

show_help() {
    cat <<'HELP'
system-monitor.sh - CPU, memory, disk, and process resource monitoring

USAGE:
    ./system-monitor.sh [OPTIONS]

OPTIONS:
    --watch               Continuous monitoring mode
    --interval <secs>     Watch refresh interval (default: 10)
    --top <n>             Show top N processes by CPU and memory (default: 10)
    --cpu-threshold <n>   Alert if CPU% > N (default: 80)
    --mem-threshold <n>   Alert if memory% > N (default: 85)
    --disk-threshold <n>  Alert if any mount > N% full (default: 90)
    --load-threshold <n>  Alert if 1-min load avg > N (default: 4)
    --webhook <url>       POST alerts to this URL
    --dry-run             Show current state, send no webhooks
    --json                JSON summary output
    --help                Show this help message

WHAT IT SHOWS:
    1. CPU usage (overall + per-core if available)
    2. Memory and swap usage
    3. Load averages (1/5/15 min)
    4. Disk usage across all mounts
    5. Top N processes by CPU%
    6. Top N processes by memory%
    7. Raspberry Pi temperature (if available)

EXAMPLES:
    # One-shot snapshot
    ./system-monitor.sh

    # Watch mode, refresh every 5 seconds
    ./system-monitor.sh --watch --interval 5

    # Alert via webhook if CPU > 90%
    ./system-monitor.sh --cpu-threshold 90 --webhook https://hooks.example.com/alert

    # JSON snapshot for dashboards
    ./system-monitor.sh --json

EXIT CODES:
    0  All within thresholds
    1  One or more thresholds exceeded
    2  Fatal error
HELP
}

add_alert() {
    local msg="$1"
    ALERTS+=("$msg")
    STATUS="alert"
    local escaped
    escaped=$(json_escape "$msg")
    if [ "$ALERTS_JSON" = "[]" ]; then
        ALERTS_JSON="[\"$escaped\"]"
    else
        ALERTS_JSON="${ALERTS_JSON%]},\"$escaped\"]"
    fi
    print_warning "ALERT: $msg"
    log_line "ALERT" "$msg"
}

mask_url() {
    # Show only scheme+host, replace path/query with ***
    local url="$1"
    echo "$url" | sed -E 's|(https?://[^/]+).*|\1/***|'
}

send_webhook() {
    local url="$1"
    local payload="$2"
    local masked_url
    masked_url=$(mask_url "$url")
    [ -z "$url" ] && return
    [ "$DRY_RUN" = true ] && {
        print_info "[DRY RUN] would POST to webhook: $masked_url"
        return
    }
    curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$url" >/dev/null 2>&1 &&
        log_line "WEBHOOK" "Sent alert to $masked_url" ||
        print_warning "Failed to send webhook to $masked_url"
}

# ── CPU ───────────────────────────────────────────────────────────────────────

check_cpu() {
    print_section "CPU & Load"

    # Load averages
    local load1 load5 load15 nproc
    read -r load1 load5 load15 _ </proc/loadavg 2>/dev/null || {
        load1=0
        load5=0
        load15=0
    }
    nproc=$(nproc 2>/dev/null || echo 1)

    printf "  Load average:  %.2f  %.2f  %.2f  (1/5/15 min)\n" "$load1" "$load5" "$load15"
    printf "  CPUs:          %d\n" "$nproc"

    # CPU usage via /proc/stat (1-second sample)
    local cpu_idle1 cpu_total1 cpu_idle2 cpu_total2
    read -r _ cpu_user1 cpu_nice1 cpu_sys1 cpu_idle1 cpu_iowait1 _ _ _ _ </proc/stat
    cpu_total1=$((cpu_user1 + cpu_nice1 + cpu_sys1 + cpu_idle1 + cpu_iowait1))
    sleep 1
    read -r _ cpu_user2 cpu_nice2 cpu_sys2 cpu_idle2 cpu_iowait2 _ _ _ _ </proc/stat
    cpu_total2=$((cpu_user2 + cpu_nice2 + cpu_sys2 + cpu_idle2 + cpu_iowait2))

    local cpu_delta_total=$((cpu_total2 - cpu_total1))
    local cpu_delta_idle=$((cpu_idle2 - cpu_idle1))
    local cpu_pct=0
    [ "$cpu_delta_total" -gt 0 ] &&
        cpu_pct=$(awk "BEGIN {printf \"%.1f\", 100 * ($cpu_delta_total - $cpu_delta_idle) / $cpu_delta_total}")

    printf "  CPU usage:     %s%%\n" "$cpu_pct"

    # Raspberry Pi temperature
    local temp_file="/sys/class/thermal/thermal_zone0/temp"
    if [ -f "$temp_file" ]; then
        local temp_raw temp_c
        temp_raw=$(cat "$temp_file" 2>/dev/null || echo 0)
        temp_c=$(awk "BEGIN {printf \"%.1f\", $temp_raw/1000}")
        printf "  CPU temp:      %s°C\n" "$temp_c"
        if awk "BEGIN {exit !($temp_raw > 80000)}"; then
            add_alert "CPU temperature critical: ${temp_c}°C"
        fi
    fi

    # Threshold check
    local load1_int
    load1_int=$(awk "BEGIN {printf \"%d\", $load1 + 0.5}")
    if [ "$load1_int" -ge "$LOAD_THRESHOLD" ]; then
        add_alert "High load average: ${load1} (threshold: ${LOAD_THRESHOLD})"
    fi

    local cpu_int
    cpu_int=$(awk "BEGIN {printf \"%d\", $cpu_pct + 0.5}")
    if [ "$cpu_int" -ge "$CPU_THRESHOLD" ]; then
        add_alert "High CPU usage: ${cpu_pct}% (threshold: ${CPU_THRESHOLD}%)"
    fi

    log_line "CPU" "usage=${cpu_pct}% load=${load1}"
}

# ── Memory ────────────────────────────────────────────────────────────────────

check_memory() {
    print_section "Memory"

    local mem_total mem_available mem_free mem_buffers mem_cached
    mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    mem_available=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    mem_free=$(grep "^MemFree:" /proc/meminfo | awk '{print $2}')
    mem_buffers=$(grep "^Buffers:" /proc/meminfo | awk '{print $2}')
    mem_cached=$(grep "^Cached:" /proc/meminfo | awk '{print $2}')

    local mem_used=$((mem_total - mem_available))
    local mem_pct
    mem_pct=$(awk "BEGIN {printf \"%.1f\", 100 * $mem_used / $mem_total}")

    local mem_total_h mem_used_h mem_avail_h
    mem_total_h=$(awk "BEGIN {printf \"%.1f GB\", $mem_total/1048576}")
    mem_used_h=$(awk "BEGIN {printf \"%.1f GB\", $mem_used/1048576}")
    mem_avail_h=$(awk "BEGIN {printf \"%.1f GB\", $mem_available/1048576}")

    printf "  Total:         %s\n" "$mem_total_h"
    printf "  Used:          %s (%s%%)\n" "$mem_used_h" "$mem_pct"
    printf "  Available:     %s\n" "$mem_avail_h"

    # Swap
    local swap_total swap_free swap_used swap_pct
    swap_total=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
    swap_free=$(grep SwapFree /proc/meminfo | awk '{print $2}')
    swap_used=$((swap_total - swap_free))
    if [ "$swap_total" -gt 0 ]; then
        swap_pct=$(awk "BEGIN {printf \"%.1f\", 100 * $swap_used / $swap_total}")
        local swap_total_h swap_used_h
        swap_total_h=$(awk "BEGIN {printf \"%.1f GB\", $swap_total/1048576}")
        swap_used_h=$(awk "BEGIN {printf \"%.1f GB\", $swap_used/1048576}")
        printf "  Swap:          %s / %s (%s%%)\n" "$swap_used_h" "$swap_total_h" "$swap_pct"
    else
        printf "  Swap:          none\n"
    fi

    local mem_int
    mem_int=$(awk "BEGIN {printf \"%d\", $mem_pct + 0.5}")
    if [ "$mem_int" -ge "$MEM_THRESHOLD" ]; then
        add_alert "High memory usage: ${mem_pct}% (threshold: ${MEM_THRESHOLD}%)"
    fi

    log_line "MEMORY" "used=${mem_pct}% total=${mem_total_h}"
}

# ── Disk ──────────────────────────────────────────────────────────────────────

check_disk() {
    print_section "Disk Usage"

    printf "  %-20s %-8s %-8s %-8s %s\n" "MOUNT" "TOTAL" "USED" "FREE" "USE%"
    printf "  %s\n" "$(printf '─%.0s' {1..60})"

    local alert_issued=false
    while IFS= read -r line; do
        local mount total used avail pct
        pct=$(echo "$line" | awk '{print $5}' | tr -d '%')
        mount=$(echo "$line" | awk '{print $6}')
        total=$(echo "$line" | awk '{print $2}')
        used=$(echo "$line" | awk '{print $3}')
        avail=$(echo "$line" | awk '{print $4}')

        local color="$NC"
        if [ "$pct" -ge "$DISK_THRESHOLD" ]; then
            color="$RED"
        elif [ "$pct" -ge "$((DISK_THRESHOLD - 10))" ]; then
            color="$YELLOW"
        fi

        printf "  %-20s %-8s %-8s %-8s ${color}%s%%${NC}\n" "$mount" "$total" "$used" "$avail" "$pct"

        if [ "$pct" -ge "$DISK_THRESHOLD" ] && [ "$alert_issued" = false ]; then
            add_alert "Disk ${mount} at ${pct}% (threshold: ${DISK_THRESHOLD}%)"
        fi
    done < <(df -h --output=source,size,used,avail,pcent,target 2>/dev/null |
        tail -n +2 |
        grep -v "^tmpfs\|^udev\|^devtmpfs\|^overlay\|^none" |
        sort -t'%' -k1 -rn 2>/dev/null || df -h | tail -n +2)

    log_line "DISK" "checked"
}

# ── Top processes ─────────────────────────────────────────────────────────────

check_processes() {
    print_section "Top Processes"

    printf "  ${BOLD}By CPU%%:${NC}\n"
    printf "  %-8s %-10s %-6s %-6s  %s\n" "PID" "USER" "CPU%" "MEM%" "COMMAND"
    printf "  %s\n" "$(printf '─%.0s' {1..60})"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        ps aux -r 2>/dev/null
    else
        ps aux --sort=-%cpu 2>/dev/null
    fi | tail -n +2 | head -"$TOP_N" |
        while read -r user pid cpu mem _ _ _ _ _ _ cmd; do
            local short_cmd="${cmd:0:40}"
            printf "  %-8s %-10s %-6s %-6s  %s\n" "$pid" "${user:0:10}" "$cpu" "$mem" "$short_cmd"
        done

    echo ""
    printf "  ${BOLD}By MEM%%:${NC}\n"
    printf "  %-8s %-10s %-6s %-6s  %s\n" "PID" "USER" "CPU%" "MEM%" "COMMAND"
    printf "  %s\n" "$(printf '─%.0s' {1..60})"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        ps aux -m 2>/dev/null
    else
        ps aux --sort=-%mem 2>/dev/null
    fi | tail -n +2 | head -"$TOP_N" |
        while read -r user pid cpu mem _ _ _ _ _ _ cmd; do
            local short_cmd="${cmd:0:40}"
            printf "  %-8s %-10s %-6s %-6s  %s\n" "$pid" "${user:0:10}" "$cpu" "$mem" "$short_cmd"
        done
}

# ── Single run ────────────────────────────────────────────────────────────────

run_checks() {
    ALERTS=()
    ALERTS_JSON="[]"
    STATUS="ok"
    check_cpu
    check_memory
    check_disk
    check_processes

    # Send webhook if alerts
    if [ ${#ALERTS[@]} -gt 0 ] && [ -n "$WEBHOOK_URL" ]; then
        local host
        host=$(hostname -s 2>/dev/null || echo "unknown")
        local payload
        payload=$(printf '{"host":"%s","timestamp":"%s","alerts":%s}' \
            "$host" "$(get_iso8601_timestamp)" "$ALERTS_JSON")
        send_webhook "$WEBHOOK_URL" "$payload"
    fi
}

# ── Parse args ────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
    --watch)
        WATCH_MODE=true
        shift
        ;;
    --interval)
        WATCH_INTERVAL="$2"
        shift 2
        ;;
    --top)
        TOP_N="$2"
        shift 2
        ;;
    --cpu-threshold)
        CPU_THRESHOLD="$2"
        shift 2
        ;;
    --mem-threshold)
        MEM_THRESHOLD="$2"
        shift 2
        ;;
    --disk-threshold)
        DISK_THRESHOLD="$2"
        shift 2
        ;;
    --load-threshold)
        LOAD_THRESHOLD="$2"
        shift 2
        ;;
    --webhook)
        WEBHOOK_URL="$2"
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
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

require_jq_if_json "$OUTPUT_JSON" || exit 2

if [[ "$OSTYPE" == "darwin"* ]]; then
    print_warning "Some features require Linux (/proc filesystem)"
fi

if [ "$DRY_RUN" = true ]; then
    echo -e "${BOLD}━━━ System Monitor ━━━${NC}"
    echo ""
    print_warning "DRY RUN — would monitor: CPU, memory, disk, processes"
    print_info "Thresholds: CPU>${CPU_THRESHOLD}% MEM>${MEM_THRESHOLD}% DISK>${DISK_THRESHOLD}% LOAD>${LOAD_THRESHOLD}"
    exit 0
fi

if [ "$WATCH_MODE" = true ]; then
    trap 'echo ""; print_info "Stopped."; exit 0' INT TERM
    while true; do
        clear
        echo -e "${BOLD}━━━ System Monitor — $(date '+%Y-%m-%d %H:%M:%S') ━━━${NC}"
        echo -e "${BLUE}ℹ${NC} Thresholds: CPU>${CPU_THRESHOLD}% MEM>${MEM_THRESHOLD}% DISK>${DISK_THRESHOLD}% LOAD>${LOAD_THRESHOLD}"
        run_checks
        echo ""
        print_info "Refreshing every ${WATCH_INTERVAL}s — Ctrl+C to stop"
        sleep "$WATCH_INTERVAL"
    done
else
    echo -e "${BOLD}━━━ System Monitor ━━━${NC}"
    echo ""
    print_info "Thresholds: CPU>${CPU_THRESHOLD}% MEM>${MEM_THRESHOLD}% DISK>${DISK_THRESHOLD}% LOAD>${LOAD_THRESHOLD}"
    run_checks
fi

# ── Summary ───────────────────────────────────────────────────────────────────

RUN_END_TS=$(date +%s)
DURATION_MS=$(((RUN_END_TS - RUN_START_TS) * 1000))

echo ""
echo -e "${BOLD}━━━ Status ━━━${NC}"
echo ""
if [ "$STATUS" = "ok" ]; then
    print_success "All metrics within thresholds"
else
    print_warning "${#ALERTS[@]} threshold(s) exceeded"
fi

if [ "$OUTPUT_JSON" = true ]; then
    jq -n \
        --arg script "system-monitor.sh" \
        --arg version "1.0.0" \
        --arg timestamp "$(get_iso8601_timestamp)" \
        --arg status "$STATUS" \
        --argjson duration_ms "$DURATION_MS" \
        --argjson alerts "$ALERTS_JSON" \
        --argjson errors "$ERRORS" \
        '{
            script: $script,
            version: $version,
            timestamp: $timestamp,
            status: $status,
            duration_ms: $duration_ms,
            errors: [],
            result: {
                alerts: $alerts,
                errors: $errors
            }
        }' >"$JSON_FILE"
    chmod 600 "$JSON_FILE"
    print_info "JSON: $JSON_FILE"
fi

[ "$STATUS" != "ok" ] && exit 1
exit 0
