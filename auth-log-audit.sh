#!/usr/bin/env bash
set -u

# auth-log-audit.sh - Audit SSH authentication logs for threats and anomalies
# Version: 1.0.0
# Usage: ./auth-log-audit.sh [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

LOG_DIR="${SCRIPT_DIR}/logs/auth-audit"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RUN_START_TS=$(date +%s)
LOG_FILE="${LOG_DIR}/auth_audit_${TIMESTAMP}.log"
JSON_FILE="${LOG_DIR}/auth_audit_${TIMESTAMP}.json"

# Defaults
DAYS=7
DRY_RUN=false
OUTPUT_JSON=false
TOP_ATTACKERS=10
ALERT_THRESHOLD=50 # alert if any IP has > N failed attempts

# Results
FAILED_ATTEMPTS=0
SUCCESSFUL_LOGINS=0
UNIQUE_ATTACKERS=0
SUDO_EVENTS=0
NEW_USERS=0
STATUS="ok"

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
auth-log-audit.sh - Audit SSH authentication logs for threats and anomalies

USAGE:
    ./auth-log-audit.sh [OPTIONS]

OPTIONS:
    --days <n>           Look back N days (default: 7)
    --top <n>            Show top N attacking IPs (default: 10)
    --alert-threshold <n>  Alert if any IP has > N failures (default: 50)
    --dry-run            Show what would be analysed without reading logs
    --json               JSON summary output
    --help               Show this help message

LOG FILES:
    Reads (in order, whichever exist):
      /var/log/auth.log        (Debian/Ubuntu)
      /var/log/auth.log.1
      /var/log/secure          (RHEL/CentOS)
      /var/log/secure.1
    Requires read access — run with sudo if logs are root-only.

WHAT IT REPORTS:
    - Failed SSH login attempts (brute force detection)
    - Top N attacking IPs with attempt counts
    - Successful logins: user, IP, timestamp
    - sudo usage: who, what command
    - New user/group creation events
    - Invalid usernames tried

EXAMPLES:
    # Audit last 7 days
    ./auth-log-audit.sh

    # Last 30 days, top 20 attackers
    ./auth-log-audit.sh --days 30 --top 20

    # Alert if any IP has > 100 failures
    ./auth-log-audit.sh --alert-threshold 100

    # JSON output for SIEM
    sudo ./auth-log-audit.sh --json

EXIT CODES:
    0  No significant threats
    1  High-volume attack detected (above threshold)
    2  Fatal error (no log files found)
HELP
}

# ── Find auth log files ───────────────────────────────────────────────────────

find_log_files() {
    local candidates=(
        "/var/log/auth.log"
        "/var/log/auth.log.1"
        "/var/log/secure"
        "/var/log/secure.1"
    )
    local found=()
    for f in "${candidates[@]}"; do
        [ -r "$f" ] && found+=("$f")
    done
    # Also check for rotated gz files within date range
    for pattern in "/var/log/auth.log.*.gz" "/var/log/secure.*.gz"; do
        for f in $pattern; do
            [ -r "$f" ] && found+=("$f")
        done
    done
    echo "${found[@]:-}"
}

# ── Read all log content (handles .gz) ───────────────────────────────────────

read_logs() {
    local files=("$@")
    for f in "${files[@]}"; do
        case "$f" in
        *.gz) zcat "$f" 2>/dev/null ;;
        *) cat "$f" 2>/dev/null ;;
        esac
    done
}

# ── Parse failed attempts ─────────────────────────────────────────────────────

analyze_failures() {
    local content="$1"

    print_section "Failed SSH Attempts"

    # Count total failures
    FAILED_ATTEMPTS=$(echo "$content" | grep -cE "Failed (password|publickey)|Invalid user|authentication failure" 2>/dev/null || echo 0)

    # Top attacking IPs
    local ip_counts
    ip_counts=$(echo "$content" |
        grep -E "Failed (password|publickey)|Invalid user" |
        grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' |
        sort | uniq -c | sort -rn |
        head -"$TOP_ATTACKERS")

    UNIQUE_ATTACKERS=$(echo "$content" |
        grep -E "Failed (password|publickey)|Invalid user" |
        grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' |
        sort -u | wc -l)

    print_info "Total failures: $FAILED_ATTEMPTS"
    print_info "Unique source IPs: $UNIQUE_ATTACKERS"

    if [ -n "$ip_counts" ]; then
        echo ""
        printf "  %-8s  %s\n" "COUNT" "IP ADDRESS"
        printf "  %s\n" "$(printf '─%.0s' {1..40})"
        echo "$ip_counts" | while read -r count ip; do
            local color="$NC"
            [ "$count" -ge "$ALERT_THRESHOLD" ] && {
                color="$RED"
                STATUS="alert"
            }
            [ "$count" -ge "$((ALERT_THRESHOLD / 2))" ] && [ "$count" -lt "$ALERT_THRESHOLD" ] && color="$YELLOW"
            printf "  ${color}%-8s  %s${NC}\n" "$count" "$ip"
        done
    fi

    # Invalid usernames
    local invalid_users
    invalid_users=$(echo "$content" |
        grep "Invalid user" |
        grep -oP "Invalid user \K\S+" |
        sort | uniq -c | sort -rn | head -10)

    if [ -n "$invalid_users" ]; then
        echo ""
        print_info "Top invalid usernames tried:"
        echo "$invalid_users" | while read -r count user; do
            printf "  %-8s  %s\n" "$count" "$user"
        done
    fi

    log_line "FAILURES" "total=${FAILED_ATTEMPTS} unique_ips=${UNIQUE_ATTACKERS}"
}

# ── Parse successful logins ───────────────────────────────────────────────────

analyze_successes() {
    local content="$1"

    print_section "Successful Logins"

    local successes
    successes=$(echo "$content" |
        grep -E "Accepted (password|publickey|keyboard-interactive)" |
        tail -50)

    SUCCESSFUL_LOGINS=$(echo "$successes" | grep -c "Accepted" 2>/dev/null || echo 0)
    print_info "Total successful logins: $SUCCESSFUL_LOGINS"

    if [ -n "$successes" ]; then
        echo ""
        printf "  %-12s %-16s %-15s  %s\n" "METHOD" "USER" "FROM IP" "TIMESTAMP"
        printf "  %s\n" "$(printf '─%.0s' {1..65})"
        echo "$successes" | while read -r line; do
            local method user ip ts
            ts=$(echo "$line" | awk '{print $1, $2, $3}')
            method=$(echo "$line" | grep -oE 'Accepted \S+' | awk '{print $2}')
            user=$(echo "$line" | grep -oP 'for \K\S+')
            ip=$(echo "$line" | grep -oE 'from ([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '{print $2}')
            printf "  %-12s %-16s %-15s  %s\n" "${method:-?}" "${user:-?}" "${ip:-?}" "${ts:-?}"
        done | tail -20
    fi

    log_line "SUCCESSES" "total=${SUCCESSFUL_LOGINS}"
}

# ── Sudo events ───────────────────────────────────────────────────────────────

analyze_sudo() {
    local content="$1"

    print_section "Sudo Usage"

    local sudo_events
    sudo_events=$(echo "$content" |
        grep "sudo:" |
        grep "COMMAND=" |
        tail -30)

    SUDO_EVENTS=$(echo "$sudo_events" | grep -c "COMMAND=" 2>/dev/null || echo 0)
    print_info "Sudo events (last 30): $SUDO_EVENTS"

    if [ -n "$sudo_events" ]; then
        echo ""
        echo "$sudo_events" | while read -r line; do
            local user ts cmd
            ts=$(echo "$line" | awk '{print $1, $2, $3}')
            user=$(echo "$line" | grep -oP '^\S+ \S+ \S+ \K\S+(?=\s*:)')
            cmd=$(echo "$line" | grep -oP 'COMMAND=\K.*')
            printf "  [%s] %s → %s\n" "${ts:-?}" "${user:-?}" "${cmd:0:60}"
        done
    fi

    log_line "SUDO" "events=${SUDO_EVENTS}"
}

# ── User/group creation ───────────────────────────────────────────────────────

analyze_user_changes() {
    local content="$1"

    print_section "User & Group Changes"

    local user_events
    user_events=$(echo "$content" |
        grep -E "useradd|userdel|groupadd|groupdel|passwd.*changed|new user|new group" |
        head -20)

    NEW_USERS=$(echo "$user_events" | grep -c "new user" 2>/dev/null || echo 0)

    if [ -n "$user_events" ]; then
        print_warning "User/group changes detected:"
        echo "$user_events" | while read -r line; do
            local ts
            ts=$(echo "$line" | awk '{print $1, $2, $3}')
            echo "  [$ts] ${line##*]: }"
        done
    else
        print_success "No user/group changes in this period"
    fi

    log_line "USER_CHANGES" "new_users=${NEW_USERS}"
}

# ── Parse args ────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
    --days)
        DAYS="$2"
        shift 2
        ;;
    --top)
        TOP_ATTACKERS="$2"
        shift 2
        ;;
    --alert-threshold)
        ALERT_THRESHOLD="$2"
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

echo -e "${BOLD}━━━ Auth Log Audit ━━━${NC}"
echo ""
print_info "Period:  last ${DAYS} days"
print_info "Alert:   IPs with > ${ALERT_THRESHOLD} failures"
print_info "Log:     $LOG_FILE"

if [ "$DRY_RUN" = true ]; then
    print_warning "DRY RUN — would analyse: /var/log/auth.log (and rotated variants)"
    exit 0
fi

# Find log files
read -ra LOG_FILES <<<"$(find_log_files)"

if [ ${#LOG_FILES[@]} -eq 0 ]; then
    print_error "No readable auth log files found. Try running with sudo."
    exit 2
fi

print_info "Reading: ${LOG_FILES[*]}"

# Read and filter to last N days
echo ""
print_info "Loading logs..."
LOG_CONTENT=$(read_logs "${LOG_FILES[@]}" |
    grep -E "$(date -d "-${DAYS} days" '+%b' 2>/dev/null || date -v"-${DAYS}d" '+%b' 2>/dev/null || echo 'Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec')" \
        2>/dev/null || true)

if [ -z "$LOG_CONTENT" ]; then
    print_warning "No log entries found for the past ${DAYS} days"
    exit 0
fi

analyze_failures "$LOG_CONTENT"
analyze_successes "$LOG_CONTENT"
analyze_sudo "$LOG_CONTENT"
analyze_user_changes "$LOG_CONTENT"

# ── Summary ───────────────────────────────────────────────────────────────────

RUN_END_TS=$(date +%s)
DURATION_MS=$(((RUN_END_TS - RUN_START_TS) * 1000))

echo ""
echo -e "${BOLD}━━━ Summary ━━━${NC}"
echo ""
printf "  Failed SSH attempts:    %d\n" "$FAILED_ATTEMPTS"
printf "  Unique attacking IPs:   %d\n" "$UNIQUE_ATTACKERS"
printf "  Successful logins:      %d\n" "$SUCCESSFUL_LOGINS"
printf "  Sudo events:            %d\n" "$SUDO_EVENTS"
printf "  New users created:      %d\n" "$NEW_USERS"
echo ""

if [ "$STATUS" = "ok" ]; then
    print_success "No high-volume attacks detected"
else
    print_warning "High-volume attack detected — review top IPs above and consider blocking with ufw/fail2ban"
fi

print_info "Log: $LOG_FILE"

if [ "$OUTPUT_JSON" = true ]; then
    jq -n \
        --arg script "auth-log-audit.sh" \
        --arg version "1.0.0" \
        --arg timestamp "$(get_iso8601_timestamp)" \
        --arg status "$STATUS" \
        --argjson duration_ms "$DURATION_MS" \
        --argjson days "$DAYS" \
        --argjson failed "$FAILED_ATTEMPTS" \
        --argjson unique_ips "$UNIQUE_ATTACKERS" \
        --argjson successful "$SUCCESSFUL_LOGINS" \
        --argjson sudo_events "$SUDO_EVENTS" \
        --argjson new_users "$NEW_USERS" \
        '{
            script: $script,
            version: $version,
            timestamp: $timestamp,
            status: $status,
            duration_ms: $duration_ms,
            errors: [],
            result: {
                period_days: $days,
                failed_attempts: $failed,
                unique_attacking_ips: $unique_ips,
                successful_logins: $successful,
                sudo_events: $sudo_events,
                new_users_created: $new_users
            }
        }' >"$JSON_FILE"
    chmod 600 "$JSON_FILE"
    print_info "JSON: $JSON_FILE"
fi

[ "$STATUS" != "ok" ] && exit 1
exit 0
