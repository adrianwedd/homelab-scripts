#!/usr/bin/env bash
set -u

# log-manager.sh - Rotate, compress, and prune logs across scripts and system
# Version: 1.0.0
# Usage: ./log-manager.sh [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

LOG_DIR="${SCRIPT_DIR}/logs/log-manager"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RUN_START_TS=$(date +%s)
LOG_FILE="${LOG_DIR}/log_manager_${TIMESTAMP}.log"
JSON_FILE="${LOG_DIR}/log_manager_${TIMESTAMP}.json"

# Defaults
RETENTION_DAYS=30
COMPRESS_DAYS=7
DRY_RUN=false
OUTPUT_JSON=false
FORCE_YES=false
CUSTOM_DIRS=""

# Counters
BYTES_FREED=0
FILES_COMPRESSED=0
FILES_DELETED=0
ERRORS=0
ACTIONS_JSON="[]"

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
log-manager.sh - Rotate, compress, and prune logs across scripts and system

USAGE:
    ./log-manager.sh [OPTIONS]

OPTIONS:
    --retention-days <n>  Delete logs older than N days (default: 30)
    --compress-days <n>   Compress logs older than N days (default: 7)
    --dirs <paths>        Colon-separated extra directories to manage
    -y, --yes             Skip confirmation prompts
    --dry-run             Show what would happen without making changes
    --json                JSON summary output
    --help                Show this help message

WHAT IT MANAGES:
    - Script logs:     ./logs/**/*.log
    - rclone log:      ~/rclone-sync.log (rotates at 50MB)
    - systemd journal: vacuums to retention limit
    - Common app logs: /var/log/syslog, auth.log (compress only, no delete)

ACTIONS:
    1. Compress .log files older than --compress-days with gzip
    2. Delete .log and .log.gz files older than --retention-days
    3. Vacuum systemd journal to --retention-days
    4. Rotate oversized rclone log (>50MB)

EXAMPLES:
    # Preview what would be cleaned
    ./log-manager.sh --dry-run

    # Clean with 14-day retention
    ./log-manager.sh --retention-days 14

    # Also manage custom log dirs
    ./log-manager.sh --dirs "/var/log/myapp:/opt/app/logs"

EXIT CODES:
    0  Success
    1  Completed with errors
    2  Fatal error
HELP
}

bytes_to_human() {
    local bytes="$1"
    if [ "$bytes" -ge 1073741824 ]; then
        awk "BEGIN {printf \"%.2f GB\", $bytes/1073741824}"
    elif [ "$bytes" -ge 1048576 ]; then
        awk "BEGIN {printf \"%.2f MB\", $bytes/1048576}"
    elif [ "$bytes" -ge 1024 ]; then
        awk "BEGIN {printf \"%.1f KB\", $bytes/1024}"
    else
        echo "${bytes} B"
    fi
}

get_size_bytes() {
    local path="$1"
    if [ -f "$path" ]; then
        stat -c%s "$path" 2>/dev/null || echo 0
    elif [ -d "$path" ]; then
        du -sb "$path" 2>/dev/null | awk '{print $1}' || echo 0
    else
        echo 0
    fi
}

record_action() {
    local action="$1" path="$2" bytes="${3:-0}"
    local escaped_path
    escaped_path=$(echo "$path" | sed 's/"/\\"/g')
    local entry
    entry=$(printf '{"action":"%s","path":"%s","bytes":%s}' "$action" "$escaped_path" "$bytes")
    if [ "$ACTIONS_JSON" = "[]" ]; then
        ACTIONS_JSON="[$entry]"
    else
        ACTIONS_JSON="${ACTIONS_JSON%]},${entry}]"
    fi
}

# ── Compress old logs ─────────────────────────────────────────────────────────

compress_logs() {
    local dir="$1"
    local label="${2:-$dir}"

    [ -d "$dir" ] || return

    local count=0
    local bytes_before=0

    while IFS= read -r f; do
        local sz
        sz=$(get_size_bytes "$f")
        bytes_before=$((bytes_before + sz))

        if [ "$DRY_RUN" = true ]; then
            echo -e "  ${YELLOW}[DRY RUN]${NC} would compress: $f ($(bytes_to_human "$sz"))"
            count=$((count + 1))
        else
            gzip -f "$f" 2>/dev/null && {
                local sz_after
                sz_after=$(get_size_bytes "${f}.gz")
                local saved=$((sz - sz_after))
                BYTES_FREED=$((BYTES_FREED + saved))
                FILES_COMPRESSED=$((FILES_COMPRESSED + 1))
                record_action "compressed" "$f" "$saved"
                count=$((count + 1))
                log_line "COMPRESSED" "$f (saved $(bytes_to_human "$saved"))"
            } || print_error "Failed to compress: $f"
        fi
    done < <(find "$dir" -name "*.log" -not -name "*.gz" -mtime "+${COMPRESS_DAYS}" -type f 2>/dev/null)

    [ "$count" -gt 0 ] && print_info "Compressed $count file(s) in $label"
}

# ── Delete old logs ───────────────────────────────────────────────────────────

prune_logs() {
    local dir="$1"
    local label="${2:-$dir}"

    [ -d "$dir" ] || return

    local count=0

    while IFS= read -r f; do
        local sz
        sz=$(get_size_bytes "$f")

        if [ "$DRY_RUN" = true ]; then
            echo -e "  ${YELLOW}[DRY RUN]${NC} would delete: $f ($(bytes_to_human "$sz"))"
            count=$((count + 1))
        else
            rm -f "$f" && {
                BYTES_FREED=$((BYTES_FREED + sz))
                FILES_DELETED=$((FILES_DELETED + 1))
                record_action "deleted" "$f" "$sz"
                count=$((count + 1))
                log_line "DELETED" "$f"
            } || print_error "Failed to delete: $f"
        fi
    done < <(find "$dir" \( -name "*.log" -o -name "*.log.gz" \) -mtime "+${RETENTION_DAYS}" -type f 2>/dev/null)

    [ "$count" -gt 0 ] && print_info "Deleted $count old log file(s) from $label"
}

# ── Script log dirs ───────────────────────────────────────────────────────────

manage_script_logs() {
    print_section "Script Logs (./logs/)"

    local total_sz
    total_sz=$(get_size_bytes "${SCRIPT_DIR}/logs")
    print_info "Current size: $(bytes_to_human "$total_sz")"

    compress_logs "${SCRIPT_DIR}/logs" "./logs"
    prune_logs "${SCRIPT_DIR}/logs" "./logs"

    # Show log dir breakdown
    echo ""
    find "${SCRIPT_DIR}/logs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | while read -r subdir; do
        local sz
        sz=$(get_size_bytes "$subdir")
        local count
        count=$(find "$subdir" -type f 2>/dev/null | wc -l)
        printf "  %-40s %s (%d files)\n" "$(basename "$subdir")/" "$(bytes_to_human "$sz")" "$count"
    done
}

# ── rclone log rotation ───────────────────────────────────────────────────────

manage_rclone_log() {
    print_section "rclone Log"

    local rclone_log="${HOME}/rclone-sync.log"
    if [ ! -f "$rclone_log" ]; then
        print_info "rclone log not found: $rclone_log"
        return
    fi

    local sz
    sz=$(get_size_bytes "$rclone_log")
    local sz_mb
    sz_mb=$(awk "BEGIN {printf \"%.1f\", $sz/1048576}")
    print_info "rclone log: ${sz_mb}MB — $rclone_log"

    # Rotate if > 50MB
    if [ "$sz" -gt 52428800 ]; then
        local archive="${rclone_log}.${TIMESTAMP}.gz"
        if [ "$DRY_RUN" = true ]; then
            print_warning "[DRY RUN] would rotate: $rclone_log → $archive"
        else
            gzip -c "$rclone_log" >"$archive" && {
                : >"$rclone_log"
                BYTES_FREED=$((BYTES_FREED + sz))
                FILES_COMPRESSED=$((FILES_COMPRESSED + 1))
                record_action "rotated" "$rclone_log" "$sz"
                print_success "Rotated rclone log (${sz_mb}MB) → $archive"
            } || print_error "Failed to rotate rclone log"
        fi
    else
        print_success "rclone log within size limit (${sz_mb}MB < 50MB)"
    fi
}

# ── systemd journal ───────────────────────────────────────────────────────────

manage_journal() {
    print_section "systemd Journal"

    if ! command -v journalctl >/dev/null 2>&1; then
        print_info "journalctl not found — skipping"
        return
    fi

    local journal_sz
    journal_sz=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)? [KMGTP]?B' | tail -1 || echo "unknown")
    print_info "Journal disk usage: $journal_sz"

    if [ "$DRY_RUN" = true ]; then
        print_warning "[DRY RUN] would vacuum journal to ${RETENTION_DAYS} days retention"
    else
        local before_sz
        before_sz=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo 0)

        journalctl --vacuum-time="${RETENTION_DAYS}d" 2>/dev/null && {
            local after_sz
            after_sz=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo 0)
            local saved=$((before_sz - after_sz))
            [ "$saved" -gt 0 ] && BYTES_FREED=$((BYTES_FREED + saved))
            record_action "journal_vacuum" "systemd-journal" "$saved"
            print_success "Journal vacuumed to ${RETENTION_DAYS}-day retention"
        } || print_warning "Journal vacuum failed (may need sudo)"
    fi
}

# ── Custom dirs ───────────────────────────────────────────────────────────────

manage_custom_dirs() {
    [ -z "$CUSTOM_DIRS" ] && return

    print_section "Custom Log Directories"

    IFS=':' read -ra dirs <<<"$CUSTOM_DIRS"
    for dir in "${dirs[@]}"; do
        if [ ! -d "$dir" ]; then
            print_warning "Directory not found: $dir"
            continue
        fi
        print_info "Managing: $dir"
        compress_logs "$dir" "$dir"
        prune_logs "$dir" "$dir"
    done
}

# ── Parse args ────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
    --retention-days)
        RETENTION_DAYS="$2"
        shift 2
        ;;
    --compress-days)
        COMPRESS_DAYS="$2"
        shift 2
        ;;
    --dirs)
        CUSTOM_DIRS="$2"
        shift 2
        ;;
    -y | --yes)
        FORCE_YES=true
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

echo -e "${BOLD}━━━ Log Manager ━━━${NC}"
echo ""
print_info "Retention: ${RETENTION_DAYS} days"
print_info "Compress after: ${COMPRESS_DAYS} days"
print_info "Log: $LOG_FILE"
[ "$DRY_RUN" = true ] && print_warning "DRY RUN — no changes will be made"

# ── Run ───────────────────────────────────────────────────────────────────────

manage_script_logs
manage_rclone_log
manage_journal
manage_custom_dirs

# ── Summary ───────────────────────────────────────────────────────────────────

RUN_END_TS=$(date +%s)
DURATION_MS=$(((RUN_END_TS - RUN_START_TS) * 1000))

echo ""
echo -e "${BOLD}━━━ Summary ━━━${NC}"
echo ""

if [ "$DRY_RUN" = true ]; then
    print_warning "DRY RUN — no changes made"
else
    printf "  Files compressed:  %d\n" "$FILES_COMPRESSED"
    printf "  Files deleted:     %d\n" "$FILES_DELETED"
    printf "  Space freed:       %s\n" "$(bytes_to_human "$BYTES_FREED")"
    printf "  Errors:            %d\n" "$ERRORS"
fi

echo ""
print_info "Log: $LOG_FILE"

if [ "$OUTPUT_JSON" = true ]; then
    local_status="ok"
    [ "$ERRORS" -gt 0 ] && local_status="errors"

    jq -n \
        --arg script "log-manager.sh" \
        --arg version "1.0.0" \
        --arg timestamp "$(get_iso8601_timestamp)" \
        --arg status "$local_status" \
        --argjson duration_ms "$DURATION_MS" \
        --argjson dry_run "$DRY_RUN" \
        --argjson bytes_freed "$BYTES_FREED" \
        --argjson files_compressed "$FILES_COMPRESSED" \
        --argjson files_deleted "$FILES_DELETED" \
        --argjson errors "$ERRORS" \
        --argjson actions "$ACTIONS_JSON" \
        '{
            script: $script,
            version: $version,
            timestamp: $timestamp,
            status: $status,
            duration_ms: $duration_ms,
            errors: [],
            result: {
                dry_run: $dry_run,
                bytes_freed: $bytes_freed,
                files_compressed: $files_compressed,
                files_deleted: $files_deleted,
                errors: $errors,
                actions: $actions
            }
        }' >"$JSON_FILE"
    chmod 600 "$JSON_FILE"
    print_info "JSON: $JSON_FILE"
fi

[ "$ERRORS" -gt 0 ] && exit 1
exit 0
