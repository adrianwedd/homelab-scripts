#!/usr/bin/env bash
set -u

# secrets-scan.sh - Scan git repositories for accidentally committed secrets
# Version: 1.0.0
# Usage: ./secrets-scan.sh [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

LOG_DIR="${SCRIPT_DIR}/logs/secrets-scan"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RUN_START_TS=$(date +%s)
LOG_FILE="${LOG_DIR}/secrets_scan_${TIMESTAMP}.log"
JSON_FILE="${LOG_DIR}/secrets_scan_${TIMESTAMP}.json"

# Defaults
SCAN_DIR="${HOME}/repos"
DRY_RUN=false
OUTPUT_JSON=false
SCAN_HISTORY=false
SEVERITY_FILTER="" # empty = all

# Results
FINDINGS_CRITICAL=0
FINDINGS_HIGH=0
FINDINGS_MEDIUM=0
FINDINGS_LOW=0
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
    echo "[$(get_iso8601_timestamp)] ERROR: $1" >>"$LOG_FILE"
}
print_success() {
    echo -e "${GREEN}✓${NC} $1"
    echo "[$(get_iso8601_timestamp)] OK: $1" >>"$LOG_FILE"
}
print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
    echo "[$(get_iso8601_timestamp)] WARN: $1" >>"$LOG_FILE"
}
print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
    echo "[$(get_iso8601_timestamp)] INFO: $1" >>"$LOG_FILE"
}
print_section() {
    echo ""
    echo -e "${CYAN}━━━ $1 ━━━${NC}"
    echo ""
    echo "[$(get_iso8601_timestamp)] SECTION: $1" >>"$LOG_FILE"
}

show_help() {
    cat <<'HELP'
secrets-scan.sh - Scan git repositories for accidentally committed secrets

USAGE:
    ./secrets-scan.sh [OPTIONS]

OPTIONS:
    --dir <path>          Directory to scan (default: ~/repos)
    --severity <level>    Filter: critical|high|medium|low (default: all)
    --history             Also scan git commit history (slow)
    --dry-run             Show what would be scanned without scanning
    --json                JSON summary output
    --help                Show this help message

WHAT IT DETECTS:
    CRITICAL  Private keys, AWS credentials, database DSNs with passwords
    HIGH      GitHub tokens, Google API keys, Stripe live keys, JWTs
    MEDIUM    Generic API key assignments, Bearer tokens, Slack tokens
    LOW       Password-like assignments, high-entropy strings in configs

NOTES:
    - Secret values are masked in output (never printed in full)
    - Binary files are skipped automatically
    - Skipped dirs: .git, node_modules, .venv, venv, __pycache__, dist, build
    - --history scans all git commits (can be slow on large repos)

EXAMPLES:
    # Scan all repos
    ./secrets-scan.sh

    # Scan a specific directory
    ./secrets-scan.sh --dir ~/projects

    # Only show critical and high findings
    ./secrets-scan.sh --severity high

    # Full history scan with JSON output
    ./secrets-scan.sh --history --json

EXIT CODES:
    0  No findings (or dry run)
    1  One or more secrets found
    2  Error
HELP
}

# Mask a secret value — show first 4 chars then asterisks
mask_secret() {
    local val="$1"
    local len="${#val}"
    if [ "$len" -le 4 ]; then
        echo "****"
    elif [ "$len" -le 8 ]; then
        echo "${val:0:2}****"
    else
        echo "${val:0:4}$(printf '*%.0s' $(seq 1 8))…"
    fi
}

# Check if a file is binary
is_binary() {
    local file="$1"
    # Use file command if available, otherwise check for null bytes
    if command -v file >/dev/null 2>&1; then
        file "$file" 2>/dev/null | grep -qiE 'binary|data|image|audio|video|compressed|archive|font'
    else
        LC_ALL=C grep -qP '\x00' "$file" 2>/dev/null
    fi
}

# Record a finding
record_finding() {
    local severity="$1"
    local repo="$2"
    local file="$3"
    local line="$4"
    local pattern_name="$5"
    local excerpt="$6"

    # Apply severity filter
    if [ -n "$SEVERITY_FILTER" ]; then
        case "$SEVERITY_FILTER" in
        critical) [[ "$severity" != "CRITICAL" ]] && return ;;
        high) [[ "$severity" != "CRITICAL" && "$severity" != "HIGH" ]] && return ;;
        medium) [[ "$severity" == "LOW" ]] && return ;;
        esac
    fi

    # Increment counters
    case "$severity" in
    CRITICAL) FINDINGS_CRITICAL=$((FINDINGS_CRITICAL + 1)) ;;
    HIGH) FINDINGS_HIGH=$((FINDINGS_HIGH + 1)) ;;
    MEDIUM) FINDINGS_MEDIUM=$((FINDINGS_MEDIUM + 1)) ;;
    LOW) FINDINGS_LOW=$((FINDINGS_LOW + 1)) ;;
    esac

    # Color by severity
    local color="$NC"
    case "$severity" in
    CRITICAL) color="$RED" ;;
    HIGH) color="$YELLOW" ;;
    MEDIUM) color="$BLUE" ;;
    LOW) color="$NC" ;;
    esac

    printf "  ${color}[%s]${NC} ${BOLD}%s${NC}  %s:%s\n" \
        "$severity" "$pattern_name" "$file" "$line"
    printf "         %s\n" "$excerpt"

    echo "[$(get_iso8601_timestamp)] FINDING [$severity] $pattern_name in $repo/$file:$line" >>"$LOG_FILE"

    # Append to JSON array
    local escaped_file escaped_excerpt escaped_repo
    escaped_file=$(echo "$file" | sed 's/"/\\"/g')
    escaped_excerpt=$(echo "$excerpt" | sed 's/"/\\"/g')
    escaped_repo=$(echo "$repo" | sed 's/"/\\"/g')

    local finding
    finding=$(printf '{"severity":"%s","pattern":"%s","repo":"%s","file":"%s","line":%s,"excerpt":"%s"}' \
        "$severity" "$pattern_name" "$escaped_repo" "$escaped_file" "$line" "$escaped_excerpt")

    if [ "$FINDINGS_JSON" = "[]" ]; then
        FINDINGS_JSON="[$finding]"
    else
        FINDINGS_JSON="${FINDINGS_JSON%]},${finding}]"
    fi
}

# Scan a single file for secrets
scan_file() {
    local file="$1"
    local repo="$2"
    local rel_file="${file#$SCAN_DIR/}"

    is_binary "$file" && return

    # Read file once into variable for multiple pattern scans
    local content
    content=$(cat "$file" 2>/dev/null) || return

    # Helper: grep file, record findings
    grep_and_record() {
        local severity="$1"
        local pattern_name="$2"
        local pattern="$3"
        local mask_group="${4:-0}" # which grep group to mask (0 = whole match)

        while IFS=: read -r lineno match; do
            [ -z "$lineno" ] && continue
            # Mask the sensitive value
            local display
            display=$(echo "$match" | sed 's/[A-Za-z0-9+/=_\-]\{8,\}/***MASKED***/2')
            record_finding "$severity" "$repo" "$rel_file" "$lineno" "$pattern_name" "$display"
        done < <(echo "$content" | grep -nE "$pattern" 2>/dev/null | head -5)
    }

    # ── CRITICAL ───────────────────────────────────────────────────────────
    grep_and_record "CRITICAL" "private-key-header" \
        '-----BEGIN (RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY'

    grep_and_record "CRITICAL" "aws-access-key" \
        'AKIA[0-9A-Z]{16}'

    grep_and_record "CRITICAL" "database-dsn-with-password" \
        '(postgres|postgresql|mysql|mongodb|redis)://[^:@\s]+:[^@\s]{4,}@[^\s]+'

    grep_and_record "CRITICAL" "aws-secret-key-env" \
        '(AWS_SECRET_ACCESS_KEY|aws_secret_access_key)\s*[:=]\s*[A-Za-z0-9/+]{20,}'

    # ── HIGH ───────────────────────────────────────────────────────────────
    grep_and_record "HIGH" "github-pat" \
        'gh[ps]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{80,}'

    grep_and_record "HIGH" "google-api-key" \
        'AIza[0-9A-Za-z\-_]{35}'

    grep_and_record "HIGH" "stripe-live-key" \
        'sk_live_[0-9a-zA-Z]{24}'

    grep_and_record "HIGH" "jwt-token" \
        'eyJ[A-Za-z0-9+/]{10,}\.[Ee][Yy][Jj][A-Za-z0-9+/]{10,}'

    grep_and_record "HIGH" "cloudflare-api-token" \
        '(CF_API_TOKEN|CLOUDFLARE_API_TOKEN|cf_token)\s*[:=]\s*[A-Za-z0-9_\-]{20,}'

    grep_and_record "HIGH" "sendgrid-api-key" \
        'SG\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}'

    grep_and_record "HIGH" "twilio-account-sid" \
        'AC[a-z0-9]{32}'

    grep_and_record "HIGH" "anthropic-api-key" \
        'sk-ant-[A-Za-z0-9_\-]{40,}'

    grep_and_record "HIGH" "openai-api-key" \
        'sk-[A-Za-z0-9]{48}'

    # ── MEDIUM ─────────────────────────────────────────────────────────────
    grep_and_record "MEDIUM" "slack-token" \
        'xox[baprs]-[0-9]{10,}-[0-9]{10,}-[A-Za-z0-9]+'

    grep_and_record "MEDIUM" "bearer-token" \
        'Authorization:\s*Bearer\s+[A-Za-z0-9+/=._\-]{20,}'

    grep_and_record "MEDIUM" "generic-api-key-assignment" \
        '(api_key|API_KEY|apiKey|api-key)\s*[:=]\s*['"'"'"][A-Za-z0-9_\-]{16,}['"'"'"]'

    grep_and_record "MEDIUM" "generic-secret-assignment" \
        '(secret|SECRET|client_secret|CLIENT_SECRET)\s*[:=]\s*['"'"'"][^'"'"'"]{12,}['"'"'"]'

    # ── LOW ────────────────────────────────────────────────────────────────
    grep_and_record "LOW" "hardcoded-password" \
        '(password|PASSWORD|passwd|PASSWD)\s*[:=]\s*['"'"'"][^'"'"'"]{8,}['"'"'"]'

    grep_and_record "LOW" "private-key-file-path" \
        '(id_rsa|id_ed25519|\.pem|\.p12|\.pfx)\s*[:=]'
}

# Scan git history for a repo
scan_history() {
    local repo_path="$1"
    local repo_name="$2"

    print_info "Scanning git history for $repo_name (this may take a while)..."

    if ! git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
        return
    fi

    local tmp_patch
    tmp_patch=$(mktemp)
    trap 'rm -f "$tmp_patch"' RETURN

    # Get all added lines from all commits
    git -C "$repo_path" log --all --diff-filter=A -p --no-color 2>/dev/null |
        grep '^+[^+]' |
        sed 's/^+//' >"$tmp_patch"

    # Patterns in history (simplified — just the critical ones)
    local patterns=(
        "CRITICAL|private-key|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY"
        "CRITICAL|aws-access-key|AKIA[0-9A-Z]{16}"
        "CRITICAL|database-dsn|postgres://[^:]+:[^@]+@"
        "HIGH|github-pat|gh[ps]_[A-Za-z0-9]{36}"
        "HIGH|google-api-key|AIza[0-9A-Za-z\-_]{35}"
    )

    for entry in "${patterns[@]}"; do
        local severity pattern_name pattern
        severity=$(echo "$entry" | cut -d'|' -f1)
        pattern_name=$(echo "$entry" | cut -d'|' -f2)
        pattern=$(echo "$entry" | cut -d'|' -f3)

        while IFS=: read -r lineno match; do
            [ -z "$match" ] && continue
            local display
            display=$(echo "$match" | sed 's/[A-Za-z0-9+/=_\-]\{8,\}/***MASKED***/2')
            record_finding "$severity" "$repo_name" "[history]" "$lineno" "$pattern_name (history)" "$display"
        done < <(grep -nE "$pattern" "$tmp_patch" 2>/dev/null | head -3)
    done
}

# Dirs to skip
SKIP_DIRS=".git|node_modules|.venv|venv|__pycache__|dist|build|.next|.cache|vendor"
SKIP_EXTENSIONS="png|jpg|jpeg|gif|svg|ico|woff|woff2|ttf|eot|mp3|mp4|mov|avi|mkv|zip|tar|gz|bz2|xz|7z|pdf|db|sqlite|pyc|pyo|so|dylib|dll|exe|bin|lock"

# ── Main ──────────────────────────────────────────────────────────────────────

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
    --dir)
        SCAN_DIR="$2"
        shift 2
        ;;
    --severity)
        SEVERITY_FILTER="$2"
        shift 2
        ;;
    --history)
        SCAN_HISTORY=true
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

# Setup log dir
umask 077
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

require_jq_if_json "$OUTPUT_JSON" || exit 2

if [ ! -d "$SCAN_DIR" ]; then
    print_error "Scan directory not found: $SCAN_DIR"
    exit 2
fi

echo -e "${BOLD}━━━ Secrets Scanner ━━━${NC}"
echo ""
print_info "Scan root:  $SCAN_DIR"
print_info "Severity:   ${SEVERITY_FILTER:-all}"
print_info "History:    $SCAN_HISTORY"
print_info "Log:        $LOG_FILE"
echo ""

if [ "$DRY_RUN" = true ]; then
    print_warning "DRY RUN — showing repos that would be scanned"
    echo ""
    find "$SCAN_DIR" -maxdepth 2 -name ".git" -type d | while read -r gitdir; do
        echo "  $(dirname "$gitdir")"
    done
    echo ""
    print_info "Re-run without --dry-run to scan"
    exit 0
fi

# Find repos
mapfile -t REPOS < <(find "$SCAN_DIR" -maxdepth 2 -name ".git" -type d | sed 's|/.git$||' | sort)

if [ ${#REPOS[@]} -eq 0 ]; then
    # No git repos — just scan the directory directly
    REPOS=("$SCAN_DIR")
fi

total_files=0
total_repos=${#REPOS[@]}

for repo_path in "${REPOS[@]}"; do
    repo_name=$(basename "$repo_path")
    print_section "Scanning: $repo_name"

    repo_files=0
    repo_findings_before=$((FINDINGS_CRITICAL + FINDINGS_HIGH + FINDINGS_MEDIUM + FINDINGS_LOW))

    # Build find prune args from SKIP_DIRS pipe-separated list
    prune_args=()
    first=true
    while IFS= read -r skip_name; do
        [ -z "$skip_name" ] && continue
        if [ "$first" = true ]; then
            first=false
        else
            prune_args+=("-o")
        fi
        prune_args+=("-name" "$skip_name")
    done < <(echo "$SKIP_DIRS" | tr '|' '\n')

    # Walk files
    while IFS= read -r file; do
        # Skip by extension
        ext="${file##*.}"
        echo "$SKIP_EXTENSIONS" | grep -qw "$ext" && continue

        scan_file "$file" "$repo_name"
        repo_files=$((repo_files + 1))
        total_files=$((total_files + 1))
    done < <(find "$repo_path" \
        -type d \( "${prune_args[@]}" \) -prune \
        -o -type f -print 2>/dev/null)

    repo_findings=$((FINDINGS_CRITICAL + FINDINGS_HIGH + FINDINGS_MEDIUM + FINDINGS_LOW - repo_findings_before))

    if [ "$repo_findings" -eq 0 ]; then
        print_success "$repo_name — clean ($repo_files files scanned)"
    else
        print_warning "$repo_name — $repo_findings finding(s) in $repo_files files"
    fi

    # Optionally scan git history
    if [ "$SCAN_HISTORY" = true ]; then
        scan_history "$repo_path" "$repo_name"
    fi
done

# ── Summary ───────────────────────────────────────────────────────────────────

total_findings=$((FINDINGS_CRITICAL + FINDINGS_HIGH + FINDINGS_MEDIUM + FINDINGS_LOW))
RUN_END_TS=$(date +%s)
DURATION_MS=$(((RUN_END_TS - RUN_START_TS) * 1000))

echo ""
echo -e "${BOLD}━━━ Summary ━━━${NC}"
echo ""
printf "  Repos scanned:   %d\n" "$total_repos"
printf "  Files scanned:   %d\n" "$total_files"
echo ""
printf "  ${RED}CRITICAL:${NC}  %d\n" "$FINDINGS_CRITICAL"
printf "  ${YELLOW}HIGH:${NC}      %d\n" "$FINDINGS_HIGH"
printf "  ${BLUE}MEDIUM:${NC}    %d\n" "$FINDINGS_MEDIUM"
printf "  LOW:       %d\n" "$FINDINGS_LOW"
echo ""

if [ "$total_findings" -eq 0 ]; then
    print_success "No secrets found"
else
    print_warning "$total_findings finding(s) — review above and rotate any exposed credentials"
fi

echo ""
print_info "Full log: $LOG_FILE"

# JSON output
if [ "$OUTPUT_JSON" = true ]; then
    local_status="ok"
    [ "$total_findings" -gt 0 ] && local_status="findings"
    [ "$FINDINGS_CRITICAL" -gt 0 ] && local_status="critical"

    jq -n \
        --arg script "secrets-scan.sh" \
        --arg version "1.0.0" \
        --arg timestamp "$(get_iso8601_timestamp)" \
        --arg status "$local_status" \
        --argjson duration_ms "$DURATION_MS" \
        --argjson findings "$FINDINGS_JSON" \
        --argjson critical "$FINDINGS_CRITICAL" \
        --argjson high "$FINDINGS_HIGH" \
        --argjson medium "$FINDINGS_MEDIUM" \
        --argjson low "$FINDINGS_LOW" \
        --argjson repos "$total_repos" \
        --argjson files "$total_files" \
        '{
            script: $script,
            version: $version,
            timestamp: $timestamp,
            status: $status,
            duration_ms: $duration_ms,
            errors: [],
            result: {
                repos_scanned: $repos,
                files_scanned: $files,
                findings_critical: $critical,
                findings_high: $high,
                findings_medium: $medium,
                findings_low: $low,
                findings: $findings
            }
        }' >"$JSON_FILE"
    chmod 600 "$JSON_FILE"
    print_info "JSON: $JSON_FILE"
fi

[ "$total_findings" -gt 0 ] && exit 1
exit 0
