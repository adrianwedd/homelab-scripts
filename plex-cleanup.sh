#!/usr/bin/env bash
set -u

# plex-cleanup.sh - Clean up Plex Media Server junk, cache, and duplicates
# Version: 1.0.0
# Usage: ./plex-cleanup.sh [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

LOG_DIR="${SCRIPT_DIR}/logs/plex-cleanup"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RUN_START_TS=$(date +%s)
LOG_FILE="${LOG_DIR}/plex_cleanup_${TIMESTAMP}.log"
JSON_FILE="${LOG_DIR}/plex_cleanup_${TIMESTAMP}.json"

# Defaults
PLEX_DIR="/home/plex"
PLEX_DATA_DIR="" # auto-detected
DRY_RUN=false
OUTPUT_JSON=false
SKIP_TRANSCODER=false
SKIP_THUMBNAILS=false
SKIP_DUPLICATES=false
SKIP_EMPTIES=false
FORCE_YES=false

# Counters
BYTES_FREED=0
FILES_REMOVED=0
DIRS_REMOVED=0
ERRORS=0
ERRORS_JSON="[]"
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
plex-cleanup.sh - Clean up Plex Media Server junk, cache, and duplicates

USAGE:
    ./plex-cleanup.sh [OPTIONS]

OPTIONS:
    --plex-dir <path>     Plex media root (default: /home/plex)
    --skip-transcoder     Skip Plex transcoder cache cleanup
    --skip-thumbnails     Skip thumbnail/junk file removal (.DS_Store, Thumbs.db, etc.)
    --skip-duplicates     Skip duplicate media detection
    --skip-empties        Skip empty directory removal
    -y, --yes             Skip confirmation prompts
    --dry-run             Show what would be removed without deleting
    --json                JSON summary output
    --help                Show this help message

WHAT IT CLEANS:
    1. Plex transcoder/temp cache  (safe to delete — always regenerated)
    2. System junk files           (.DS_Store, Thumbs.db, desktop.ini, ._* files)
    3. Empty directories           (leftover after moves/deletions)
    4. Duplicate media files       (same size + MD5, keeps first found)

PLEX DATA DIR:
    Auto-detected from common locations:
      /var/lib/plexmediaserver/Library/Application Support/Plex Media Server
      ~/.local/share/Plex Media Server
      /home/plex/.local/share/Plex Media Server

EXAMPLES:
    # Dry run — see what would be cleaned
    ./plex-cleanup.sh --dry-run

    # Clean everything, no prompts
    ./plex-cleanup.sh -y

    # Only clean transcoder cache, with JSON output
    ./plex-cleanup.sh --skip-duplicates --skip-thumbnails --skip-empties --json

    # Scan specific Plex directory
    ./plex-cleanup.sh --plex-dir /mnt/media

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
        if [[ "$OSTYPE" == "darwin"* ]]; then
            stat -f%z "$path" 2>/dev/null || echo 0
        else
            stat -c%s "$path" 2>/dev/null || echo 0
        fi
    elif [ -d "$path" ]; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            du -sk "$path" 2>/dev/null | awk '{print $1 * 1024}' || echo 0
        else
            du -sb "$path" 2>/dev/null | awk '{print $1}' || echo 0
        fi
    else
        echo 0
    fi
}

confirm() {
    local prompt="$1"
    if [ "$FORCE_YES" = true ] || [ "$DRY_RUN" = true ]; then
        return 0
    fi
    echo -e "${YELLOW}?${NC} $prompt [y/N] "
    read -r answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

safe_remove() {
    local path="$1"
    local label="${2:-}"
    local size
    size=$(get_size_bytes "$path")

    if [ "$DRY_RUN" = true ]; then
        echo -e "  ${YELLOW}[DRY RUN]${NC} would remove: $path ($(bytes_to_human "$size"))"
        return 0
    fi

    if [ -f "$path" ]; then
        rm -f "$path" && {
            BYTES_FREED=$((BYTES_FREED + size))
            FILES_REMOVED=$((FILES_REMOVED + 1))
            log_line "REMOVED" "$path (${size}B)"
        } || print_error "Failed to remove: $path"
    elif [ -d "$path" ]; then
        rm -rf "$path" && {
            BYTES_FREED=$((BYTES_FREED + size))
            DIRS_REMOVED=$((DIRS_REMOVED + 1))
            log_line "REMOVED_DIR" "$path (${size}B)"
        } || print_error "Failed to remove dir: $path"
    fi
}

record_action() {
    local action="$1"
    local path="$2"
    local bytes="${3:-0}"
    local escaped_path
    escaped_path=$(json_escape "$path")
    local entry
    entry=$(printf '{"action":"%s","path":"%s","bytes":%s}' "$action" "$escaped_path" "$bytes")
    if [ "$ACTIONS_JSON" = "[]" ]; then
        ACTIONS_JSON="[$entry]"
    else
        ACTIONS_JSON="${ACTIONS_JSON%]},${entry}]"
    fi
}

# ── Auto-detect Plex data directory ───────────────────────────────────────────

detect_plex_data_dir() {
    local candidates=(
        "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server"
        "${PLEX_DIR}/.local/share/Plex Media Server"
        "${HOME}/.local/share/Plex Media Server"
        "/opt/plexmediaserver/Library/Application Support/Plex Media Server"
    )
    for candidate in "${candidates[@]}"; do
        if [ -d "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    echo ""
}

# ── Section 1: Plex Transcoder Cache ──────────────────────────────────────────

clean_transcoder_cache() {
    print_section "Plex Transcoder & Cache"

    if [ -z "$PLEX_DATA_DIR" ]; then
        print_warning "Plex data directory not found — skipping transcoder cleanup"
        print_info "Set with: export PLEX_DATA_DIR='/path/to/Plex Media Server'"
        return
    fi

    local cache_dirs=(
        "${PLEX_DATA_DIR}/Cache"
        "${PLEX_DATA_DIR}/Codecs"
        "${PLEX_DATA_DIR}/Crash Reports"
        "${PLEX_DATA_DIR}/Logs"
    )

    local total_cache=0
    for dir in "${cache_dirs[@]}"; do
        if [ -d "$dir" ]; then
            local sz
            sz=$(get_size_bytes "$dir")
            total_cache=$((total_cache + sz))
            printf "  %-50s %s\n" "$dir" "$(bytes_to_human "$sz")"
        fi
    done

    echo ""
    print_info "Total cache: $(bytes_to_human "$total_cache")"

    if [ "$total_cache" -eq 0 ]; then
        print_success "No cache to clean"
        return
    fi

    if ! confirm "Remove Plex cache/logs? (They will be regenerated by Plex)"; then
        print_info "Skipped"
        return
    fi

    for dir in "${cache_dirs[@]}"; do
        if [ -d "$dir" ]; then
            local sz
            sz=$(get_size_bytes "$dir")
            if [ "$DRY_RUN" = true ]; then
                echo -e "  ${YELLOW}[DRY RUN]${NC} would clear: $dir ($(bytes_to_human "$sz"))"
            else
                # Clear contents but keep the directory itself
                find "$dir" -mindepth 1 -delete 2>/dev/null && {
                    BYTES_FREED=$((BYTES_FREED + sz))
                    print_success "Cleared: $dir"
                    record_action "cleared_dir" "$dir" "$sz"
                } || print_error "Could not clear: $dir"
            fi
        fi
    done

    # Also clean Plex's Plug-in Support/Databases cache (safe to delete)
    local db_cache="${PLEX_DATA_DIR}/Plug-in Support/Databases"
    if [ -d "$db_cache" ]; then
        local tmpdbs
        tmpdbs=$(find "$db_cache" -name "*.tmp" -o -name "*.db-wal" -o -name "*.db-shm" 2>/dev/null)
        if [ -n "$tmpdbs" ]; then
            print_info "Cleaning database temp files..."
            echo "$tmpdbs" | while read -r f; do
                safe_remove "$f"
            done
        fi
    fi

    # Plex-generated "Versions" subdirs (transcoded versions of originals)
    local versions_count=0
    local versions_bytes=0
    while IFS= read -r versions_dir; do
        local sz
        sz=$(get_size_bytes "$versions_dir")
        versions_bytes=$((versions_bytes + sz))
        versions_count=$((versions_count + 1))
    done < <(find "$PLEX_DIR" -maxdepth 6 -type d -name "Versions" 2>/dev/null)

    if [ "$versions_count" -gt 0 ]; then
        echo ""
        print_info "Found $versions_count 'Versions' dir(s) using $(bytes_to_human "$versions_bytes") (Plex-optimized versions)"
        if confirm "Remove Plex Versions directories? (saves space; Plex will re-create if needed)"; then
            find "$PLEX_DIR" -maxdepth 6 -type d -name "Versions" 2>/dev/null | while read -r d; do
                safe_remove "$d"
                record_action "removed_versions_dir" "$d" "$(get_size_bytes "$d")"
            done
        fi
    fi
}

# ── Section 2: Thumbnail Junk ─────────────────────────────────────────────────

clean_thumbnails() {
    print_section "System Junk Files"

    local junk_patterns=(".DS_Store" "Thumbs.db" "desktop.ini" ".Spotlight-V100" ".Trashes" ".fseventsd")
    local hidden_patterns=("._*" ".AppleDouble" ".AppleDB")

    local total_junk=0
    local junk_files=()

    for pattern in "${junk_patterns[@]}" "${hidden_patterns[@]}"; do
        while IFS= read -r f; do
            local sz
            sz=$(get_size_bytes "$f")
            total_junk=$((total_junk + sz))
            junk_files+=("$f")
        done < <(find "$PLEX_DIR" -name "$pattern" 2>/dev/null)
    done

    if [ ${#junk_files[@]} -eq 0 ]; then
        print_success "No system junk files found"
        return
    fi

    print_info "Found ${#junk_files[@]} junk file(s) totalling $(bytes_to_human "$total_junk")"

    # Show a sample
    local shown=0
    for f in "${junk_files[@]}"; do
        [ "$shown" -ge 10 ] && break
        echo "  $f"
        shown=$((shown + 1))
    done
    [ ${#junk_files[@]} -gt 10 ] && echo "  ... and $((${#junk_files[@]} - 10)) more"

    if ! confirm "Remove these junk files?"; then
        print_info "Skipped"
        return
    fi

    for f in "${junk_files[@]}"; do
        safe_remove "$f"
        record_action "removed_junk" "$f" "$(get_size_bytes "$f")"
    done
}

# ── Section 3: Empty Directories ──────────────────────────────────────────────

clean_empty_dirs() {
    print_section "Empty Directories"

    local empty_dirs=()
    while IFS= read -r d; do
        empty_dirs+=("$d")
    done < <(find "$PLEX_DIR" -mindepth 1 -type d -empty 2>/dev/null | sort -r)

    if [ ${#empty_dirs[@]} -eq 0 ]; then
        print_success "No empty directories found"
        return
    fi

    print_info "Found ${#empty_dirs[@]} empty director(ies)"

    local shown=0
    for d in "${empty_dirs[@]}"; do
        [ "$shown" -ge 15 ] && break
        echo "  $d"
        shown=$((shown + 1))
    done
    [ ${#empty_dirs[@]} -gt 15 ] && echo "  ... and $((${#empty_dirs[@]} - 15)) more"

    if ! confirm "Remove empty directories?"; then
        print_info "Skipped"
        return
    fi

    for d in "${empty_dirs[@]}"; do
        if [ "$DRY_RUN" = true ]; then
            echo -e "  ${YELLOW}[DRY RUN]${NC} would rmdir: $d"
        else
            rmdir "$d" 2>/dev/null && {
                DIRS_REMOVED=$((DIRS_REMOVED + 1))
                log_line "RMDIR" "$d"
                record_action "removed_empty_dir" "$d" 0
            }
        fi
    done

    print_success "Cleaned ${#empty_dirs[@]} empty director(ies)"
}

# ── Section 4: Duplicate Detection ────────────────────────────────────────────

clean_duplicates() {
    print_section "Duplicate Media Detection"

    local media_exts="mp4|mkv|avi|m4v|mov|flac|mp3|m4a|aac|wav|ogg|opus"

    print_info "Scanning for duplicate media files (same size + MD5)..."
    print_info "This may take a few minutes on large libraries..."

    local tmp_size_index
    tmp_size_index=$(mktemp)
    trap 'rm -f "$tmp_size_index"' RETURN

    # Build size index: "size path"
    find "$PLEX_DIR" -type f 2>/dev/null | grep -iE "\.(${media_exts})$" | while read -r f; do
        local sz
        sz=$(get_size_bytes "$f")
        echo "$sz $f"
    done >"$tmp_size_index"

    # Find sizes that appear more than once
    local dup_sizes
    dup_sizes=$(awk '{print $1}' "$tmp_size_index" | sort | uniq -d)

    if [ -z "$dup_sizes" ]; then
        print_success "No duplicate candidates found (no files share the same size)"
        return
    fi

    local dup_count=0
    local dup_bytes=0
    local dup_list=()

    # For each duplicate size group, compare MD5
    while read -r dup_size; do
        local files_of_size=()
        while IFS= read -r f; do
            files_of_size+=("$f")
        done < <(grep "^${dup_size} " "$tmp_size_index" | cut -d' ' -f2-)

        # Group by MD5 (requires Bash 4+ for associative arrays)
        if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
            print_warning "Duplicate detection requires Bash 4.0+ (current: $BASH_VERSION) — skipping"
            return
        fi
        declare -A md5_groups
        for f in "${files_of_size[@]}"; do
            local md5
            if command -v md5sum >/dev/null 2>&1; then
                md5=$(md5sum "$f" 2>/dev/null | awk '{print $1}') || continue
            else
                md5=$(md5 -r "$f" 2>/dev/null | awk '{print $1}') || continue
            fi
            if [ -n "${md5_groups[$md5]+_}" ]; then
                # Duplicate — keep first, mark this one
                dup_list+=("$f")
                dup_bytes=$((dup_bytes + dup_size))
                dup_count=$((dup_count + 1))
            else
                md5_groups[$md5]="$f"
            fi
        done
        unset md5_groups
    done <<<"$dup_sizes"

    if [ ${#dup_list[@]} -eq 0 ]; then
        print_success "No exact duplicates found (files with same size have different content)"
        return
    fi

    print_warning "Found ${#dup_list[@]} duplicate file(s) totalling $(bytes_to_human "$dup_bytes")"
    echo ""
    for f in "${dup_list[@]}"; do
        echo "  DUP: $f"
    done
    echo ""

    if ! confirm "Remove duplicate files? (the first occurrence of each will be kept)"; then
        print_info "Skipped — review list above and remove manually"
        return
    fi

    for f in "${dup_list[@]}"; do
        local sz
        sz=$(get_size_bytes "$f")
        safe_remove "$f"
        record_action "removed_duplicate" "$f" "$sz"
    done
}

# ── Parse args ────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
    --plex-dir)
        PLEX_DIR="$2"
        shift 2
        ;;
    --skip-transcoder)
        SKIP_TRANSCODER=true
        shift
        ;;
    --skip-thumbnails)
        SKIP_THUMBNAILS=true
        shift
        ;;
    --skip-duplicates)
        SKIP_DUPLICATES=true
        shift
        ;;
    --skip-empties)
        SKIP_EMPTIES=true
        shift
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

# ── Validate user-supplied paths ─────────────────────────────────────────────

validate_output_dir "$PLEX_DIR" || exit 1

# ── Setup ─────────────────────────────────────────────────────────────────────

umask 077
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

require_jq_if_json "$OUTPUT_JSON" || exit 2

# Validate PLEX_DIR: block system directories
case "$(realpath "$PLEX_DIR" 2>/dev/null || echo "$PLEX_DIR")" in
/usr | /usr/* | /etc | /etc/* | /var | /var/* | /bin | /bin/* | /sbin | /sbin/* | \
    /boot | /boot/* | /sys | /sys/* | /proc | /proc/* | /dev | /dev/*)
    print_error "Refusing to operate on system directory: $PLEX_DIR"
    exit 2
    ;;
esac

if [ ! -d "$PLEX_DIR" ]; then
    print_error "Plex directory not found: $PLEX_DIR"
    print_info "Use --plex-dir to specify the correct path"
    exit 2
fi

PLEX_DATA_DIR=$(detect_plex_data_dir)

echo -e "${BOLD}━━━ Plex Cleanup ━━━${NC}"
echo ""
print_info "Plex root:   $PLEX_DIR"
print_info "Plex data:   ${PLEX_DATA_DIR:-not found}"
print_info "Dry run:     $DRY_RUN"
print_info "Log:         $LOG_FILE"

if [ "$DRY_RUN" = true ]; then
    echo ""
    print_warning "DRY RUN — no files will be deleted"
fi

# ── Run sections ──────────────────────────────────────────────────────────────

[ "$SKIP_TRANSCODER" = false ] && clean_transcoder_cache
[ "$SKIP_THUMBNAILS" = false ] && clean_thumbnails
[ "$SKIP_EMPTIES" = false ] && clean_empty_dirs
[ "$SKIP_DUPLICATES" = false ] && clean_duplicates

# ── Summary ───────────────────────────────────────────────────────────────────

RUN_END_TS=$(date +%s)
DURATION_MS=$(((RUN_END_TS - RUN_START_TS) * 1000))

echo ""
echo -e "${BOLD}━━━ Summary ━━━${NC}"
echo ""

if [ "$DRY_RUN" = true ]; then
    print_warning "DRY RUN — no changes made"
else
    printf "  Files removed:   %d\n" "$FILES_REMOVED"
    printf "  Dirs removed:    %d\n" "$DIRS_REMOVED"
    printf "  Space freed:     %s\n" "$(bytes_to_human "$BYTES_FREED")"
    printf "  Errors:          %d\n" "$ERRORS"
fi

echo ""
print_info "Log: $LOG_FILE"

if [ "$OUTPUT_JSON" = true ]; then
    local_status="ok"
    [ "$ERRORS" -gt 0 ] && local_status="errors"

    jq -n \
        --arg script "plex-cleanup.sh" \
        --arg version "1.0.0" \
        --arg timestamp "$(get_iso8601_timestamp)" \
        --arg status "$local_status" \
        --argjson duration_ms "$DURATION_MS" \
        --argjson dry_run "$DRY_RUN" \
        --argjson bytes_freed "$BYTES_FREED" \
        --argjson files_removed "$FILES_REMOVED" \
        --argjson dirs_removed "$DIRS_REMOVED" \
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
                files_removed: $files_removed,
                dirs_removed: $dirs_removed,
                errors: $errors,
                actions: $actions
            }
        }' >"$JSON_FILE"
    chmod 600 "$JSON_FILE"
    print_info "JSON: $JSON_FILE"
fi

[ "$ERRORS" -gt 0 ] && exit 1
exit 0
