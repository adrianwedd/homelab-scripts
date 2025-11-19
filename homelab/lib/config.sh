#!/usr/bin/env bash
# homelab/lib/config.sh - Configuration management with script detection
# Part of homelab v1.0.0

# Script path storage
# Note: We use environment variables instead of associative arrays for bash 3.x compatibility
# Scripts are stored as HOMELAB_SCRIPT_<NAME> variables

# Helper functions for script path storage (bash 3.x compatible)
get_script_path() {
  local script_name="$1"
  # Convert script-name.sh to SCRIPT_NAME_SH
  local var_name="HOMELAB_SCRIPT_$(echo "$script_name" | tr '[:lower:]' '[:upper:]' | sed 's/[.-]/_/g')"
  echo "${!var_name:-}"
}

set_script_path() {
  local script_name="$1"
  local script_path="$2"
  # Convert script-name.sh to SCRIPT_NAME_SH
  local var_name="HOMELAB_SCRIPT_$(echo "$script_name" | tr '[:lower:]' '[:upper:]' | sed 's/[.-]/_/g')"
  eval "$var_name=\"$script_path\""
}

# Default configuration values
set_default_config() {
  # Paths
  : "${HOMELAB_LOG_DIR:=$HOME/homelab-logs}"
  : "${HOMELAB_CONFIG_DIR:=$HOME/.config/homelab}"
  : "${HOMELAB_CONFIG_FILE:=$HOMELAB_CONFIG_DIR/homelab.conf}"
  : "${HOMELAB_MAX_LOG_AGE_DAYS:=90}"

  # Display options
  : "${HOMELAB_COLOR:=true}"
  : "${HOMELAB_VERBOSE:=false}"

  # Workflow defaults - Morning
  : "${MORNING_SSH_AUDIT_OPTS:=--all-users --risk}"
  : "${MORNING_NMAP_OPTS:=--delta}"
  : "${MORNING_UPDATE_OPTS:=--dry-run}"

  # Workflow defaults - Weekly
  : "${WEEKLY_CLEANUP_OPTS:=--smart-gc --clean-venvs --venv-age 60}"
  : "${WEEKLY_SSH_AUDIT_OPTS:=--all-users --risk-detail}"
  : "${WEEKLY_NMAP_OPTS:=--full --delta}"
  : "${WEEKLY_UPDATE_OPTS:=}"

  # Workflow defaults - Emergency
  : "${EMERGENCY_DISK_THRESHOLD_GB:=10}"
  : "${EMERGENCY_CLEANUP_OPTS:=--full-gc --clean-venvs --venv-age 30 -y}"

  # Workflow defaults - Pre-deploy
  : "${PREDEPLOY_FAIL_ON_RISK:=high}"
  : "${PREDEPLOY_MIN_DISK_GB:=10}"

  # Script paths (empty = auto-detect)
  : "${HOMELAB_DISK_CLEANUP:=}"
  : "${HOMELAB_SSH_AUDIT:=}"
  : "${HOMELAB_NMAP_SCAN:=}"
  : "${HOMELAB_RCLONE_SYNC:=}"
  : "${HOMELAB_UPDATE_ALL:=}"
  : "${HOMELAB_SMART_CLEANUP:=}"
}

# Detect script location with fallback chain
detect_script() {
  local script_name="$1"
  local config_var="$2"  # e.g., HOMELAB_SSH_AUDIT

  # 1. Use explicit config path if set and executable
  if [ -n "${!config_var:-}" ] && [ -x "${!config_var}" ]; then
    echo "${!config_var}"
    return 0
  fi

  # 2. Check parent directory (repo root) - prioritize working scripts
  local parent_dir="$(dirname "$SCRIPT_DIR")"
  if [ -x "${parent_dir}/${script_name}" ]; then
    echo "${parent_dir}/${script_name}"
    return 0
  fi

  # 3. Check same directory as homelab.sh (fallback for standalone installs)
  if [ -x "${SCRIPT_DIR}/${script_name}" ]; then
    echo "${SCRIPT_DIR}/${script_name}"
    return 0
  fi

  # 4. Check common bin locations
  for dir in "$HOME/bin" "/usr/local/bin" "/opt/homelab"; do
    if [ -x "${dir}/${script_name}" ]; then
      echo "${dir}/${script_name}"
      return 0
    fi
  done

  # 5. Search PATH
  if command -v "$script_name" >/dev/null 2>&1; then
    command -v "$script_name"
    return 0
  fi

  # Not found
  return 1
}

# Validate all required scripts
validate_scripts() {
  local missing_required=()
  local missing_optional=()

  # Core scripts (required for basic functionality)
  for script in disk-cleanup.sh update-all.sh; do
    local var_name="HOMELAB_$(echo "$script" | tr '[:lower:]' '[:upper:]' | sed 's/[.-]/_/g')"
    if detected_path=$(detect_script "$script" "$var_name"); then
      set_script_path "$script" "$detected_path"
    else
      missing_required+=("$script")
      set_script_path "$script" ""
    fi
  done

  # Optional scripts (workflows degrade gracefully)
  for script in ssh-key-audit.sh nmap-scan.sh rclone-sync.sh smart-cleanup.sh; do
    local var_name="HOMELAB_$(echo "$script" | tr '[:lower:]' '[:upper:]' | sed 's/[.-]/_/g')"
    if detected_path=$(detect_script "$script" "$var_name"); then
      set_script_path "$script" "$detected_path"
    else
      missing_optional+=("$script")
      set_script_path "$script" ""
    fi
  done

  # Report missing required scripts (fatal)
  if [ ${#missing_required[@]} -gt 0 ]; then
    print_error "Required scripts not found:"
    for script in "${missing_required[@]}"; do
      echo "  - $script"
    done
    echo ""
    echo "Install missing scripts or set paths in $HOMELAB_CONFIG_FILE"
    echo ""
    echo "Example config:"
    for script in "${missing_required[@]}"; do
      local var_name="HOMELAB_$(echo "$script" | tr '[:lower:]' '[:upper:]' | sed 's/[.-]/_/g')"
      echo "  ${var_name}=\"/path/to/${script}\""
    done
    echo ""
    echo "Download scripts from: https://github.com/adrianwedd/homelab-scripts"
    return 1
  fi

  # Warn about optional scripts (non-fatal)
  if [ ${#missing_optional[@]} -gt 0 ]; then
    print_warning "Optional scripts not found (some workflows will skip steps):"
    for script in "${missing_optional[@]}"; do
      echo "  - $script"
    done
    echo ""
  fi

  return 0
}


# Load configuration file
load_config() {
  # Set defaults first
  set_default_config

  # Create config directory if needed
  mkdir -p "$HOMELAB_CONFIG_DIR"

  # Load user config if exists
  if [ -f "$HOMELAB_CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$HOMELAB_CONFIG_FILE"
  fi

  # Create example config if none exists
  if [ ! -f "$HOMELAB_CONFIG_FILE" ]; then
    create_example_config
  fi

  # Validate scripts are available
  validate_scripts || return 1

  # Create log directory
  mkdir -p "$HOMELAB_LOG_DIR"
  chmod 700 "$HOMELAB_LOG_DIR"

  return 0
}

# Create example configuration file
create_example_config() {
  cat > "$HOMELAB_CONFIG_FILE" <<'EOF'
# Homelab v1.0.0 Configuration
# This file is sourced by homelab.sh - use bash syntax

# =============================================================================
# PATHS
# =============================================================================

# Log directory
HOMELAB_LOG_DIR="$HOME/homelab-logs"

# Maximum log age in days (older logs auto-deleted)
HOMELAB_MAX_LOG_AGE_DAYS=90

# =============================================================================
# SCRIPT PATHS
# =============================================================================
# Leave empty for auto-detection, or specify custom paths
# Auto-detection searches:
#   1. Explicit config path (below)
#   2. Same directory as homelab.sh
#   3. $HOME/bin/
#   4. /usr/local/bin/
#   5. /opt/homelab/
#   6. $PATH

HOMELAB_DISK_CLEANUP=""
HOMELAB_SSH_AUDIT=""
HOMELAB_NMAP_SCAN=""
HOMELAB_RCLONE_SYNC=""
HOMELAB_UPDATE_ALL=""
HOMELAB_SMART_CLEANUP=""

# Example custom paths:
# HOMELAB_DISK_CLEANUP="/custom/path/disk-cleanup.sh"
# HOMELAB_SSH_AUDIT="/opt/scripts/ssh-key-audit.sh"

# =============================================================================
# DISPLAY OPTIONS
# =============================================================================

HOMELAB_COLOR=true
HOMELAB_VERBOSE=false

# =============================================================================
# WORKFLOW DEFAULTS
# =============================================================================

# Morning Routine
MORNING_SSH_AUDIT_OPTS="--all-users --risk"
MORNING_NMAP_OPTS="--delta"
MORNING_UPDATE_OPTS="--dry-run"

# Weekly Maintenance
WEEKLY_CLEANUP_OPTS="--smart-gc --clean-venvs --venv-age 60"
WEEKLY_SSH_AUDIT_OPTS="--all-users --risk-detail"
WEEKLY_NMAP_OPTS="--full --delta"
WEEKLY_UPDATE_OPTS=""

# Emergency Cleanup
EMERGENCY_DISK_THRESHOLD_GB=10
EMERGENCY_CLEANUP_OPTS="--full-gc --clean-venvs --venv-age 30 -y"

# Pre-Deploy Checks
PREDEPLOY_FAIL_ON_RISK="high"
PREDEPLOY_MIN_DISK_GB=10

# =============================================================================
# FUTURE FEATURES (Phase 2+)
# =============================================================================

# Webhook notifications (coming in Phase 2)
# HOMELAB_WEBHOOK_URL=""
# HOMELAB_WEBHOOK_EVENTS="cleanup,ssh-critical,network-change"

# Scheduling (coming in Phase 2)
# HOMELAB_SCHEDULE_MORNING="0 6 * * *"
# HOMELAB_SCHEDULE_WEEKLY="0 3 * * 0"
EOF

  chmod 600 "$HOMELAB_CONFIG_FILE"
  print_info "Created example config: $HOMELAB_CONFIG_FILE"
}

# Show current configuration
show_config() {
  print_section "Homelab Configuration"

  echo "Config file: $HOMELAB_CONFIG_FILE"
  echo "Log directory: $HOMELAB_LOG_DIR"
  echo ""

  echo "Detected Scripts:"
  for script in disk-cleanup.sh update-all.sh ssh-key-audit.sh nmap-scan.sh rclone-sync.sh smart-cleanup.sh; do
    local script_path=$(get_script_path "$script")
    if [ -n "$script_path" ]; then
      echo "  ✓ $script → $script_path"
    else
      echo "  ✗ $script → not found"
    fi
  done
  echo ""

  echo "Workflow Defaults:"
  echo "  Morning:"
  echo "    SSH Audit: $MORNING_SSH_AUDIT_OPTS"
  echo "    Network:   $MORNING_NMAP_OPTS"
  echo "    Updates:   $MORNING_UPDATE_OPTS"
  echo ""
  echo "  Weekly:"
  echo "    Cleanup:   $WEEKLY_CLEANUP_OPTS"
  echo "    SSH Audit: $WEEKLY_SSH_AUDIT_OPTS"
  echo "    Network:   $WEEKLY_NMAP_OPTS"
  echo ""
}

# Validate configuration
validate_config() {
  local warnings=0

  print_section "Configuration Validation"

  echo "✓ Configuration file: $HOMELAB_CONFIG_FILE"

  # Check log directory
  if [ -d "$HOMELAB_LOG_DIR" ] && [ -w "$HOMELAB_LOG_DIR" ]; then
    local log_count=$(find "$HOMELAB_LOG_DIR" -name "homelab_*.log" -type f 2>/dev/null | wc -l | tr -d ' ')
    echo "✓ Log directory: $HOMELAB_LOG_DIR ($log_count logs)"
  elif mkdir -p "$HOMELAB_LOG_DIR" 2>/dev/null && chmod 700 "$HOMELAB_LOG_DIR" 2>/dev/null; then
    echo "✓ Log directory: $HOMELAB_LOG_DIR (created)"
  else
    echo "✗ Log directory: $HOMELAB_LOG_DIR (not writable)"
    return 1
  fi

  # Validate log retention
  if [ "${HOMELAB_MAX_LOG_AGE_DAYS:-90}" -lt 7 ]; then
    print_warning "HOMELAB_MAX_LOG_AGE_DAYS is very low (${HOMELAB_MAX_LOG_AGE_DAYS} days)"
    echo "  Recommended: 30-90 days"
    warnings=$((warnings + 1))
  elif [ "${HOMELAB_MAX_LOG_AGE_DAYS:-90}" -gt 365 ]; then
    print_warning "HOMELAB_MAX_LOG_AGE_DAYS is very high (${HOMELAB_MAX_LOG_AGE_DAYS} days)"
    echo "  May consume significant disk space"
    warnings=$((warnings + 1))
  fi

  # Check disk space
  if command -v df >/dev/null 2>&1; then
    local available_gb=$(df -g "$HOMELAB_LOG_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
    if [ "$available_gb" -lt 5 ] && [ "$available_gb" -gt 0 ]; then
      print_warning "Low disk space: ${available_gb}GB available"
      echo "  Consider running: homelab emergency"
      warnings=$((warnings + 1))
    fi
  fi

  echo ""
  echo "Script Detection:"

  local found=0 missing=0
  for script in disk-cleanup.sh update-all.sh ssh-key-audit.sh nmap-scan.sh rclone-sync.sh smart-cleanup.sh; do
    local script_path=$(get_script_path "$script")
    if [ -n "$script_path" ]; then
      if [ ! -x "$script_path" ]; then
        echo "  ⚠ $script → $script_path (not executable)"
        echo "     Fix: chmod +x $script_path"
        warnings=$((warnings + 1))
      else
        echo "  ✓ $script → $script_path"
      fi
      found=$((found + 1))
    else
      echo "  ✗ $script → not found"
      missing=$((missing + 1))
    fi
  done

  echo ""

  if [ $missing -gt 0 ]; then
    print_warning "$missing optional scripts not found (some workflows will skip steps)"
    echo ""
  fi

  # Workflow availability
  echo "Workflow Status:"
  check_workflow_availability "morning" "ssh-key-audit.sh" "nmap-scan.sh" "rclone-sync.sh" "update-all.sh"
  check_workflow_availability "weekly" "disk-cleanup.sh" "update-all.sh" "ssh-key-audit.sh" "nmap-scan.sh"
  check_workflow_availability "emergency" "disk-cleanup.sh"
  check_workflow_availability "pre-deploy" "ssh-key-audit.sh" "disk-cleanup.sh"

  echo ""

  if [ $found -eq 6 ] && [ $warnings -eq 0 ]; then
    print_success "Configuration valid - full functionality enabled"
  elif [ $found -eq 6 ]; then
    print_warning "Configuration has $warnings warning(s) - review above"
  elif [ $missing -gt 0 ]; then
    echo "Recommendation:"
    echo "  Install missing scripts or update config paths for full functionality"
  fi

  return 0
}

# Check workflow availability
check_workflow_availability() {
  local workflow="$1"; shift
  local required_scripts=("$@")
  local available=0
  local total=${#required_scripts[@]}

  for script in "${required_scripts[@]}"; do
    local script_path=$(get_script_path "$script")
    if [ -n "$script_path" ]; then
      available=$((available + 1))
    fi
  done

  if [ $available -eq $total ]; then
    echo "  $workflow → ✓ Available ($available/$total steps)"
  elif [ $available -gt 0 ]; then
    echo "  $workflow → ⚠ Partially available ($available/$total steps)"
  else
    echo "  $workflow → ✗ Unavailable ($available/$total steps)"
  fi
}
