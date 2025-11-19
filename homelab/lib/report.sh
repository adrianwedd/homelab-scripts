#!/usr/bin/env bash
# homelab/lib/report.sh - Report generation functionality
# Part of homelab v1.0.0

# Generate activity report for a given time period
generate_report() {
  # Parse options
  local period="weekly"
  local since_date=""
  local format="markdown"
  local output_mode="file"

  while [[ $# -gt 0 ]]; do
    case $1 in
      weekly|monthly)
        period="$1"
        shift
        ;;
      --since)
        since_date="$2"
        period="custom"
        shift 2
        ;;
      --format)
        format="$2"
        shift 2
        ;;
      --json)
        format="json"
        shift
        ;;
      --stdout)
        output_mode="stdout"
        shift
        ;;
      *)
        shift
        ;;
    esac
  done

  # Calculate time window
  local cutoff_ts
  case "$period" in
    weekly)
      cutoff_ts=$(date -v-7d +%s 2>/dev/null || date -d '7 days ago' +%s 2>/dev/null)
      ;;
    monthly)
      cutoff_ts=$(date -v-30d +%s 2>/dev/null || date -d '30 days ago' +%s 2>/dev/null)
      ;;
    custom)
      if [ -z "$since_date" ]; then
        print_error "Custom period requires --since DATE"
        return 1
      fi
      cutoff_ts=$(date -j -f "%Y-%m-%d" "$since_date" +%s 2>/dev/null || date -d "$since_date" +%s 2>/dev/null)
      ;;
  esac

  if [ -z "$cutoff_ts" ]; then
    print_error "Failed to calculate time window"
    return 1
  fi

  # Collect data
  print_section "Generating $period report"

  local ssh_data=$(aggregate_ssh_trends "$cutoff_ts")
  local network_data=$(aggregate_network_changes "$cutoff_ts")
  local disk_data=$(aggregate_disk_cleanup "$cutoff_ts")
  local update_data=$(aggregate_update_activity "$cutoff_ts")

  # Generate output based on format
  if [ "$format" = "json" ]; then
    generate_json_report "$period" "$cutoff_ts" "$ssh_data" "$network_data" "$disk_data" "$update_data" "$output_mode"
  else
    generate_markdown_report "$period" "$cutoff_ts" "$ssh_data" "$network_data" "$disk_data" "$update_data" "$output_mode"
  fi
}

# Aggregate SSH audit trends over time period
aggregate_ssh_trends() {
  local cutoff_ts="$1"

  # Find all SSH audit JSONs in time window
  local total_audits=0
  local max_criticals=0
  local max_warnings=0
  local targets_affected=0
  local trend="stable"

  while IFS= read -r -d '' file; do
    local mtime=$(get_file_mtime "$file")
    [ "$mtime" -lt "$cutoff_ts" ] && continue

    total_audits=$((total_audits + 1))

    # Parse risk data
    local criticals=$(grep -o '"critical":[[:space:]]*[0-9]*' "$file" 2>/dev/null | grep -o '[0-9]*$' || echo 0)
    local warnings=$(grep -o '"warnings":[[:space:]]*[0-9]*' "$file" 2>/dev/null | grep -o '[0-9]*$' || echo 0)
    local targets=$(grep -o '"targets_with_issues":[[:space:]]*[0-9]*' "$file" 2>/dev/null | grep -o '[0-9]*$' || echo 0)

    [ "$criticals" -gt "$max_criticals" ] && max_criticals=$criticals
    [ "$warnings" -gt "$max_warnings" ] && max_warnings=$warnings
    [ "$targets" -gt "$targets_affected" ] && targets_affected=$targets
  done < <(find "$HOMELAB_LOG_DIR" -name "*ssh_audit_summary*.json" -type f -print0 2>/dev/null)

  # Check scripts/logs if it exists
  if [ -d "$HOME/repos/scripts/logs/ssh-key-audit" ]; then
    while IFS= read -r -d '' file; do
      local mtime=$(get_file_mtime "$file")
      [ "$mtime" -lt "$cutoff_ts" ] && continue

      total_audits=$((total_audits + 1))

      local criticals=$(grep -o '"critical":[[:space:]]*[0-9]*' "$file" 2>/dev/null | grep -o '[0-9]*$' || echo 0)
      local warnings=$(grep -o '"warnings":[[:space:]]*[0-9]*' "$file" 2>/dev/null | grep -o '[0-9]*$' || echo 0)
      local targets=$(grep -o '"targets_with_issues":[[:space:]]*[0-9]*' "$file" 2>/dev/null | grep -o '[0-9]*$' || echo 0)

      [ "$criticals" -gt "$max_criticals" ] && max_criticals=$criticals
      [ "$warnings" -gt "$max_warnings" ] && max_warnings=$warnings
      [ "$targets" -gt "$targets_affected" ] && targets_affected=$targets
    done < <(find "$HOME/repos/scripts/logs/ssh-key-audit" -name "*ssh_audit_summary*.json" -type f -print0 2>/dev/null)
  fi

  # Simple trend: if we have criticals, trending bad
  if [ "$max_criticals" -gt 0 ]; then
    trend="critical"
  elif [ "$max_warnings" -gt 3 ]; then
    trend="warning"
  else
    trend="good"
  fi

  # Return data as colon-separated values
  echo "$total_audits:$max_criticals:$max_warnings:$targets_affected:$trend"
}

# Aggregate network changes over time period
aggregate_network_changes() {
  local cutoff_ts="$1"

  local scans_performed=0
  local unique_new_hosts=0
  local unique_removed_hosts=0

  # Track unique IPs that appeared/disappeared
  local -a new_ips=()
  local -a removed_ips=()

  while IFS= read -r -d '' file; do
    local mtime=$(get_file_mtime "$file")
    [ "$mtime" -lt "$cutoff_ts" ] && continue

    scans_performed=$((scans_performed + 1))

    # Parse corresponding log file for delta
    local log_file="${file%.json}.log"
    if [ -f "$log_file" ]; then
      # Extract new hosts
      while read -r ip; do
        local found=0
        for existing in "${new_ips[@]}"; do
          if [ "$existing" = "$ip" ]; then
            found=1
            break
          fi
        done
        [ "$found" -eq 0 ] && new_ips+=("$ip")
      done < <(sed -n '/New hosts detected:/,/^$/p' "$log_file" 2>/dev/null | grep '^\s*+' | awk '{print $2}')

      # Extract removed hosts
      while read -r ip; do
        local found=0
        for existing in "${removed_ips[@]}"; do
          if [ "$existing" = "$ip" ]; then
            found=1
            break
          fi
        done
        [ "$found" -eq 0 ] && removed_ips+=("$ip")
      done < <(sed -n '/Hosts no longer responding:/,/^$/p' "$log_file" 2>/dev/null | grep '^\s*-' | awk '{print $2}')
    fi
  done < <(find "$HOMELAB_LOG_DIR" -name "*nmap*.json" -type f -print0 2>/dev/null)

  unique_new_hosts=${#new_ips[@]}
  unique_removed_hosts=${#removed_ips[@]}

  # Return data - safely handle empty arrays
  local new_ips_str="${new_ips[*]:-}"
  local removed_ips_str="${removed_ips[*]:-}"
  echo "$scans_performed:$unique_new_hosts:$unique_removed_hosts:$new_ips_str:$removed_ips_str"
}

# Aggregate disk cleanup activity over time period
aggregate_disk_cleanup() {
  local cutoff_ts="$1"

  local cleanups_run=0
  local total_freed_bytes=0
  local total_git_processed=0
  local total_venv_removed=0

  # Check homelab logs
  while IFS= read -r -d '' file; do
    local mtime=$(get_file_mtime "$file")
    [ "$mtime" -lt "$cutoff_ts" ] && continue

    cleanups_run=$((cleanups_run + 1))

    local freed_bytes=$(grep -o '"total_freed_bytes":[[:space:]]*[0-9]*' "$file" 2>/dev/null | grep -o '[0-9]*$' || echo 0)
    local git_proc=$(grep -o '"processed":[[:space:]]*[0-9]*' "$file" 2>/dev/null | grep -o '[0-9]*' | head -1 || echo 0)
    local venv_rem=$(grep -o '"removed":[[:space:]]*[0-9]*' "$file" 2>/dev/null | grep -o '[0-9]*' | tail -1 || echo 0)

    total_freed_bytes=$((total_freed_bytes + freed_bytes))
    total_git_processed=$((total_git_processed + git_proc))
    total_venv_removed=$((total_venv_removed + venv_rem))
  done < <(find "$HOMELAB_LOG_DIR" -name "*disk_cleanup_summary*.json" -type f -print0 2>/dev/null)

  # Check scripts/logs if exists
  if [ -d "$HOME/repos/scripts/logs" ]; then
    while IFS= read -r -d '' file; do
      local mtime=$(get_file_mtime "$file")
      [ "$mtime" -lt "$cutoff_ts" ] && continue

      cleanups_run=$((cleanups_run + 1))

      local freed_bytes=$(grep -o '"total_freed_bytes":[[:space:]]*[0-9]*' "$file" 2>/dev/null | grep -o '[0-9]*$' || echo 0)
      local git_proc=$(grep -o '"processed":[[:space:]]*[0-9]*' "$file" 2>/dev/null | grep -o '[0-9]*' | head -1 || echo 0)
      local venv_rem=$(grep -o '"removed":[[:space:]]*[0-9]*' "$file" 2>/dev/null | grep -o '[0-9]*' | tail -1 || echo 0)

      total_freed_bytes=$((total_freed_bytes + freed_bytes))
      total_git_processed=$((total_git_processed + git_proc))
      total_venv_removed=$((total_venv_removed + venv_rem))
    done < <(find "$HOME/repos/scripts/logs" -name "*disk_cleanup_summary*.json" -type f -print0 2>/dev/null)
  fi

  # Return data
  echo "$cleanups_run:$total_freed_bytes:$total_git_processed:$total_venv_removed"
}

# Aggregate package update activity over time period
aggregate_update_activity() {
  local cutoff_ts="$1"

  local updates_run=0
  local total_packages=0

  while IFS= read -r -d '' file; do
    local mtime=$(get_file_mtime "$file")
    [ "$mtime" -lt "$cutoff_ts" ] && continue

    updates_run=$((updates_run + 1))

    # Count packages updated
    local brew=$(grep -o "Upgrading [0-9]* outdated package" "$file" 2>/dev/null | awk '{print $2}' | head -1 || echo 0)
    local npm=$(grep -c "npm.*update.*-g" "$file" 2>/dev/null || echo 0)
    local pip=$(grep -c "Successfully installed" "$file" 2>/dev/null || echo 0)

    total_packages=$((total_packages + brew + npm + pip))
  done < <(find "$HOMELAB_LOG_DIR" -name "*update_*.log" -type f -print0 2>/dev/null)

  echo "$updates_run:$total_packages"
}

# Generate JSON format report
generate_json_report() {
  local period="$1" cutoff_ts="$2" ssh_data="$3" network_data="$4" disk_data="$5" update_data="$6" output_mode="$7"

  # Parse aggregated data
  IFS=: read -r ssh_audits ssh_criticals ssh_warnings ssh_targets ssh_trend <<< "$ssh_data"
  IFS=: read -r net_scans net_new net_removed net_new_ips net_removed_ips <<< "$network_data"
  IFS=: read -r cleanups freed_bytes git_processed venv_removed <<< "$disk_data"
  IFS=: read -r updates packages <<< "$update_data"

  local output=$(cat <<EOF
{
  "version": "1.0",
  "period": "$period",
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "cutoff_timestamp": $cutoff_ts,
  "ssh_audits": {
    "total_runs": $ssh_audits,
    "max_criticals": $ssh_criticals,
    "max_warnings": $ssh_warnings,
    "targets_affected": $ssh_targets,
    "trend": "$ssh_trend"
  },
  "network_scans": {
    "total_runs": $net_scans,
    "unique_new_hosts": $net_new,
    "unique_removed_hosts": $net_removed
  },
  "disk_cleanup": {
    "total_runs": $cleanups,
    "total_freed_bytes": $freed_bytes,
    "git_repos_processed": $git_processed,
    "virtualenvs_removed": $venv_removed
  },
  "package_updates": {
    "total_runs": $updates,
    "packages_updated": $packages
  }
}
EOF
)

  if [ "$output_mode" = "stdout" ]; then
    echo "$output"
  else
    local report_file="$HOMELAB_LOG_DIR/reports/homelab_report_${period}_$(date +%Y%m%d_%H%M%S).json"
    mkdir -p "$HOMELAB_LOG_DIR/reports"
    echo "$output" > "$report_file"
    print_success "Report saved: $report_file"
  fi
}

# Generate Markdown format report
generate_markdown_report() {
  local period="$1" cutoff_ts="$2" ssh_data="$3" network_data="$4" disk_data="$5" update_data="$6" output_mode="$7"

  # Parse aggregated data
  IFS=: read -r ssh_audits ssh_criticals ssh_warnings ssh_targets ssh_trend <<< "$ssh_data"
  IFS=: read -r net_scans net_new net_removed net_new_ips net_removed_ips <<< "$network_data"
  IFS=: read -r cleanups freed_bytes git_processed venv_removed <<< "$disk_data"
  IFS=: read -r updates packages <<< "$update_data"

  # Convert bytes to human readable
  local freed_human="0 B"
  if [ "$freed_bytes" -gt 0 ]; then
    if command -v numfmt >/dev/null 2>&1; then
      freed_human=$(numfmt --to=iec-i --suffix=B "$freed_bytes" 2>/dev/null || echo "${freed_bytes} bytes")
    else
      # Simple conversion
      if [ "$freed_bytes" -ge 1073741824 ]; then
        freed_human="$((freed_bytes / 1073741824)) GB"
      elif [ "$freed_bytes" -ge 1048576 ]; then
        freed_human="$((freed_bytes / 1048576)) MB"
      elif [ "$freed_bytes" -ge 1024 ]; then
        freed_human="$((freed_bytes / 1024)) KB"
      else
        freed_human="$freed_bytes bytes"
      fi
    fi
  fi

  # Determine period display name
  local period_display
  case "$period" in
    weekly) period_display="Last 7 Days" ;;
    monthly) period_display="Last 30 Days" ;;
    custom) period_display="Custom Period (since $(date -r "$cutoff_ts" +%Y-%m-%d 2>/dev/null || date -d "@$cutoff_ts" +%Y-%m-%d))" ;;
  esac

  # Generate SSH trend indicator
  local ssh_indicator
  case "$ssh_trend" in
    critical) ssh_indicator="🔴 Critical" ;;
    warning) ssh_indicator="🟡 Warning" ;;
    good) ssh_indicator="🟢 Good" ;;
    *) ssh_indicator="⚪ Unknown" ;;
  esac

  local output=$(cat <<EOF
# Homelab Activity Report

**Period:** $period_display
**Generated:** $(date '+%Y-%m-%d %H:%M:%S')

---

## Executive Summary

- **SSH Audits:** $ssh_audits runs, $ssh_indicator status
- **Network Scans:** $net_scans scans performed
- **Disk Cleanup:** $freed_human freed across $cleanups runs
- **Package Updates:** $packages packages updated

---

## SSH Key Security

**Status:** $ssh_indicator

- Audit runs: $ssh_audits
- Max criticals found: $ssh_criticals
- Max warnings found: $ssh_warnings
- Targets with issues: $ssh_targets

$([ "$ssh_criticals" -gt 0 ] && echo "⚠️ **Action Required:** Critical SSH key issues detected. Review immediately.")

---

## Network Discovery

- Scans performed: $net_scans
- New devices detected: $net_new
- Devices removed: $net_removed

$(if [ "$net_new" -gt 0 ]; then
  echo ""
  echo "### New Devices"
  echo ""
  echo "\`\`\`"
  echo "$net_new_ips" | tr ' ' '\n' | head -10
  [ "$net_new" -gt 10 ] && echo "... and $((net_new - 10)) more"
  echo "\`\`\`"
fi)

$(if [ "$net_removed" -gt 0 ]; then
  echo ""
  echo "### Removed Devices"
  echo ""
  echo "\`\`\`"
  echo "$net_removed_ips" | tr ' ' '\n' | head -10
  [ "$net_removed" -gt 10 ] && echo "... and $((net_removed - 10)) more"
  echo "\`\`\`"
fi)

---

## Disk Cleanup

- Cleanup runs: $cleanups
- Total space freed: **$freed_human**
- Git repositories processed: $git_processed
- Virtualenvs removed: $venv_removed

---

## Package Updates

- Update runs: $updates
- Total packages updated: $packages

---

## Recommendations

$(if [ "${ssh_criticals:-0}" -gt 0 ]; then
  echo "- 🔴 **Critical:** Review SSH key audit findings immediately"
fi)

$(if [ "${net_new:-0}" -gt 5 ]; then
  echo "- 🟡 **Warning:** $net_new new devices detected - verify authorized access"
fi)

$(if [ "${cleanups:-0}" -eq 0 ]; then
  echo "- 💾 **Maintenance:** No cleanups performed this period - consider running \`homelab weekly\`"
fi)

$(if [ "${updates:-0}" -eq 0 ]; then
  echo "- 📦 **Updates:** No package updates performed - consider running \`homelab weekly\`"
fi)

---

*Generated by homelab orchestrator v1.0.0*
EOF
)

  if [ "$output_mode" = "stdout" ]; then
    echo "$output"
  else
    local report_file="$HOMELAB_LOG_DIR/reports/homelab_report_${period}_$(date +%Y%m%d_%H%M%S).md"
    mkdir -p "$HOMELAB_LOG_DIR/reports"
    echo "$output" > "$report_file"
    print_success "Report saved: $report_file"

    # Show preview
    echo ""
    print_section "Report Preview"
    echo "$output" | head -30
    echo ""
    print_info "Full report: $report_file"
  fi
}
