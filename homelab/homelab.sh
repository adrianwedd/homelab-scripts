#!/usr/bin/env bash
set -euo pipefail

# homelab - Unified DevOps orchestrator for system maintenance scripts
# Version: 2.4.0-dev
# Usage: homelab <command> [options]

VERSION="2.4.0-dev"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Global flags
DRY_RUN=false
HOMELAB_VERBOSE=false
HOMELAB_QUIET=false

# Source library modules
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/notifications.sh"
source "${SCRIPT_DIR}/lib/workflows.sh"
source "${SCRIPT_DIR}/lib/conditions.sh"
source "${SCRIPT_DIR}/lib/status.sh"
source "${SCRIPT_DIR}/lib/report.sh"
source "${SCRIPT_DIR}/lib/scheduler.sh"

# Show help message
show_help() {
  cat <<'HELP'
homelab - Unified DevOps orchestrator for system maintenance scripts

USAGE:
  homelab <command> [options]

COMMANDS:
  Workflows:
    morning              Run morning routine (ssh-audit, nmap, sync check, updates preview)
    weekly               Run weekly maintenance (cleanup, updates, full scans)
    emergency            Emergency disk cleanup (aggressive mode)
    pre-deploy           Pre-deployment checks (ssh, disk, network, git)

  Information:
    status               Show system status dashboard
    report <period>      Generate activity report (weekly|monthly|--since DATE)
    logs [workflow]      View logs (defaults to latest workflow)
    list-logs            List available logs
    rotate-logs          Delete logs older than HOMELAB_MAX_LOG_AGE_DAYS (default: 90)
    version              Show version information
    help                 Show this help message

  Scheduling:
    schedule install     Install automated workflow schedule (cron/launchd)
    schedule remove      Remove automated workflow schedule
    schedule status      Show current schedule status
    schedule show        Preview schedule configuration

  Notifications:
    notify test          Test notification delivery (sends test notification)
    notify test --dry-run    Preview notification configuration without sending

  Workflow Management:
    workflow list        List all workflows (built-in + custom)
    workflow show <name> Display workflow definition
    workflow validate <name>  Validate workflow configuration
    workflow run <name>  Execute custom workflow

  Configuration:
    config show          Show current configuration
    config edit          Edit configuration file
    config validate      Validate configuration and script detection

GLOBAL OPTIONS:
  --dry-run            Preview actions without executing
  --verbose, -v        Show detailed output
  --quiet, -q          Minimal output (errors only)
  --no-color           Disable color output
  --config PATH        Use custom config file

WORKFLOW OPTIONS:
  All workflows:
    --notify           Enable notifications for manual runs (default: off)

  morning:
    --skip-ssh         Skip SSH key audit
    --skip-network     Skip network scan
    --skip-backup      Skip backup status check
    --skip-updates     Skip update check

  weekly:
    --skip-cleanup     Skip disk cleanup
    --skip-updates     Skip system updates
    --skip-scans       Skip full scans

  emergency:
    --threshold GB     Disk space threshold (default: 10GB)

  pre-deploy:
    --fail-on-risk LEVEL   Fail if risk level exceeds (low|medium|high|critical)
    --min-disk GB          Minimum disk space required (default: 10GB)

EXAMPLES:
  # Run morning routine
  homelab morning

  # Preview weekly maintenance
  homelab weekly --dry-run

  # Emergency cleanup if disk < 5GB
  homelab emergency --threshold 5

  # Pre-deploy checks (fail on HIGH risk)
  homelab pre-deploy --fail-on-risk high

  # Show detailed status
  homelab status --verbose

  # Generate weekly activity report
  homelab report weekly

  # Generate monthly report as JSON
  homelab report monthly --json --stdout

  # Custom date range report
  homelab report --since "2025-01-01"

  # Install automated schedule
  homelab schedule install

  # Check schedule status
  homelab schedule status

  # View morning routine logs
  homelab logs morning

  # Validate configuration
  homelab config validate

  # Test notifications
  homelab notify test

  # Run workflow with notifications enabled
  homelab morning --notify

VERSION: 2.2.0
HELP
}

# Show version
show_version() {
  echo "homelab v${VERSION}"
  echo ""
  echo "Detected scripts:"
  for script in disk-cleanup.sh update-all.sh ssh-key-audit.sh nmap-scan.sh rclone-sync.sh; do
    local script_path=$(get_script_path "$script")
    if [ -n "$script_path" ]; then
      echo "  ✓ $script"
    else
      echo "  ✗ $script (not found)"
    fi
  done
}

# Manage custom workflows (Phase 2.3.1)
manage_workflows() {
  local subcommand="${1:-list}"
  shift || true

  case "$subcommand" in
    list)
      cmd_workflow_list
      ;;
    show)
      local workflow_name="${1:-}"
      if [ -z "$workflow_name" ]; then
        print_error "Workflow name required"
        echo "Usage: homelab workflow show <name>"
        return 1
      fi
      cmd_workflow_show "$workflow_name"
      ;;
    validate)
      local workflow_name="${1:-}"
      if [ -z "$workflow_name" ]; then
        print_error "Workflow name required"
        echo "Usage: homelab workflow validate <name>"
        return 1
      fi
      cmd_workflow_validate "$workflow_name"
      ;;
    run)
      local workflow_name="${1:-}"
      if [ -z "$workflow_name" ]; then
        print_error "Workflow name required"
        echo "Usage: homelab workflow run <name> [options]"
        return 1
      fi
      shift
      cmd_workflow_run "$workflow_name" "$@"
      ;;
    *)
      print_error "Unknown workflow command: $subcommand"
      echo ""
      echo "Usage: homelab workflow <command> [options]"
      echo ""
      echo "Commands:"
      echo "  list                List all workflows (built-in + custom)"
      echo "  show <name>         Display workflow definition"
      echo "  validate <name>     Validate workflow configuration"
      echo "  run <name>          Execute custom workflow"
      return 1
      ;;
  esac
}

# Workflow command: list
cmd_workflow_list() {
  print_section "Available Workflows"
  echo ""

  # Built-in workflows
  echo "Built-in:"
  for workflow in morning weekly emergency pre-deploy; do
    local desc
    desc=$(get_workflow_description "$workflow")
    local schedule
    schedule=$(get_workflow_schedule "$workflow")

    local override_mark=""
    if has_workflow_override "$workflow"; then
      override_mark="*"
    fi

    printf "  %-20s %s (%s)%s\n" "$workflow$override_mark" "$desc" "$schedule" ""
  done

  echo ""

  # Custom workflows
  local custom_workflows
  custom_workflows=$(list_custom_workflows)

  if [ -n "$custom_workflows" ]; then
    echo "Custom:"
    echo "$custom_workflows" | while read -r workflow; do
      local desc
      desc=$(get_workflow_description "$workflow")
      local schedule
      schedule=$(get_workflow_schedule "$workflow")
      printf "  %-20s %s (%s)\n" "$workflow" "$desc" "$schedule"
    done
    echo ""
  fi

  # Overrides note
  if list_all_workflows | while read -r wf; do has_workflow_override "$wf" && exit 0; done; then
    echo "* Custom override active"
    echo ""
  fi

  print_info "Run 'homelab workflow show <name>' for details"
}

# Workflow command: show
cmd_workflow_show() {
  local workflow_name="$1"

  print_section "Workflow: $workflow_name"
  echo ""

  # Check if it's a built-in workflow
  if is_builtin_workflow "$workflow_name"; then
    local desc
    desc=$(get_workflow_description "$workflow_name")
    echo "Description: $desc"
    echo "Type: Built-in"

    if has_workflow_override "$workflow_name"; then
      echo "Override: Active"
      local override_file
      override_file=$(get_workflow_file "$workflow_name")
      echo "Config: $override_file"
    else
      echo "Override: None"
    fi

    echo ""
    local schedule
    schedule=$(get_workflow_schedule "$workflow_name")
    echo "Schedule: $schedule"
    echo ""

    # Show default options for built-in workflows
    case "$workflow_name" in
      morning)
        echo "Default Steps:"
        echo "  1. SSH Key Audit ($MORNING_SSH_AUDIT_OPTS)"
        echo "  2. Network Scan ($MORNING_NMAP_OPTS)"
        echo "  3. Backup Status (--status)"
        echo "  4. Package Updates ($MORNING_UPDATE_OPTS)"
        ;;
      weekly)
        echo "Default Steps:"
        echo "  1. Disk Cleanup ($WEEKLY_CLEANUP_OPTS)"
        echo "  2. System Updates ($WEEKLY_UPDATE_OPTS)"
        echo "  3. SSH Key Audit ($WEEKLY_SSH_AUDIT_OPTS)"
        echo "  4. Network Scan ($WEEKLY_NMAP_OPTS)"
        echo "  5. Backup Verification (--check)"
        ;;
      emergency)
        echo "Default Steps:"
        echo "  1. Check disk space (threshold: ${EMERGENCY_DISK_THRESHOLD_GB}GB)"
        echo "  2. Aggressive cleanup if needed ($EMERGENCY_CLEANUP_OPTS)"
        echo "  3. Re-check disk space"
        ;;
      pre-deploy)
        echo "Default Steps:"
        echo "  1. SSH key audit with risk thresholds"
        echo "  2. Disk space check (minimum: ${PREDEPLOY_MIN_DISK_GB}GB)"
        echo "  3. Network scan"
        echo "  4. Git status check"
        ;;
    esac

    return 0
  fi

  # Try to get custom workflow definition
  local workflow_file
  workflow_file=$(get_workflow_file "$workflow_name")

  if [ -z "$workflow_file" ]; then
    print_error "Workflow not found: $workflow_name"
    echo "Run 'homelab workflow list' to see available workflows"
    return 1
  fi

  # Validate JSON first
  if ! validate_json "$workflow_file"; then
    print_error "Invalid JSON in workflow file: $workflow_file"
    return 1
  fi

  # Display custom workflow details
  local desc
  desc=$(get_workflow_description "$workflow_name")
  echo "Description: $desc"
  echo "Type: Custom"
  echo ""

  local schedule
  schedule=$(get_workflow_schedule "$workflow_name")
  echo "Schedule: $schedule"
  echo ""

  # Parse and display steps
  echo "Steps:"

  # Warn if using fallback parser
  if ! has_json_parser; then
    print_warning "⚠ jq or python3 required for full workflow details"
    echo "  Install with: brew install jq (macOS) or apt install jq (Linux)"
    echo ""
    echo "  (Limited parsing available)"
    echo ""
  fi

  local parser
  parser=$(detect_json_parser)

  case "$parser" in
    jq)
      local step_count
      step_count=$(jq '.steps | length' "$workflow_file")
      for ((i=0; i<step_count; i++)); do
        local step_name
        local step_script
        local step_args
        step_name=$(jq -r ".steps[$i].name" "$workflow_file")
        step_script=$(jq -r ".steps[$i].script" "$workflow_file")
        step_args=$(jq -r ".steps[$i].args | join(\" \")" "$workflow_file" 2>/dev/null || echo "")

        echo "  $((i+1)). $step_name"
        echo "     Script: $step_script $step_args"
      done
      ;;
    python3)
      python3 <<EOF
import json
with open('$workflow_file') as f:
    data = json.load(f)
    for i, step in enumerate(data.get('steps', []), 1):
        print(f"  {i}. {step['name']}")
        args = ' '.join(step.get('args', []))
        print(f"     Script: {step['script']} {args}")
EOF
      ;;
    *)
      # Fallback: just show file path
      echo "  See full definition in config file"
      ;;
  esac

  echo ""
  echo "Config: $workflow_file"
}

# Workflow command: validate
cmd_workflow_validate() {
  local workflow_name="$1"

  # Check if workflow exists
  local workflow_file
  workflow_file=$(get_workflow_file "$workflow_name")

  if [ -z "$workflow_file" ] && ! is_builtin_workflow "$workflow_name"; then
    print_error "Workflow not found: $workflow_name"
    return 1
  fi

  # Built-in workflows are always valid
  if is_builtin_workflow "$workflow_name" && [ -z "$workflow_file" ]; then
    print_success "✓ Built-in workflow (always valid)"
    return 0
  fi

  # Validate custom workflow JSON and structure
  if [ -n "$workflow_file" ]; then
    if validate_workflow_definition "$workflow_file"; then
      print_success "✓ Workflow definition valid"
      print_info "Config: $workflow_file"
    else
      return 1
    fi
  fi

  return 0
}

# Workflow command: run
cmd_workflow_run() {
  local workflow_name="$1"
  shift

  # Check if workflow exists
  local workflow_file
  workflow_file=$(get_workflow_file "$workflow_name")

  if [ -z "$workflow_file" ] && ! is_builtin_workflow "$workflow_name"; then
    print_error "Workflow not found: $workflow_name"
    echo "Run 'homelab workflow list' to see available workflows"
    return 1
  fi

  # If it's a built-in workflow, run the built-in function
  if is_builtin_workflow "$workflow_name" && [ -z "$workflow_file" ]; then
    case "$workflow_name" in
      morning)
        run_morning_routine "$@"
        ;;
      weekly)
        run_weekly_maintenance "$@"
        ;;
      emergency)
        run_emergency_cleanup "$@"
        ;;
      pre-deploy)
        run_predeploy_checks "$@"
        ;;
    esac
    return $?
  fi

  # Otherwise, execute as custom workflow
  execute_custom_workflow "$workflow_name" "$@"
}

# Manage configuration
manage_config() {
  local subcommand="${1:-show}"

  case "$subcommand" in
    show)
      show_config
      ;;
    edit)
      if [ -n "${EDITOR:-}" ]; then
        "$EDITOR" "$HOMELAB_CONFIG_FILE"
      elif command -v nano >/dev/null 2>&1; then
        nano "$HOMELAB_CONFIG_FILE"
      elif command -v vi >/dev/null 2>&1; then
        vi "$HOMELAB_CONFIG_FILE"
      else
        print_error "No editor found. Set EDITOR environment variable."
        echo "Config file: $HOMELAB_CONFIG_FILE"
        return 1
      fi
      ;;
    validate)
      validate_config
      ;;
    reset)
      if [ -f "$HOMELAB_CONFIG_FILE" ]; then
        mv "$HOMELAB_CONFIG_FILE" "${HOMELAB_CONFIG_FILE}.backup"
        print_info "Backed up config to ${HOMELAB_CONFIG_FILE}.backup"
      fi
      create_example_config
      print_success "Reset config to defaults"
      ;;
    *)
      print_error "Unknown config command: $subcommand"
      echo "Valid commands: show, edit, validate, reset"
      return 1
      ;;
  esac
}

# Main entry point
main() {
  # Parse global options inline
  while [[ $# -gt 0 ]]; do
    case $1 in
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --verbose|-v)
        HOMELAB_VERBOSE=true
        shift
        ;;
      --quiet|-q)
        HOMELAB_QUIET=true
        shift
        ;;
      --no-color)
        HOMELAB_COLOR=false
        shift
        ;;
      --config)
        HOMELAB_CONFIG_FILE="$2"
        shift 2
        ;;
      *)
        # Found command or non-global option, stop parsing globals
        break
        ;;
    esac
  done

  # Load configuration
  if ! load_config; then
    print_error "Failed to load configuration"
    echo ""
    echo "Run 'homelab config validate' to diagnose issues"
    exit 1
  fi

  # Get command
  local command="${1:-help}"
  shift || true

  # Route to command handlers
  case "$command" in
    # Workflows
    morning)
      run_morning_routine "$@"
      ;;
    weekly)
      run_weekly_maintenance "$@"
      ;;
    emergency)
      run_emergency_cleanup "$@"
      ;;
    pre-deploy)
      run_predeploy_checks "$@"
      ;;

    # Information
    status)
      show_status_dashboard "$@"
      ;;
    report)
      generate_report "$@"
      ;;
    logs)
      show_logs "$@"
      ;;
    list-logs)
      list_logs
      ;;
    rotate-logs)
      # Check for --dry-run flag
      local dry_run=false
      if [ "${1:-}" = "--dry-run" ]; then
        dry_run=true
      fi
      rotate_logs "$dry_run"
      ;;
    version)
      show_version
      ;;
    help|--help|-h)
      show_help
      ;;

    # Configuration
    config)
      manage_config "$@"
      ;;

    # Scheduling
    schedule)
      local subcmd="${1:-}"
      case "$subcmd" in
        install)
          shift
          install_schedule "$@"
          ;;
        remove)
          remove_schedule
          ;;
        status)
          show_schedule_status
          ;;
        show)
          show_schedule_config
          ;;
        *)
          print_error "Unknown schedule command: ${subcmd}"
          echo ""
          echo "Usage: homelab schedule <install|remove|status|show>"
          exit 1
          ;;
      esac
      ;;

    # Notifications
    notify)
      local subcmd="${1:-}"
      case "$subcmd" in
        test)
          shift
          local dry_run=false
          if [ "${1:-}" = "--dry-run" ]; then
            dry_run=true
          fi
          test_notifications "$dry_run"
          ;;
        *)
          print_error "Unknown notify command: ${subcmd}"
          echo ""
          echo "Usage: homelab notify test [--dry-run]"
          exit 1
          ;;
      esac
      ;;

    # Custom Workflows (Phase 2.3.1)
    workflow)
      manage_workflows "$@"
      ;;

    # Unknown command
    *)
      print_error "Unknown command: $command"
      echo ""
      show_help
      exit 1
      ;;
  esac
}

# Run main
main "$@"
