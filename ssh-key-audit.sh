#!/usr/bin/env bash
set -u

# ssh-key-audit.sh - Audit SSH authorized_keys for hygiene and risk
# Version: 1.5.0
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
TARGETS_MISSING_KEYS=0  # Informational: targets with missing authorized_keys

# Risk scoring state (v1.5.0+)
ENABLE_RISK=false
RISK_DETAIL=false
RISK_CONFIG_PATH=""

# Risk scoring requires bash 4+ for associative arrays
if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
  declare -A RISK_SCORES       # RISK_SCORES[user]=score
  declare -A RISK_LEVELS       # RISK_LEVELS[user]=level
  declare -A RISK_FACTORS_JSON # RISK_FACTORS_JSON[user]=json_array_string
fi

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
  --risk                  Enable risk scoring (adds risk_* fields to JSON)
  --risk-detail           Show detailed risk breakdown per target (implies --risk)
  --risk-config PATH      Load risk weights from config file
  --help                  Show this help

NOTES:
  - Read-only audit; makes no changes
  - Permissions checked: ~/.ssh (700), authorized_keys (600)
  - Duplicate detection compares base64 key blobs (type+blob)

VERSION: 1.5.0
HELP
}

# Clamp risk weight to valid range [0, 100]
clamp_weight() {
  local weight=$1

  # Validate numeric
  if ! [[ "$weight" =~ ^[0-9]+$ ]]; then
    print_warning "Invalid risk weight: $weight (not numeric), using 0"
    echo 0
    return
  fi

  # Clamp to [0, 100]
  if [ "$weight" -lt 0 ]; then
    print_warning "Risk weight $weight < 0, clamping to 0"
    echo 0
  elif [ "$weight" -gt 100 ]; then
    print_warning "Risk weight $weight > 100, clamping to 100"
    echo 100
  else
    echo "$weight"
  fi
}

# Set default risk scoring weights
set_default_risk_weights() {
  # Target-level weights
  : "${SSH_AUDIT_RISK_SSH_DIR_PERMS:=40}"
  : "${SSH_AUDIT_RISK_AUTH_KEYS_PERMS:=35}"
  : "${SSH_AUDIT_RISK_AUTH_KEYS_MISSING:=5}"

  # Key type weights (weak crypto)
  : "${SSH_AUDIT_RISK_WEAK_SSH_RSA:=50}"
  : "${SSH_AUDIT_RISK_WEAK_SSH_DSS:=50}"
  : "${SSH_AUDIT_RISK_WEAK_ECDSA_NIST:=0}"  # Default 0, opt-in via config

  # Key hygiene weights
  : "${SSH_AUDIT_RISK_UNSAFE_OPTIONS:=35}"
  : "${SSH_AUDIT_RISK_DUPLICATE:=20}"

  # Stale key thresholds (>= days)
  : "${SSH_AUDIT_RISK_STALE_365:=25}"
  : "${SSH_AUDIT_RISK_STALE_180:=15}"
  : "${SSH_AUDIT_RISK_STALE_90:=8}"

  # Risk level thresholds
  : "${SSH_AUDIT_RISK_THRESHOLD_CRITICAL:=85}"
  : "${SSH_AUDIT_RISK_THRESHOLD_HIGH:=50}"
  : "${SSH_AUDIT_RISK_THRESHOLD_MEDIUM:=20}"
  : "${SSH_AUDIT_RISK_THRESHOLD_LOW:=1}"

  # Scoring modifiers
  : "${SSH_AUDIT_RISK_SYSTEM_MULTIPLIER:=1.25}"
  : "${SSH_AUDIT_RISK_TARGET_MAX:=100}"
  : "${SSH_AUDIT_RISK_KEY_MAX:=100}"

  # Display options
  : "${SSH_AUDIT_RISK_TOP_N:=5}"
}

# Validate all risk weights on config load
validate_risk_config() {
  # Validate and clamp all weights
  SSH_AUDIT_RISK_SSH_DIR_PERMS=$(clamp_weight "$SSH_AUDIT_RISK_SSH_DIR_PERMS")
  SSH_AUDIT_RISK_AUTH_KEYS_PERMS=$(clamp_weight "$SSH_AUDIT_RISK_AUTH_KEYS_PERMS")
  SSH_AUDIT_RISK_AUTH_KEYS_MISSING=$(clamp_weight "$SSH_AUDIT_RISK_AUTH_KEYS_MISSING")
  SSH_AUDIT_RISK_WEAK_SSH_RSA=$(clamp_weight "$SSH_AUDIT_RISK_WEAK_SSH_RSA")
  SSH_AUDIT_RISK_WEAK_SSH_DSS=$(clamp_weight "$SSH_AUDIT_RISK_WEAK_SSH_DSS")
  SSH_AUDIT_RISK_WEAK_ECDSA_NIST=$(clamp_weight "$SSH_AUDIT_RISK_WEAK_ECDSA_NIST")
  SSH_AUDIT_RISK_UNSAFE_OPTIONS=$(clamp_weight "$SSH_AUDIT_RISK_UNSAFE_OPTIONS")
  SSH_AUDIT_RISK_DUPLICATE=$(clamp_weight "$SSH_AUDIT_RISK_DUPLICATE")
  SSH_AUDIT_RISK_STALE_365=$(clamp_weight "$SSH_AUDIT_RISK_STALE_365")
  SSH_AUDIT_RISK_STALE_180=$(clamp_weight "$SSH_AUDIT_RISK_STALE_180")
  SSH_AUDIT_RISK_STALE_90=$(clamp_weight "$SSH_AUDIT_RISK_STALE_90")

  # Validate thresholds
  SSH_AUDIT_RISK_THRESHOLD_CRITICAL=$(clamp_weight "$SSH_AUDIT_RISK_THRESHOLD_CRITICAL")
  SSH_AUDIT_RISK_THRESHOLD_HIGH=$(clamp_weight "$SSH_AUDIT_RISK_THRESHOLD_HIGH")
  SSH_AUDIT_RISK_THRESHOLD_MEDIUM=$(clamp_weight "$SSH_AUDIT_RISK_THRESHOLD_MEDIUM")
  SSH_AUDIT_RISK_THRESHOLD_LOW=$(clamp_weight "$SSH_AUDIT_RISK_THRESHOLD_LOW")
}

# Load risk scoring configuration from file or env
load_risk_config() {
  # Skip if risk scoring disabled
  [ "$ENABLE_RISK" != "true" ] && return 0

  # Check bash version (requires 4+ for associative arrays)
  if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    print_error "Risk scoring requires bash 4.0 or higher (current: ${BASH_VERSION})"
    print_error "Risk scoring disabled for this run"
    ENABLE_RISK=false
    return 1
  fi

  # Always set defaults first (env vars will override)
  set_default_risk_weights

  # Search paths in priority order
  local config_file=""

  # 1. Explicit --risk-config path
  if [ -n "$RISK_CONFIG_PATH" ] && [ -f "$RISK_CONFIG_PATH" ]; then
    config_file="$RISK_CONFIG_PATH"
  # 2. Repo-local override
  elif [ -f "./.ssh-audit.conf" ]; then
    config_file="./.ssh-audit.conf"
  # 3. User home config
  elif [ -f "$HOME/.ssh-audit.conf" ]; then
    config_file="$HOME/.ssh-audit.conf"
  # 4. System-wide config
  elif [ -f "/etc/ssh-audit/config.conf" ]; then
    config_file="/etc/ssh-audit/config.conf"
  fi

  # Source config if found
  if [ -n "$config_file" ]; then
    print_info "Loading risk config: $config_file"

    # shellcheck disable=SC1090
    if source "$config_file" 2>/dev/null; then
      # Validate loaded weights
      validate_risk_config
      return 0
    else
      print_error "Failed to load risk config: $config_file (syntax error)"
      print_error "Risk scoring disabled for this run"
      ENABLE_RISK=false
      return 1
    fi
  fi

  # No config file, using defaults
  print_info "Using built-in risk scoring defaults"
  validate_risk_config
  return 0
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
    --risk) ENABLE_RISK=true; shift;;
    --risk-detail) ENABLE_RISK=true; RISK_DETAIL=true; shift;;
    --risk-config) RISK_CONFIG_PATH="$2"; shift 2;;
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

# Load risk config if enabled (v1.5.0+)
if [ "$ENABLE_RISK" = true ]; then
  load_risk_config
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

# Risk factor descriptions (v1.5.0+)
# Only initialize if bash 4+ is available
if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
  declare -A RISK_DESCRIPTIONS=(
    # Target-level issues
    ["ssh-dir-perms"]="World-readable ~/.ssh directory exposes key material"
    ["auth-keys-perms"]="authorized_keys permissions allow unauthorized modification"
    ["auth-keys-missing"]="No authorized_keys file present (informational)"

    # Key type issues
    ["weak-type:ssh-rsa"]="SHA-1 collision vulnerability in ssh-rsa signatures (deprecated OpenSSH 8.8+)"
    ["weak-type:ssh-dss"]="Weak DSA signatures (removed OpenSSH 7.0+)"
    ["weak-type:ecdsa-sha2-nistp256"]="NIST P-256 curve (potential backdoor concerns)"
    ["weak-type:ecdsa-sha2-nistp384"]="NIST P-384 curve (potential backdoor concerns)"
    ["weak-type:ecdsa-sha2-nistp521"]="NIST P-521 curve (potential backdoor concerns)"

    # Key hygiene issues
    ["unsafe-options"]="Unsafe key options enable command injection or lateral movement"
    ["duplicate"]="Key reuse across targets increases blast radius on compromise"
    ["stale"]="Key age exceeds policy threshold (rotation recommended)"
  )
fi

# Calculate risk score for a target user
# Args: target_user, is_system, target_issues (array ref), keys_data (array)
# Returns: JSON string with risk_score, risk_level, risk_factors
calculate_risk_score() {
  local target_user="$1"
  local is_system="$2"
  local -n _target_issues_ref="$3"
  shift 3
  local keys_data=("$@")

  local target_score=0
  local max_key_score=0
  local -a risk_factors=()

  # Process target-level issues
  for issue in "${_target_issues_ref[@]}"; do
    case "$issue" in
      ssh-dir-perms:*)
        local perms="${issue#ssh-dir-perms:}"
        target_score=$((target_score + SSH_AUDIT_RISK_SSH_DIR_PERMS))
        local desc="${RISK_DESCRIPTIONS[ssh-dir-perms]} (perms: $perms)"
        risk_factors+=("{\"type\": \"target\", \"factor\": \"ssh-dir-perms\", \"weight\": $SSH_AUDIT_RISK_SSH_DIR_PERMS, \"description\": \"$(json_escape "$desc")\"}")
        ;;
      auth-keys-perms:*)
        local perms="${issue#auth-keys-perms:}"
        target_score=$((target_score + SSH_AUDIT_RISK_AUTH_KEYS_PERMS))
        local desc="${RISK_DESCRIPTIONS[auth-keys-perms]} (perms: $perms)"
        risk_factors+=("{\"type\": \"target\", \"factor\": \"auth-keys-perms\", \"weight\": $SSH_AUDIT_RISK_AUTH_KEYS_PERMS, \"description\": \"$(json_escape "$desc")\"}")
        ;;
      auth-keys-missing)
        target_score=$((target_score + SSH_AUDIT_RISK_AUTH_KEYS_MISSING))
        risk_factors+=("{\"type\": \"target\", \"factor\": \"auth-keys-missing\", \"weight\": $SSH_AUDIT_RISK_AUTH_KEYS_MISSING, \"description\": \"$(json_escape "${RISK_DESCRIPTIONS[auth-keys-missing]}")\"}")
        ;;
    esac
  done

  # Cap target score
  [ "$target_score" -gt "$SSH_AUDIT_RISK_TARGET_MAX" ] && target_score=$SSH_AUDIT_RISK_TARGET_MAX

  # Process key-level issues
  local key_index=0
  for key_data in "${keys_data[@]}"; do
    IFS='|' read -r key_type key_comment issues_str <<< "$key_data"
    IFS=',' read -r -a key_issues <<< "$issues_str"

    local key_score=0

    for issue in "${key_issues[@]}"; do
      case "$issue" in
        weak-type:ssh-rsa)
          key_score=$((key_score + SSH_AUDIT_RISK_WEAK_SSH_RSA))
          risk_factors+=("{\"type\": \"key\", \"key_index\": $key_index, \"factor\": \"weak-type:ssh-rsa\", \"weight\": $SSH_AUDIT_RISK_WEAK_SSH_RSA, \"description\": \"$(json_escape "${RISK_DESCRIPTIONS[weak-type:ssh-rsa]}")\"}")
          ;;
        weak-type:ssh-dss)
          key_score=$((key_score + SSH_AUDIT_RISK_WEAK_SSH_DSS))
          risk_factors+=("{\"type\": \"key\", \"key_index\": $key_index, \"factor\": \"weak-type:ssh-dss\", \"weight\": $SSH_AUDIT_RISK_WEAK_SSH_DSS, \"description\": \"$(json_escape "${RISK_DESCRIPTIONS[weak-type:ssh-dss]}")\"}")
          ;;
        weak-type:ecdsa-sha2-nistp*)
          [ "$SSH_AUDIT_RISK_WEAK_ECDSA_NIST" -gt 0 ] && {
            key_score=$((key_score + SSH_AUDIT_RISK_WEAK_ECDSA_NIST))
            local curve="${issue#weak-type:}"
            local desc="${RISK_DESCRIPTIONS[weak-type:$curve]}"
            risk_factors+=("{\"type\": \"key\", \"key_index\": $key_index, \"factor\": \"$issue\", \"weight\": $SSH_AUDIT_RISK_WEAK_ECDSA_NIST, \"description\": \"$(json_escape "$desc")\"}")
          }
          ;;
        unsafe-options:*)
          key_score=$((key_score + SSH_AUDIT_RISK_UNSAFE_OPTIONS))
          local opts="${issue#unsafe-options:}"
          local desc="${RISK_DESCRIPTIONS[unsafe-options]} ($opts)"
          risk_factors+=("{\"type\": \"key\", \"key_index\": $key_index, \"factor\": \"unsafe-options\", \"weight\": $SSH_AUDIT_RISK_UNSAFE_OPTIONS, \"description\": \"$(json_escape "$desc")\"}")
          ;;
        duplicate:*)
          key_score=$((key_score + SSH_AUDIT_RISK_DUPLICATE))
          local count="${issue#duplicate:}"
          local desc="${RISK_DESCRIPTIONS[duplicate]} (found on $count targets)"
          risk_factors+=("{\"type\": \"key\", \"key_index\": $key_index, \"factor\": \"duplicate\", \"weight\": $SSH_AUDIT_RISK_DUPLICATE, \"description\": \"$(json_escape "$desc")\"}")
          ;;
        stale:*)
          local age_days="${issue#stale:}"
          local stale_weight=0
          local desc="${RISK_DESCRIPTIONS[stale]}"

          # Use >= threshold logic (non-additive)
          if [ "$age_days" -ge 365 ]; then
            stale_weight=$SSH_AUDIT_RISK_STALE_365
            desc="Key age exceeds threshold ($age_days days >= 365)"
          elif [ "$age_days" -ge 180 ]; then
            stale_weight=$SSH_AUDIT_RISK_STALE_180
            desc="Key age exceeds threshold ($age_days days >= 180)"
          elif [ "$age_days" -ge 90 ]; then
            stale_weight=$SSH_AUDIT_RISK_STALE_90
            desc="Key age exceeds threshold ($age_days days >= 90)"
          fi

          if [ "$stale_weight" -gt 0 ]; then
            key_score=$((key_score + stale_weight))
            risk_factors+=("{\"type\": \"key\", \"key_index\": $key_index, \"factor\": \"stale\", \"weight\": $stale_weight, \"description\": \"$(json_escape "$desc")\"}")
          fi
          ;;
      esac
    done

    # Cap key score
    [ "$key_score" -gt "$SSH_AUDIT_RISK_KEY_MAX" ] && key_score=$SSH_AUDIT_RISK_KEY_MAX

    # Track max key score
    [ "$key_score" -gt "$max_key_score" ] && max_key_score=$key_score

    key_index=$((key_index + 1))
  done

  # Calculate final score: target + max_key, capped at 100
  local raw_score=$((target_score + max_key_score))
  [ "$raw_score" -gt 100 ] && raw_score=100

  # Apply system multiplier
  local final_score=$raw_score
  if [ "$is_system" = true ]; then
    # Use awk for floating point multiplication
    final_score=$(awk -v score="$raw_score" -v mult="$SSH_AUDIT_RISK_SYSTEM_MULTIPLIER" 'BEGIN { printf "%.0f", score * mult }')
    [ "$final_score" -gt 100 ] && final_score=100
  fi

  # Determine risk level
  local risk_level="CLEAN"
  if [ "$final_score" -ge "$SSH_AUDIT_RISK_THRESHOLD_CRITICAL" ]; then
    risk_level="CRITICAL"
  elif [ "$final_score" -ge "$SSH_AUDIT_RISK_THRESHOLD_HIGH" ]; then
    risk_level="HIGH"
  elif [ "$final_score" -ge "$SSH_AUDIT_RISK_THRESHOLD_MEDIUM" ]; then
    risk_level="MEDIUM"
  elif [ "$final_score" -ge "$SSH_AUDIT_RISK_THRESHOLD_LOW" ]; then
    risk_level="LOW"
  fi

  # Build JSON response
  local factors_json=""
  if [ ${#risk_factors[@]} -gt 0 ]; then
    factors_json=$(IFS=','; echo "${risk_factors[*]}")
  fi

  echo "{ \"risk_score\": $final_score, \"risk_level\": \"$risk_level\", \"risk_factors\": [ $factors_json ] }"
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
  declare -a target_issues=()  # Track target-level issues for JSON
  declare -a keys_data=()       # Track key data for risk scoring (v1.5.0+)

  if [ -d "$ssh_dir" ]; then
    ssh_mode=$(get_mode "$ssh_dir")
    if [ "$ssh_mode" != "700" ]; then
      msg="$target_user: ~/.ssh permissions $ssh_mode (expected 700)"
      if [ -n "$FAIL_ON" ] && contains_rule "perms" "${FAIL_ON_ARRAY[@]}"; then crit_count=$((crit_count+1)); else warn_count=$((warn_count+1)); fi
      print_warning "$msg"; user_issues=$((user_issues+1))
      target_issues+=("ssh-dir-perms:$ssh_mode")
    fi
  fi

  # Early exit if no authorized_keys, but still create JSON entry below
  if [ ! -f "$path" ]; then
    # Missing authorized_keys is informational (users may have no SSH access)
    # BUT: It's still tracked in target_issues for SIEM visibility
    # Increment USERS_WITH_ISSUES only if there are OTHER issues (e.g., .ssh perms)
    target_issues+=("auth-keys-missing")
    TARGETS_MISSING_KEYS=$((TARGETS_MISSING_KEYS+1))
    # Aggregate per-user JSON (even with no keys)
    local esc_user=$(json_escape "$target_user")
    local esc_path=$(json_escape "$path")
    local is_system_json="false"
    [ "$is_system" = "true" ] && is_system_json="true"
    # Build target_issues JSON
    local target_issues_json="[]"
    if [ ${#target_issues[@]} -gt 0 ]; then
      local first=true; target_issues_json=""; for it in "${target_issues[@]}"; do
        $first || target_issues_json+=", "; first=false; target_issues_json+="\"$it\""; done
      target_issues_json="[ $target_issues_json ]"
    fi

    # Calculate risk score for missing authorized_keys (v1.5.0+)
    if [ "$ENABLE_RISK" = true ]; then
      local risk_json=$(calculate_risk_score "$target_user" "$is_system" target_issues)
      local score=$(echo "$risk_json" | awk -F'"risk_score": ' '{print $2}' | awk -F',' '{print $1}')
      local level=$(echo "$risk_json" | awk -F'"risk_level": "' '{print $2}' | awk -F'"' '{print $1}')
      local factors=$(echo "$risk_json" | awk -F'"risk_factors": ' '{print $2}' | sed 's/}$//')
      RISK_SCORES["$target_user"]=$score
      RISK_LEVELS["$target_user"]=$level
      RISK_FACTORS_JSON["$target_user"]=$factors
      json_buf_users+=("{ \"user\": \"$esc_user\", \"path\": \"$esc_path\", \"is_system\": $is_system_json, \"target_issues\": $target_issues_json, \"risk_score\": $score, \"risk_level\": \"$level\", \"risk_factors\": $factors, \"keys\": [ ] }")
    else
      json_buf_users+=("{ \"user\": \"$esc_user\", \"path\": \"$esc_path\", \"is_system\": $is_system_json, \"target_issues\": $target_issues_json, \"keys\": [ ] }")
    fi

    # Count this target as having issues only if there are problems BEYOND missing file
    # (e.g., .ssh permission issues detected earlier)
    if [ $user_issues -gt 0 ]; then USERS_WITH_ISSUES=$((USERS_WITH_ISSUES+1)); fi
    return 0
  fi

  auth_mode=$(get_mode "$path")
  if [ "$auth_mode" != "600" ]; then
    msg="$target_user: authorized_keys permissions $auth_mode (expected 600)"
    if [ -n "$FAIL_ON" ] && contains_rule "perms" "${FAIL_ON_ARRAY[@]}"; then crit_count=$((crit_count+1)); else warn_count=$((warn_count+1)); fi
    print_warning "$msg"; user_issues=$((user_issues+1))
    target_issues+=("auth-keys-perms:$auth_mode")
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
    # Covers: ssh-rsa, ssh-dss, ssh-ed25519, ssh-ed448, ecdsa-sha2-*, sk-* (FIDO), *-cert-v01@openssh.com
    local key_type_pattern='(ssh-(rsa|dss|ed25519|ed448)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)(@openssh\.com)?|(ssh-rsa|ssh-dss|ssh-ed25519|ssh-ed448|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)-cert-v01@openssh\.com)'

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

    # Build keys_data for risk scoring (if enabled) - v1.5.0+
    if [ "$ENABLE_RISK" = true ]; then
      local issues_str=$(IFS=','; echo "${issues[*]}")
      keys_data+=("$key_type|$key_comment|$issues_str")
    fi
  done < "$path"

  # Calculate risk score (v1.5.0+)
  if [ "$ENABLE_RISK" = true ]; then
    local risk_json=$(calculate_risk_score "$target_user" "$is_system" target_issues "${keys_data[@]}")

    # Parse and store in associative arrays (using awk, not grep!)
    local score=$(echo "$risk_json" | awk -F'"risk_score": ' '{print $2}' | awk -F',' '{print $1}')
    local level=$(echo "$risk_json" | awk -F'"risk_level": "' '{print $2}' | awk -F'"' '{print $1}')
    local factors=$(echo "$risk_json" | awk -F'"risk_factors": ' '{print $2}' | sed 's/}$//')

    RISK_SCORES["$target_user"]=$score
    RISK_LEVELS["$target_user"]=$level
    RISK_FACTORS_JSON["$target_user"]=$factors
  fi

  # Aggregate per-user JSON (escape all strings)
  keys_joined=""
  if [ ${#keys_json[@]} -gt 0 ]; then
    first=true; for j in "${keys_json[@]}"; do $first || keys_joined+=" ,"; first=false; keys_joined+="$j"; done
  fi
  local esc_user=$(json_escape "$target_user")
  local esc_path=$(json_escape "$path")
  local is_system_json="false"
  [ "$is_system" = "true" ] && is_system_json="true"
  # Build target_issues JSON
  local target_issues_json="[]"
  if [ ${#target_issues[@]} -gt 0 ]; then
    local first=true; target_issues_json=""; for it in "${target_issues[@]}"; do
      $first || target_issues_json+=", "; first=false; target_issues_json+="\"$it\""; done
    target_issues_json="[ $target_issues_json ]"
  fi

  # Build final JSON with risk fields (v1.5.0+)
  if [ "$ENABLE_RISK" = true ]; then
    json_buf_users+=("{ \"user\": \"$esc_user\", \"path\": \"$esc_path\", \"is_system\": $is_system_json, \"target_issues\": $target_issues_json, \"risk_score\": ${RISK_SCORES[$target_user]}, \"risk_level\": \"${RISK_LEVELS[$target_user]}\", \"risk_factors\": ${RISK_FACTORS_JSON[$target_user]}, \"keys\": [ $keys_joined ] }")
  else
    json_buf_users+=("{ \"user\": \"$esc_user\", \"path\": \"$esc_path\", \"is_system\": $is_system_json, \"target_issues\": $target_issues_json, \"keys\": [ $keys_joined ] }")
  fi

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

# Print risk summary with color-coded distribution (v1.5.0+)
print_risk_summary() {
  [ "$ENABLE_RISK" != "true" ] && return 0

  local -a critical_targets=()
  local -a high_targets=()
  local -a medium_targets=()
  local -a low_targets=()
  local -a clean_targets=()

  # Group targets by risk level
  for user in "${!RISK_LEVELS[@]}"; do
    local level="${RISK_LEVELS[$user]}"
    case "$level" in
      CRITICAL) critical_targets+=("$user");;
      HIGH) high_targets+=("$user");;
      MEDIUM) medium_targets+=("$user");;
      LOW) low_targets+=("$user");;
      CLEAN) clean_targets+=("$user");;
    esac
  done

  # Print distribution
  echo -e "${BLUE}━━━ Risk Distribution ━━━${NC}"
  echo ""
  [ ${#critical_targets[@]} -gt 0 ] && echo -e "${RED}🔴 CRITICAL:${NC} ${#critical_targets[@]} targets"
  [ ${#high_targets[@]} -gt 0 ] && echo -e "${RED}🟠 HIGH:${NC} ${#high_targets[@]} targets"
  [ ${#medium_targets[@]} -gt 0 ] && echo -e "${YELLOW}🟡 MEDIUM:${NC} ${#medium_targets[@]} targets"
  [ ${#low_targets[@]} -gt 0 ] && echo -e "${BLUE}🔵 LOW:${NC} ${#low_targets[@]} targets"
  [ ${#clean_targets[@]} -gt 0 ] && echo -e "${GREEN}🟢 CLEAN:${NC} ${#clean_targets[@]} targets"
  echo ""

  # Build sorted list of risky targets (score descending)
  local -a risky_targets=()
  risky_targets+=("${critical_targets[@]}")
  risky_targets+=("${high_targets[@]}")
  risky_targets+=("${medium_targets[@]}")
  risky_targets+=("${low_targets[@]}")

  # Show top N risky targets
  if [ ${#risky_targets[@]} -gt 0 ]; then
    echo -e "${BLUE}━━━ Top Risky Targets ━━━${NC}"
    echo ""
    local shown=0
    for user in "${risky_targets[@]}"; do
      [ "$shown" -ge "$SSH_AUDIT_RISK_TOP_N" ] && break
      local score="${RISK_SCORES[$user]}"
      local level="${RISK_LEVELS[$user]}"

      # Color-code by level
      local color="$NC"
      local icon="  "
      case "$level" in
        CRITICAL) color="$RED"; icon="🔴";;
        HIGH) color="$RED"; icon="🟠";;
        MEDIUM) color="$YELLOW"; icon="🟡";;
        LOW) color="$BLUE"; icon="🔵";;
      esac

      # Extract top 2 risk factors for preview
      local factors_json="${RISK_FACTORS_JSON[$user]}"
      local top_factors=$(echo "$factors_json" | awk -F'"factor": "' '{for (i=2; i<=NF; i++) print $i}' | awk -F'"' '{print $1}' | head -2)
      local factor_preview=$(echo "$top_factors" | tr '\n' ', ' | sed 's/, $//')

      echo -e "$icon ${color}${user}${NC} (score: $score, level: $level)"
      [ -n "$factor_preview" ] && echo -e "   Top issues: $factor_preview"
      shown=$((shown + 1))
    done
    echo ""

    # Show detailed breakdown if enabled
    if [ "$RISK_DETAIL" = true ]; then
      for user in "${risky_targets[@]}"; do
        print_risk_detail "$user"
      done
    fi
  else
    echo -e "${GREEN}✓ All targets are clean (no risk factors detected)${NC}"
    echo ""
  fi
}

# Print detailed risk breakdown for a specific target (v1.5.0+)
print_risk_detail() {
  local user="$1"
  local score="${RISK_SCORES[$user]}"
  local level="${RISK_LEVELS[$user]}"
  local factors_json="${RISK_FACTORS_JSON[$user]}"

  # Color-code by level
  local color="$NC"
  local icon="  "
  case "$level" in
    CRITICAL) color="$RED"; icon="🔴";;
    HIGH) color="$RED"; icon="🟠";;
    MEDIUM) color="$YELLOW"; icon="🟡";;
    LOW) color="$BLUE"; icon="🔵";;
    CLEAN) color="$GREEN"; icon="🟢";;
  esac

  echo -e "${BLUE}━━━ Detailed Risk: ${color}${user}${NC} ${BLUE}(score: $score, level: $level) ━━━${NC}"
  echo ""

  # Parse factors JSON (minimal parsing, using awk not grep)
  # Extract target-level issues
  local target_factors=$(echo "$factors_json" | awk -F'"type": "target"' '{for (i=2; i<=NF; i++) print $i}' | awk -F'"factor": "' '{if ($2) print $2}' | awk -F'"' '{print $1}')
  if [ -n "$target_factors" ]; then
    echo -e "${YELLOW}Target-level issues:${NC}"
    while IFS= read -r factor; do
      [ -z "$factor" ] && continue
      local weight=$(echo "$factors_json" | awk -v f="$factor" -F'"factor": "'"$factor"'"' '{if ($2) print $2}' | awk -F'"weight": ' '{if ($2) print $2}' | awk -F',' '{print $1}' | head -1)
      local desc=$(echo "$factors_json" | awk -v f="$factor" -F'"factor": "'"$factor"'"' '{if ($2) print $2}' | awk -F'"description": "' '{if ($2) print $2}' | awk -F'"' '{print $1}' | head -1)
      echo -e "  $icon $factor (weight: $weight)"
      [ -n "$desc" ] && echo -e "     $desc"
    done <<< "$target_factors"
    echo ""
  fi

  # Extract key-level issues (group by key_index)
  local key_factors=$(echo "$factors_json" | awk -F'"type": "key"' '{for (i=2; i<=NF; i++) print $i}')
  if [ -n "$key_factors" ]; then
    echo -e "${YELLOW}Key-level issues:${NC}"
    # Group by key_index
    local -A key_issues_map
    while IFS= read -r factor_block; do
      [ -z "$factor_block" ] && continue
      local key_idx=$(echo "$factor_block" | awk -F'"key_index": ' '{if ($2) print $2}' | awk -F',' '{print $1}' | head -1)
      local factor=$(echo "$factor_block" | awk -F'"factor": "' '{if ($2) print $2}' | awk -F'"' '{print $1}' | head -1)
      local weight=$(echo "$factor_block" | awk -F'"weight": ' '{if ($2) print $2}' | awk -F',' '{print $1}' | head -1)
      local desc=$(echo "$factor_block" | awk -F'"description": "' '{if ($2) print $2}' | awk -F'"' '{print $1}' | head -1)
      [ -z "$factor" ] && continue
      echo -e "  $icon Key #$key_idx: $factor (weight: $weight)"
      [ -n "$desc" ] && echo -e "     $desc"
    done <<< "$key_factors"
    echo ""
  fi
}

print_section "Summary"
total_targets=$((TOTAL_USERS + TOTAL_SYSTEM_TARGETS))
total_targets_with_issues=$USERS_WITH_ISSUES
[ "$TOTAL_USERS" -gt 0 ] && print_info "Users scanned: $TOTAL_USERS"
[ "$TOTAL_SYSTEM_TARGETS" -gt 0 ] && print_info "System targets scanned: $TOTAL_SYSTEM_TARGETS"
[ "$total_targets" -gt 0 ] && print_info "Total targets: $total_targets"
print_info "Targets with issues: $total_targets_with_issues"
[ "$TARGETS_MISSING_KEYS" -gt 0 ] && print_info "Targets with missing authorized_keys: $TARGETS_MISSING_KEYS (informational)"
print_info "Total keys: $TOTAL_KEYS"
print_info "Warnings: $warn_count, Critical: $crit_count"

# Add risk summary with blank line separator (v1.5.0+)
if [ "$ENABLE_RISK" = true ]; then
  echo  # Blank line between sections
  print_risk_summary
fi

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
