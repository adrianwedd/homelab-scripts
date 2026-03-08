#!/usr/bin/env bash
set -u

# firewall-audit.sh - Audit UFW/iptables rules against a baseline
# Version: 1.0.0
# Usage: ./firewall-audit.sh [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

LOG_DIR="${SCRIPT_DIR}/logs/firewall-audit"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RUN_START_TS=$(date +%s)
LOG_FILE="${LOG_DIR}/firewall_audit_${TIMESTAMP}.log"
JSON_FILE="${LOG_DIR}/firewall_audit_${TIMESTAMP}.json"
DEFAULT_BASELINE="${SCRIPT_DIR}/config/firewall-baseline.conf"

# Defaults
BASELINE_FILE=""
SKIP_NMAP=false
DRY_RUN=false
OUTPUT_JSON=false

# Results
ISSUES=0
STATUS="ok"
FINDINGS_JSON="[]"
OPEN_PORTS_JSON="[]"

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

show_help() {
    cat <<'HELP'
firewall-audit.sh - Audit UFW/iptables rules and open ports against a baseline

USAGE:
    ./firewall-audit.sh [OPTIONS]

OPTIONS:
    --baseline <file>    Expected open ports baseline file (default: config/firewall-baseline.conf)
    --skip-nmap          Skip nmap localhost scan (faster, less accurate)
    --dry-run            Show what would be checked without running
    --json               JSON summary output
    --help               Show this help message

BASELINE FILE FORMAT:
    One rule per line: port/proto [comment]
    Example:
        22/tcp    SSH
        80/tcp    HTTP
        443/tcp   HTTPS
        25565/tcp Minecraft
    Lines starting with # are comments.

WHAT IT CHECKS:
    1. UFW status and active rules (if UFW available)
    2. iptables INPUT chain (requires root for full view)
    3. Actually listening ports (ss -tlnup)
    4. Compares listening ports against baseline — flags unexpected ones
    5. nmap localhost scan (optional — authoritative from outside perspective)

EXAMPLES:
    # Basic audit
    sudo ./firewall-audit.sh

    # Against a custom baseline
    sudo ./firewall-audit.sh --baseline /etc/firewall-expected.conf

    # Quick audit without nmap
    ./firewall-audit.sh --skip-nmap

    # JSON output
    sudo ./firewall-audit.sh --json

EXIT CODES:
    0  No unexpected ports found
    1  Unexpected ports or firewall issues detected
    2  Fatal error
HELP
}

record_finding() {
    local severity="$1" description="$2"
    ISSUES=$((ISSUES + 1))
    STATUS="issues"
    local color="$NC"
    [ "$severity" = "ERROR" ] && color="$RED"
    [ "$severity" = "WARN" ] && color="$YELLOW"
    printf "  ${color}[%s]${NC} %s\n" "$severity" "$description"
    log_line "$severity" "$description"
    local escaped
    escaped=$(echo "$description" | sed 's/"/\\"/g')
    local entry
    entry=$(printf '{"severity":"%s","description":"%s"}' "$severity" "$escaped")
    [ "$FINDINGS_JSON" = "[]" ] && FINDINGS_JSON="[$entry]" || FINDINGS_JSON="${FINDINGS_JSON%]},${entry}]"
}

# ── Load baseline ─────────────────────────────────────────────────────────────

load_baseline() {
    declare -ga BASELINE_PORTS=()
    local file="${BASELINE_FILE:-$DEFAULT_BASELINE}"

    if [ ! -f "$file" ]; then
        print_warning "No baseline file found at $file"
        print_info "Create one with expected ports, e.g.:"
        echo "    22/tcp    SSH"
        echo "    80/tcp    HTTP"
        echo "    443/tcp   HTTPS"
        print_info "Or skip baseline comparison by running without --baseline"
        return 1
    fi

    while IFS= read -r line; do
        [[ "$line" =~ ^#|^$ ]] && continue
        local port_proto
        port_proto=$(echo "$line" | awk '{print $1}')
        BASELINE_PORTS+=("$port_proto")
    done <"$file"

    print_info "Baseline: $file (${#BASELINE_PORTS[@]} rules)"
    return 0
}

# ── UFW ───────────────────────────────────────────────────────────────────────

check_ufw() {
    print_section "UFW Status"

    if ! command -v ufw >/dev/null 2>&1; then
        print_info "UFW not installed"
        return
    fi

    local ufw_status
    ufw_status=$(ufw status 2>/dev/null)

    if echo "$ufw_status" | grep -q "Status: active"; then
        print_success "UFW is active"
    else
        record_finding "WARN" "UFW is inactive or disabled — host is unprotected"
    fi

    # Print rules
    echo ""
    echo "$ufw_status" | while read -r line; do
        [ -n "$line" ] && echo "  $line"
    done

    log_line "UFW" "$(echo "$ufw_status" | head -1)"
}

# ── iptables ──────────────────────────────────────────────────────────────────

check_iptables() {
    print_section "iptables INPUT Chain"

    if ! command -v iptables >/dev/null 2>&1; then
        print_info "iptables not found"
        return
    fi

    local rules
    rules=$(iptables -L INPUT -n --line-numbers 2>/dev/null)

    if [ -z "$rules" ]; then
        print_warning "Cannot read iptables rules (run with sudo)"
        return
    fi

    local default_policy
    default_policy=$(echo "$rules" | head -1 | grep -oE 'policy [A-Z]+' | awk '{print $2}')

    if [ "$default_policy" = "ACCEPT" ]; then
        record_finding "WARN" "iptables INPUT default policy is ACCEPT — all traffic allowed unless explicitly blocked"
    else
        print_success "iptables INPUT default policy: $default_policy"
    fi

    echo ""
    echo "$rules" | while read -r line; do
        echo "  $line"
    done
}

# ── Listening ports ───────────────────────────────────────────────────────────

check_listening_ports() {
    print_section "Listening Ports"

    local listening
    listening=$(ss -tlnup 2>/dev/null | tail -n +2)

    if [ -z "$listening" ]; then
        print_warning "Cannot enumerate listening ports (try with sudo for process names)"
        return
    fi

    printf "  %-8s %-25s %-20s %s\n" "PROTO" "LOCAL ADDRESS" "PROCESS" "STATUS"
    printf "  %s\n" "$(printf '─%.0s' {1..70})"

    local baseline_loaded=false
    declare -ga BASELINE_PORTS 2>/dev/null || true
    [ "${#BASELINE_PORTS[@]}" -gt 0 ] && baseline_loaded=true

    echo "$listening" | while IFS= read -r line; do
        local proto local_addr process
        proto=$(echo "$line" | awk '{print $1}')
        local_addr=$(echo "$line" | awk '{print $5}')
        process=$(echo "$line" | grep -oP 'users:\(\("\K[^"]+' || echo "?")

        local port
        port=$(echo "$local_addr" | rev | cut -d: -f1 | rev)

        local flag=""
        local color="$GREEN"

        if [ "$baseline_loaded" = true ]; then
            local matched=false
            for expected in "${BASELINE_PORTS[@]}"; do
                local exp_port exp_proto
                exp_port=$(echo "$expected" | cut -d/ -f1)
                exp_proto=$(echo "$expected" | cut -d/ -f2)
                if [ "$port" = "$exp_port" ] && [ "$proto" = "$exp_proto" ]; then
                    matched=true
                    break
                fi
            done
            if [ "$matched" = false ]; then
                flag=" ${RED}[UNEXPECTED]${NC}"
                color="$YELLOW"
                record_finding "WARN" "Unexpected open port: ${port}/${proto} (process: $process)"
            fi
        fi

        printf "  %-8s %-25s %-20s%b%s\n" "$proto" "$local_addr" "${process:0:20}" "$flag" ""

        # Append to open ports JSON
        local entry
        entry=$(printf '{"proto":"%s","port":%s,"addr":"%s","process":"%s"}' \
            "$proto" "$port" "$local_addr" "$process")
    done

    log_line "PORTS" "checked"
}

# ── nmap localhost ────────────────────────────────────────────────────────────

check_nmap() {
    print_section "nmap Localhost Scan"

    if ! command -v nmap >/dev/null 2>&1; then
        print_warning "nmap not installed — skipping (install with: sudo apt install nmap)"
        return
    fi

    print_info "Scanning 127.0.0.1 (TCP SYN scan)..."
    local nmap_out
    nmap_out=$(nmap -sS -p- --open -T4 127.0.0.1 2>/dev/null || nmap -sT --open -T4 127.0.0.1 2>/dev/null)

    echo "$nmap_out" | grep -E "^[0-9]+/|Nmap scan" | while read -r line; do
        echo "  $line"
    done

    local open_count
    open_count=$(echo "$nmap_out" | grep -c "^[0-9]" || echo 0)
    print_info "nmap found $open_count open port(s) on localhost"
    log_line "NMAP" "$open_count ports open on localhost"
}

# ── Parse args ────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
    --baseline)
        BASELINE_FILE="$2"
        shift 2
        ;;
    --skip-nmap)
        SKIP_NMAP=true
        shift
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

echo -e "${BOLD}━━━ Firewall Audit ━━━${NC}"
echo ""
print_info "Log: $LOG_FILE"

if [ "$DRY_RUN" = true ]; then
    print_warning "DRY RUN — would check UFW, iptables, listening ports, and nmap"
    exit 0
fi

load_baseline || true
check_ufw
check_iptables
check_listening_ports
[ "$SKIP_NMAP" = false ] && check_nmap

# ── Summary ───────────────────────────────────────────────────────────────────

RUN_END_TS=$(date +%s)
DURATION_MS=$(((RUN_END_TS - RUN_START_TS) * 1000))

echo ""
echo -e "${BOLD}━━━ Summary ━━━${NC}"
echo ""
if [ "$STATUS" = "ok" ]; then
    print_success "No unexpected ports or firewall issues found"
else
    print_warning "$ISSUES issue(s) detected — review above"
fi

print_info "Log: $LOG_FILE"

if [ "$OUTPUT_JSON" = true ]; then
    jq -n \
        --arg script "firewall-audit.sh" \
        --arg version "1.0.0" \
        --arg timestamp "$(get_iso8601_timestamp)" \
        --arg status "$STATUS" \
        --argjson duration_ms "$DURATION_MS" \
        --argjson issues "$ISSUES" \
        --argjson findings "$FINDINGS_JSON" \
        '{
            script: $script,
            version: $version,
            timestamp: $timestamp,
            status: $status,
            duration_ms: $duration_ms,
            errors: [],
            result: {
                issues: $issues,
                findings: $findings
            }
        }' >"$JSON_FILE"
    chmod 600 "$JSON_FILE"
    print_info "JSON: $JSON_FILE"
fi

[ "$STATUS" != "ok" ] && exit 1
exit 0
