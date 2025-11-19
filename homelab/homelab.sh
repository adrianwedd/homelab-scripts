#!/usr/bin/env bash
set -euo pipefail

# homelab - Unified DevOps orchestrator for system maintenance scripts
# Version: 1.0.0
# Usage: homelab <command> [options]

VERSION="1.0.0"
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

VERSION: 1.0.0
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
