#!/usr/bin/env bash
set -u

# ssh-key-audit.sh - Audit SSH authorized_keys for hygiene and risk
# Version: 1.4.0
# Usage: ./ssh-key-audit.sh [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

LOG_DIR="${SCRIPT_DIR}/logs/ssh-key-audit"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/ssh_audit_${TIMESTAMP}.log"
JSON_FILE="${LOG_DIR}/ssh_audit_summary_${TIMESTAMP}.json"

mkdir -p "$LOG_DIR" && chmod 700 "$LOG_DIR" || true
umask 077

# Defaults
USERS=""
ALL_USERS=false
HOME_ROOT="/home"
INCLUDE_SYSTEM=false
SYSTEM_PATHS="/etc/ssh/authorized_keys:/etc/ssh/authorized_keys.d"
FORBID_TYPES="ssh-rsa"
MAX_AGE_DAYS=0   # 0 disables age check
FAIL_ON=""      # comma list: weak-type,perms,stale,duplicate,unsafe-options
OUTPUT_JSON=false
DRY_RUN=false

# State
WARNINGS=()
CRITICALS=()
TOTAL_KEYS=0
TOTAL_USERS=0
TOTAL_SYSTEM_TARGETS=0
USERS_WITH_ISSUES=0

# Colors and print helpers
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
print_error(){ echo -e "${RED}✗ Error:${NC} $1" >&2; echo "[$(get_iso8601_timestamp)] ERROR: $1" >>"$LOG_FILE"; }
print_success(){ echo -e "${GREEN}✓${NC} $1"; echo "[$(get_iso8601_timestamp)] SUCCESS: $1" >>"$LOG_FILE"; }
print_warning(){ echo -e "${YELLOW}⚠${NC} $1"; echo "[$(get_iso8601_timestamp)] WARNING: $1" >>"$LOG_FILE"; WARNINGS+=("$1"); }
print_info(){ echo -e "${BLUE}ℹ${NC} $1"; echo "[$(get_iso8601_timestamp)] INFO: $1" >>"$LOG_FILE"; }
print_section(){ echo ""; echo -e "${BLUE}━━━ $1 ━━━${NC}"; echo ""; echo "[$(get_iso8601_timestamp)] SECTION: $1" >>"$LOG_FILE"; }

show_help(){ cat <<'HELP'
ssh-key-audit.sh - Audit SSH authorized_keys for hygiene and risk

USAGE:
  ./ssh-key-audit.sh [OPTIONS]

OPTIONS:
  --users <list>          Comma-separated usernames to audit
  --all-users             Audit all users under --home-root (default: /home)
  --home-root <path>      Root for home directories (default: /home)
  --system                Include system-level files (defaults below)
  --system-paths <list>   Colon-separated system paths (default: /etc/ssh/authorized_keys:/etc/ssh/authorized_keys.d)
  --forbid-types <list>   Comma list of forbidden key types (default: ssh-rsa)
  --max-age <days>        Flag keys older than N days (0 disables)
  --fail-on <rules>       Comma list: weak-type,perms,stale,duplicate,unsafe-options
  --json                  Output JSON summary
  --dry-run               Preview without reading filesystem
  --help                  Show this help

NOTES:
  - Read-only audit; makes no changes
  - Permissions checked: ~/.ssh (700), authorized_keys (600)
  - Duplicate detection compares base64 key blobs (type+blob)

VERSION: 1.4.0
HELP
}

# Parse CLI
while [[ $# -gt 0 ]]; do
  case $1 in
    --users) USERS="$2"; shift 2;;
    --all-users) ALL_USERS=true; shift;;
    --home-root) HOME_ROOT="$2"; shift 2;;
    --system) INCLUDE_SYSTEM=true; shift;;
    --system-paths) SYSTEM_PATHS="$2"; shift 2;;
    --forbid-types) FORBID_TYPES="$2"; shift 2;;
    --max-age) MAX_AGE_DAYS="$2"; shift 2;;
    --fail-on) FAIL_ON="$2"; shift 2;;
    --json) OUTPUT_JSON=true; shift;;
    --dry-run) DRY_RUN=true; shift;;
    --help) show_help; exit 0;;
    *) print_error "Unknown option: $1"; show_help; exit 1;;
  esac
done

# Validate
if [ -n "$USERS" ] && [ "$ALL_USERS" = true ]; then
  print_error "--users and --all-users are mutually exclusive"; exit 1
fi
if ! [[ "$MAX_AGE_DAYS" =~ ^[0-9]+$ ]]; then
  print_error "--max-age must be a non-negative integer"; exit 1
fi
if [ "$MAX_AGE_DAYS" -gt 3650 ]; then
  print_error "--max-age must be <= 3650"; exit 1
fi

# Helper: trim leading/trailing whitespace from a string
trim() {
  local var="$1"
  # Remove leading whitespace
  var="${var#"${var%%[![:space:]]*}"}"
  # Remove trailing whitespace
  var="${var%"${var##*[![:space:]]}"}"
  echo "$var"
}

# Normalize lists (trim whitespace from each element)
declare -a FORBID_ARRAY=()
if [ -n "$FORBID_TYPES" ]; then
  IFS=',' read -r -a raw_forbid <<< "$FORBID_TYPES"
  for item in "${raw_forbid[@]}"; do
    item=$(trim "$item")
    [ -n "$item" ] && FORBID_ARRAY+=("$item")
  done
fi

declare -a FAIL_ON_ARRAY=()
if [ -n "$FAIL_ON" ]; then
  FAIL_ON_LC=$(printf '%s' "$FAIL_ON" | tr '[:upper:]' '[:lower:]')
  IFS=',' read -r -a raw_failon <<< "$FAIL_ON_LC"
  for item in "${raw_failon[@]}"; do
    item=$(trim "$item")
    [ -n "$item" ] && FAIL_ON_ARRAY+=("$item")
  done
fi

declare -a SYSTEM_PATH_ARRAY=()
if [ -n "$SYSTEM_PATHS" ]; then
  IFS=':' read -r -a raw_syspaths <<< "$SYSTEM_PATHS"
  for item in "${raw_syspaths[@]}"; do
    item=$(trim "$item")
    [ -n "$item" ] && SYSTEM_PATH_ARRAY+=("$item")
  done
fi

contains_rule(){ local x=$(echo "$1" | tr '[:upper:]' '[:lower:]'); shift; [ $# -eq 0 ] && return 1; for r in "$@"; do [ "$x" = "$r" ] && return 0; done; return 1; }

# JSON escape function (handles quotes, backslashes, control chars)
json_escape() {
  local str="$1"
  # Escape backslashes first, then quotes, then control characters
  str="${str//\\/\\\\}"  # \ -> \\
  str="${str//\"/\\\"}"  # " -> \"
  str="${str//$'\t'/\\t}"  # tab -> \t
  str="${str//$'\r'/\\r}"  # CR -> \r
  str="${str//$'\n'/\\n}"  # LF -> \n
  echo "$str"
}

print_section "SSH Key Audit"
print_info "Home root: $HOME_ROOT"
[ -n "$USERS" ] && print_info "Users: $USERS"
[ "$ALL_USERS" = true ] && print_info "All users under: $HOME_ROOT"
[ "$INCLUDE_SYSTEM" = true ] && print_info "System paths: $SYSTEM_PATHS"
print_info "Forbid types: $FORBID_TYPES"
[ "$MAX_AGE_DAYS" -gt 0 ] && print_info "Max age days: $MAX_AGE_DAYS"
[ -n "$FAIL_ON" ] && print_info "Fail-on rules: $FAIL_ON"
print_info "Log file: $LOG_FILE"

if [ "$DRY_RUN" = true ]; then
  print_warning "DRY RUN - no filesystem will be read"
  exit 0
fi

# Discover user list
declare -a USER_LIST=()
if [ -n "$USERS" ]; then
  # Parse comma-separated list and trim whitespace
  IFS=',' read -r -a raw_users <<< "$USERS"
  for item in "${raw_users[@]}"; do
    item=$(trim "$item")
    [ -n "$item" ] && USER_LIST+=("$item")
  done
elif [ "$ALL_USERS" = true ]; then
  # List directories under HOME_ROOT matching typical user homes
  while IFS= read -r d; do
    base=$(basename "$d")
    USER_LIST+=("$base")
  done < <(find "$HOME_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
fi

# Helpers
get_mode() {
  local p="$1"; stat -c %a "$p" 2>/dev/null || stat -f %Lp "$p" 2>/dev/null || echo ""
}

parse_comment_date() {
  # Try to extract YYYY-MM-DD or ISO date from comment
  echo "$1" | grep -Eo '[0-9]{4}[-/][0-9]{2}[-/][0-9]{2}' | head -1 || true
}

days_since_epoch() { date -u -d "$1" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$1" +%s 2>/dev/null || echo "0"; }

now_epoch=$(date -u +%s 2>/dev/null || date +%s)

# Issue counters
crit_count=0; warn_count=0

json_buf_users=()

audit_auth_keys() {
  local target_user="$1"; local path="$2"; local is_system="$3"
  local user_issues=0
  local ssh_dir=$(dirname "$path")
  local ssh_mode="" auth_mode=""
  local keys_json=()
  local duplicate_map=""  # newline-separated list of seen keys

  if [ -d "$ssh_dir" ]; then
    ssh_mode=$(get_mode "$ssh_dir")
    if [ "$ssh_mode" != "700" ]; then
      msg="$target_user: ~/.ssh permissions $ssh_mode (expected 700)"
      if [ -n "$FAIL_ON" ] && contains_rule "perms" "${FAIL_ON_ARRAY[@]}"; then crit_count=$((crit_count+1)); else warn_count=$((warn_count+1)); fi
      print_warning "$msg"; user_issues=$((user_issues+1))
    fi
  fi

  if [ ! -f "$path" ]; then
    return 0
  fi

  auth_mode=$(get_mode "$path")
  if [ "$auth_mode" != "600" ]; then
    msg="$target_user: authorized_keys permissions $auth_mode (expected 600)"
    if [ -n "$FAIL_ON" ] && contains_rule "perms" "${FAIL_ON_ARRAY[@]}"; then crit_count=$((crit_count+1)); else warn_count=$((warn_count+1)); fi
    print_warning "$msg"; user_issues=$((user_issues+1))
  fi

  local file_mtime=$(stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null || echo "0")
  local file_age_days=0
  if [ "$file_mtime" -gt 0 ] && [ "$now_epoch" -gt "$file_mtime" ]; then
    file_age_days=$(( (now_epoch - file_mtime) / 86400 ))
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    # Skip blanks/comments
    echo "$line" | grep -qE '^\s*$|^\s*#' && continue

    # Comprehensive OpenSSH key type regex (RFC 4253, RFC 5656, RFC 8709, OpenSSH extensions)
    # Covers: ssh-rsa, ssh-dss, ssh-ed25519, ecdsa-sha2-*, sk-* (FIDO), *-cert-v01@openssh.com
    local key_type_pattern='(ssh-(rsa|dss|ed25519|ed448)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)(@openssh\.com)?|(ssh-rsa|ssh-dss|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519|sk-ecdsa-sha2-nistp256)-cert-v01@openssh\.com)'

    # Detect key type position (first field or after options)
    key_type=$(echo "$line" | awk '{print $1}' | grep -E "^${key_type_pattern}$")
    options_part=""
    rest="$line"

    if [ -z "$key_type" ]; then
      # Options precede key; extract type and parse options
      # Use awk to find the first key type token (more reliable than sed for this case)
      key_type=$(echo "$line" | awk -v pattern="$key_type_pattern" '{
        for (i=1; i<=NF; i++) {
          if ($i ~ "^" pattern "$") {
            print $i
            exit
          }
        }
      }')

      if [ -n "$key_type" ]; then
        # Extract options (everything before key type)
        # Extract rest (key type + blob + comment)
        # Use word boundary matching to avoid greedy sed issues
        options_part=$(echo "$line" | awk -v kt="$key_type" '{
          for (i=1; i<=NF; i++) {
            if ($i == kt) {
              for (j=1; j<i; j++) printf "%s ", $j
              exit
            }
          }
        }' | sed 's/ $//')

        rest=$(echo "$line" | awk -v kt="$key_type" '{
          found=0
          for (i=1; i<=NF; i++) {
            if (found || $i == kt) {
              found=1
              printf "%s ", $i
            }
          }
        }' | sed 's/ $//')
      fi
    fi

    [ -z "$key_type" ] && { print_warning "$target_user: Unrecognized key line"; warn_count=$((warn_count+1)); user_issues=$((user_issues+1)); continue; }

    key_blob=$(echo "$rest" | awk '{print $2}')
    key_comment=$(echo "$rest" | cut -d' ' -f3-)

    TOTAL_KEYS=$((TOTAL_KEYS+1))

    # Issues per key
    declare -a issues=()
    # Weak type
    for t in "${FORBID_ARRAY[@]}"; do
      if [ "$key_type" = "$t" ]; then
        issues+=("weak-type:$t");
        print_warning "$target_user: weak key type $t in $key_comment"
        if [ -n "$FAIL_ON" ] && contains_rule "weak-type" "${FAIL_ON_ARRAY[@]}"; then crit_count=$((crit_count+1)); else warn_count=$((warn_count+1)); fi
      fi
    done
    # Unsafe options (any options present => flag)
    if [ -n "$options_part" ]; then
      issues+=("unsafe-options")
      print_warning "$target_user: unsafe options ($options_part) in $key_comment"
      if [ -n "$FAIL_ON" ] && contains_rule "unsafe-options" "${FAIL_ON_ARRAY[@]}"; then crit_count=$((crit_count+1)); else warn_count=$((warn_count+1)); fi
    fi
    # Age
    if [ "$MAX_AGE_DAYS" -gt 0 ]; then
      # Try comment date first
      cdate=$(parse_comment_date "$key_comment")
      key_age_days="$file_age_days"
      if [ -n "$cdate" ]; then
        ce=$(days_since_epoch "${cdate//\//-}")
        if [ "$ce" -gt 0 ] && [ "$now_epoch" -gt "$ce" ]; then
          key_age_days=$(( (now_epoch - ce) / 86400 ))
        fi
      fi
      if [ "$key_age_days" -ge "$MAX_AGE_DAYS" ] && [ "$MAX_AGE_DAYS" -gt 0 ]; then
        issues+=("stale:${key_age_days}d")
        print_warning "$target_user: stale key (${key_age_days} days) in $key_comment"
        if [ -n "$FAIL_ON" ] && contains_rule "stale" "${FAIL_ON_ARRAY[@]}"; then crit_count=$((crit_count+1)); else warn_count=$((warn_count+1)); fi
      fi
    fi

    # Duplicate detection by key type + blob
    norm_key="$key_type:$key_blob"
    if echo "$duplicate_map" | grep -qFx "$norm_key"; then
      issues+=("duplicate")
      print_warning "$target_user: duplicate key blob $key_type in $key_comment"
      if [ -n "$FAIL_ON" ] && contains_rule "duplicate" "${FAIL_ON_ARRAY[@]}"; then crit_count=$((crit_count+1)); else warn_count=$((warn_count+1)); fi
    else
      duplicate_map="${duplicate_map}${norm_key}"$'\n'
    fi

    [ ${#issues[@]} -gt 0 ] && user_issues=$((user_issues+1))

    # Build key JSON fragment
    key_issues_json=""
    if [ ${#issues[@]} -gt 0 ]; then
      first=true; for it in "${issues[@]}"; do
        $first || key_issues_json+=" ,"; first=false; key_issues_json+="\"$it\""; done
      key_issues_json="[ $key_issues_json ]"
    else
      key_issues_json="[]"
    fi
    # Escape comment for JSON
    esc_comment=$(json_escape "$key_comment")
    keys_json+=("{ \"type\": \"$key_type\", \"comment\": \"$esc_comment\", \"issues\": $key_issues_json }")
  done < "$path"

  # Aggregate per-user JSON (escape all strings)
  keys_joined=""
  if [ ${#keys_json[@]} -gt 0 ]; then
    first=true; for j in "${keys_json[@]}"; do $first || keys_joined+=" ,"; first=false; keys_joined+="$j"; done
  fi
  local esc_user=$(json_escape "$target_user")
  local esc_path=$(json_escape "$path")
  local is_system_json="false"
  [ "$is_system" = "true" ] && is_system_json="true"
  json_buf_users+=("{ \"user\": \"$esc_user\", \"path\": \"$esc_path\", \"is_system\": $is_system_json, \"keys\": [ $keys_joined ] }")

  if [ $user_issues -gt 0 ]; then USERS_WITH_ISSUES=$((USERS_WITH_ISSUES+1)); fi
}

# Audit user homes
for u in "${USER_LIST[@]}"; do
  TOTAL_USERS=$((TOTAL_USERS+1))
  home="$HOME_ROOT/$u"
  auth="$home/.ssh/authorized_keys"
  audit_auth_keys "$u" "$auth" "false"
done

# Audit system paths
if [ "$INCLUDE_SYSTEM" = true ]; then
  for sp in "${SYSTEM_PATH_ARRAY[@]}"; do
    if [ -d "$sp" ]; then
      while IFS= read -r f; do
        TOTAL_SYSTEM_TARGETS=$((TOTAL_SYSTEM_TARGETS+1))
        audit_auth_keys "system" "$f" "true"
      done < <(find "$sp" -type f -name 'authorized_keys*' 2>/dev/null)
    elif [ -f "$sp" ]; then
      TOTAL_SYSTEM_TARGETS=$((TOTAL_SYSTEM_TARGETS+1))
      audit_auth_keys "system" "$sp" "true"
    fi
  done
fi

print_section "Summary"
total_targets=$((TOTAL_USERS + TOTAL_SYSTEM_TARGETS))
total_targets_with_issues=$USERS_WITH_ISSUES
[ "$TOTAL_USERS" -gt 0 ] && print_info "Users scanned: $TOTAL_USERS"
[ "$TOTAL_SYSTEM_TARGETS" -gt 0 ] && print_info "System targets scanned: $TOTAL_SYSTEM_TARGETS"
[ "$total_targets" -gt 0 ] && print_info "Total targets: $total_targets"
print_info "Targets with issues: $total_targets_with_issues"
print_info "Total keys: $TOTAL_KEYS"
print_info "Warnings: $warn_count, Critical: $crit_count"

if [ "$OUTPUT_JSON" = true ]; then
  users_joined=""
  if [ ${#json_buf_users[@]} -gt 0 ]; then
    first=true; for j in "${json_buf_users[@]}"; do $first || users_joined+=" ,"; first=false; users_joined+="$j"; done
  fi
  esc_home_root=$(json_escape "$HOME_ROOT")
  esc_log_file=$(json_escape "$LOG_FILE")
  cat > "$JSON_FILE" <<EOF
{
  "timestamp": "$(get_iso8601_timestamp)",
  "home_root": "$esc_home_root",
  "users_scanned": $TOTAL_USERS,
  "system_targets_scanned": $TOTAL_SYSTEM_TARGETS,
  "total_targets": $total_targets,
  "targets_with_issues": $total_targets_with_issues,
  "total_keys": $TOTAL_KEYS,
  "warnings": $warn_count,
  "critical": $crit_count,
  "targets": [ $users_joined ],
  "log_file": "$esc_log_file"
}
EOF
  chmod 600 "$JSON_FILE" 2>/dev/null || true
  print_success "JSON summary written: $JSON_FILE"
fi

# Exit code policy
if [ $crit_count -gt 0 ]; then
  exit 2
elif [ $warn_count -gt 0 ]; then
  exit 1
else
  exit 0
fi
