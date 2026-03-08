#!/usr/bin/env bash
set -u

# backup-verify.sh - Verify that backups are valid and recent
# Version: 1.0.0
# Usage: ./backup-verify.sh [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

LOG_DIR="${SCRIPT_DIR}/logs/backup-verify"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RUN_START_TS=$(date +%s)
LOG_FILE="${LOG_DIR}/backup_verify_${TIMESTAMP}.log"
JSON_FILE="${LOG_DIR}/backup_verify_${TIMESTAMP}.json"

# Defaults
MAX_AGE_HOURS=26      # alert if newest backup is older than this
DB_BACKUP_DIR=""      # auto-detect from db-backup.sh default
RCLONE_REMOTE=""      # auto-detect
RCLONE_REMOTE_PATH="" # auto-detect
DOCKER_BACKUP_DIR=""  # auto-detect from docker-volume-backup.sh default
DRY_RUN=false
OUTPUT_JSON=false

# Results
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_SKIPPED=0
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
backup-verify.sh - Verify that backups are valid and recent

USAGE:
    ./backup-verify.sh [OPTIONS]

OPTIONS:
    --max-age-hours <n>     Alert if newest backup older than N hours (default: 26)
    --db-backup-dir <path>  Database backup directory (auto-detected)
    --docker-backup-dir <p> Docker volume backup directory (auto-detected)
    --rclone-remote <name>  rclone remote name (auto-detected)
    --dry-run               Show what would be checked without verifying
    --json                  JSON summary output
    --help                  Show this help message

WHAT IT VERIFIES:
    1. Database backups (db-backup.sh output)
       - Latest backup exists and is < max-age-hours old
       - Backup file is non-empty and readable
       - SQLite: tries PRAGMA integrity_check (read-only)
       - SQL dump: checks for expected keywords

    2. rclone remote
       - Remote is reachable (rclone lsd)
       - Remote has files modified within the last 48 hours

    3. Docker volume backups (docker-volume-backup.sh output)
       - Latest .tar.gz exists and is < max-age-hours old
       - Archive is non-empty and passes tar integrity check

EXAMPLES:
    # Verify all auto-detected backups
    ./backup-verify.sh

    # Custom backup directories
    ./backup-verify.sh --db-backup-dir /mnt/backups/db

    # Strict: alert if backup > 6 hours old
    ./backup-verify.sh --max-age-hours 6

    # JSON output for monitoring
    ./backup-verify.sh --json

EXIT CODES:
    0  All backups verified
    1  One or more verification failures
    2  Fatal error
HELP
}

pass_check() {
    local name="$1" detail="${2:-}"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
    print_success "$name${detail:+: $detail}"
    log_line "PASS" "$name${detail:+ | $detail}"
    local escaped
    escaped=$(echo "$name${detail:+: $detail}" | sed 's/"/\\"/g')
    local entry
    entry=$(printf '{"check":"%s","result":"pass"}' "$escaped")
    [ "$FINDINGS_JSON" = "[]" ] && FINDINGS_JSON="[$entry]" || FINDINGS_JSON="${FINDINGS_JSON%]},${entry}]"
}

fail_check() {
    local name="$1" detail="${2:-}"
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
    STATUS="failures"
    print_warning "FAIL: $name${detail:+ — $detail}"
    log_line "FAIL" "$name${detail:+ | $detail}"
    local escaped
    escaped=$(echo "$name${detail:+: $detail}" | sed 's/"/\\"/g')
    local entry
    entry=$(printf '{"check":"%s","result":"fail","detail":"%s"}' "$name" "$escaped")
    [ "$FINDINGS_JSON" = "[]" ] && FINDINGS_JSON="[$entry]" || FINDINGS_JSON="${FINDINGS_JSON%]},${entry}]"
}

skip_check() {
    local name="$1" reason="${2:-not configured}"
    CHECKS_SKIPPED=$((CHECKS_SKIPPED + 1))
    print_info "SKIP: $name — $reason"
    log_line "SKIP" "$name | $reason"
}

file_age_hours() {
    local file="$1"
    local mod_ts
    mod_ts=$(stat -c%Y "$file" 2>/dev/null || echo 0)
    local now_ts
    now_ts=$(date +%s)
    echo $(((now_ts - mod_ts) / 3600))
}

# ── Database backup verification ──────────────────────────────────────────────

verify_db_backups() {
    print_section "Database Backups"

    # Auto-detect db-backup.sh output dir
    local backup_dir="$DB_BACKUP_DIR"
    if [ -z "$backup_dir" ]; then
        # Check common locations used by db-backup.sh
        local candidates=("${SCRIPT_DIR}/backups/db" "${HOME}/backups/db" "/tmp/db-backups")
        for c in "${candidates[@]}"; do
            [ -d "$c" ] && {
                backup_dir="$c"
                break
            }
        done
    fi

    if [ -z "$backup_dir" ] || [ ! -d "$backup_dir" ]; then
        skip_check "db-backup" "no backup directory found (use --db-backup-dir)"
        return
    fi

    print_info "Backup dir: $backup_dir"

    # Find newest backup
    local newest
    newest=$(find "$backup_dir" -type f \( -name "*.sql" -o -name "*.sql.gz" -o -name "*.db" \) \
        -printf "%T@ %p\n" 2>/dev/null | sort -rn | head -1 | awk '{print $2}')

    if [ -z "$newest" ]; then
        fail_check "db-backup-exists" "no backup files found in $backup_dir"
        return
    fi

    print_info "Newest backup: $newest"

    # Age check
    local age_hours
    age_hours=$(file_age_hours "$newest")
    if [ "$age_hours" -gt "$MAX_AGE_HOURS" ]; then
        fail_check "db-backup-age" "newest backup is ${age_hours}h old (max: ${MAX_AGE_HOURS}h)"
    else
        pass_check "db-backup-age" "${age_hours}h old (within ${MAX_AGE_HOURS}h limit)"
    fi

    # Size check
    local sz
    sz=$(stat -c%s "$newest" 2>/dev/null || echo 0)
    if [ "$sz" -eq 0 ]; then
        fail_check "db-backup-size" "backup file is empty: $newest"
    else
        pass_check "db-backup-size" "$(numfmt --to=iec "$sz" 2>/dev/null || echo "${sz}B")"
    fi

    # Integrity check
    case "$newest" in
    *.db)
        if command -v sqlite3 >/dev/null 2>&1; then
            local integrity
            integrity=$(sqlite3 "$newest" "PRAGMA integrity_check;" 2>/dev/null | head -1)
            if [ "$integrity" = "ok" ]; then
                pass_check "db-backup-integrity" "SQLite integrity_check OK"
            else
                fail_check "db-backup-integrity" "SQLite integrity_check failed: $integrity"
            fi
        else
            skip_check "db-backup-integrity" "sqlite3 not installed"
        fi
        ;;
    *.sql)
        if grep -qE "^(CREATE TABLE|INSERT INTO|BEGIN TRANSACTION)" "$newest" 2>/dev/null; then
            pass_check "db-backup-integrity" "SQL dump contains expected keywords"
        else
            fail_check "db-backup-integrity" "SQL dump missing expected keywords (may be corrupt)"
        fi
        ;;
    *.sql.gz)
        if zcat "$newest" 2>/dev/null | grep -qE "^(CREATE TABLE|INSERT INTO)"; then
            pass_check "db-backup-integrity" "Compressed SQL dump contains expected keywords"
        else
            fail_check "db-backup-integrity" "Compressed SQL dump validation failed"
        fi
        ;;
    esac
}

# ── rclone remote verification ────────────────────────────────────────────────

verify_rclone() {
    print_section "rclone Remote"

    if ! command -v rclone >/dev/null 2>&1; then
        skip_check "rclone" "rclone not installed"
        return
    fi

    # Auto-detect remote
    local remote="$RCLONE_REMOTE"
    if [ -z "$remote" ]; then
        remote=$(rclone listremotes 2>/dev/null | head -1 | tr -d ':')
    fi

    if [ -z "$remote" ]; then
        skip_check "rclone-remote" "no remotes configured (run: rclone config)"
        return
    fi

    local remote_path="${RCLONE_REMOTE_PATH:-repos}"
    print_info "Remote: ${remote}: / path: $remote_path"

    # Reachability
    if rclone lsd "${remote}:" --max-depth 1 >/dev/null 2>&1; then
        pass_check "rclone-reachable" "${remote}: is accessible"
    else
        fail_check "rclone-reachable" "cannot connect to ${remote}: — check credentials"
        return
    fi

    # Recent files check
    local recent_count
    recent_count=$(rclone ls "${remote}:${remote_path}" \
        --max-age 48h 2>/dev/null | wc -l || echo 0)

    if [ "$recent_count" -gt 0 ]; then
        pass_check "rclone-recent-files" "$recent_count file(s) modified in last 48h"
    else
        fail_check "rclone-recent-files" "no files modified in last 48h on ${remote}:${remote_path}"
    fi
}

# ── Docker volume backup verification ─────────────────────────────────────────

verify_docker_backups() {
    print_section "Docker Volume Backups"

    local backup_dir="$DOCKER_BACKUP_DIR"
    if [ -z "$backup_dir" ]; then
        local candidates=("${SCRIPT_DIR}/backups/docker-volumes" "${HOME}/backups/docker-volumes")
        for c in "${candidates[@]}"; do
            [ -d "$c" ] && {
                backup_dir="$c"
                break
            }
        done
    fi

    if [ -z "$backup_dir" ] || [ ! -d "$backup_dir" ]; then
        skip_check "docker-volume-backup" "no backup directory found (use --docker-backup-dir)"
        return
    fi

    print_info "Backup dir: $backup_dir"

    local newest
    newest=$(find "$backup_dir" -type f -name "*.tar.gz" \
        -printf "%T@ %p\n" 2>/dev/null | sort -rn | head -1 | awk '{print $2}')

    if [ -z "$newest" ]; then
        fail_check "docker-volume-backup-exists" "no .tar.gz backup files found"
        return
    fi

    print_info "Newest: $newest"

    local age_hours
    age_hours=$(file_age_hours "$newest")
    if [ "$age_hours" -gt "$MAX_AGE_HOURS" ]; then
        fail_check "docker-volume-backup-age" "${age_hours}h old (max: ${MAX_AGE_HOURS}h)"
    else
        pass_check "docker-volume-backup-age" "${age_hours}h old"
    fi

    # Integrity check via tar -t
    if tar -tzf "$newest" >/dev/null 2>&1; then
        pass_check "docker-volume-backup-integrity" "tar archive is valid"
    else
        fail_check "docker-volume-backup-integrity" "tar archive is corrupt: $newest"
    fi
}

# ── Parse args ────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
    --max-age-hours)
        MAX_AGE_HOURS="$2"
        shift 2
        ;;
    --db-backup-dir)
        DB_BACKUP_DIR="$2"
        shift 2
        ;;
    --docker-backup-dir)
        DOCKER_BACKUP_DIR="$2"
        shift 2
        ;;
    --rclone-remote)
        RCLONE_REMOTE="$2"
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

echo -e "${BOLD}━━━ Backup Verify ━━━${NC}"
echo ""
print_info "Max backup age: ${MAX_AGE_HOURS}h"
print_info "Log: $LOG_FILE"

if [ "$DRY_RUN" = true ]; then
    print_warning "DRY RUN — would verify:"
    echo "  - Database backups (${DB_BACKUP_DIR:-auto-detect})"
    echo "  - rclone remote (${RCLONE_REMOTE:-auto-detect})"
    echo "  - Docker volume backups (${DOCKER_BACKUP_DIR:-auto-detect})"
    exit 0
fi

verify_db_backups
verify_rclone
verify_docker_backups

# ── Summary ───────────────────────────────────────────────────────────────────

RUN_END_TS=$(date +%s)
DURATION_MS=$(((RUN_END_TS - RUN_START_TS) * 1000))

echo ""
echo -e "${BOLD}━━━ Summary ━━━${NC}"
echo ""
printf "  Passed:   ${GREEN}%d${NC}\n" "$CHECKS_PASSED"
printf "  Failed:   ${RED}%d${NC}\n" "$CHECKS_FAILED"
printf "  Skipped:  %d\n" "$CHECKS_SKIPPED"
echo ""

if [ "$STATUS" = "ok" ]; then
    print_success "All backup checks passed"
else
    print_warning "$CHECKS_FAILED check(s) failed — backups may be stale or corrupt"
fi

print_info "Log: $LOG_FILE"

if [ "$OUTPUT_JSON" = true ]; then
    jq -n \
        --arg script "backup-verify.sh" \
        --arg version "1.0.0" \
        --arg timestamp "$(get_iso8601_timestamp)" \
        --arg status "$STATUS" \
        --argjson duration_ms "$DURATION_MS" \
        --argjson passed "$CHECKS_PASSED" \
        --argjson failed "$CHECKS_FAILED" \
        --argjson skipped "$CHECKS_SKIPPED" \
        --argjson findings "$FINDINGS_JSON" \
        '{
            script: $script,
            version: $version,
            timestamp: $timestamp,
            status: $status,
            duration_ms: $duration_ms,
            errors: [],
            result: {
                checks_passed: $passed,
                checks_failed: $failed,
                checks_skipped: $skipped,
                findings: $findings
            }
        }' >"$JSON_FILE"
    chmod 600 "$JSON_FILE"
    print_info "JSON: $JSON_FILE"
fi

[ "$STATUS" != "ok" ] && exit 1
exit 0
