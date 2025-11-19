#!/usr/bin/env bash
#
# state.sh - Workflow state tracking
#
# Manages persistent state for workflows in ~/.config/homelab/workflows/state.json
# Enables last_run conditions and status reporting.

# Get state file path
get_state_file() {
  local state_dir="${HOMELAB_CONFIG_DIR:-$HOME/.config/homelab}/workflows"
  echo "$state_dir/state.json"
}

# Initialize state file if it doesn't exist
init_state_file() {
  local state_file
  state_file=$(get_state_file)
  local state_dir
  state_dir=$(dirname "$state_file")

  # Create directory if needed
  if [ ! -d "$state_dir" ]; then
    mkdir -p "$state_dir" 2>/dev/null || {
      print_warning "Failed to create state directory: $state_dir"
      return 1
    }
  fi

  # Create empty state file if it doesn't exist
  if [ ! -f "$state_file" ]; then
    echo '{}' > "$state_file" 2>/dev/null || {
      print_warning "Failed to create state file: $state_file"
      return 1
    }
    chmod 600 "$state_file" 2>/dev/null
  fi

  return 0
}

# Read workflow state
# Usage: read_workflow_state <workflow_name> <field>
# Returns: field value or empty string if not found
read_workflow_state() {
  local workflow_name="$1"
  local field="$2"
  local state_file
  state_file=$(get_state_file)

  # Initialize if needed
  if [ ! -f "$state_file" ]; then
    init_state_file || return 1
  fi

  # Try jq first, fall back to python3
  if command -v jq >/dev/null 2>&1; then
    jq -r ".[\"$workflow_name\"].$field // \"\"" "$state_file" 2>/dev/null || echo ""
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "
import json, sys
try:
    with open('$state_file') as f:
        data = json.load(f)
    print(data.get('$workflow_name', {}).get('$field', ''))
except:
    pass
" 2>/dev/null || echo ""
  else
    print_warning "State tracking requires jq or python3"
    return 1
  fi
}

# Get last run timestamp for workflow
# Usage: get_last_run_timestamp <workflow_name>
# Returns: ISO 8601 timestamp or empty string
get_last_run_timestamp() {
  local workflow_name="$1"
  read_workflow_state "$workflow_name" "last_run"
}

# Calculate hours since last run
# Usage: get_hours_since_last_run <workflow_name>
# Returns: hours as decimal, or empty if never run
get_hours_since_last_run() {
  local workflow_name="$1"
  local last_run
  last_run=$(get_last_run_timestamp "$workflow_name")

  if [ -z "$last_run" ]; then
    echo ""
    return 0
  fi

  # Convert ISO 8601 to epoch
  local last_run_epoch
  if date --version >/dev/null 2>&1; then
    # GNU date (Linux)
    last_run_epoch=$(date -d "$last_run" +%s 2>/dev/null)
  else
    # BSD date (macOS)
    last_run_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_run" +%s 2>/dev/null)
  fi

  if [ -z "$last_run_epoch" ]; then
    # Fallback: try parsing with python3
    if command -v python3 >/dev/null 2>&1; then
      last_run_epoch=$(python3 -c "
from datetime import datetime
try:
    dt = datetime.fromisoformat('$last_run'.replace('Z', '+00:00'))
    print(int(dt.timestamp()))
except:
    pass
" 2>/dev/null)
    fi
  fi

  if [ -z "$last_run_epoch" ]; then
    echo ""
    return 0
  fi

  # Calculate difference
  local now_epoch
  now_epoch=$(date +%s)
  local diff_seconds=$((now_epoch - last_run_epoch))

  # Convert to hours with 2 decimal places
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "print(round($diff_seconds / 3600.0, 2))"
  elif command -v awk >/dev/null 2>&1; then
    awk "BEGIN { printf \"%.2f\", $diff_seconds / 3600.0 }"
  else
    # Fallback: integer hours
    echo $((diff_seconds / 3600))
  fi
}

# Write workflow state
# Usage: write_workflow_state <workflow_name> <status> <exit_code> <duration> <completed> <total> <failed_list> <skipped_list>
write_workflow_state() {
  local workflow_name="$1"
  local status="$2"          # success, warning, failure
  local exit_code="$3"
  local duration="$4"
  local completed="$5"
  local total="$6"
  local failed_list="$7"     # Space-separated step names
  local skipped_list="$8"    # Space-separated step names

  local state_file
  state_file=$(get_state_file)

  # Initialize if needed
  if [ ! -f "$state_file" ]; then
    init_state_file || return 1
  fi

  # Get current timestamp in ISO 8601 format
  local timestamp
  if date --version >/dev/null 2>&1; then
    # GNU date (Linux)
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  else
    # BSD date (macOS)
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  fi

  # Convert space-separated lists to JSON arrays
  local failed_array="[]"
  if [ -n "$failed_list" ]; then
    if command -v jq >/dev/null 2>&1; then
      failed_array=$(echo "$failed_list" | tr ' ' '\n' | jq -R . | jq -s .)
    elif command -v python3 >/dev/null 2>&1; then
      failed_array=$(python3 -c "import json; print(json.dumps('$failed_list'.split()))")
    fi
  fi

  local skipped_array="[]"
  if [ -n "$skipped_list" ]; then
    if command -v jq >/dev/null 2>&1; then
      skipped_array=$(echo "$skipped_list" | tr ' ' '\n' | jq -R . | jq -s .)
    elif command -v python3 >/dev/null 2>&1; then
      skipped_array=$(python3 -c "import json; print(json.dumps('$skipped_list'.split()))")
    fi
  fi

  # Update state using jq or python3
  if command -v jq >/dev/null 2>&1; then
    # Use jq for atomic update
    local tmp_file
    tmp_file=$(mktemp) || return 1

    jq --arg name "$workflow_name" \
       --arg ts "$timestamp" \
       --arg st "$status" \
       --argjson ec "$exit_code" \
       --arg dur "$duration" \
       --argjson comp "$completed" \
       --argjson tot "$total" \
       --argjson failed "$failed_array" \
       --argjson skipped "$skipped_array" \
       '.[$name] = {
         "last_run": $ts,
         "last_status": $st,
         "last_exit_code": $ec,
         "last_duration": $dur,
         "completed_steps": $comp,
         "total_steps": $tot,
         "failed_steps": $failed,
         "skipped_steps": $skipped
       }' "$state_file" > "$tmp_file" 2>/dev/null

    if [ $? -eq 0 ]; then
      mv "$tmp_file" "$state_file"
      chmod 600 "$state_file"
      return 0
    else
      rm -f "$tmp_file"
      return 1
    fi

  elif command -v python3 >/dev/null 2>&1; then
    # Use python3 for atomic update
    python3 -c "
import json
import os

state_file = '$state_file'
workflow_name = '$workflow_name'

# Read current state
try:
    with open(state_file, 'r') as f:
        data = json.load(f)
except:
    data = {}

# Update workflow entry
data[workflow_name] = {
    'last_run': '$timestamp',
    'last_status': '$status',
    'last_exit_code': $exit_code,
    'last_duration': '$duration',
    'completed_steps': $completed,
    'total_steps': $total,
    'failed_steps': $failed_array,
    'skipped_steps': $skipped_array
}

# Write atomically
tmp_file = state_file + '.tmp'
with open(tmp_file, 'w') as f:
    json.dump(data, f, indent=2)
os.rename(tmp_file, state_file)
os.chmod(state_file, 0o600)
" 2>/dev/null
    return $?

  else
    print_warning "State tracking requires jq or python3"
    return 1
  fi
}

# Get workflow state summary
# Usage: get_workflow_state_summary <workflow_name>
# Returns: human-readable summary or empty if never run
get_workflow_state_summary() {
  local workflow_name="$1"
  local state_file
  state_file=$(get_state_file)

  if [ ! -f "$state_file" ]; then
    echo ""
    return 0
  fi

  local last_run
  last_run=$(read_workflow_state "$workflow_name" "last_run")

  if [ -z "$last_run" ]; then
    echo ""
    return 0
  fi

  local status
  local duration
  local completed
  local total
  status=$(read_workflow_state "$workflow_name" "last_status")
  duration=$(read_workflow_state "$workflow_name" "last_duration")
  completed=$(read_workflow_state "$workflow_name" "completed_steps")
  total=$(read_workflow_state "$workflow_name" "total_steps")

  # Format status with color
  local status_color=""
  case "$status" in
    success) status_color="${GREEN}" ;;
    warning) status_color="${YELLOW}" ;;
    failure) status_color="${RED}" ;;
  esac

  echo "${status_color}${status}${NC} - ${completed}/${total} steps - ${duration} - ${last_run}"
}

# Clear workflow state (for testing)
# Usage: clear_workflow_state <workflow_name>
clear_workflow_state() {
  local workflow_name="$1"
  local state_file
  state_file=$(get_state_file)

  if [ ! -f "$state_file" ]; then
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    local tmp_file
    tmp_file=$(mktemp) || return 1
    jq --arg name "$workflow_name" 'del(.[$name])' "$state_file" > "$tmp_file" 2>/dev/null
    if [ $? -eq 0 ]; then
      mv "$tmp_file" "$state_file"
      return 0
    else
      rm -f "$tmp_file"
      return 1
    fi
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "
import json
state_file = '$state_file'
try:
    with open(state_file, 'r') as f:
        data = json.load(f)
    if '$workflow_name' in data:
        del data['$workflow_name']
    with open(state_file, 'w') as f:
        json.dump(data, f, indent=2)
except:
    pass
" 2>/dev/null
    return $?
  else
    return 1
  fi
}
