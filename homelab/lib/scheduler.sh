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

  # Get schedule configuration
  local morning_cron="${HOMELAB_SCHEDULE_MORNING:-0 8 * * *}"
  local weekly_cron="${HOMELAB_SCHEDULE_WEEKLY:-0 2 * * 0}"

  print_info "Schedule configuration:"
  echo "  Morning routine: $morning_cron (daily at 8:00 AM)"
  echo "  Weekly maintenance: $weekly_cron (Sundays at 2:00 AM)"
  echo ""

  # Create log directory if needed
  mkdir -p "$HOMELAB_LOG_DIR"

  # Shell-escape paths for safe cron embedding
  local escaped_homelab_path=$(shell_escape "$homelab_path")
  local escaped_morning_log=$(shell_escape "$HOMELAB_LOG_DIR/cron_morning.log")
  local escaped_weekly_log=$(shell_escape "$HOMELAB_LOG_DIR/cron_weekly.log")

  # Generate crontab entries with properly escaped paths
  local cron_entries=$(cat <<EOF
# homelab automated workflows (installed $(date '+%Y-%m-%d %H:%M:%S'))
$morning_cron $escaped_homelab_path morning --quiet --scheduled >> $escaped_morning_log 2>&1
$weekly_cron $escaped_homelab_path weekly --quiet --scheduled >> $escaped_weekly_log 2>&1
# end homelab
EOF
)

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
  local morning_plist="$launch_dir/com.homelab.morning.plist"
  local weekly_plist="$launch_dir/com.homelab.weekly.plist"

  # Get schedule configuration (convert cron to launchd time)
  local morning_hour="${HOMELAB_SCHEDULE_MORNING_HOUR:-8}"
  local morning_minute="${HOMELAB_SCHEDULE_MORNING_MINUTE:-0}"
  local weekly_hour="${HOMELAB_SCHEDULE_WEEKLY_HOUR:-2}"
  local weekly_minute="${HOMELAB_SCHEDULE_WEEKLY_MINUTE:-0}"
  local weekly_weekday="${HOMELAB_SCHEDULE_WEEKLY_WEEKDAY:-0}"  # 0 = Sunday

  print_info "Schedule configuration:"
  echo "  Morning routine: Daily at ${morning_hour}:$(printf '%02d' $morning_minute)"
  echo "  Weekly maintenance: Weekday $weekly_weekday at ${weekly_hour}:$(printf '%02d' $weekly_minute)"
  echo ""

  # Create log directory if needed
  mkdir -p "$HOMELAB_LOG_DIR"

  # XML-escape paths for safe plist embedding
  local escaped_homelab_path=$(xml_escape "$homelab_path")
  local escaped_log_dir=$(xml_escape "$HOMELAB_LOG_DIR")

  # Generate morning plist
  local morning_plist_content=$(cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.homelab.morning</string>
    <key>ProgramArguments</key>
    <array>
        <string>$escaped_homelab_path</string>
        <string>morning</string>
        <string>--quiet</string>
        <string>--scheduled</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>$morning_hour</integer>
        <key>Minute</key>
        <integer>$morning_minute</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$escaped_log_dir/launchd_morning.log</string>
    <key>StandardErrorPath</key>
    <string>$escaped_log_dir/launchd_morning.log</string>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
EOF
)

  # Generate weekly plist
  local weekly_plist_content=$(cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.homelab.weekly</string>
    <key>ProgramArguments</key>
    <array>
        <string>$escaped_homelab_path</string>
        <string>weekly</string>
        <string>--quiet</string>
        <string>--scheduled</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key>
        <integer>$weekly_weekday</integer>
        <key>Hour</key>
        <integer>$weekly_hour</integer>
        <key>Minute</key>
        <integer>$weekly_minute</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$escaped_log_dir/launchd_weekly.log</string>
    <key>StandardErrorPath</key>
    <string>$escaped_log_dir/launchd_weekly.log</string>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
EOF
)

  if [ "$dry_run" = true ]; then
    print_section "Dry-run: Would create the following launchd plists"
    echo ""
    print_info "Morning plist: $morning_plist"
    echo "$morning_plist_content" | head -15
    echo "..."
    echo ""
    print_info "Weekly plist: $weekly_plist"
    echo "$weekly_plist_content" | head -15
    echo "..."
    return 0
  fi

  # Create LaunchAgents directory if needed
  mkdir -p "$launch_dir"

  # Backup existing plists
  if [ -f "$morning_plist" ]; then
    local backup_morning="$HOMELAB_LOG_DIR/$(basename "$morning_plist").backup_$(date +%s)"
    cp "$morning_plist" "$backup_morning"
    print_info "Backed up existing morning plist to: $backup_morning"
  fi

  if [ -f "$weekly_plist" ]; then
    local backup_weekly="$HOMELAB_LOG_DIR/$(basename "$weekly_plist").backup_$(date +%s)"
    cp "$weekly_plist" "$backup_weekly"
    print_info "Backed up existing weekly plist to: $backup_weekly"
  fi

  # Create log directory
  mkdir -p "$HOMELAB_LOG_DIR"

  # Write plists
  echo "$morning_plist_content" > "$morning_plist"
  echo "$weekly_plist_content" > "$weekly_plist"

  # Load jobs
  launchctl unload "$morning_plist" 2>/dev/null || true
  launchctl unload "$weekly_plist" 2>/dev/null || true
  launchctl load "$morning_plist"
  launchctl load "$weekly_plist"

  print_success "Schedule installed successfully!"
  echo ""
  print_info "Installed jobs:"
  echo "  • com.homelab.morning: Daily at ${morning_hour}:$(printf '%02d' $morning_minute)"
  echo "  • com.homelab.weekly: Weekday $weekly_weekday at ${weekly_hour}:$(printf '%02d' $weekly_minute)"
  echo ""
  print_info "Next steps:"
  echo "  • View schedule: homelab schedule status"
  echo "  • Check logs: tail -f $HOMELAB_LOG_DIR/launchd_morning.log"
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
  local morning_plist="$launch_dir/com.homelab.morning.plist"
  local weekly_plist="$launch_dir/com.homelab.weekly.plist"

  local removed=0

  # Unload and remove morning job
  if [ -f "$morning_plist" ]; then
    launchctl unload "$morning_plist" 2>/dev/null || true
    local backup="$HOMELAB_LOG_DIR/$(basename "$morning_plist").removed_$(date +%s)"
    mv "$morning_plist" "$backup"
    print_success "Removed morning schedule (backed up to: $backup)"
    removed=$((removed + 1))
  fi

  # Unload and remove weekly job
  if [ -f "$weekly_plist" ]; then
    launchctl unload "$weekly_plist" 2>/dev/null || true
    local backup="$HOMELAB_LOG_DIR/$(basename "$weekly_plist").removed_$(date +%s)"
    mv "$weekly_plist" "$backup"
    print_success "Removed weekly schedule (backed up to: $backup)"
    removed=$((removed + 1))
  fi

  if [ "$removed" -eq 0 ]; then
    print_warning "No homelab launchd jobs found"
  else
    echo ""
    print_info "homelab schedule removed successfully"
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
  if ! crontab -l 2>/dev/null | grep -q "homelab morning"; then
    print_warning "homelab schedule not installed"
    echo ""
    print_info "Install schedule: homelab schedule install"
    return 0
  fi

  print_success "homelab schedule is active"
  echo ""

  # Show current schedule
  print_info "Active schedules:"
  crontab -l 2>/dev/null | grep -A2 "# homelab automated workflows" | grep -v "^#" | while read -r line; do
    if [ -n "$line" ]; then
      # Parse cron line using read
      local -a cron_parts
      read -ra cron_parts <<< "$line"
      local schedule="${cron_parts[0]} ${cron_parts[1]} ${cron_parts[2]} ${cron_parts[3]} ${cron_parts[4]}"
      local command=$(echo "$line" | sed 's/^[^ ]* [^ ]* [^ ]* [^ ]* [^ ]* //')

      # Determine workflow type
      if echo "$command" | grep -q "morning"; then
        echo "  • Morning: $schedule"
      elif echo "$command" | grep -q "weekly"; then
        echo "  • Weekly: $schedule"
      fi
    fi
  done

  echo ""

  # Show recent runs from cron logs
  if [ -f "$HOMELAB_LOG_DIR/cron_morning.log" ]; then
    local last_morning=$(tail -1 "$HOMELAB_LOG_DIR/cron_morning.log" 2>/dev/null)
    [ -n "$last_morning" ] && print_info "Last morning run: $(date -r "$HOMELAB_LOG_DIR/cron_morning.log" '+%Y-%m-%d %H:%M' 2>/dev/null || echo 'unknown')"
  fi

  if [ -f "$HOMELAB_LOG_DIR/cron_weekly.log" ]; then
    local last_weekly=$(tail -1 "$HOMELAB_LOG_DIR/cron_weekly.log" 2>/dev/null)
    [ -n "$last_weekly" ] && print_info "Last weekly run: $(date -r "$HOMELAB_LOG_DIR/cron_weekly.log" '+%Y-%m-%d %H:%M' 2>/dev/null || echo 'unknown')"
  fi
}

# Show launchd status
show_launchd_status() {
  local morning_loaded=false
  local weekly_loaded=false

  # Check if jobs are loaded
  if launchctl list | grep -q "com.homelab.morning"; then
    morning_loaded=true
  fi

  if launchctl list | grep -q "com.homelab.weekly"; then
    weekly_loaded=true
  fi

  if [ "$morning_loaded" = false ] && [ "$weekly_loaded" = false ]; then
    print_warning "homelab schedule not installed"
    echo ""
    print_info "Install schedule: homelab schedule install"
    return 0
  fi

  print_success "homelab schedule is active"
  echo ""

  print_info "Active jobs:"

  if [ "$morning_loaded" = true ]; then
    local morning_plist="$HOME/Library/LaunchAgents/com.homelab.morning.plist"
    if [ -f "$morning_plist" ]; then
      local hour=$(grep -A1 "<key>Hour</key>" "$morning_plist" | grep "<integer>" | sed 's/.*<integer>\(.*\)<\/integer>.*/\1/')
      local minute=$(grep -A1 "<key>Minute</key>" "$morning_plist" | grep "<integer>" | sed 's/.*<integer>\(.*\)<\/integer>.*/\1/')
      echo "  • Morning: Daily at ${hour}:$(printf '%02d' $minute)"
    else
      echo "  • Morning: Loaded (schedule unknown)"
    fi
  fi

  if [ "$weekly_loaded" = true ]; then
    local weekly_plist="$HOME/Library/LaunchAgents/com.homelab.weekly.plist"
    if [ -f "$weekly_plist" ]; then
      local hour=$(grep -A1 "<key>Hour</key>" "$weekly_plist" | grep "<integer>" | sed 's/.*<integer>\(.*\)<\/integer>.*/\1/')
      local minute=$(grep -A1 "<key>Minute</key>" "$weekly_plist" | grep "<integer>" | sed 's/.*<integer>\(.*\)<\/integer>.*/\1/')
      local weekday=$(grep -A1 "<key>Weekday</key>" "$weekly_plist" | grep "<integer>" | sed 's/.*<integer>\(.*\)<\/integer>.*/\1/' || echo "0")
      local weekday_name="Sunday"
      case "$weekday" in
        1) weekday_name="Monday" ;;
        2) weekday_name="Tuesday" ;;
        3) weekday_name="Wednesday" ;;
        4) weekday_name="Thursday" ;;
        5) weekday_name="Friday" ;;
        6) weekday_name="Saturday" ;;
      esac
      echo "  • Weekly: ${weekday_name}s at ${hour}:$(printf '%02d' $minute)"
    else
      echo "  • Weekly: Loaded (schedule unknown)"
    fi
  fi

  echo ""

  # Show recent runs
  if [ -f "$HOMELAB_LOG_DIR/launchd_morning.log" ]; then
    print_info "Last morning run: $(date -r "$HOMELAB_LOG_DIR/launchd_morning.log" '+%Y-%m-%d %H:%M' 2>/dev/null || echo 'unknown')"
  fi

  if [ -f "$HOMELAB_LOG_DIR/launchd_weekly.log" ]; then
    print_info "Last weekly run: $(date -r "$HOMELAB_LOG_DIR/launchd_weekly.log" '+%Y-%m-%d %H:%M' 2>/dev/null || echo 'unknown')"
  fi
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
