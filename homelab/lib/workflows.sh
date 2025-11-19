#!/usr/bin/env bash
# homelab/lib/workflows.sh - Workflow definitions and custom workflow management
# Part of homelab v1.0.0

# ============================================================================
# CUSTOM WORKFLOW MANAGEMENT (Phase 2.3.1)
# ============================================================================

# JSON parser detection and fallback strategy
# Returns 0 if a suitable parser is available, 1 if only fallback available
detect_json_parser() {
  if command -v jq >/dev/null 2>&1; then
    echo "jq"
    return 0
  elif command -v python3 >/dev/null 2>&1; then
    echo "python3"
    return 0
  else
    # Fallback parser is fragile - warn users
    echo "fallback"
    return 1  # Signal that only fallback is available
  fi
}

# Check if a proper JSON parser is available
# Returns 0 if jq or python3 available, 1 if only fallback
has_json_parser() {
  command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1
}

# Parse JSON value using available parser
# Usage: json_get_value <json_string> <key_path>
# Example: json_get_value "$json" ".name"
json_get_value() {
  local json="$1"
  local key_path="$2"
  local parser
  parser=$(detect_json_parser)

  case "$parser" in
    jq)
      echo "$json" | jq -r "$key_path" 2>/dev/null || echo ""
      ;;
    python3)
      echo "$json" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data$key_path)" 2>/dev/null || echo ""
      ;;
    fallback)
      # Basic grep/sed parsing (limited functionality)
      local key="${key_path#.}"
      echo "$json" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed 's/.*"\([^"]*\)".*/\1/' | head -1
      ;;
  esac
}

# Escape single quotes for safe embedding in Python strings
# Usage: escaped=$(escape_single_quotes "$path")
escape_single_quotes() {
  local str="$1"
  # Replace ' with '\'' (end quote, escaped quote, start quote)
  echo "${str//\'/\'\\\'\'}"
}

# Validate JSON syntax
# Returns 0 if valid, 1 if invalid
validate_json() {
  local json_file="$1"
  local parser
  parser=$(detect_json_parser)

  if [ ! -f "$json_file" ]; then
    return 1
  fi

  case "$parser" in
    jq)
      jq empty "$json_file" >/dev/null 2>&1
      ;;
    python3)
      local escaped_path
      escaped_path=$(escape_single_quotes "$json_file")
      python3 -c "import sys, json; json.load(open('$escaped_path'))" >/dev/null 2>&1
      ;;
    fallback)
      # Basic check: ensure it has matching braces
      local open_braces
      local close_braces
      open_braces=$(grep -o '{' "$json_file" | wc -l)
      close_braces=$(grep -o '}' "$json_file" | wc -l)
      [ "$open_braces" -eq "$close_braces" ]
      ;;
  esac
}

# Load custom workflow definitions from config directory
# Returns list of custom workflow names (one per line)
list_custom_workflows() {
  local workflow_dir="${HOMELAB_WORKFLOW_DIR:-$HOME/.config/homelab/workflows}"

  if [ ! -d "$workflow_dir" ]; then
    return 0
  fi

  find "$workflow_dir" -maxdepth 1 -name "*.json" -type f 2>/dev/null | while read -r workflow_file; do
    local workflow_name
    workflow_name=$(basename "$workflow_file" .json)
    echo "$workflow_name"
  done
}

# Check if a workflow name is a built-in workflow
is_builtin_workflow() {
  local workflow_name="$1"
  case "$workflow_name" in
    morning|weekly|emergency|pre-deploy)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Check if a built-in workflow has a custom override
has_workflow_override() {
  local workflow_name="$1"
  local override_dir="${HOMELAB_WORKFLOW_OVERRIDE_DIR:-$HOME/.config/homelab/.workflow-overrides}"
  local override_file="$override_dir/${workflow_name}.json"

  [ -f "$override_file" ]
}

# Get workflow definition file path
# Returns path if found, empty string otherwise
get_workflow_file() {
  local workflow_name="$1"
  local override_dir="${HOMELAB_WORKFLOW_OVERRIDE_DIR:-$HOME/.config/homelab/.workflow-overrides}"
  local workflow_dir="${HOMELAB_WORKFLOW_DIR:-$HOME/.config/homelab/workflows}"

  # Check for override first
  if [ -f "$override_dir/${workflow_name}.json" ]; then
    echo "$override_dir/${workflow_name}.json"
    return 0
  fi

  # Check custom workflows directory
  if [ -f "$workflow_dir/${workflow_name}.json" ]; then
    echo "$workflow_dir/${workflow_name}.json"
    return 0
  fi

  return 1
}

# List all available workflows (built-in + custom)
list_all_workflows() {
  # Built-in workflows
  echo "morning"
  echo "weekly"
  echo "emergency"
  echo "pre-deploy"

  # Custom workflows
  list_custom_workflows
}

# Get workflow description
get_workflow_description() {
  local workflow_name="$1"
  local workflow_file

  # Check if it's a built-in workflow
  case "$workflow_name" in
    morning)
      echo "Daily maintenance (ssh-audit, nmap, sync check, updates preview)"
      return 0
      ;;
    weekly)
      echo "Weekly deep clean (cleanup, updates, full scans)"
      return 0
      ;;
    emergency)
      echo "Emergency disk cleanup (aggressive mode)"
      return 0
      ;;
    pre-deploy)
      echo "Pre-deployment checks (ssh, disk, network, git)"
      return 0
      ;;
  esac

  # Try to get description from custom workflow
  workflow_file=$(get_workflow_file "$workflow_name")
  if [ -n "$workflow_file" ] && [ -f "$workflow_file" ]; then
    local description
    if command -v jq >/dev/null 2>&1; then
      description=$(jq -r '.description // empty' "$workflow_file" 2>/dev/null)
    elif command -v python3 >/dev/null 2>&1; then
      local escaped_path
      escaped_path=$(escape_single_quotes "$workflow_file")
      description=$(python3 -c "import sys, json; data=json.load(open('$escaped_path')); print(data.get('description', ''))" 2>/dev/null)
    else
      description=$(grep -o '"description"[[:space:]]*:[[:space:]]*"[^"]*"' "$workflow_file" | sed 's/.*"\([^"]*\)".*/\1/' | head -1)
    fi

    if [ -n "$description" ]; then
      echo "$description"
      return 0
    fi
  fi

  echo "Custom workflow"
}

# Get workflow schedule information
get_workflow_schedule() {
  local workflow_name="$1"
  local workflow_file

  # Check if it's a built-in workflow with default schedule
  case "$workflow_name" in
    morning)
      echo "Daily at ${HOMELAB_SCHEDULE_MORNING_HOUR:-8}:${HOMELAB_SCHEDULE_MORNING_MINUTE:-00}"
      return 0
      ;;
    weekly)
      echo "Weekday ${HOMELAB_SCHEDULE_WEEKLY_WEEKDAY:-0} at ${HOMELAB_SCHEDULE_WEEKLY_HOUR:-2}:${HOMELAB_SCHEDULE_WEEKLY_MINUTE:-00}"
      return 0
      ;;
    emergency|pre-deploy)
      echo "Manual"
      return 0
      ;;
  esac

  # Try to get schedule from custom workflow
  workflow_file=$(get_workflow_file "$workflow_name")
  if [ -n "$workflow_file" ] && [ -f "$workflow_file" ]; then
    local schedule_comment
    if command -v jq >/dev/null 2>&1; then
      schedule_comment=$(jq -r '.schedule.comment // empty' "$workflow_file" 2>/dev/null)
    elif command -v python3 >/dev/null 2>&1; then
      local escaped_path
      escaped_path=$(escape_single_quotes "$workflow_file")
      schedule_comment=$(python3 -c "import sys, json; data=json.load(open('$escaped_path')); print(data.get('schedule', {}).get('comment', ''))" 2>/dev/null)
    fi

    if [ -n "$schedule_comment" ]; then
      echo "$schedule_comment"
      return 0
    fi
  fi

  echo "Manual"
}

# Validate workflow definition structure and script availability
# Usage: validate_workflow_definition <workflow_file>
# Returns: 0 if valid, 1 if invalid (with error messages)
validate_workflow_definition() {
  local workflow_file="$1"
  local validation_errors=0

  if [ ! -f "$workflow_file" ]; then
    print_error "Workflow file not found: $workflow_file"
    return 1
  fi

  # Validate JSON syntax first
  if ! validate_json "$workflow_file"; then
    print_error "Invalid JSON syntax in workflow file"
    return 1
  fi

  # Require jq or python3 for detailed validation
  if ! has_json_parser; then
    print_warning "Detailed validation requires jq or python3 (only basic JSON syntax checked)"
    return 0
  fi

  local parser
  parser=$(detect_json_parser)

  # Validate required fields
  local workflow_name
  if [ "$parser" = "jq" ]; then
    workflow_name=$(jq -r '.name // ""' "$workflow_file")
  else
    local escaped_path
    escaped_path=$(escape_single_quotes "$workflow_file")
    workflow_name=$(python3 -c "import json; data=json.load(open('$escaped_path')); print(data.get('name', ''))" 2>/dev/null)
  fi

  if [ -z "$workflow_name" ]; then
    print_error "Workflow missing required 'name' field"
    validation_errors=$((validation_errors + 1))
  fi

  # Get step count
  local step_count
  if [ "$parser" = "jq" ]; then
    step_count=$(jq '.steps | length' "$workflow_file" 2>/dev/null || echo "0")
  else
    local escaped_path
    escaped_path=$(escape_single_quotes "$workflow_file")
    step_count=$(python3 -c "import json; data=json.load(open('$escaped_path')); print(len(data.get('steps', [])))" 2>/dev/null || echo "0")
  fi

  if [ "$step_count" -eq 0 ]; then
    print_error "Workflow has no steps defined"
    validation_errors=$((validation_errors + 1))
    return 1
  fi

  # Validate workflow-level conditions block (if present)
  local has_conditions
  if [ "$parser" = "jq" ]; then
    has_conditions=$(jq 'has("conditions")' "$workflow_file" 2>/dev/null || echo "false")
  else
    local escaped_path
    escaped_path=$(escape_single_quotes "$workflow_file")
    has_conditions=$(python3 -c "import json; data=json.load(open('$escaped_path')); print('true' if 'conditions' in data else 'false')" 2>/dev/null || echo "false")
  fi

  if [ "$has_conditions" = "true" ]; then
    # Validate each condition type if present
    local condition_types="disk time_window last_run command file_exists"
    for cond_type in $condition_types; do
      local has_cond
      if [ "$parser" = "jq" ]; then
        has_cond=$(jq "has(\"conditions\") and (.conditions | has(\"$cond_type\"))" "$workflow_file" 2>/dev/null || echo "false")
      else
        has_cond=$(python3 -c "import json; data=json.load(open('$escaped_path')); print('true' if 'conditions' in data and '$cond_type' in data['conditions'] else 'false')" 2>/dev/null || echo "false")
      fi

      if [ "$has_cond" = "true" ]; then
        # Validate action field (must be "skip" or "fail")
        local action
        if [ "$parser" = "jq" ]; then
          action=$(jq -r ".conditions.$cond_type.action // \"\"" "$workflow_file" 2>/dev/null)
        else
          action=$(python3 -c "import json; data=json.load(open('$escaped_path')); print(data['conditions']['$cond_type'].get('action', ''))" 2>/dev/null)
        fi

        if [ -n "$action" ] && [ "$action" != "skip" ] && [ "$action" != "fail" ]; then
          print_error "Condition '$cond_type': action must be 'skip' or 'fail', got '$action'"
          validation_errors=$((validation_errors + 1))
        fi

        # Type-specific validation
        case "$cond_type" in
          disk)
            # Validate min_free_gb is numeric and in range
            local min_free_gb
            if [ "$parser" = "jq" ]; then
              min_free_gb=$(jq -r '.conditions.disk.min_free_gb // ""' "$workflow_file" 2>/dev/null)
            else
              min_free_gb=$(python3 -c "import json; data=json.load(open('$escaped_path')); print(data['conditions']['disk'].get('min_free_gb', ''))" 2>/dev/null)
            fi

            if [ -z "$min_free_gb" ]; then
              print_error "Condition 'disk': missing required field 'min_free_gb'"
              validation_errors=$((validation_errors + 1))
            elif ! [[ "$min_free_gb" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
              print_error "Condition 'disk': min_free_gb must be numeric, got '$min_free_gb'"
              validation_errors=$((validation_errors + 1))
            fi

            # Validate path field (optional, defaults to /)
            local disk_path
            if [ "$parser" = "jq" ]; then
              disk_path=$(jq -r '.conditions.disk.path // "/"' "$workflow_file" 2>/dev/null)
            else
              disk_path=$(python3 -c "import json; data=json.load(open('$escaped_path')); print(data['conditions']['disk'].get('path', '/'))" 2>/dev/null)
            fi

            # Expand tilde in path
            disk_path="${disk_path/#\~/$HOME}"

            if [ ! -d "$disk_path" ]; then
              print_warning "Condition 'disk': path '$disk_path' does not exist (will fail at runtime)"
            fi
            ;;

          time_window)
            # Validate start and end fields (HH:MM format)
            local start_time end_time
            if [ "$parser" = "jq" ]; then
              start_time=$(jq -r '.conditions.time_window.start // ""' "$workflow_file" 2>/dev/null)
              end_time=$(jq -r '.conditions.time_window.end // ""' "$workflow_file" 2>/dev/null)
            else
              start_time=$(python3 -c "import json; data=json.load(open('$escaped_path')); print(data['conditions']['time_window'].get('start', ''))" 2>/dev/null)
              end_time=$(python3 -c "import json; data=json.load(open('$escaped_path')); print(data['conditions']['time_window'].get('end', ''))" 2>/dev/null)
            fi

            if [ -z "$start_time" ]; then
              print_error "Condition 'time_window': missing required field 'start'"
              validation_errors=$((validation_errors + 1))
            elif ! [[ "$start_time" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]; then
              print_error "Condition 'time_window': start must be HH:MM format, got '$start_time'"
              validation_errors=$((validation_errors + 1))
            fi

            if [ -z "$end_time" ]; then
              print_error "Condition 'time_window': missing required field 'end'"
              validation_errors=$((validation_errors + 1))
            elif ! [[ "$end_time" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]; then
              print_error "Condition 'time_window': end must be HH:MM format, got '$end_time'"
              validation_errors=$((validation_errors + 1))
            fi
            ;;

          last_run)
            # Validate min_hours_since is numeric
            local min_hours
            if [ "$parser" = "jq" ]; then
              min_hours=$(jq -r '.conditions.last_run.min_hours_since // ""' "$workflow_file" 2>/dev/null)
            else
              min_hours=$(python3 -c "import json; data=json.load(open('$escaped_path')); print(data['conditions']['last_run'].get('min_hours_since', ''))" 2>/dev/null)
            fi

            if [ -z "$min_hours" ]; then
              print_error "Condition 'last_run': missing required field 'min_hours_since'"
              validation_errors=$((validation_errors + 1))
            elif ! [[ "$min_hours" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
              print_error "Condition 'last_run': min_hours_since must be numeric, got '$min_hours'"
              validation_errors=$((validation_errors + 1))
            fi
            ;;

          command)
            # Validate script field is present
            local cmd_script
            if [ "$parser" = "jq" ]; then
              cmd_script=$(jq -r '.conditions.command.script // ""' "$workflow_file" 2>/dev/null)
            else
              cmd_script=$(python3 -c "import json; data=json.load(open('$escaped_path')); print(data['conditions']['command'].get('script', ''))" 2>/dev/null)
            fi

            if [ -z "$cmd_script" ]; then
              print_error "Condition 'command': missing required field 'script'"
              validation_errors=$((validation_errors + 1))
            fi

            # Validate timeout is numeric (if present)
            local cmd_timeout
            if [ "$parser" = "jq" ]; then
              cmd_timeout=$(jq -r '.conditions.command.timeout // ""' "$workflow_file" 2>/dev/null)
            else
              cmd_timeout=$(python3 -c "import json; data=json.load(open('$escaped_path')); print(data['conditions']['command'].get('timeout', ''))" 2>/dev/null)
            fi

            if [ -n "$cmd_timeout" ] && ! [[ "$cmd_timeout" =~ ^[0-9]+$ ]]; then
              print_error "Condition 'command': timeout must be an integer, got '$cmd_timeout'"
              validation_errors=$((validation_errors + 1))
            fi
            ;;

          file_exists)
            # Validate path field is present
            local file_path
            if [ "$parser" = "jq" ]; then
              file_path=$(jq -r '.conditions.file_exists.path // ""' "$workflow_file" 2>/dev/null)
            else
              file_path=$(python3 -c "import json; data=json.load(open('$escaped_path')); print(data['conditions']['file_exists'].get('path', ''))" 2>/dev/null)
            fi

            if [ -z "$file_path" ]; then
              print_error "Condition 'file_exists': missing required field 'path'"
              validation_errors=$((validation_errors + 1))
            fi

            # Validate negate is boolean (if present)
            local negate_val
            if [ "$parser" = "jq" ]; then
              negate_val=$(jq -r '.conditions.file_exists.negate | type' "$workflow_file" 2>/dev/null)
            else
              negate_val=$(python3 -c "import json; data=json.load(open('$escaped_path')); val=data['conditions']['file_exists'].get('negate'); print(type(val).__name__ if val is not None else 'null')" 2>/dev/null)
            fi

            if [ -n "$negate_val" ] && [ "$negate_val" != "boolean" ] && [ "$negate_val" != "bool" ] && [ "$negate_val" != "null" ]; then
              print_error "Condition 'file_exists': negate must be boolean, got '$negate_val'"
              validation_errors=$((validation_errors + 1))
            fi
            ;;
        esac
      fi
    done
  fi

  # Validate each step
  for ((i=0; i<step_count; i++)); do
    local step_name
    local step_script
    local step_args_type

    if [ "$parser" = "jq" ]; then
      step_name=$(jq -r ".steps[$i].name // \"\"" "$workflow_file")
      step_script=$(jq -r ".steps[$i].script // \"\"" "$workflow_file")
      step_args_type=$(jq -r ".steps[$i].args | type" "$workflow_file" 2>/dev/null || echo "null")
    else
      local escaped_path
      escaped_path=$(escape_single_quotes "$workflow_file")
      step_name=$(python3 -c "import json; data=json.load(open('$escaped_path')); print(data['steps'][$i].get('name', ''))" 2>/dev/null)
      step_script=$(python3 -c "import json; data=json.load(open('$escaped_path')); print(data['steps'][$i].get('script', ''))" 2>/dev/null)
      step_args_type=$(python3 -c "import json; data=json.load(open('$escaped_path')); args=data['steps'][$i].get('args'); print(type(args).__name__ if args is not None else 'null')" 2>/dev/null)
    fi

    # Validate step name
    if [ -z "$step_name" ]; then
      print_error "Step $((i+1)): Missing 'name' field"
      validation_errors=$((validation_errors + 1))
    fi

    # Validate step script
    if [ -z "$step_script" ]; then
      print_error "Step $((i+1)) ($step_name): Missing 'script' field"
      validation_errors=$((validation_errors + 1))
      continue
    fi

    # Validate args is an array (if present)
    if [ "$step_args_type" != "null" ] && [ "$step_args_type" != "array" ] && [ "$step_args_type" != "list" ]; then
      print_error "Step $((i+1)) ($step_name): 'args' must be an array, got $step_args_type"
      validation_errors=$((validation_errors + 1))
    fi

    # Normalize tilde in script path (bash doesn't expand ~ in variables)
    local normalized_script="${step_script/#\~/$HOME}"

    # Check if script exists AND is executable (mirror runtime requirements)
    local script_found=false

    # Check if it's an absolute path (including tilde-expanded paths)
    if [[ "$normalized_script" == /* ]] && [ -f "$normalized_script" ] && [ -x "$normalized_script" ]; then
      script_found=true
    # Check if it's in PATH
    elif command -v "$step_script" >/dev/null 2>&1; then
      script_found=true
    # Check if it's a built-in script (in registry)
    elif type -t get_script_path >/dev/null 2>&1 && [ -n "$(get_script_path "$step_script" 2>/dev/null || true)" ]; then
      script_found=true
    # Check in homelab directory (relative to SCRIPT_DIR)
    elif [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/$step_script" ] && [ -x "$SCRIPT_DIR/$step_script" ]; then
      script_found=true
    # Check in parent directory (for symlinked scripts)
    elif [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/../$step_script" ] && [ -x "$SCRIPT_DIR/../$step_script" ]; then
      script_found=true
    # Check in current directory
    elif [ -f "./$step_script" ] && [ -x "./$step_script" ]; then
      script_found=true
    fi

    if [ "$script_found" = false ]; then
      print_warning "Step $((i+1)) ($step_name): Script '$step_script' not found in PATH or common locations"
      print_warning "  Script will be resolved at execution time"
    fi

    # Validate step-level when block (if present)
    local has_when
    if [ "$parser" = "jq" ]; then
      has_when=$(jq ".steps[$i] | has(\"when\")" "$workflow_file" 2>/dev/null || echo "false")
    else
      local escaped_path
      escaped_path=$(escape_single_quotes "$workflow_file")
      has_when=$(python3 -c "import json; data=json.load(open('$escaped_path')); print('true' if 'when' in data['steps'][$i] else 'false')" 2>/dev/null || echo "false")
    fi

    if [ "$has_when" = "true" ]; then
      # Validate each step condition type if present
      local step_condition_types="disk time_window command file_exists weekday"
      for when_type in $step_condition_types; do
        local has_when_cond
        if [ "$parser" = "jq" ]; then
          has_when_cond=$(jq ".steps[$i] | has(\"when\") and (.when | has(\"$when_type\"))" "$workflow_file" 2>/dev/null || echo "false")
        else
          has_when_cond=$(python3 -c "import json; data=json.load(open('$escaped_path')); print('true' if 'when' in data['steps'][$i] and '$when_type' in data['steps'][$i]['when'] else 'false')" 2>/dev/null || echo "false")
        fi

        if [ "$has_when_cond" = "true" ]; then
          # Validate action field (must be "skip" or "fail")
          local when_action
          if [ "$parser" = "jq" ]; then
            when_action=$(jq -r ".steps[$i].when.$when_type.action // \"\"" "$workflow_file" 2>/dev/null)
          else
            when_action=$(python3 -c "import json; data=json.load(open('$escaped_path')); print(data['steps'][$i]['when']['$when_type'].get('action', ''))" 2>/dev/null)
          fi

          if [ -n "$when_action" ] && [ "$when_action" != "skip" ] && [ "$when_action" != "fail" ]; then
            print_error "Step $((i+1)) ($step_name) when '$when_type': action must be 'skip' or 'fail', got '$when_action'"
            validation_errors=$((validation_errors + 1))
          fi

          # Type-specific validation (same as workflow-level, plus weekday)
          case "$when_type" in
            disk)
              local step_min_free_gb
              if [ "$parser" = "jq" ]; then
                step_min_free_gb=$(jq -r ".steps[$i].when.disk.min_free_gb // \"\"" "$workflow_file" 2>/dev/null)
              else
                step_min_free_gb=$(python3 -c "import json; data=json.load(open('$escaped_path')); print(data['steps'][$i]['when']['disk'].get('min_free_gb', ''))" 2>/dev/null)
              fi

              if [ -z "$step_min_free_gb" ]; then
                print_error "Step $((i+1)) ($step_name) when 'disk': missing required field 'min_free_gb'"
                validation_errors=$((validation_errors + 1))
              elif ! [[ "$step_min_free_gb" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                print_error "Step $((i+1)) ($step_name) when 'disk': min_free_gb must be numeric, got '$step_min_free_gb'"
                validation_errors=$((validation_errors + 1))
              fi
              ;;

            time_window)
              local step_start_time step_end_time
              if [ "$parser" = "jq" ]; then
                step_start_time=$(jq -r ".steps[$i].when.time_window.start // \"\"" "$workflow_file" 2>/dev/null)
                step_end_time=$(jq -r ".steps[$i].when.time_window.end // \"\"" "$workflow_file" 2>/dev/null)
              else
                step_start_time=$(python3 -c "import json; data=json.load(open('$escaped_path')); print(data['steps'][$i]['when']['time_window'].get('start', ''))" 2>/dev/null)
                step_end_time=$(python3 -c "import json; data=json.load(open('$escaped_path')); print(data['steps'][$i]['when']['time_window'].get('end', ''))" 2>/dev/null)
              fi

              if [ -z "$step_start_time" ]; then
                print_error "Step $((i+1)) ($step_name) when 'time_window': missing required field 'start'"
                validation_errors=$((validation_errors + 1))
              elif ! [[ "$step_start_time" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]; then
                print_error "Step $((i+1)) ($step_name) when 'time_window': start must be HH:MM format, got '$step_start_time'"
                validation_errors=$((validation_errors + 1))
              fi

              if [ -z "$step_end_time" ]; then
                print_error "Step $((i+1)) ($step_name) when 'time_window': missing required field 'end'"
                validation_errors=$((validation_errors + 1))
              elif ! [[ "$step_end_time" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]; then
                print_error "Step $((i+1)) ($step_name) when 'time_window': end must be HH:MM format, got '$step_end_time'"
                validation_errors=$((validation_errors + 1))
              fi
              ;;

            command)
              local step_cmd_script
              if [ "$parser" = "jq" ]; then
                step_cmd_script=$(jq -r ".steps[$i].when.command.script // \"\"" "$workflow_file" 2>/dev/null)
              else
                step_cmd_script=$(python3 -c "import json; data=json.load(open('$escaped_path')); print(data['steps'][$i]['when']['command'].get('script', ''))" 2>/dev/null)
              fi

              if [ -z "$step_cmd_script" ]; then
                print_error "Step $((i+1)) ($step_name) when 'command': missing required field 'script'"
                validation_errors=$((validation_errors + 1))
              fi

              local step_cmd_timeout
              if [ "$parser" = "jq" ]; then
                step_cmd_timeout=$(jq -r ".steps[$i].when.command.timeout // \"\"" "$workflow_file" 2>/dev/null)
              else
                step_cmd_timeout=$(python3 -c "import json; data=json.load(open('$escaped_path')); print(data['steps'][$i]['when']['command'].get('timeout', ''))" 2>/dev/null)
              fi

              if [ -n "$step_cmd_timeout" ] && ! [[ "$step_cmd_timeout" =~ ^[0-9]+$ ]]; then
                print_error "Step $((i+1)) ($step_name) when 'command': timeout must be an integer, got '$step_cmd_timeout'"
                validation_errors=$((validation_errors + 1))
              fi
              ;;

            file_exists)
              local step_file_path
              if [ "$parser" = "jq" ]; then
                step_file_path=$(jq -r ".steps[$i].when.file_exists.path // \"\"" "$workflow_file" 2>/dev/null)
              else
                step_file_path=$(python3 -c "import json; data=json.load(open('$escaped_path')); print(data['steps'][$i]['when']['file_exists'].get('path', ''))" 2>/dev/null)
              fi

              if [ -z "$step_file_path" ]; then
                print_error "Step $((i+1)) ($step_name) when 'file_exists': missing required field 'path'"
                validation_errors=$((validation_errors + 1))
              fi

              local step_negate_val
              if [ "$parser" = "jq" ]; then
                step_negate_val=$(jq -r ".steps[$i].when.file_exists.negate | type" "$workflow_file" 2>/dev/null)
              else
                step_negate_val=$(python3 -c "import json; data=json.load(open('$escaped_path')); val=data['steps'][$i]['when']['file_exists'].get('negate'); print(type(val).__name__ if val is not None else 'null')" 2>/dev/null)
              fi

              if [ -n "$step_negate_val" ] && [ "$step_negate_val" != "boolean" ] && [ "$step_negate_val" != "bool" ] && [ "$step_negate_val" != "null" ]; then
                print_error "Step $((i+1)) ($step_name) when 'file_exists': negate must be boolean, got '$step_negate_val'"
                validation_errors=$((validation_errors + 1))
              fi
              ;;

            weekday)
              # Validate days is an array of integers 0-6
              local days_type
              if [ "$parser" = "jq" ]; then
                days_type=$(jq -r ".steps[$i].when.weekday.days | type" "$workflow_file" 2>/dev/null)
              else
                days_type=$(python3 -c "import json; data=json.load(open('$escaped_path')); days=data['steps'][$i]['when']['weekday'].get('days'); print(type(days).__name__ if days is not None else 'null')" 2>/dev/null)
              fi

              if [ "$days_type" = "null" ]; then
                print_error "Step $((i+1)) ($step_name) when 'weekday': missing required field 'days'"
                validation_errors=$((validation_errors + 1))
              elif [ "$days_type" != "array" ] && [ "$days_type" != "list" ]; then
                print_error "Step $((i+1)) ($step_name) when 'weekday': 'days' must be an array, got $days_type"
                validation_errors=$((validation_errors + 1))
              else
                # Validate each day is 0-6
                local days_length
                if [ "$parser" = "jq" ]; then
                  days_length=$(jq -r ".steps[$i].when.weekday.days | length" "$workflow_file" 2>/dev/null)
                else
                  days_length=$(python3 -c "import json; data=json.load(open('$escaped_path')); print(len(data['steps'][$i]['when']['weekday']['days']))" 2>/dev/null)
                fi

                for ((d=0; d<days_length; d++)); do
                  local day_val
                  if [ "$parser" = "jq" ]; then
                    day_val=$(jq -r ".steps[$i].when.weekday.days[$d]" "$workflow_file" 2>/dev/null)
                  else
                    day_val=$(python3 -c "import json; data=json.load(open('$escaped_path')); print(data['steps'][$i]['when']['weekday']['days'][$d])" 2>/dev/null)
                  fi

                  if ! [[ "$day_val" =~ ^[0-6]$ ]]; then
                    print_error "Step $((i+1)) ($step_name) when 'weekday': days must be integers 0-6 (got '$day_val')"
                    validation_errors=$((validation_errors + 1))
                  fi
                done
              fi
              ;;
          esac
        fi
      done
    fi
  done

  if [ $validation_errors -gt 0 ]; then
    print_error "Workflow validation failed with $validation_errors error(s)"
    return 1
  fi

  return 0
}

# Execute a custom workflow from JSON definition
# Usage: execute_custom_workflow <workflow_name> [options]
execute_custom_workflow() {
  local workflow_name="$1"
  shift

  # Get workflow file
  local workflow_file
  workflow_file=$(get_workflow_file "$workflow_name")

  if [ -z "$workflow_file" ]; then
    print_error "Workflow not found: $workflow_name"
    return 1
  fi

  # Validate JSON syntax
  if ! validate_json "$workflow_file"; then
    print_error "Invalid JSON in workflow file: $workflow_file"
    return 1
  fi

  # Require jq or python3 for execution
  if ! has_json_parser; then
    print_error "Custom workflow execution requires jq or python3"
    echo "Install with: brew install jq (macOS) or apt install jq (Linux)"
    return 1
  fi

  # Validate workflow structure (required fields, step format, etc.)
  if ! validate_workflow_definition "$workflow_file"; then
    print_error "Workflow validation failed - cannot execute"
    return 1
  fi

  # Parse workflow options
  local is_scheduled=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --dry-run) DRY_RUN=true; shift ;;
      --verbose|-v) HOMELAB_VERBOSE=true; shift ;;
      --quiet|-q) HOMELAB_QUIET=true; shift ;;
      --notify) HOMELAB_NOTIFY_MANUAL=true; shift ;;
      --scheduled) is_scheduled=true; shift ;;
      *) shift ;;
    esac
  done

  # Evaluate workflow-level conditions (pre-flight checks)
  if type -t evaluate_workflow_conditions >/dev/null 2>&1; then
    local condition_result
    CONDITION_SKIP_REASON=""  # Global variable set by condition evaluators
    evaluate_workflow_conditions "$workflow_file"
    condition_result=$?

    if [ $condition_result -eq 1 ]; then
      # Conditions failed with skip action
      print_info "Workflow skipped: $CONDITION_SKIP_REASON"
      log_to_file "INFO: Workflow skipped - $CONDITION_SKIP_REASON"

      # Send warning-level notification for skip with reason in skipped field
      if type -t send_notification >/dev/null 2>&1; then
        send_notification "$workflow_name" "warning" "0s" "0" "0" "" "Workflow: $CONDITION_SKIP_REASON" "" "$is_scheduled" false
      fi

      return 0  # Exit 0 for skip (not an error)
    elif [ $condition_result -eq 2 ]; then
      # Conditions failed with fail action
      print_error "Workflow failed condition check: $CONDITION_SKIP_REASON"
      log_to_file "ERROR: Workflow failed - $CONDITION_SKIP_REASON"

      # Send failure notification with reason in failed field
      if type -t send_notification >/dev/null 2>&1; then
        send_notification "$workflow_name" "failure" "0s" "0" "0" "Condition: $CONDITION_SKIP_REASON" "" "" "$is_scheduled" false
      fi

      return 1  # Exit 1 for failure
    fi
  fi

  # Initialize workflow logging
  init_workflow_logging "$workflow_name"

  # Get workflow metadata
  local parser
  parser=$(detect_json_parser)

  local step_count
  if [ "$parser" = "jq" ]; then
    step_count=$(jq '.steps | length' "$workflow_file")
  else
    local escaped_path
    escaped_path=$(escape_single_quotes "$workflow_file")
    step_count=$(python3 -c "import json; data=json.load(open('$escaped_path')); print(len(data.get('steps', [])))" 2>/dev/null || echo "0")
  fi

  WORKFLOW_TOTAL_STEPS=$step_count

  local description
  description=$(get_workflow_description "$workflow_name")

  print_section "Custom Workflow: $workflow_name"
  if [ "${HOMELAB_VERBOSE:-false}" = true ]; then
    echo "Description: $description"
    echo "Steps: $step_count"
    echo ""
  fi

  # Send start notification if enabled
  if type -t send_notification >/dev/null 2>&1; then
    send_notification "$workflow_name" "start" "0s" "0" "$WORKFLOW_TOTAL_STEPS" "" "" "$WORKFLOW_LOG" "$is_scheduled" false
  fi

  # Execute each step
  local exit_code=0
  for ((i=0; i<step_count; i++)); do
    local step_name
    local step_script
    local skip_on_error
    local timeout

    # Parse step metadata
    if [ "$parser" = "jq" ]; then
      step_name=$(jq -r ".steps[$i].name" "$workflow_file")
      step_script=$(jq -r ".steps[$i].script" "$workflow_file")
      skip_on_error=$(jq -r ".steps[$i].skip_on_error // false" "$workflow_file")
      timeout=$(jq -r ".steps[$i].timeout // 0" "$workflow_file")
    else
      # python3 parser
      local escaped_path
      escaped_path=$(escape_single_quotes "$workflow_file")
      step_name=$(python3 -c "import json; data=json.load(open('$escaped_path')); print(data['steps'][$i]['name'])" 2>/dev/null)
      step_script=$(python3 -c "import json; data=json.load(open('$escaped_path')); print(data['steps'][$i]['script'])" 2>/dev/null)
      skip_on_error=$(python3 -c "import json; data=json.load(open('$escaped_path')); print(str(data['steps'][$i].get('skip_on_error', False)).lower())" 2>/dev/null)
      timeout=$(python3 -c "import json; data=json.load(open('$escaped_path')); print(data['steps'][$i].get('timeout', 0))" 2>/dev/null)
    fi

    # Evaluate step-level conditions (when guards)
    if type -t evaluate_step_conditions >/dev/null 2>&1; then
      local step_condition_result
      CONDITION_SKIP_REASON=""
      evaluate_step_conditions "$workflow_file" "$i"
      step_condition_result=$?

      if [ $step_condition_result -eq 1 ]; then
        # Step conditions failed with skip action
        print_info "  ℹ Step $((i+1)) skipped: $CONDITION_SKIP_REASON"
        log_to_file "INFO: Step $((i+1)) ($step_name) skipped - $CONDITION_SKIP_REASON"

        # Track skipped step (don't increment WORKFLOW_STEP_COUNT - run_step manages that)
        WORKFLOW_SKIPPED_STEPS+=("$step_name")
        continue  # Skip to next step
      elif [ $step_condition_result -eq 2 ]; then
        # Step conditions failed with fail action
        print_error "  ✗ Step $((i+1)) failed condition: $CONDITION_SKIP_REASON"
        log_to_file "ERROR: Step $((i+1)) ($step_name) failed - $CONDITION_SKIP_REASON"

        # Track failed step
        WORKFLOW_FAILED_STEPS+=("$step_name")

        if [ "$skip_on_error" != "true" ]; then
          exit_code=1
          break  # Stop workflow
        else
          continue  # Continue to next step
        fi
      fi
    fi

    # Parse args as array (safely preserving spaces and special characters)
    local step_args=()
    if [ "$parser" = "jq" ]; then
      # Use jq to output one arg per line, then read into array
      while IFS= read -r arg; do
        step_args+=("$arg")
      done < <(jq -r ".steps[$i].args[]? // empty" "$workflow_file" 2>/dev/null)
    else
      # Use python3 to output one arg per line, then read into array
      local escaped_path
      escaped_path=$(escape_single_quotes "$workflow_file")
      while IFS= read -r arg; do
        step_args+=("$arg")
      done < <(python3 -c "import json, sys; data=json.load(open('$escaped_path')); args=data['steps'][$i].get('args', []); [print(arg) for arg in args]" 2>/dev/null)
    fi

    # Execute step with properly quoted args array
    if run_step "$step_name" "$step_script" "${step_args[@]}"; then
      :  # Step succeeded
    else
      local step_exit=$?
      if [ "$skip_on_error" = "true" ]; then
        print_warning "  ⚠ Step failed but continuing (skip_on_error=true)"
        log_to_file "WARNING: Step $((i+1)) failed but continuing"
      else
        print_error "  ✗ Step failed, stopping workflow"
        log_to_file "ERROR: Step $((i+1)) failed, stopping workflow"
        exit_code=$step_exit
        break
      fi
    fi
  done

  # Print summary and complete logging
  print_workflow_summary
  complete_workflow_logging "$workflow_name" "$exit_code" "$is_scheduled"

  return $exit_code
}

# ============================================================================
# BUILT-IN WORKFLOW DEFINITIONS
# ============================================================================

# Morning routine workflow
run_morning_routine() {
  init_workflow_logging "morning"

  # Parse options (preserve global flags if already set)
  local skip_ssh=false skip_network=false skip_updates=false skip_backup=false
  local is_scheduled=false  # Set to true if called from cron/launchd
  while [[ $# -gt 0 ]]; do
    case $1 in
      --skip-ssh) skip_ssh=true; shift ;;
      --skip-network) skip_network=true; shift ;;
      --skip-updates) skip_updates=true; shift ;;
      --skip-backup) skip_backup=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      --verbose|-v) HOMELAB_VERBOSE=true; shift ;;
      --quiet|-q) HOMELAB_QUIET=true; shift ;;
      --notify) HOMELAB_NOTIFY_MANUAL=true; shift ;;
      --scheduled) is_scheduled=true; shift ;;  # Internal flag from scheduler
      *) shift ;;
    esac
  done

  WORKFLOW_TOTAL_STEPS=4
  print_section "Morning Routine"

  # Send start notification if enabled
  if type -t send_notification >/dev/null 2>&1; then
    send_notification "morning" "start" "0s" "0" "$WORKFLOW_TOTAL_STEPS" "" "" "$WORKFLOW_LOG" "$is_scheduled" false
  fi

  # Step 1: SSH key audit
  if [ "$skip_ssh" != true ]; then
    run_step "SSH Key Audit" "ssh-key-audit.sh" $MORNING_SSH_AUDIT_OPTS
  else
    print_info "[1/$WORKFLOW_TOTAL_STEPS] SSH Key Audit... (skipped by user)"
    WORKFLOW_STEP_COUNT=$((WORKFLOW_STEP_COUNT + 1))
  fi

  # Step 2: Network scan
  if [ "$skip_network" != true ]; then
    run_step "Network Scan" "nmap-scan.sh" $MORNING_NMAP_OPTS
  else
    print_info "[2/$WORKFLOW_TOTAL_STEPS] Network Scan... (skipped by user)"
    WORKFLOW_STEP_COUNT=$((WORKFLOW_STEP_COUNT + 1))
  fi

  # Step 3: Backup sync status
  if [ "$skip_backup" != true ]; then
    run_step "Backup Status" "rclone-sync.sh" --status
  else
    print_info "[3/$WORKFLOW_TOTAL_STEPS] Backup Status... (skipped by user)"
    WORKFLOW_STEP_COUNT=$((WORKFLOW_STEP_COUNT + 1))
  fi

  # Step 4: Package updates preview
  if [ "$skip_updates" != true ]; then
    run_step "Package Updates" "update-all.sh" $MORNING_UPDATE_OPTS
  else
    print_info "[4/$WORKFLOW_TOTAL_STEPS] Package Updates... (skipped by user)"
    WORKFLOW_STEP_COUNT=$((WORKFLOW_STEP_COUNT + 1))
  fi

  print_workflow_summary
  complete_workflow_logging "morning" 0 "$is_scheduled"
}

# Weekly maintenance workflow
run_weekly_maintenance() {
  init_workflow_logging "weekly"

  # Parse options
  local skip_cleanup=false skip_updates=false skip_scans=false
  local is_scheduled=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --skip-cleanup) skip_cleanup=true; shift ;;
      --skip-updates) skip_updates=true; shift ;;
      --skip-scans) skip_scans=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      --verbose|-v) HOMELAB_VERBOSE=true; shift ;;
      --quiet|-q) HOMELAB_QUIET=true; shift ;;
      --notify) HOMELAB_NOTIFY_MANUAL=true; shift ;;
      --scheduled) is_scheduled=true; shift ;;
      *) shift ;;
    esac
  done

  WORKFLOW_TOTAL_STEPS=5
  print_section "Weekly Maintenance"

  # Send start notification if enabled
  if type -t send_notification >/dev/null 2>&1; then
    send_notification "weekly" "start" "0s" "0" "$WORKFLOW_TOTAL_STEPS" "" "" "$WORKFLOW_LOG" "$is_scheduled" false
  fi

  # Step 1: Disk cleanup
  if [ "$skip_cleanup" != true ]; then
    run_step "Disk Cleanup" "disk-cleanup.sh" $WEEKLY_CLEANUP_OPTS
  else
    print_info "[1/$WORKFLOW_TOTAL_STEPS] Disk Cleanup... (skipped by user)"
    WORKFLOW_STEP_COUNT=$((WORKFLOW_STEP_COUNT + 1))
  fi

  # Step 2: System updates
  if [ "$skip_updates" != true ]; then
    run_step "System Updates" "update-all.sh" $WEEKLY_UPDATE_OPTS
  else
    print_info "[2/$WORKFLOW_TOTAL_STEPS] System Updates... (skipped by user)"
    WORKFLOW_STEP_COUNT=$((WORKFLOW_STEP_COUNT + 1))
  fi

  # Step 3: SSH key audit (detailed)
  if [ "$skip_scans" != true ]; then
    run_step "SSH Key Audit" "ssh-key-audit.sh" $WEEKLY_SSH_AUDIT_OPTS
  else
    print_info "[3/$WORKFLOW_TOTAL_STEPS] SSH Key Audit... (skipped by user)"
    WORKFLOW_STEP_COUNT=$((WORKFLOW_STEP_COUNT + 1))
  fi

  # Step 4: Network scan (full)
  if [ "$skip_scans" != true ]; then
    run_step "Network Scan" "nmap-scan.sh" $WEEKLY_NMAP_OPTS
  else
    print_info "[4/$WORKFLOW_TOTAL_STEPS] Network Scan... (skipped by user)"
    WORKFLOW_STEP_COUNT=$((WORKFLOW_STEP_COUNT + 1))
  fi

  # Step 5: Backup verification
  if [ "$skip_scans" != true ]; then
    run_step "Backup Verification" "rclone-sync.sh" --check
  else
    print_info "[5/$WORKFLOW_TOTAL_STEPS] Backup Verification... (skipped by user)"
    WORKFLOW_STEP_COUNT=$((WORKFLOW_STEP_COUNT + 1))
  fi

  print_workflow_summary
  complete_workflow_logging "weekly" 0 "$is_scheduled"
}

# Emergency cleanup workflow
run_emergency_cleanup() {
  init_workflow_logging "emergency"

  # Parse options
  local threshold_gb="$EMERGENCY_DISK_THRESHOLD_GB"
  local is_scheduled=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --threshold) threshold_gb="$2"; shift 2 ;;
      --dry-run) DRY_RUN=true; shift ;;
      --verbose|-v) HOMELAB_VERBOSE=true; shift ;;
      --quiet|-q) HOMELAB_QUIET=true; shift ;;
      --notify) HOMELAB_NOTIFY_MANUAL=true; shift ;;
      --scheduled) is_scheduled=true; shift ;;
      *) shift ;;
    esac
  done

  WORKFLOW_TOTAL_STEPS=3
  print_section "Emergency Cleanup"

  # Send start notification if enabled
  if type -t send_notification >/dev/null 2>&1; then
    send_notification "emergency" "start" "0s" "0" "$WORKFLOW_TOTAL_STEPS" "" "" "$WORKFLOW_LOG" "$is_scheduled" false
  fi

  # Step 1: Check disk space
  print_info "[1/$WORKFLOW_TOTAL_STEPS] Checking disk space..."
  WORKFLOW_STEP_COUNT=$((WORKFLOW_STEP_COUNT + 1))

  local avail_gb=$(df -BG / 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G' || df -g / 2>/dev/null | awk 'NR==2 {print $4}')
  if [ -z "$avail_gb" ]; then
    # macOS fallback
    avail_gb=$(df -h / | awk 'NR==2 {print $4}' | sed 's/Gi*$//')
  fi

  echo "  Available: ${avail_gb}GB (threshold: ${threshold_gb}GB)"
  log_to_file "Disk space: ${avail_gb}GB available (threshold: ${threshold_gb}GB)"

  if [ "$avail_gb" -lt "$threshold_gb" ]; then
    print_warning "  ⚠ Disk space below threshold - proceeding with aggressive cleanup"
    log_to_file "WARNING: Disk space below threshold"

    # Step 2: Aggressive cleanup
    run_step "Aggressive Cleanup" "disk-cleanup.sh" $EMERGENCY_CLEANUP_OPTS

    # Step 3: Re-check disk space
    print_info "[3/$WORKFLOW_TOTAL_STEPS] Re-checking disk space..."
    WORKFLOW_STEP_COUNT=$((WORKFLOW_STEP_COUNT + 1))

    local avail_after=$(df -BG / 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G' || df -g / 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -z "$avail_after" ]; then
      avail_after=$(df -h / | awk 'NR==2 {print $4}' | sed 's/Gi*$//')
    fi

    local freed=$((avail_after - avail_gb))
    echo "  Available: ${avail_after}GB (freed: ${freed}GB)"
    log_to_file "Post-cleanup: ${avail_after}GB available (freed: ${freed}GB)"

    if [ "$avail_after" -ge "$threshold_gb" ]; then
      print_success "  ✓ Disk space recovered to safe levels"
    else
      print_warning "  ⚠ Still below threshold - manual intervention may be needed"
    fi
  else
    print_success "  ✓ Disk space healthy - no emergency cleanup needed"
    log_to_file "Disk space healthy - skipping emergency cleanup"
    WORKFLOW_STEP_COUNT=$((WORKFLOW_TOTAL_STEPS))
  fi

  print_workflow_summary
  complete_workflow_logging "emergency" 0 "$is_scheduled"
}

# Pre-deployment checks workflow
run_predeploy_checks() {
  init_workflow_logging "pre-deploy"

  # Parse options
  local fail_on_risk="$PREDEPLOY_FAIL_ON_RISK"
  local min_disk_gb="$PREDEPLOY_MIN_DISK_GB"
  local is_scheduled=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --fail-on-risk) fail_on_risk="$2"; shift 2 ;;
      --min-disk) min_disk_gb="$2"; shift 2 ;;
      --dry-run) DRY_RUN=true; shift ;;
      --verbose|-v) HOMELAB_VERBOSE=true; shift ;;
      --quiet|-q) HOMELAB_QUIET=true; shift ;;
      --notify) HOMELAB_NOTIFY_MANUAL=true; shift ;;
      --scheduled) is_scheduled=true; shift ;;
      *) shift ;;
    esac
  done

  WORKFLOW_TOTAL_STEPS=4
  local exit_code=0
  local warnings=0
  local critical=0

  print_section "Pre-Deploy Checks"

  # Send start notification if enabled
  if type -t send_notification >/dev/null 2>&1; then
    send_notification "pre-deploy" "start" "0s" "0" "$WORKFLOW_TOTAL_STEPS" "" "" "$WORKFLOW_LOG" "$is_scheduled" false
  fi

  # Step 1: SSH key audit with risk threshold
  if run_step "SSH Key Audit" "ssh-key-audit.sh" --all-users --risk --json; then
    # Parse risk levels from JSON (simplified - would use jq in production)
    # For now, just check if the command succeeded
    :
  else
    print_warning "  ⚠ SSH audit had warnings"
    warnings=$((warnings + 1))
  fi

  # Step 2: Disk space check
  print_info "[2/$WORKFLOW_TOTAL_STEPS] Disk Space Check..."
  WORKFLOW_STEP_COUNT=$((WORKFLOW_STEP_COUNT + 1))

  local avail_gb=$(df -BG / 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G' || df -g / 2>/dev/null | awk 'NR==2 {print $4}')
  if [ -z "$avail_gb" ]; then
    avail_gb=$(df -h / | awk 'NR==2 {print $4}' | sed 's/Gi*$//')
  fi

  echo "  Available: ${avail_gb}GB (minimum: ${min_disk_gb}GB)"
  if [ "$avail_gb" -lt "$min_disk_gb" ]; then
    print_error "  ✗ Insufficient disk space for deployment"
    critical=$((critical + 1))
    exit_code=2
  else
    print_success "  ✓ Sufficient disk space"
  fi

  # Step 3: Network scan
  run_step "Network Scan" "nmap-scan.sh" --delta

  # Step 4: Git status check (if in a git repo)
  print_info "[4/$WORKFLOW_TOTAL_STEPS] Git Status Check..."
  WORKFLOW_STEP_COUNT=$((WORKFLOW_STEP_COUNT + 1))

  if git rev-parse --git-dir > /dev/null 2>&1; then
    if git diff-index --quiet HEAD --; then
      print_success "  ✓ Working directory clean"
    else
      print_warning "  ⚠ Uncommitted changes detected"
      warnings=$((warnings + 1))
    fi
  else
    print_info "  ⊘ Not a git repository (skipped)"
  fi

  # Summary
  print_section "Pre-Deploy Summary"
  echo "Warnings: $warnings"
  echo "Critical: $critical"
  echo ""

  if [ $critical -gt 0 ]; then
    print_error "Pre-deploy checks FAILED - $critical critical issues"
    print_info "Abort deployment and resolve critical issues"
    exit_code=2
  elif [ $warnings -gt 0 ]; then
    print_warning "Pre-deploy checks passed with $warnings warnings"
    print_info "Review warnings before deploying"
    exit_code=1
  else
    print_success "All pre-deploy checks passed"
    print_info "Safe to deploy"
    exit_code=0
  fi

  echo ""
  echo "Full log: $WORKFLOW_LOG"

  complete_workflow_logging "pre-deploy" "$exit_code" "$is_scheduled"
  return $exit_code
}
