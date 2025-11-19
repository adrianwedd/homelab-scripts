#!/usr/bin/env bash
# homelab/lib/conditions.sh - Workflow condition evaluation
# Part of homelab v2.4.0 (Phase 2.3.2)

# ============================================================================
# CONDITION EVALUATION
# ============================================================================

# Evaluate workflow-level conditions (pre-flight checks)
# Returns: 0 if all conditions pass, 1 if any fail (skip), 2 if any fail (fail)
# Sets: CONDITION_SKIP_REASON if conditions fail
evaluate_workflow_conditions() {
  local workflow_file="$1"

  # Check if workflow has conditions block
  if ! has_conditions_block "$workflow_file"; then
    return 0  # No conditions, allow execution
  fi

  # Require jq for condition evaluation
  if ! command -v jq >/dev/null 2>&1; then
    print_warning "Condition evaluation requires jq (install: brew install jq)"
    return 0  # Fail open - allow execution if we can't evaluate
  fi

  local escaped_path
  escaped_path=$(escape_single_quotes "$workflow_file")

  # Evaluate each condition type
  local condition_types="disk time_window last_run command file_exists"

  for condition_type in $condition_types; do
    # Check if this condition type exists
    if jq -e ".conditions.$condition_type" "$workflow_file" >/dev/null 2>&1; then
      # Evaluate condition
      local action
      action=$(jq -r ".conditions.$condition_type.action // \"skip\"" "$workflow_file" 2>/dev/null)

      if ! "check_${condition_type}_condition" "$workflow_file"; then
        # Condition failed
        if [ "$action" = "fail" ]; then
          return 2  # Fail workflow
        else
          return 1  # Skip workflow
        fi
      fi
    fi
  done

  return 0  # All conditions passed
}

# Evaluate step-level conditions (when guards)
# Returns: 0 if all conditions pass, 1 if any fail (skip), 2 if any fail (fail)
# Sets: CONDITION_SKIP_REASON if conditions fail
evaluate_step_conditions() {
  local workflow_file="$1"
  local step_index="$2"

  # Check if step has when block
  if ! has_step_when_block "$workflow_file" "$step_index"; then
    return 0  # No conditions, allow execution
  fi

  # Require jq for condition evaluation
  if ! command -v jq >/dev/null 2>&1; then
    print_warning "Condition evaluation requires jq (install: brew install jq)"
    return 0  # Fail open - allow execution if we can't evaluate
  fi

  local escaped_path
  escaped_path=$(escape_single_quotes "$workflow_file")

  # Evaluate each condition type
  local condition_types="disk time_window last_run command file_exists weekday"

  for condition_type in $condition_types; do
    # Check if this condition type exists in step's when block
    if jq -e ".steps[$step_index].when.$condition_type" "$workflow_file" >/dev/null 2>&1; then
      # Evaluate condition (pass step index for step-specific conditions)
      local action
      action=$(jq -r ".steps[$step_index].when.$condition_type.action // \"skip\"" "$workflow_file" 2>/dev/null)

      if ! "check_step_${condition_type}_condition" "$workflow_file" "$step_index"; then
        # Condition failed
        if [ "$action" = "fail" ]; then
          return 2  # Fail step (may stop workflow)
        else
          return 1  # Skip step
        fi
      fi
    fi
  done

  return 0  # All conditions passed
}

# ============================================================================
# CONDITION EVALUATORS (Workflow-Level)
# ============================================================================

# Check disk space condition
# Returns: 0 if condition passes, 1 if fails
check_disk_condition() {
  local workflow_file="$1"
  local escaped_path
  escaped_path=$(escape_single_quotes "$workflow_file")

  # Extract condition parameters
  local min_free_gb path
  min_free_gb=$(jq -r '.conditions.disk.min_free_gb' "$workflow_file" 2>/dev/null)
  path=$(jq -r '.conditions.disk.path // "/"' "$workflow_file" 2>/dev/null)

  if [ -z "$min_free_gb" ] || [ "$min_free_gb" = "null" ]; then
    print_warning "Disk condition missing min_free_gb parameter"
    return 0  # Fail open
  fi

  # Get available space in GB
  local avail_gb
  if df -BG "$path" >/dev/null 2>&1; then
    # Linux: df -BG
    avail_gb=$(df -BG "$path" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G')
  elif df -g "$path" >/dev/null 2>&1; then
    # macOS: df -g
    avail_gb=$(df -g "$path" 2>/dev/null | awk 'NR==2 {print $4}')
  else
    # Fallback: try df -h and parse
    avail_gb=$(df -h "$path" 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/Gi*$//' | awk '{print int($1)}')
  fi

  if [ -z "$avail_gb" ]; then
    print_warning "Unable to check disk space for $path"
    return 0  # Fail open if we can't check
  fi

  # Compare (handle floating point with awk)
  if awk "BEGIN {exit !($avail_gb < $min_free_gb)}"; then
    CONDITION_SKIP_REASON="Disk space below threshold: ${avail_gb}GB < ${min_free_gb}GB (path: $path)"
    print_info "$CONDITION_SKIP_REASON"
    return 1  # Condition failed
  fi

  return 0  # Condition passed
}

# Check time window condition
# Returns: 0 if within window, 1 if outside
check_time_window_condition() {
  local workflow_file="$1"
  local escaped_path
  escaped_path=$(escape_single_quotes "$workflow_file")

  # Extract condition parameters
  local start_time end_time timezone
  start_time=$(jq -r '.conditions.time_window.start' "$workflow_file" 2>/dev/null)
  end_time=$(jq -r '.conditions.time_window.end' "$workflow_file" 2>/dev/null)
  timezone=$(jq -r '.conditions.time_window.timezone // "local"' "$workflow_file" 2>/dev/null)

  if [ -z "$start_time" ] || [ "$start_time" = "null" ] || [ -z "$end_time" ] || [ "$end_time" = "null" ]; then
    print_warning "Time window condition missing start/end parameters"
    return 0  # Fail open
  fi

  # Get current time in HH:MM format
  local current_time
  current_time=$(date +%H:%M)

  # Convert HH:MM to minutes since midnight
  local start_minutes end_minutes current_minutes
  start_minutes=$(echo "$start_time" | awk -F: '{print ($1 * 60) + $2}')
  end_minutes=$(echo "$end_time" | awk -F: '{print ($1 * 60) + $2}')
  current_minutes=$(echo "$current_time" | awk -F: '{print ($1 * 60) + $2}')

  # Check if within window
  local within_window=false

  # Handle overnight windows (e.g., 22:00 - 06:00)
  if [ "$start_minutes" -gt "$end_minutes" ]; then
    # Window crosses midnight
    if [ "$current_minutes" -ge "$start_minutes" ] || [ "$current_minutes" -lt "$end_minutes" ]; then
      within_window=true
    fi
  else
    # Normal window (same day)
    if [ "$current_minutes" -ge "$start_minutes" ] && [ "$current_minutes" -lt "$end_minutes" ]; then
      within_window=true
    fi
  fi

  if [ "$within_window" = "false" ]; then
    CONDITION_SKIP_REASON="Outside time window: $current_time not in [$start_time - $end_time]"
    print_info "$CONDITION_SKIP_REASON"
    return 1  # Outside window
  fi

  return 0  # Within window
}

# Check last run condition (cooldown period)
# Returns: 0 if enough time passed, 1 if too recent
check_last_run_condition() {
  local workflow_file="$1"
  local escaped_path
  escaped_path=$(escape_single_quotes "$workflow_file")

  # Extract condition parameters
  local min_hours
  min_hours=$(jq -r '.conditions.last_run.min_hours_since' "$workflow_file" 2>/dev/null)

  if [ -z "$min_hours" ] || [ "$min_hours" = "null" ]; then
    print_warning "Last run condition missing min_hours_since parameter"
    return 0  # Fail open
  fi

  # Get workflow name
  local workflow_name
  workflow_name=$(jq -r '.name' "$workflow_file" 2>/dev/null)

  # Get hours since last run using state tracking
  local hours_since
  if type -t get_hours_since_last_run >/dev/null 2>&1; then
    hours_since=$(get_hours_since_last_run "$workflow_name")
  else
    print_warning "State tracking not available (get_hours_since_last_run not found)"
    return 0  # Fail open
  fi

  # If never run, allow execution
  if [ -z "$hours_since" ]; then
    return 0  # No previous run
  fi

  # Check if enough time has passed
  # Use awk for floating point comparison (bash only does integers)
  local is_too_recent
  if command -v awk >/dev/null 2>&1; then
    is_too_recent=$(awk -v hs="$hours_since" -v mh="$min_hours" 'BEGIN { print (hs < mh) ? 1 : 0 }')
  else
    # Fallback: integer comparison
    local hours_int=${hours_since%.*}
    local min_int=${min_hours%.*}
    if [ "$hours_int" -lt "$min_int" ]; then
      is_too_recent=1
    else
      is_too_recent=0
    fi
  fi

  if [ "$is_too_recent" -eq 1 ]; then
    CONDITION_SKIP_REASON="Too soon since last run: ${hours_since}h < ${min_hours}h"
    print_info "$CONDITION_SKIP_REASON"
    return 1  # Too recent
  fi

  return 0  # Enough time passed
}

# Check command condition
# Returns: 0 if command succeeds, 1 if fails
check_command_condition() {
  local workflow_file="$1"
  local escaped_path
  escaped_path=$(escape_single_quotes "$workflow_file")

  # Extract condition parameters
  local command_script timeout_sec
  command_script=$(jq -r '.conditions.command.script' "$workflow_file" 2>/dev/null)
  timeout_sec=$(jq -r '.conditions.command.timeout // 30' "$workflow_file" 2>/dev/null)

  if [ -z "$command_script" ] || [ "$command_script" = "null" ]; then
    print_warning "Command condition missing script parameter"
    return 0  # Fail open
  fi

  # Use timeout if available (coreutils on macOS, built-in on Linux)
  local timeout_cmd=""
  if command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd="gtimeout $timeout_sec"
  elif command -v timeout >/dev/null 2>&1; then
    timeout_cmd="timeout $timeout_sec"
  fi

  # Execute command
  local exit_code
  if [ -n "$timeout_cmd" ]; then
    $timeout_cmd bash -c "$command_script" >/dev/null 2>&1
    exit_code=$?
  else
    # No timeout available, run without it
    bash -c "$command_script" >/dev/null 2>&1
    exit_code=$?
  fi

  if [ $exit_code -ne 0 ]; then
    CONDITION_SKIP_REASON="Condition command failed (exit $exit_code): $command_script"
    print_info "$CONDITION_SKIP_REASON"
    return 1  # Command failed
  fi

  return 0  # Command succeeded
}

# Check file exists condition
# Returns: 0 if condition passes, 1 if fails
check_file_exists_condition() {
  local workflow_file="$1"
  local escaped_path
  escaped_path=$(escape_single_quotes "$workflow_file")

  # Extract condition parameters
  local file_path negate
  file_path=$(jq -r '.conditions.file_exists.path' "$workflow_file" 2>/dev/null)
  negate=$(jq -r '.conditions.file_exists.negate // false' "$workflow_file" 2>/dev/null)

  if [ -z "$file_path" ] || [ "$file_path" = "null" ]; then
    print_warning "File exists condition missing path parameter"
    return 0  # Fail open
  fi

  # Expand tilde
  local normalized_path="${file_path/#\~/$HOME}"

  if [ "$negate" = "true" ]; then
    # Skip if file EXISTS
    if [ -f "$normalized_path" ]; then
      CONDITION_SKIP_REASON="File exists (negate=true): $file_path"
      print_info "$CONDITION_SKIP_REASON"
      return 1  # Condition failed (file exists, we wanted it not to)
    fi
  else
    # Skip if file DOESN'T exist
    if [ ! -f "$normalized_path" ]; then
      CONDITION_SKIP_REASON="File does not exist: $file_path"
      print_info "$CONDITION_SKIP_REASON"
      return 1  # Condition failed (file missing, we wanted it)
    fi
  fi

  return 0  # Condition passed
}

# ============================================================================
# CONDITION EVALUATORS (Step-Level)
# ============================================================================

# Step-level conditions use the same evaluators as workflow-level, but read from .steps[$i].when instead

# Check disk condition for step
check_step_disk_condition() {
  local workflow_file="$1"
  local step_index="$2"

  # Temporarily rewrite workflow to look like workflow-level for reuse
  local min_free_gb path
  min_free_gb=$(jq -r ".steps[$step_index].when.disk.min_free_gb" "$workflow_file" 2>/dev/null)
  path=$(jq -r ".steps[$step_index].when.disk.path // \"/\"" "$workflow_file" 2>/dev/null)

  if [ -z "$min_free_gb" ] || [ "$min_free_gb" = "null" ]; then
    return 0
  fi

  # Get available space in GB
  local avail_gb
  if df -BG "$path" >/dev/null 2>&1; then
    avail_gb=$(df -BG "$path" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G')
  elif df -g "$path" >/dev/null 2>&1; then
    avail_gb=$(df -g "$path" 2>/dev/null | awk 'NR==2 {print $4}')
  else
    avail_gb=$(df -h "$path" 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/Gi*$//' | awk '{print int($1)}')
  fi

  if [ -z "$avail_gb" ]; then
    return 0
  fi

  if awk "BEGIN {exit !($avail_gb < $min_free_gb)}"; then
    CONDITION_SKIP_REASON="Step: Disk space below threshold: ${avail_gb}GB < ${min_free_gb}GB"
    print_info "$CONDITION_SKIP_REASON"
    return 1
  fi

  return 0
}

# Check time window condition for step
check_step_time_window_condition() {
  local workflow_file="$1"
  local step_index="$2"

  local start_time end_time
  start_time=$(jq -r ".steps[$step_index].when.time_window.start" "$workflow_file" 2>/dev/null)
  end_time=$(jq -r ".steps[$step_index].when.time_window.end" "$workflow_file" 2>/dev/null)

  if [ -z "$start_time" ] || [ "$start_time" = "null" ]; then
    return 0
  fi

  local current_time
  current_time=$(date +%H:%M)

  local start_minutes end_minutes current_minutes
  start_minutes=$(echo "$start_time" | awk -F: '{print ($1 * 60) + $2}')
  end_minutes=$(echo "$end_time" | awk -F: '{print ($1 * 60) + $2}')
  current_minutes=$(echo "$current_time" | awk -F: '{print ($1 * 60) + $2}')

  local within_window=false

  if [ "$start_minutes" -gt "$end_minutes" ]; then
    if [ "$current_minutes" -ge "$start_minutes" ] || [ "$current_minutes" -lt "$end_minutes" ]; then
      within_window=true
    fi
  else
    if [ "$current_minutes" -ge "$start_minutes" ] && [ "$current_minutes" -lt "$end_minutes" ]; then
      within_window=true
    fi
  fi

  if [ "$within_window" = "false" ]; then
    CONDITION_SKIP_REASON="Step: Outside time window: $current_time not in [$start_time - $end_time]"
    print_info "$CONDITION_SKIP_REASON"
    return 1
  fi

  return 0
}

# Check last run condition for step (same as workflow-level)
check_step_last_run_condition() {
  local workflow_file="$1"
  local step_index="$2"

  # Steps use workflow-level last_run tracking
  check_last_run_condition "$workflow_file"
}

# Check command condition for step
check_step_command_condition() {
  local workflow_file="$1"
  local step_index="$2"

  local command_script timeout_sec
  command_script=$(jq -r ".steps[$step_index].when.command.script" "$workflow_file" 2>/dev/null)
  timeout_sec=$(jq -r ".steps[$step_index].when.command.timeout // 30" "$workflow_file" 2>/dev/null)

  if [ -z "$command_script" ] || [ "$command_script" = "null" ]; then
    return 0
  fi

  local timeout_cmd=""
  if command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd="gtimeout $timeout_sec"
  elif command -v timeout >/dev/null 2>&1; then
    timeout_cmd="timeout $timeout_sec"
  fi

  local exit_code
  if [ -n "$timeout_cmd" ]; then
    $timeout_cmd bash -c "$command_script" >/dev/null 2>&1
    exit_code=$?
  else
    bash -c "$command_script" >/dev/null 2>&1
    exit_code=$?
  fi

  if [ $exit_code -ne 0 ]; then
    CONDITION_SKIP_REASON="Step: Condition command failed (exit $exit_code)"
    print_info "$CONDITION_SKIP_REASON"
    return 1
  fi

  return 0
}

# Check file exists condition for step
check_step_file_exists_condition() {
  local workflow_file="$1"
  local step_index="$2"

  local file_path negate
  file_path=$(jq -r ".steps[$step_index].when.file_exists.path" "$workflow_file" 2>/dev/null)
  negate=$(jq -r ".steps[$step_index].when.file_exists.negate // false" "$workflow_file" 2>/dev/null)

  if [ -z "$file_path" ] || [ "$file_path" = "null" ]; then
    return 0
  fi

  local normalized_path="${file_path/#\~/$HOME}"

  if [ "$negate" = "true" ]; then
    if [ -f "$normalized_path" ]; then
      CONDITION_SKIP_REASON="Step: File exists (negate=true): $file_path"
      print_info "$CONDITION_SKIP_REASON"
      return 1
    fi
  else
    if [ ! -f "$normalized_path" ]; then
      CONDITION_SKIP_REASON="Step: File does not exist: $file_path"
      print_info "$CONDITION_SKIP_REASON"
      return 1
    fi
  fi

  return 0
}

# Check weekday condition (step-only)
check_step_weekday_condition() {
  local workflow_file="$1"
  local step_index="$2"

  # Get allowed days array as comma-separated string
  local allowed_days
  allowed_days=$(jq -r ".steps[$step_index].when.weekday.days | join(\",\")" "$workflow_file" 2>/dev/null)

  if [ -z "$allowed_days" ] || [ "$allowed_days" = "null" ]; then
    return 0
  fi

  # Get current day (0=Sunday...6=Saturday)
  local current_day
  current_day=$(date +%w)

  # Check if current day is in allowed list
  if echo ",$allowed_days," | grep -q ",$current_day,"; then
    return 0  # Day matches
  fi

  CONDITION_SKIP_REASON="Step: Day not in allowed list: $current_day not in [$allowed_days]"
  print_info "$CONDITION_SKIP_REASON"
  return 1  # Day doesn't match
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Check if workflow has conditions block
has_conditions_block() {
  local workflow_file="$1"

  if command -v jq >/dev/null 2>&1; then
    jq -e '.conditions' "$workflow_file" >/dev/null 2>&1
  else
    grep -q '"conditions"' "$workflow_file" 2>/dev/null
  fi
}

# Check if step has when block
has_step_when_block() {
  local workflow_file="$1"
  local step_index="$2"

  if command -v jq >/dev/null 2>&1; then
    jq -e ".steps[$step_index].when" "$workflow_file" >/dev/null 2>&1
  else
    false  # Can't check without jq
  fi
}
