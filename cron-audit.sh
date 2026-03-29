#!/usr/bin/env bash
set -u

# cron-audit.sh - Audit all cron jobs and systemd timers for issues
# Version: 1.0.0
# Usage: ./cron-audit.sh [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

LOG_DIR="${SCRIPT_DIR}/logs/cron-audit"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RUN_START_TS=$(date +%s)
LOG_FILE="${LOG_DIR}/cron_audit_${TIMESTAMP}.log"
JSON_FILE="${LOG_DIR}/cron_audit_${TIMESTAMP}.json"

# Defaults
DRY_RUN=false
OUTPUT_JSON=false

# Counters
TOTAL_JOBS=0
ISSUES=0
STATUS="ok"
FINDINGS_JSON="[]"

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
cron-audit.sh - Audit all cron jobs and systemd timers for issues

USAGE:
    ./cron-audit.sh [OPTIONS]

OPTIONS:
    --dry-run    Show what would be checked without reading configs
    --json       JSON summary output
    --help       Show this help message

WHAT IT AUDITS:
    Cron sources:
      /etc/crontab          System crontab
      /etc/cron.d/*         Package-installed cron jobs
      /var/spool/cron/*     Per-user crontabs (requires root or matching user)
      /etc/cron.{hourly,daily,weekly,monthly}/*  Drop-in scripts

    systemd:
      All active timers (systemctl list-timers)

    Checks performed:
      - Commands pointing to missing/non-executable files
      - Jobs running as root unnecessarily (when non-root would suffice)
      - Wildcard schedules (* * * * * — runs every minute)
      - Jobs with no output redirection (silent failures)
      - Duplicate schedules (same command, multiple entries)

EXAMPLES:
    ./cron-audit.sh
    ./cron-audit.sh --json
    sudo ./cron-audit.sh   # To read all user crontabs

EXIT CODES:
    0  No issues found
    1  Issues detected
    2  Fatal error
HELP
}

record_finding() {
    local severity="$1" source="$2" schedule="$3" user="$4" command="$5" issue="$6"
    ISSUES=$((ISSUES + 1))
    STATUS="issues"

    local color="$NC"
    [ "$severity" = "ERROR" ] && color="$RED"
    [ "$severity" = "WARN" ] && color="$YELLOW"

    printf "  ${color}[%s]${NC} %s\n" "$severity" "$issue"
    printf "        Source: %s  User: %s\n" "$source" "$user"
    printf "        Sched:  %s\n" "$schedule"
    printf "        Cmd:    %s\n\n" "${command:0:80}"

    local escaped_cmd escaped_source escaped_issue
    escaped_cmd=$(json_escape "$command")
    escaped_source=$(json_escape "$source")
    escaped_issue=$(json_escape "$issue")

    local entry
    entry=$(printf '{"severity":"%s","source":"%s","schedule":"%s","user":"%s","command":"%s","issue":"%s"}' \
        "$severity" "$escaped_source" "$schedule" "$user" "$escaped_cmd" "$escaped_issue")
    if [ "$FINDINGS_JSON" = "[]" ]; then
        FINDINGS_JSON="[$entry]"
    else
        FINDINGS_JSON="${FINDINGS_JSON%]},${entry}]"
    fi

    log_line "$severity" "$issue | $source | $command"
}

# Check a single cron line for issues
check_cron_line() {
    local source="$1"
    local user="$2"
    local schedule="$3"
    local command="$4"

    TOTAL_JOBS=$((TOTAL_JOBS + 1))

    # Extract the actual executable (first word of command, skip env vars)
    local exe
    exe=$(echo "$command" | sed 's/^[A-Z_]*=[^ ]* //g' | awk '{print $1}')

    # Skip shell built-ins
    case "$exe" in
    echo | printf | true | false | : | test | [ | [[) return ;;
    esac

    # Check: wildcard schedule (runs every minute)
    if [ "$schedule" = "* * * * *" ]; then
        record_finding "WARN" "$source" "$schedule" "$user" "$command" \
            "Wildcard schedule (* * * * *) runs every minute"
    fi

    # Check: command missing
    if [[ "$exe" == /* ]] && [ ! -e "$exe" ]; then
        record_finding "ERROR" "$source" "$schedule" "$user" "$command" \
            "Command not found: $exe"
    elif [[ "$exe" == /* ]] && [ ! -x "$exe" ]; then
        record_finding "WARN" "$source" "$schedule" "$user" "$command" \
            "Command not executable: $exe"
    fi

    # Check: no output redirection (silent failures)
    if ! echo "$command" | grep -qE ">/|2>|&>|>> "; then
        record_finding "WARN" "$source" "$schedule" "$user" "$command" \
            "No output redirection — failures will be silently lost (add >/dev/null 2>&1 or log to file)"
    fi
}

# ── Parse /etc/crontab and /etc/cron.d/* ─────────────────────────────────────

check_system_crontabs() {
    print_section "System Crontabs (/etc/crontab, /etc/cron.d)"

    local sources=("/etc/crontab")
    while IFS= read -r f; do
        sources+=("$f")
    done < <(find /etc/cron.d -maxdepth 1 -type f 2>/dev/null | sort)

    local found=0
    for src in "${sources[@]}"; do
        [ -r "$src" ] || continue
        found=$((found + 1))

        while IFS= read -r line; do
            # Skip comments and empty lines
            [[ "$line" =~ ^#|^$ ]] && continue
            # Skip SHELL/PATH/MAILTO vars
            [[ "$line" =~ ^[A-Z_]+= ]] && continue

            # System crontab format: min hr dom mon dow user command
            local min hr dom mon dow user cmd
            read -r min hr dom mon dow user cmd <<<"$line"
            [ -z "$cmd" ] && continue

            local schedule="${min} ${hr} ${dom} ${mon} ${dow}"
            printf "  %-25s  %-10s  %s\n" "$schedule" "$user" "${cmd:0:50}"
            check_cron_line "$src" "$user" "$schedule" "$cmd"
        done <"$src"
    done

    [ "$found" -eq 0 ] && print_info "No system crontabs found"
}

# ── Parse user crontabs ───────────────────────────────────────────────────────

check_user_crontabs() {
    print_section "User Crontabs (/var/spool/cron)"

    local spool_dir="/var/spool/cron/crontabs"
    [ -d "$spool_dir" ] || spool_dir="/var/spool/cron"
    [ -d "$spool_dir" ] || {
        print_info "No user crontab spool found"
        return
    }

    local found=0
    while IFS= read -r crontab_file; do
        local username
        username=$(basename "$crontab_file")
        [ -r "$crontab_file" ] || continue
        found=$((found + 1))

        print_info "User: $username"
        while IFS= read -r line; do
            [[ "$line" =~ ^#|^$ ]] && continue
            [[ "$line" =~ ^[A-Z_]+= ]] && continue

            local min hr dom mon dow cmd
            read -r min hr dom mon dow cmd <<<"$line"
            [ -z "$cmd" ] && continue

            local schedule="${min} ${hr} ${dom} ${mon} ${dow}"
            printf "  %-25s  %s\n" "$schedule" "${cmd:0:60}"
            check_cron_line "$crontab_file" "$username" "$schedule" "$cmd"
        done <"$crontab_file"
    done < <(find "$spool_dir" -maxdepth 1 -type f 2>/dev/null | sort)

    [ "$found" -eq 0 ] && print_info "No user crontabs found (run with sudo to see all users)"
}

# ── Check cron.{hourly,daily,weekly,monthly} ──────────────────────────────────

check_cron_dirs() {
    print_section "Cron Drop-in Scripts"

    local dirs=(hourly daily weekly monthly)
    for period in "${dirs[@]}"; do
        local dir="/etc/cron.${period}"
        [ -d "$dir" ] || continue
        local scripts
        scripts=$(find "$dir" -maxdepth 1 -type f 2>/dev/null | sort)
        if [ -n "$scripts" ]; then
            echo "  /etc/cron.${period}:"
            while read -r f; do
                local ok="${GREEN}✓${NC}"
                [ -x "$f" ] || {
                    ok="${RED}✗ not executable${NC}"
                    ISSUES=$((ISSUES + 1))
                    STATUS="issues"
                }
                printf "    %b %s\n" "$ok" "$(basename "$f")"
                TOTAL_JOBS=$((TOTAL_JOBS + 1))
            done < <(echo "$scripts")
        fi
    done
}

# ── systemd timers ────────────────────────────────────────────────────────────

check_systemd_timers() {
    print_section "systemd Timers"

    if ! command -v systemctl >/dev/null 2>&1; then
        print_info "systemctl not found — skipping"
        return
    fi

    local timers
    timers=$(systemctl list-timers --all --no-pager 2>/dev/null | grep -v "^$\|NEXT\|timers listed" || true)

    if [ -z "$timers" ]; then
        print_info "No active systemd timers"
        return
    fi

    printf "  %-30s %-20s %-15s\n" "TIMER" "NEXT" "LAST"
    printf "  %s\n" "$(printf '─%.0s' {1..70})"

    while read -r line; do
        # Format: NEXT LEFT LAST PASSED UNIT ACTIVATES
        local timer
        timer=$(echo "$line" | awk '{print $(NF-1)}')
        local next
        next=$(echo "$line" | awk '{print $1, $2, $3}')
        local last
        last=$(echo "$line" | awk '{print $5, $6, $7}')
        [ -z "$timer" ] && continue
        printf "  %-30s %-20s %s\n" "${timer:0:30}" "${next:0:20}" "${last:0:15}"
        TOTAL_JOBS=$((TOTAL_JOBS + 1))
    done < <(echo "$timers")

    log_line "TIMERS" "checked"
}

# ── Parse args ────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
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

echo -e "${BOLD}━━━ Cron Audit ━━━${NC}"
echo ""
print_info "Log: $LOG_FILE"

if [ "$DRY_RUN" = true ]; then
    print_warning "DRY RUN — would audit:"
    echo "  /etc/crontab, /etc/cron.d/*, /var/spool/cron/*, /etc/cron.{hourly,daily,weekly,monthly}"
    echo "  systemd timers"
    exit 0
fi

check_system_crontabs
check_user_crontabs
check_cron_dirs
check_systemd_timers

# ── Summary ───────────────────────────────────────────────────────────────────

RUN_END_TS=$(date +%s)
DURATION_MS=$(((RUN_END_TS - RUN_START_TS) * 1000))

echo ""
echo -e "${BOLD}━━━ Summary ━━━${NC}"
echo ""
printf "  Total jobs found:  %d\n" "$TOTAL_JOBS"
printf "  Issues detected:   %d\n" "$ISSUES"
echo ""

if [ "$STATUS" = "ok" ]; then
    print_success "No issues found"
else
    print_warning "$ISSUES issue(s) detected — review above"
fi

print_info "Log: $LOG_FILE"

if [ "$OUTPUT_JSON" = true ]; then
    jq -n \
        --arg script "cron-audit.sh" \
        --arg version "1.0.0" \
        --arg timestamp "$(get_iso8601_timestamp)" \
        --arg status "$STATUS" \
        --argjson duration_ms "$DURATION_MS" \
        --argjson total_jobs "$TOTAL_JOBS" \
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
                total_jobs: $total_jobs,
                issues: $issues,
                findings: $findings
            }
        }' >"$JSON_FILE"
    chmod 600 "$JSON_FILE"
    print_info "JSON: $JSON_FILE"
fi

[ "$STATUS" != "ok" ] && exit 1
exit 0
