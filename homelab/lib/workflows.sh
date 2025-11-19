#!/usr/bin/env bash
# homelab/lib/workflows.sh - Workflow definitions
# Part of homelab v1.0.0

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
