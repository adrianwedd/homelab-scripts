#!/usr/bin/env bash
# homelab/lib/scheduler.sh - Workflow scheduling (cron/launchd)
# Part of homelab v1.0.0

# Shell escape for safe embedding in shell scripts (cron)
# Uses printf %q for proper shell quoting
shell_escape() {
  printf '%q' "$1"
}

# XML escape for launchd plists
xml_escape() {
  local input="$1"
  # Escape XML special characters
  input="${input//&/&amp;}"   # Must be first
  input="${input//</&lt;}"
  input="${input//>/&gt;}"
  input="${input//\"/&quot;}"
  input="${input//\'/&apos;}"
  echo "$input"
}

# Platform detection
detect_scheduler_platform() {
  if command -v launchctl >/dev/null 2>&1; then
    echo "launchd"
  elif command -v crontab >/dev/null 2>&1; then
    echo "cron"
  else
    echo "none"
  fi
}

# Get homelab executable path
get_homelab_path() {
  local homelab_path=""

  # Check if homelab is in PATH
  if command -v homelab >/dev/null 2>&1; then
    homelab_path=$(command -v homelab)
  # Check if running from script directory
  elif [ -f "$SCRIPT_DIR/homelab.sh" ]; then
    homelab_path="$SCRIPT_DIR/homelab.sh"
  else
    return 1
  fi

  # Return absolute path
  if [ -L "$homelab_path" ]; then
    # Follow symlink
    readlink -f "$homelab_path" 2>/dev/null || readlink "$homelab_path" 2>/dev/null || echo "$homelab_path"
  else
    echo "$homelab_path"
  fi
}

# Validate homelab is accessible
validate_homelab_access() {
  local homelab_path=$(get_homelab_path)

  if [ -z "$homelab_path" ]; then
    print_error "Cannot find homelab executable"
    echo ""
    print_info "To fix this, either:"
    echo "  1. Add homelab to your PATH:"
    echo "     ln -s $SCRIPT_DIR/homelab.sh ~/bin/homelab"
    echo "  2. Or use the full path in the schedule"
    return 1
  fi

  if [ ! -x "$homelab_path" ]; then
    print_error "homelab is not executable: $homelab_path"
    echo "  Run: chmod +x $homelab_path"
    return 1
  fi

  echo "$homelab_path"
  return 0
}

# Install schedule
install_schedule() {
  local platform=$(detect_scheduler_platform)
  local dry_run=false

  # Parse options
  while [[ $# -gt 0 ]]; do
    case $1 in
      --dry-run)
        dry_run=true
        shift
        ;;
      *)
        shift
        ;;
    esac
  done

  print_section "Installing Workflow Schedule"

  # Validate homelab access
  local homelab_path=$(validate_homelab_access)
  [ $? -ne 0 ] && return 1

  print_info "Detected scheduler: $platform"
  print_info "homelab path: $homelab_path"
  echo ""

  case "$platform" in
    launchd)
      install_launchd_schedule "$homelab_path" "$dry_run"
      ;;
    cron)
      install_cron_schedule "$homelab_path" "$dry_run"
      ;;
    none)
      print_error "No scheduler detected (cron or launchd)"
      return 1
      ;;
  esac
}

# Install cron schedule (Linux)
install_cron_schedule() {
  local homelab_path="$1"
  local dry_run="$2"

  # Create log directory if needed
  mkdir -p "$HOMELAB_LOG_DIR"

  # Shell-escape homelab path for safe cron embedding
  local escaped_homelab_path=$(shell_escape "$homelab_path")

  # Get list of scheduled workflows
  local scheduled_workflows=()
  if type -t list_scheduled_workflows >/dev/null 2>&1; then
    while IFS= read -r workflow_name; do
      scheduled_workflows+=("$workflow_name")
    done < <(list_scheduled_workflows)
  else
    # Fallback to built-in workflows only
    print_warning "list_scheduled_workflows not available, using built-in workflows only"
    scheduled_workflows=("morning" "weekly")
  fi

  if [ ${#scheduled_workflows[@]} -eq 0 ]; then
    print_warning "No scheduled workflows found"
    return 0
  fi

  print_info "Schedule configuration:"

  # Build cron entries dynamically
  local cron_entries="# homelab automated workflows (installed $(date '+%Y-%m-%d %H:%M:%S'))"

  for workflow_name in "${scheduled_workflows[@]}"; do
    # Get cron expression
    local cron_expr
    if type -t get_workflow_cron_expression >/dev/null 2>&1; then
      cron_expr=$(get_workflow_cron_expression "$workflow_name")
    else
      # Fallback for built-in workflows
      case "$workflow_name" in
        morning) cron_expr="${HOMELAB_SCHEDULE_MORNING:-0 8 * * *}" ;;
        weekly) cron_expr="${HOMELAB_SCHEDULE_WEEKLY:-0 2 * * 0}" ;;
        *) continue ;;
      esac
    fi

    if [ -z "$cron_expr" ]; then
      continue
    fi

    # Get human-readable schedule description
    local schedule_desc
    if type -t get_workflow_schedule >/dev/null 2>&1; then
      schedule_desc=$(get_workflow_schedule "$workflow_name")
    else
      schedule_desc="$cron_expr"
    fi

    # Create log file path
    local escaped_log=$(shell_escape "$HOMELAB_LOG_DIR/cron_${workflow_name}.log")

    # Add entry
    cron_entries+="
$cron_expr $escaped_homelab_path workflow run $workflow_name --quiet --scheduled >> $escaped_log 2>&1"

    # Show configuration
    echo "  $workflow_name: $schedule_desc"
  done

  cron_entries+="
# end homelab"

  echo ""

  if [ "$dry_run" = true ]; then
    print_section "Dry-run: Would install the following crontab entries"
    echo "$cron_entries"
    return 0
  fi

  # Backup existing crontab
  local backup_file="$HOMELAB_LOG_DIR/crontab_backup_$(date +%s).txt"
  mkdir -p "$HOMELAB_LOG_DIR"
  crontab -l > "$backup_file" 2>/dev/null || touch "$backup_file"
  print_success "Backed up existing crontab to: $backup_file"

  # Check if homelab entries already exist
  if crontab -l 2>/dev/null | grep -q "homelab morning"; then
    print_warning "homelab entries already exist in crontab"
    echo ""
    echo "Remove existing entries first:"
    echo "  homelab schedule remove"
    return 1
  fi

  # Install new entries with error handling
  local temp_cron=$(mktemp)
  trap 'rm -f "$temp_cron"' EXIT INT TERM

  (crontab -l 2>/dev/null; echo ""; echo "$cron_entries") > "$temp_cron"

  # Validate new crontab before installing
  if ! crontab "$temp_cron" 2>/dev/null; then
    print_error "Failed to install crontab"
    echo ""
    print_info "Restoring from backup: $backup_file"
    if [ -f "$backup_file" ]; then
      crontab "$backup_file" 2>/dev/null || print_warning "Backup restoration also failed"
    fi
    rm -f "$temp_cron"
    trap - EXIT INT TERM
    return 1
  fi

  rm -f "$temp_cron"
  trap - EXIT INT TERM

  print_success "Schedule installed successfully!"
  echo ""
  print_info "Next steps:"
  echo "  • View schedule: homelab schedule status"
  echo "  • Check logs: homelab logs"
  echo "  • Remove schedule: homelab schedule remove"
}

# Install launchd schedule (macOS)
install_launchd_schedule() {
  local homelab_path="$1"
  local dry_run="$2"

  local launch_dir="$HOME/Library/LaunchAgents"

  # Get list of scheduled workflows
  local scheduled_workflows=()
  if type -t list_scheduled_workflows >/dev/null 2>&1; then
    while IFS= read -r workflow_name; do
      scheduled_workflows+=("$workflow_name")
    done < <(list_scheduled_workflows)
  else
    # Fallback to built-in workflows only
    scheduled_workflows=("morning" "weekly")
  fi

  if [ ${#scheduled_workflows[@]} -eq 0 ]; then
    print_error "No scheduled workflows found"
    return 1
  fi

  # Create log directory if needed
  mkdir -p "$HOMELAB_LOG_DIR"

  # XML-escape paths for safe plist embedding
  local escaped_homelab_path=$(xml_escape "$homelab_path")
  local escaped_log_dir=$(xml_escape "$HOMELAB_LOG_DIR")

  print_info "Schedule configuration:"

  # Generate plists for each scheduled workflow
  local plist_files=()
  local plist_contents=()

  for workflow_name in "${scheduled_workflows[@]}"; do
    local cron_expr=$(get_workflow_cron_expression "$workflow_name")
    if [ -z "$cron_expr" ]; then
      print_warning "Skipping workflow '$workflow_name': no cron expression found"
      continue
    fi

    # Parse cron expression to launchd calendar interval
    # Format: minute hour day month weekday
    local cron_minute cron_hour cron_day cron_month cron_weekday
    read -r cron_minute cron_hour cron_day cron_month cron_weekday <<< "$cron_expr"

    # Build StartCalendarInterval dict based on cron fields
    local calendar_interval="    <key>StartCalendarInterval</key>
    <dict>"

    # Add Minute if specified (not *)
    if [[ "$cron_minute" =~ ^[0-9]+$ ]]; then
      calendar_interval+="
        <key>Minute</key>
        <integer>$cron_minute</integer>"
    fi

    # Add Hour if specified (not *)
    if [[ "$cron_hour" =~ ^[0-9]+$ ]]; then
      calendar_interval+="
        <key>Hour</key>
        <integer>$cron_hour</integer>"
    fi

    # Add Day if specified (not *)
    if [[ "$cron_day" =~ ^[0-9]+$ ]]; then
      calendar_interval+="
        <key>Day</key>
        <integer>$cron_day</integer>"
    fi

    # Add Month if specified (not *)
    if [[ "$cron_month" =~ ^[0-9]+$ ]]; then
      calendar_interval+="
        <key>Month</key>
        <integer>$cron_month</integer>"
    fi

    # Add Weekday if specified (not *)
    if [[ "$cron_weekday" =~ ^[0-9]+$ ]]; then
      calendar_interval+="
        <key>Weekday</key>
        <integer>$cron_weekday</integer>"
    fi

    calendar_interval+="
    </dict>"

    # Build plist content
    local plist_file="$launch_dir/com.homelab.${workflow_name}.plist"
    local plist_content=$(cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.homelab.${workflow_name}</string>
    <key>ProgramArguments</key>
    <array>
        <string>$escaped_homelab_path</string>
        <string>workflow</string>
        <string>run</string>
        <string>$workflow_name</string>
        <string>--quiet</string>
        <string>--scheduled</string>
    </array>
$calendar_interval
    <key>StandardOutPath</key>
    <string>$escaped_log_dir/launchd_${workflow_name}.log</string>
    <key>StandardErrorPath</key>
    <string>$escaped_log_dir/launchd_${workflow_name}.log</string>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
EOF
)

    plist_files+=("$plist_file")
    plist_contents+=("$plist_content")

    # Show configuration
    echo "  $workflow_name: $(get_workflow_schedule "$workflow_name")"
  done

  echo ""

  if [ "$dry_run" = true ]; then
    print_section "Dry-run: Would create the following launchd plists"
    echo ""
    for i in "${!plist_files[@]}"; do
      print_info "Plist: ${plist_files[$i]}"
      echo "${plist_contents[$i]}" | head -20
      echo "..."
      echo ""
    done
    return 0
  fi

  # Create LaunchAgents directory if needed
  mkdir -p "$launch_dir"

  # Backup and write plists
  for i in "${!plist_files[@]}"; do
    local plist_file="${plist_files[$i]}"
    local plist_content="${plist_contents[$i]}"

    # Backup existing plist if present
    if [ -f "$plist_file" ]; then
      local backup_file="$HOMELAB_LOG_DIR/$(basename "$plist_file").backup_$(date +%s)"
      cp "$plist_file" "$backup_file"
      print_info "Backed up existing plist to: $backup_file"
    fi

    # Write plist
    echo "$plist_content" > "$plist_file"

    # Unload old job if present, then load new one
    launchctl unload "$plist_file" 2>/dev/null || true
    if launchctl load "$plist_file" 2>/dev/null; then
      print_success "Loaded: $(basename "$plist_file")"
    else
      print_warning "Failed to load: $(basename "$plist_file")"
    fi
  done

  echo ""
  print_success "Schedule installed successfully!"
  echo ""
  print_info "Next steps:"
  echo "  • View schedule: homelab schedule status"
  echo "  • Check logs: tail -f $HOMELAB_LOG_DIR/launchd_*.log"
  echo "  • Remove schedule: homelab schedule remove"
}

# Remove schedule
remove_schedule() {
  local platform=$(detect_scheduler_platform)

  print_section "Removing Workflow Schedule"

  case "$platform" in
    launchd)
      remove_launchd_schedule
      ;;
    cron)
      remove_cron_schedule
      ;;
    none)
      print_error "No scheduler detected"
      return 1
      ;;
  esac
}

# Remove cron schedule
remove_cron_schedule() {
  # Backup existing crontab
  local backup_file="$HOMELAB_LOG_DIR/crontab_backup_before_remove_$(date +%s).txt"
  mkdir -p "$HOMELAB_LOG_DIR"
  crontab -l > "$backup_file" 2>/dev/null || touch "$backup_file"
  print_info "Backed up existing crontab to: $backup_file"

  # Remove homelab entries
  local temp_cron=$(mktemp)
  trap 'rm -f "$temp_cron"' EXIT INT TERM

  crontab -l 2>/dev/null | sed '/# homelab automated workflows/,/# end homelab/d' > "$temp_cron"

  # Check if anything was removed
  local before_count=$(crontab -l 2>/dev/null | wc -l | tr -d ' ')
  local after_count=$(wc -l < "$temp_cron" | tr -d ' ')

  if [ "$before_count" -eq "$after_count" ]; then
    print_warning "No homelab entries found in crontab"
    rm -f "$temp_cron"
    trap - EXIT INT TERM
    return 0
  fi

  # Install cleaned crontab with error handling
  if ! crontab "$temp_cron" 2>/dev/null; then
    print_error "Failed to install cleaned crontab"
    echo ""
    print_info "Restoring from backup: $backup_file"
    if [ -f "$backup_file" ]; then
      crontab "$backup_file" 2>/dev/null || print_warning "Backup restoration also failed"
    fi
    rm -f "$temp_cron"
    trap - EXIT INT TERM
    return 1
  fi

  rm -f "$temp_cron"
  trap - EXIT INT TERM

  print_success "homelab schedule removed from crontab"
  echo ""
  print_info "Backup available at: $backup_file"
}

# Remove launchd schedule
remove_launchd_schedule() {
  local launch_dir="$HOME/Library/LaunchAgents"
  local removed=0

  # Find all homelab plists (com.homelab.*.plist)
  while IFS= read -r plist_file; do
    if [ -f "$plist_file" ]; then
      local workflow_name=$(basename "$plist_file" .plist | sed 's/^com\.homelab\.//')

      # Unload job
      launchctl unload "$plist_file" 2>/dev/null || true

      # Backup plist
      local backup="$HOMELAB_LOG_DIR/$(basename "$plist_file").removed_$(date +%s)"
      mv "$plist_file" "$backup"

      print_success "Removed $workflow_name schedule (backed up to: $backup)"
      removed=$((removed + 1))
    fi
  done < <(find "$launch_dir" -name "com.homelab.*.plist" 2>/dev/null || true)

  if [ "$removed" -eq 0 ]; then
    print_warning "No homelab launchd jobs found"
  else
    echo ""
    print_info "homelab schedule removed successfully (removed $removed job(s))"
  fi
}

# Show schedule status
show_schedule_status() {
  local platform=$(detect_scheduler_platform)

  print_section "Workflow Schedule Status"

  print_info "Platform: $platform"
  echo ""

  case "$platform" in
    launchd)
      show_launchd_status
      ;;
    cron)
      show_cron_status
      ;;
    none)
      print_warning "No scheduler detected (cron or launchd)"
      echo ""
      print_info "Scheduling is not available on this system"
      return 1
      ;;
  esac
}

# Show cron status
show_cron_status() {
  if ! crontab -l >/dev/null 2>&1; then
    print_warning "No crontab configured"
    echo ""
    print_info "Install schedule: homelab schedule install"
    return 0
  fi

  # Check for homelab entries
  if ! crontab -l 2>/dev/null | grep -q "# homelab automated workflows"; then
    print_warning "homelab schedule not installed"
    echo ""
    print_info "Install schedule: homelab schedule install"
    return 0
  fi

  print_success "homelab schedule is active"
  echo ""

  # Get list of scheduled workflows for display
  local scheduled_workflows=()
  if type -t list_scheduled_workflows >/dev/null 2>&1; then
    while IFS= read -r workflow_name; do
      scheduled_workflows+=("$workflow_name")
    done < <(list_scheduled_workflows)
  fi

  # Show current schedule
  print_info "Active schedules:"

  # Show each scheduled workflow
  for workflow_name in "${scheduled_workflows[@]}"; do
    local schedule_desc=$(get_workflow_schedule "$workflow_name")
    echo "  • $workflow_name: $schedule_desc"
  done

  echo ""

  # Show recent runs from cron logs
  print_info "Recent workflow runs:"
  for workflow_name in "${scheduled_workflows[@]}"; do
    local log_file="$HOMELAB_LOG_DIR/cron_${workflow_name}.log"
    if [ -f "$log_file" ]; then
      local last_run=$(date -r "$log_file" '+%Y-%m-%d %H:%M' 2>/dev/null || echo 'unknown')
      echo "  • $workflow_name: $last_run"
    fi
  done
}

# Show launchd status
show_launchd_status() {
  # Get list of scheduled workflows
  local scheduled_workflows=()
  if type -t list_scheduled_workflows >/dev/null 2>&1; then
    while IFS= read -r workflow_name; do
      scheduled_workflows+=("$workflow_name")
    done < <(list_scheduled_workflows)
  fi

  # Check if any homelab jobs are loaded
  local any_loaded=false
  for workflow_name in "${scheduled_workflows[@]}"; do
    if launchctl list | grep -q "com.homelab.${workflow_name}"; then
      any_loaded=true
      break
    fi
  done

  if [ "$any_loaded" = false ]; then
    print_warning "homelab schedule not installed"
    echo ""
    print_info "Install schedule: homelab schedule install"
    return 0
  fi

  print_success "homelab schedule is active"
  echo ""

  print_info "Active jobs:"

  # Show each scheduled workflow
  for workflow_name in "${scheduled_workflows[@]}"; do
    if launchctl list | grep -q "com.homelab.${workflow_name}"; then
      local schedule_desc=$(get_workflow_schedule "$workflow_name")
      echo "  • $workflow_name: $schedule_desc"
    fi
  done

  echo ""

  # Show recent runs
  print_info "Recent workflow runs:"
  for workflow_name in "${scheduled_workflows[@]}"; do
    local log_file="$HOMELAB_LOG_DIR/launchd_${workflow_name}.log"
    if [ -f "$log_file" ]; then
      local last_run=$(date -r "$log_file" '+%Y-%m-%d %H:%M' 2>/dev/null || echo 'unknown')
      echo "  • $workflow_name: $last_run"
    fi
  done
}

# Show schedule configuration (preview without installing)
show_schedule_config() {
  local platform=$(detect_scheduler_platform)

  print_section "Schedule Configuration Preview"

  # Validate homelab access
  local homelab_path=$(validate_homelab_access)
  [ $? -ne 0 ] && return 1

  print_info "Platform: $platform"
  print_info "homelab path: $homelab_path"
  echo ""

  # Run dry-run installation
  install_schedule --dry-run
}
