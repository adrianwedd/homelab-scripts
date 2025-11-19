#!/usr/bin/env bash
# homelab/lib/logger.sh - Unified logging system
# Part of homelab v1.0.0

# Helper: Get file mtime (cross-platform)
get_file_mtime() {
  local file="$1"
  # Try macOS stat first, fall back to Linux stat, return 0 if both fail
  stat -f "%m" "$file" 2>/dev/null || stat -c "%Y" "$file" 2>/dev/null || echo 0
}

# Global logging state
WORKFLOW_LOG=""
WORKFLOW_START_TIME=0
WORKFLOW_STEP_COUNT=0
WORKFLOW_TOTAL_STEPS=0
WORKFLOW_SKIPPED_STEPS=()
WORKFLOW_FAILED_STEPS=()

# Colors (disabled if HOMELAB_COLOR=false or not a TTY)
if [ "${HOMELAB_COLOR:-true}" = "true" ] && [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

# Print functions
print_error() {
  echo -e "${RED}✗ Error:${NC} $1" >&2
  log_to_file "ERROR: $1"
}

print_success() {
  echo -e "${GREEN}✓${NC} $1"
  log_to_file "SUCCESS: $1"
}

print_warning() {
  echo -e "${YELLOW}⚠${NC} $1"
  log_to_file "WARNING: $1"
}

print_info() {
  echo -e "${BLUE}ℹ${NC} $1"
  log_to_file "INFO: $1"
}

print_section() {
  echo ""
  echo -e "${BLUE}━━━ $1 ━━━${NC}"
  echo ""
  log_to_file "=== $1 ==="
}

# Initialize logging for a workflow
init_workflow_logging() {
  local workflow_name="$1"

  # Create log directory
  mkdir -p "$HOMELAB_LOG_DIR"
  chmod 700 "$HOMELAB_LOG_DIR"

  # Create timestamped log file
  WORKFLOW_LOG="$HOMELAB_LOG_DIR/homelab_${workflow_name}_$(date +%Y%m%d_%H%M%S).log"
  touch "$WORKFLOW_LOG"
  chmod 600 "$WORKFLOW_LOG"

  # Record start time
  WORKFLOW_START_TIME=$(date +%s)

  # Reset step counters
  WORKFLOW_STEP_COUNT=0
  WORKFLOW_SKIPPED_STEPS=()
  WORKFLOW_FAILED_STEPS=()

  # Write header
  {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Homelab Workflow: $workflow_name"
    echo "Started: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
  } >> "$WORKFLOW_LOG"
}

# Log message to workflow log file
log_to_file() {
  if [ -n "$WORKFLOW_LOG" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$WORKFLOW_LOG"
  fi
}

# Complete workflow logging
complete_workflow_logging() {
  local workflow_name="$1"
  local exit_code="${2:-0}"
  local is_scheduled="${3:-false}"  # true if run from cron/launchd

  local end_time=$(date +%s)
  local duration=$((end_time - WORKFLOW_START_TIME))

  # Format duration
  local duration_str
  if [ $duration -lt 60 ]; then
    duration_str="${duration}s"
  elif [ $duration -lt 3600 ]; then
    duration_str="$((duration / 60))m $((duration % 60))s"
  else
    duration_str="$((duration / 3600))h $(( (duration % 3600) / 60))m"
  fi

  # Write footer
  {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Workflow: $workflow_name"
    echo "Completed: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Duration: $duration_str"
    echo "Exit code: $exit_code"
    if [ ${#WORKFLOW_SKIPPED_STEPS[@]} -gt 0 ]; then
      echo "Skipped: ${WORKFLOW_SKIPPED_STEPS[*]}"
    fi
    if [ ${#WORKFLOW_FAILED_STEPS[@]} -gt 0 ]; then
      echo "Failed: ${WORKFLOW_FAILED_STEPS[*]}"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  } >> "$WORKFLOW_LOG"

  # Determine notification status
  local notify_status="success"
  if [ ${#WORKFLOW_FAILED_STEPS[@]} -gt 0 ]; then
    notify_status="failure"
  elif [ ${#WORKFLOW_SKIPPED_STEPS[@]} -gt 0 ]; then
    notify_status="warning"
  fi

  # Send notification (if enabled)
  if type -t send_notification >/dev/null 2>&1; then
    local failed_list=$(IFS=,; echo "${WORKFLOW_FAILED_STEPS[*]}")
    local skipped_list=$(IFS=,; echo "${WORKFLOW_SKIPPED_STEPS[*]}")
    local completed=$((WORKFLOW_STEP_COUNT - ${#WORKFLOW_SKIPPED_STEPS[@]} - ${#WORKFLOW_FAILED_STEPS[@]}))

    send_notification \
      "$workflow_name" \
      "$notify_status" \
      "$duration_str" \
      "$completed" \
      "$WORKFLOW_TOTAL_STEPS" \
      "$failed_list" \
      "$skipped_list" \
      "$WORKFLOW_LOG" \
      "$is_scheduled" \
      false  # not dry-run
  fi

  # Write workflow state for tracking and last_run conditions
  if type -t write_workflow_state >/dev/null 2>&1; then
    local failed_list_space="${WORKFLOW_FAILED_STEPS[*]}"
    local skipped_list_space="${WORKFLOW_SKIPPED_STEPS[*]}"
    local completed=$((WORKFLOW_STEP_COUNT - ${#WORKFLOW_SKIPPED_STEPS[@]} - ${#WORKFLOW_FAILED_STEPS[@]}))

    write_workflow_state \
      "$workflow_name" \
      "$notify_status" \
      "$exit_code" \
      "$duration_str" \
      "$completed" \
      "$WORKFLOW_TOTAL_STEPS" \
      "$failed_list_space" \
      "$skipped_list_space" || {
        print_warning "Failed to write workflow state (state tracking may not work)"
      }
  fi

  # Clean up old logs
  cleanup_old_logs
}

# Clean up logs older than HOMELAB_MAX_LOG_AGE_DAYS
cleanup_old_logs() {
  if [ -d "$HOMELAB_LOG_DIR" ]; then
    find "$HOMELAB_LOG_DIR" -name "homelab_*.log" -type f -mtime "+${HOMELAB_MAX_LOG_AGE_DAYS}" -delete 2>/dev/null || true
  fi
}

# Run a workflow step with logging
run_step() {
  local step_name="$1"
  local script_key="$2"
  shift 2
  local script_args=("$@")

  local step_num=$((++WORKFLOW_STEP_COUNT))

  print_info "[$step_num/$WORKFLOW_TOTAL_STEPS] $step_name..."
  log_to_file "STEP $step_num/$WORKFLOW_TOTAL_STEPS: $step_name"

  # Normalize tilde in script_key (bash doesn't expand ~ in variables)
  local normalized_script="${script_key/#\~/$HOME}"

  # Resolve script path (built-in registry, absolute path, or PATH)
  local script_path

  # First try the built-in script registry
  script_path=$(get_script_path "$script_key" 2>/dev/null || true)

  # If not in registry, try to resolve as-is
  if [ -z "$script_path" ]; then
    # Check if it's an absolute path (including tilde-expanded paths)
    if [[ "$normalized_script" == /* ]] && [ -f "$normalized_script" ] && [ -x "$normalized_script" ]; then
      script_path="$normalized_script"
    # Check if it's in PATH
    elif command -v "$script_key" >/dev/null 2>&1; then
      script_path=$(command -v "$script_key")
    # Check in homelab directory
    elif [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/$script_key" ] && [ -x "$SCRIPT_DIR/$script_key" ]; then
      script_path="$SCRIPT_DIR/$script_key"
    # Check in parent directory (for symlinked scripts)
    elif [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/../$script_key" ] && [ -x "$SCRIPT_DIR/../$script_key" ]; then
      script_path="$SCRIPT_DIR/../$script_key"
    fi
  fi

  # If still not found, skip this step
  if [ -z "$script_path" ]; then
    print_warning "  ⊘ $step_name skipped ($script_key not found in registry, PATH, or as absolute path)"
    log_to_file "SKIPPED: $script_key not found"
    WORKFLOW_SKIPPED_STEPS+=("$step_name")
    return 0
  fi

  # Dry-run mode
  if [ "${DRY_RUN:-false}" = true ]; then
    if [ ${#script_args[@]} -gt 0 ]; then
      print_info "  [DRY RUN] Would execute: $script_path ${script_args[*]}"
      log_to_file "DRY RUN: $script_path ${script_args[*]}"
    else
      print_info "  [DRY RUN] Would execute: $script_path"
      log_to_file "DRY RUN: $script_path"
    fi
    return 0
  fi

  # Execute script and capture output
  local step_log="$HOMELAB_LOG_DIR/step_${step_num}_$(echo "$step_name" | tr ' ' '_' | tr -cd '[:alnum:]_').log"
  if [ ${#script_args[@]} -gt 0 ]; then
    log_to_file "Executing: $script_path ${script_args[*]}"
  else
    log_to_file "Executing: $script_path"
  fi
  log_to_file "Output log: $step_log"

  if "$script_path" "${script_args[@]}" > "$step_log" 2>&1; then
    print_success "  ✓ $step_name complete"
    log_to_file "COMPLETED: $step_name"

    # Show brief summary if verbose
    if [ "${HOMELAB_VERBOSE:-false}" = true ]; then
      echo "  Output:"
      tail -5 "$step_log" | sed 's/^/    /'
    fi

    return 0
  else
    local exit_code=$?
    print_warning "  ⚠ $step_name had warnings (exit code: $exit_code)"
    print_info "  See log: $step_log"
    log_to_file "WARNING: $step_name exited with code $exit_code"
    WORKFLOW_FAILED_STEPS+=("$step_name")
    return $exit_code
  fi
}

# Print workflow summary
print_workflow_summary() {
  local completed=$((WORKFLOW_STEP_COUNT - ${#WORKFLOW_SKIPPED_STEPS[@]} - ${#WORKFLOW_FAILED_STEPS[@]}))
  local duration=$(($(date +%s) - WORKFLOW_START_TIME))

  # Format duration
  local duration_str
  if [ $duration -lt 60 ]; then
    duration_str="${duration}s"
  else
    duration_str="$((duration / 60))m $((duration % 60))s"
  fi

  print_section "Summary"
  echo "Duration: $duration_str"
  echo "Completed: $completed/$WORKFLOW_STEP_COUNT steps"

  if [ ${#WORKFLOW_SKIPPED_STEPS[@]} -gt 0 ]; then
    echo "Skipped: ${#WORKFLOW_SKIPPED_STEPS[@]} steps (${WORKFLOW_SKIPPED_STEPS[*]})"
    echo ""
    print_warning "Install missing scripts for full functionality:"
    for step in "${WORKFLOW_SKIPPED_STEPS[@]}"; do
      echo "  - $step"
    done
    echo ""
    echo "See: homelab config validate"
  fi

  if [ ${#WORKFLOW_FAILED_STEPS[@]} -gt 0 ]; then
    echo "Failed: ${#WORKFLOW_FAILED_STEPS[@]} steps (${WORKFLOW_FAILED_STEPS[*]})"
    echo ""
    print_warning "Review logs for failed steps"
    echo "  Log directory: $HOMELAB_LOG_DIR"
  fi

  echo ""
  echo "Full log: $WORKFLOW_LOG"
}

# Show logs for a workflow or script
show_logs() {
  local target="${1:-}"
  local tail_lines=100
  local follow=false

  # Parse options
  shift || true
  while [[ $# -gt 0 ]]; do
    case $1 in
      --tail) tail_lines="$2"; shift 2 ;;
      --follow|-f) follow=true; shift ;;
      --since)
        # TODO: Implement date filtering in Phase 1.1
        shift 2 ;;
      *) shift ;;
    esac
  done

  # Find logs
  if [ -z "$target" ]; then
    # Show latest workflow log - find newest by mtime
    local latest="" latest_time=0
    while IFS= read -r -d '' file; do
      local mtime=$(get_file_mtime "$file")
      if [ "$mtime" -gt "$latest_time" ]; then
        latest="$file"
        latest_time="$mtime"
      fi
    done < <(find "$HOMELAB_LOG_DIR" -name "homelab_*.log" -type f -print0 2>/dev/null)

    if [ -z "$latest" ]; then
      print_error "No logs found in $HOMELAB_LOG_DIR"
      echo ""
      echo "Run a workflow to generate logs:"
      echo "  homelab morning"
      echo "  homelab weekly"
      return 1
    fi
    target="$latest"
  elif [ -f "$target" ]; then
    # Direct file path
    :
  else
    # Search for workflow or script logs
    local pattern="homelab_${target}_*.log"
    local latest="" latest_time=0
    while IFS= read -r -d '' file; do
      local mtime=$(get_file_mtime "$file")
      if [ "$mtime" -gt "$latest_time" ]; then
        latest="$file"
        latest_time="$mtime"
      fi
    done < <(find "$HOMELAB_LOG_DIR" -name "$pattern" -type f -print0 2>/dev/null)

    if [ -z "$latest" ]; then
      print_error "No logs found matching: $target"
      echo ""
      echo "Available logs:"
      find "$HOMELAB_LOG_DIR" -name "homelab_*.log" -type f -exec basename {} \; 2>/dev/null | sort -r | head -10
      echo ""
      echo "Run a workflow to generate logs:"
      echo "  homelab $target"
      return 1
    fi
    target="$latest"
  fi

  # Display log
  print_info "Showing: $target"
  echo ""

  if [ "$follow" = true ]; then
    tail -f -n "$tail_lines" "$target"
  else
    tail -n "$tail_lines" "$target"
  fi
}

# List available logs
list_logs() {
  print_section "Available Logs"

  if [ ! -d "$HOMELAB_LOG_DIR" ] || [ -z "$(ls -A "$HOMELAB_LOG_DIR")" ]; then
    print_info "No logs found"
    return 0
  fi

  echo "Recent workflow logs:"
  ls -1t "$HOMELAB_LOG_DIR"/homelab_*.log 2>/dev/null | head -20 | while read -r log; do
    local size=$(du -h "$log" | awk '{print $1}')
    local age=$(( ($(date +%s) - $(get_file_mtime "$log")) / 86400 ))
    echo "  $(basename "$log") ($size, ${age}d ago)"
  done

  echo ""
  echo "Total logs: $(find "$HOMELAB_LOG_DIR" -name "homelab_*.log" -type f | wc -l | tr -d ' ')"
  echo "Log directory: $HOMELAB_LOG_DIR"
}

# Rotate old logs (delete logs older than HOMELAB_MAX_LOG_AGE_DAYS)
rotate_logs() {
  local max_age_days="${HOMELAB_MAX_LOG_AGE_DAYS:-90}"
  local dry_run="${1:-false}"

  if [ ! -d "$HOMELAB_LOG_DIR" ]; then
    return 0
  fi

  local now=$(date +%s)
  local cutoff_time=$((now - (max_age_days * 86400)))
  local deleted_count=0
  local deleted_size=0

  if [ "$HOMELAB_VERBOSE" = true ]; then
    print_info "Checking for logs older than ${max_age_days} days..."
  fi

  while IFS= read -r -d '' log; do
    local mtime=$(get_file_mtime "$log")

    if [ "$mtime" -lt "$cutoff_time" ]; then
      local size=$(stat -f "%z" "$log" 2>/dev/null || stat -c "%s" "$log" 2>/dev/null || echo 0)
      local age_days=$(( (now - mtime) / 86400 ))

      if [ "$dry_run" = true ]; then
        echo "  Would delete: $(basename "$log") (${age_days}d old, $(numfmt --to=iec-i --suffix=B "$size" 2>/dev/null || echo "${size}B"))"
      else
        if [ "$HOMELAB_VERBOSE" = true ]; then
          echo "  Deleting: $(basename "$log") (${age_days}d old)"
        fi
        rm -f "$log"
      fi

      deleted_count=$((deleted_count + 1))
      deleted_size=$((deleted_size + size))
    fi
  done < <(find "$HOMELAB_LOG_DIR" -name "homelab_*.log" -type f -print0 2>/dev/null)

  # Also rotate cron/launchd scheduler logs
  while IFS= read -r -d '' log; do
    local mtime=$(get_file_mtime "$log")

    if [ "$mtime" -lt "$cutoff_time" ]; then
      local size=$(stat -f "%z" "$log" 2>/dev/null || stat -c "%s" "$log" 2>/dev/null || echo 0)
      local age_days=$(( (now - mtime) / 86400 ))

      if [ "$dry_run" = true ]; then
        echo "  Would delete: $(basename "$log") (${age_days}d old, $(numfmt --to=iec-i --suffix=B "$size" 2>/dev/null || echo "${size}B"))"
      else
        if [ "$HOMELAB_VERBOSE" = true ]; then
          echo "  Deleting: $(basename "$log") (${age_days}d old)"
        fi
        rm -f "$log"
      fi

      deleted_count=$((deleted_count + 1))
      deleted_size=$((deleted_size + size))
    fi
  done < <(find "$HOMELAB_LOG_DIR" \( -name "cron_*.log" -o -name "launchd_*.log" \) -type f -print0 2>/dev/null)

  # Also rotate step logs
  while IFS= read -r -d '' log; do
    local mtime=$(get_file_mtime "$log")

    if [ "$mtime" -lt "$cutoff_time" ]; then
      local size=$(stat -f "%z" "$log" 2>/dev/null || stat -c "%s" "$log" 2>/dev/null || echo 0)

      if [ "$dry_run" != true ]; then
        rm -f "$log"
      fi

      deleted_count=$((deleted_count + 1))
      deleted_size=$((deleted_size + size))
    fi
  done < <(find "$HOMELAB_LOG_DIR" -name "step_*.log" -type f -print0 2>/dev/null)

  if [ $deleted_count -gt 0 ]; then
    local size_human=$(numfmt --to=iec-i --suffix=B "$deleted_size" 2>/dev/null || echo "${deleted_size} bytes")
    if [ "$dry_run" = true ]; then
      print_info "Would delete $deleted_count old log files ($size_human)"
    else
      print_success "Deleted $deleted_count old log files ($size_human)"
    fi
  else
    if [ "$HOMELAB_VERBOSE" = true ]; then
      print_info "No logs older than ${max_age_days} days to delete"
    fi
  fi
}
