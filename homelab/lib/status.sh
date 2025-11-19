#!/usr/bin/env bash
# homelab/lib/status.sh - System status dashboard
# Part of homelab v1.0.0

# Helper: Get file mtime (cross-platform)
get_file_mtime() {
  local file="$1"
  # Try macOS stat first, fall back to Linux stat, return 0 if both fail
  stat -f "%m" "$file" 2>/dev/null || stat -c "%Y" "$file" 2>/dev/null || echo 0
}

# Show comprehensive status dashboard
show_status_dashboard() {
  # Parse options
  local verbose=false json_output=false
  while [[ $# -gt 0 ]]; do
    case $1 in
      --verbose|-v) verbose=true; shift ;;
      --json) json_output=true; shift ;;
      *) shift ;;
    esac
  done

  if [ "$json_output" = true ]; then
    show_status_json
  else
    show_status_text "$verbose"
  fi
}

# Show text-based status dashboard
show_status_text() {
  local verbose="${1:-false}"

  print_section "Homelab Status"

  show_disk_status "$verbose"
  show_ssh_status "$verbose"
  show_network_status "$verbose"
  show_backup_status "$verbose"
  show_update_status "$verbose"
  show_recent_activity

  echo ""
  print_info "For detailed info, run: homelab status --verbose"
}

# Show disk status
show_disk_status() {
  local verbose="${1:-false}"

  # Get disk usage
  local total avail used pct
  if command -v df >/dev/null 2>&1; then
    total=$(df -h / | awk 'NR==2 {print $2}')
    used=$(df -h / | awk 'NR==2 {print $3}')
    avail=$(df -h / | awk 'NR==2 {print $4}')
    pct=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
  else
    total="?" used="?" avail="?" pct="0"
  fi

  echo -e "${BLUE}💾 Disk Space${NC}"
  echo "  Available: $avail / $total (${pct}% used)"

  # Status indicator based on usage
  if [ "$pct" -lt 80 ]; then
    echo "  Status: 🟢 Healthy"
  elif [ "$pct" -lt 90 ]; then
    echo "  Status: 🟡 Monitor"
  else
    echo "  Status: 🔴 Critical"
    echo "  → Run: homelab emergency"
  fi

  # Show cleanup details in verbose mode
  if [ "$verbose" = true ]; then
    local last_cleanup=$(get_last_workflow_run 'weekly')
    if [ -n "$last_cleanup" ]; then
      echo "  Last cleanup: $last_cleanup"

      # Find latest cleanup JSON summary
      local latest_json="" latest_time=0
      while IFS= read -r -d '' file; do
        local mtime=$(get_file_mtime "$file")
        if [ "$mtime" -gt "$latest_time" ]; then
          latest_json="$file"
          latest_time="$mtime"
        fi
      done < <(find "$HOMELAB_LOG_DIR" -name "*disk_cleanup_summary*.json" -type f -print0 2>/dev/null)

      # Also check scripts/logs directory
      if [ -d "$HOME/repos/scripts/logs" ]; then
        while IFS= read -r -d '' file; do
          local mtime=$(get_file_mtime "$file")
          if [ "$mtime" -gt "$latest_time" ]; then
            latest_json="$file"
            latest_time="$mtime"
          fi
        done < <(find "$HOME/repos/scripts/logs" -name "*disk_cleanup_summary*.json" -type f -print0 2>/dev/null)
      fi

      if [ -n "$latest_json" ] && [ -f "$latest_json" ]; then
        local freed=$(grep -o '"total_freed_human":[[:space:]]*"[^"]*"' "$latest_json" 2>/dev/null | cut -d'"' -f4)
        local git_processed=$(grep -o '"processed":[[:space:]]*[0-9]*' "$latest_json" 2>/dev/null | grep -o '[0-9]*' | head -1)
        local venv_removed=$(grep -o '"removed":[[:space:]]*[0-9]*' "$latest_json" 2>/dev/null | grep -o '[0-9]*' | tail -1)

        if [ -n "$freed" ]; then
          echo "  Freed: $freed"
          if [ -n "$git_processed" ] && [ "$git_processed" -gt 0 ]; then
            echo "    Git repos: $git_processed processed"
          fi
          if [ -n "$venv_removed" ] && [ "$venv_removed" -gt 0 ]; then
            echo "    Virtualenvs: $venv_removed removed"
          fi
        fi
      fi
    else
      echo "  Last cleanup: never"
    fi
  fi

  echo ""
}

# Show SSH key status
show_ssh_status() {
  local verbose="${1:-false}"

  echo -e "${BLUE}🔐 SSH Keys${NC}"

  # Find latest SSH audit JSON - check both step logs and main logs
  local latest_json=""
  local search_dirs=("$HOMELAB_LOG_DIR")

  # Only add scripts/logs/ssh-key-audit if it exists
  local scripts_ssh_log="$HOME/repos/scripts/logs/ssh-key-audit"
  if [ -d "$scripts_ssh_log" ]; then
    search_dirs+=("$scripts_ssh_log")
  fi

  latest_json=$(find "${search_dirs[@]}" -name "*ssh_audit_summary*.json" -type f 2>/dev/null | while read -r file; do
    local mtime=$(get_file_mtime "$file")
    echo "$mtime:$file"
  done | sort -rn | head -1 | cut -d: -f2-)

  if [ -z "$latest_json" ] || [ ! -f "$latest_json" ]; then
    echo "  Status: No recent audit"
    echo "  → Run: homelab morning"
    echo ""
    return
  fi

  local last_audit_age=$(get_file_age_hours "$latest_json")
  echo "  Last audit: ${last_audit_age}h ago"

  # Parse JSON without jq (bash 3.2 compatible)
  local warnings=$(grep -o '"warnings":[[:space:]]*[0-9]*' "$latest_json" 2>/dev/null | grep -o '[0-9]*$' || echo 0)
  local critical=$(grep -o '"critical":[[:space:]]*[0-9]*' "$latest_json" 2>/dev/null | grep -o '[0-9]*$' || echo 0)
  local targets_with_issues=$(grep -o '"targets_with_issues":[[:space:]]*[0-9]*' "$latest_json" 2>/dev/null | grep -o '[0-9]*$' || echo 0)

  if [ "$critical" -gt 0 ]; then
    echo "  Status: 🔴 $critical critical issues, $warnings warnings"
    echo "  → Action: Review immediately"
  elif [ "$warnings" -gt 0 ]; then
    echo "  Status: 🟠 $warnings warnings ($targets_with_issues targets affected)"
    echo "  → Action: Review soon"
  elif [ "$warnings" -eq 0 ] && [ -s "$latest_json" ]; then
    echo "  Status: 🟢 No issues found"
  else
    echo "  Status: ℹ️  Audit available (no risk data)"
  fi

  if [ "$verbose" = true ] && [ -f "$latest_json" ]; then
    local total_keys=$(grep -o '"total_keys":[[:space:]]*[0-9]*' "$latest_json" 2>/dev/null | grep -o '[0-9]*$' || echo 0)
    local users_scanned=$(grep -o '"users_scanned":[[:space:]]*[0-9]*' "$latest_json" 2>/dev/null | grep -o '[0-9]*$' || echo 0)
    echo "  Details: $users_scanned users, $total_keys keys scanned"
  fi

  echo ""
}

# Show network status
show_network_status() {
  local verbose="${1:-false}"

  echo -e "${BLUE}🌐 Network${NC}"

  # Find latest network scan JSON using mtime sorting
  local latest_json="" latest_time=0
  while IFS= read -r -d '' file; do
    local mtime=$(get_file_mtime "$file")
    if [ "$mtime" -gt "$latest_time" ]; then
      latest_json="$file"
      latest_time="$mtime"
    fi
  done < <(find "$HOMELAB_LOG_DIR" -name "*nmap*.json" -type f -print0 2>/dev/null)

  if [ -z "$latest_json" ]; then
    echo "  Status: No recent scan"
    echo "  → Run: homelab morning"
    echo ""
    return
  fi

  local last_scan_age=$(get_file_age_hours "$latest_json")
  echo "  Last scan: ${last_scan_age}h ago"

  # Parse device count and delta information
  if [ -f "$latest_json" ]; then
    local device_count=$(grep -o '"ip"' "$latest_json" 2>/dev/null | wc -l | tr -d ' ')
    echo "  Devices: $device_count detected"

    # Parse delta information from corresponding log file (if in verbose mode)
    if [ "$verbose" = true ]; then
      local log_file="${latest_json%.json}.log"
      if [ -f "$log_file" ]; then
        # Extract new and removed hosts from Delta Analysis section
        local new_count=$(sed -n '/^=== Delta Analysis ===/,/^===/p' "$log_file" 2>/dev/null | grep -c '^\s*+' || echo 0)
        local removed_count=$(sed -n '/^=== Delta Analysis ===/,/^===/p' "$log_file" 2>/dev/null | grep -c '^\s*-' || echo 0)

        if [ "$new_count" -gt 0 ] || [ "$removed_count" -gt 0 ]; then
          echo "  Changes: +$new_count new, -$removed_count removed"

          # Show specific IPs
          if [ "$new_count" -gt 0 ]; then
            echo "  New devices:"
            sed -n '/New hosts detected:/,/^$/p' "$log_file" 2>/dev/null | grep '^\s*+' | head -3 | sed 's/^/  /'
            [ "$new_count" -gt 3 ] && echo "    ... and $((new_count - 3)) more"
          fi
          if [ "$removed_count" -gt 0 ]; then
            echo "  Removed devices:"
            sed -n '/Hosts no longer responding:/,/^$/p' "$log_file" 2>/dev/null | grep '^\s*-' | head -3 | sed 's/^/  /'
            [ "$removed_count" -gt 3 ] && echo "    ... and $((removed_count - 3)) more"
          fi
        else
          echo "  Changes: No changes since last scan"
        fi
      fi
    fi

    echo "  Status: 🔵 Normal"
  fi

  echo ""
}

# Show backup status
show_backup_status() {
  local verbose="${1:-false}"

  echo -e "${BLUE}☁️  Backup Sync${NC}"

  # Check if rclone-sync.sh is available
  local rclone_script=$(get_script_path "rclone-sync.sh")
  if [ -z "$rclone_script" ]; then
    echo "  Status: Not configured"
    echo ""
    return
  fi

  # Check rclone sync status
  if [ -f "$HOME/.rclone-sync.pid" ]; then
    local pid=$(cat "$HOME/.rclone-sync.pid" 2>/dev/null)
    if ps -p "$pid" > /dev/null 2>&1; then
      echo "  Status: 🟡 Active (PID: $pid)"
      if [ -f "$HOME/rclone-sync.log" ]; then
        local started=$(ps -p "$pid" -o lstart= 2>/dev/null | awk '{print $4}')
        echo "  Started: $started"
      fi
    else
      echo "  Status: ⚠ Stale PID file"
      echo "  → Run: $rclone_script --start"
    fi
  else
    echo "  Status: 🔴 Not running"
    echo "  → Run: $rclone_script --start"
  fi

  echo ""
}

# Show update status
show_update_status() {
  local verbose="${1:-false}"

  echo -e "${BLUE}📦 Package Updates${NC}"

  # Find latest update log using mtime sorting
  local latest_log="" latest_time=0
  while IFS= read -r -d '' file; do
    local mtime=$(get_file_mtime "$file")
    if [ "$mtime" -gt "$latest_time" ]; then
      latest_log="$file"
      latest_time="$mtime"
    fi
  done < <(find "$HOMELAB_LOG_DIR" -name "*update_*.log" -type f -print0 2>/dev/null)

  if [ -z "$latest_log" ]; then
    echo "  Status: No recent check"
    echo "  → Run: homelab morning"
    echo ""
    return
  fi

  local last_check_age=$(get_file_age_hours "$latest_log")
  echo "  Last check: ${last_check_age}h ago"

  # Parse package counts from update log
  local brew_count=0 npm_count=0 pip_count=0 total_count=0

  # Homebrew: "==> Upgrading N outdated package:"
  brew_count=$(grep -o "Upgrading [0-9]* outdated package" "$latest_log" 2>/dev/null | awk '{print $2}' | head -1 || echo 0)

  # NPM: Count lines with "npm update -g package@version"
  npm_count=$(grep -c "npm.*update.*-g" "$latest_log" 2>/dev/null || echo 0)

  # pip: "Successfully installed package-version" or "Requirement already satisfied"
  pip_count=$(grep -c "Successfully installed" "$latest_log" 2>/dev/null || echo 0)

  total_count=$((brew_count + npm_count + pip_count))

  if [ "$total_count" -gt 0 ]; then
    echo "  Updated: $total_count packages"
    if [ "$verbose" = true ]; then
      [ "$brew_count" -gt 0 ] && echo "    Homebrew: $brew_count"
      [ "$npm_count" -gt 0 ] && echo "    NPM: $npm_count"
      [ "$pip_count" -gt 0 ] && echo "    pip: $pip_count"
    fi
    echo "  Status: 🟢 Updates applied"
  else
    echo "  Status: ℹ️  No updates found"
  fi

  # Check for errors
  if [ "$verbose" = true ]; then
    local error_count=$(grep -ic "error\|failed\|permission denied" "$latest_log" 2>/dev/null || echo 0)
    if [ "$error_count" -gt 0 ]; then
      echo "  ⚠ $error_count errors detected"
      echo "  → Review: $(basename "$latest_log")"
    fi
  fi

  echo ""
}

# Show recent activity
show_recent_activity() {
  echo -e "${BLUE}━━━ Recent Activity ━━━${NC}"
  echo ""

  # Find recent workflow logs
  if [ ! -d "$HOMELAB_LOG_DIR" ]; then
    echo "  No recent activity"
    return
  fi

  # Collect and sort logs by mtime
  local -a sorted_logs=()
  while IFS= read -r -d '' file; do
    local mtime=$(get_file_mtime "$file")
    sorted_logs+=("$mtime:$file")
  done < <(find "$HOMELAB_LOG_DIR" -name "homelab_*.log" -type f -print0 2>/dev/null)

  # Sort by mtime (descending) and display top 5
  local count=0
  if [ ${#sorted_logs[@]} -gt 0 ]; then
    while IFS=: read -r mtime log; do
      local workflow=$(basename "$log" | sed 's/homelab_//' | sed 's/_[0-9]*.log$//')
      local age=$(get_file_age_relative "$log")
      local duration=$(grep "Duration:" "$log" 2>/dev/null | tail -1 | awk '{print $2}')

      if [ -n "$duration" ]; then
        echo "  • $age: $workflow (took $duration)"
      else
        echo "  • $age: $workflow"
      fi

      count=$((count + 1))
      [ $count -ge 5 ] && break
    done < <(printf '%s\n' "${sorted_logs[@]}" | sort -rn)
  fi

  if [ $count -eq 0 ]; then
    echo "  No recent workflows"
    echo ""
    echo "  Run your first workflow:"
    echo "    homelab morning"
  fi

  echo ""

  # Suggest next action - find latest morning log
  local last_morning="" latest_time=0
  while IFS= read -r -d '' file; do
    local mtime=$(get_file_mtime "$file")
    if [ "$mtime" -gt "$latest_time" ]; then
      last_morning="$file"
      latest_time="$mtime"
    fi
  done < <(find "$HOMELAB_LOG_DIR" -name "homelab_morning_*.log" -type f -print0 2>/dev/null)

  if [ -z "$last_morning" ]; then
    echo "Recommended: homelab morning"
  else
    local age_hours=$(get_file_age_hours "$last_morning")
    if [ "$age_hours" -gt 24 ]; then
      echo "Recommended: homelab morning (last run ${age_hours}h ago)"
    fi
  fi
}

# Helper: Get file age in hours
get_file_age_hours() {
  local file="$1"
  local now=$(date +%s)
  local mtime=$(stat -f%m "$file" 2>/dev/null || stat -c%Y "$file" 2>/dev/null)
  echo $(( (now - mtime) / 3600 ))
}

# Helper: Get file age in relative format
get_file_age_relative() {
  local file="$1"
  local hours=$(get_file_age_hours "$file")

  if [ "$hours" -lt 1 ]; then
    echo "just now"
  elif [ "$hours" -lt 24 ]; then
    echo "${hours}h ago"
  else
    local days=$((hours / 24))
    if [ $days -eq 1 ]; then
      echo "yesterday"
    else
      echo "${days} days ago"
    fi
  fi
}

# Helper: Get last workflow run time
get_last_workflow_run() {
  local workflow="$1"

  # Find latest workflow log using mtime sorting
  local last_log="" latest_time=0
  while IFS= read -r -d '' file; do
    local mtime=$(get_file_mtime "$file")
    if [ "$mtime" -gt "$latest_time" ]; then
      last_log="$file"
      latest_time="$mtime"
    fi
  done < <(find "$HOMELAB_LOG_DIR" -name "homelab_${workflow}_*.log" -type f -print0 2>/dev/null)

  if [ -z "$last_log" ]; then
    return 1
  fi

  get_file_age_relative "$last_log"
}

# Show JSON status (Phase 1.1)
show_status_json() {
  echo "{"
  echo "  \"status\": \"ok\","
  echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  echo "  \"message\": \"JSON output coming in Phase 1.1\""
  echo "}"
}
