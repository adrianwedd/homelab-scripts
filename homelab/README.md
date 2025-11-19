# homelab - Unified DevOps Orchestrator

Version: 1.0.0

A unified CLI that orchestrates system maintenance scripts into curated workflows with smart script detection and graceful degradation.

## Overview

`homelab` provides a single command interface to run complex maintenance workflows that combine multiple specialized scripts (disk cleanup, SSH audits, network scans, backups, updates). It automatically detects available scripts and gracefully skips missing ones.

## Features

- **Curated Workflows**: Pre-built maintenance routines (morning, weekly, emergency, pre-deploy)
- **Smart Script Detection**: Auto-discovers scripts with multi-level fallback
- **Graceful Degradation**: Skips missing optional scripts, warns about missing required ones
- **Unified Logging**: All workflows log to timestamped files with step tracking
- **Status Dashboard**: Real-time system health overview
- **Dry-Run Mode**: Preview all actions before executing
- **Configuration**: Customize workflow behavior and script paths

## Installation

### Quick Install

```bash
# Clone or download to your scripts directory
cd ~/repos/scripts
git clone <repo-url> homelab

# Make executable
chmod +x homelab/homelab.sh

# Add to PATH (optional)
ln -s ~/repos/scripts/homelab/homelab.sh ~/bin/homelab
```

### Script Dependencies

`homelab` orchestrates these scripts (all optional except `disk-cleanup.sh` and `update-all.sh`):

- `disk-cleanup.sh` (required) - Comprehensive cache cleanup
- `update-all.sh` (required) - System-wide package updates
- `ssh-key-audit.sh` (optional) - SSH key hygiene auditing
- `nmap-scan.sh` (optional) - Network discovery and change tracking
- `rclone-sync.sh` (optional) - Background backup sync
- `smart-cleanup.sh` (optional) - Interactive cleanup wrapper

Place scripts in:
1. Same directory as `homelab.sh` (recommended)
2. `~/bin/`
3. `/usr/local/bin/`
4. Anywhere in `$PATH`

Or configure explicit paths in `~/.config/homelab/homelab.conf`

## Quick Start

```bash
# Run morning routine
homelab morning

# Preview weekly maintenance
homelab weekly --dry-run

# Check system status
homelab status

# Show help
homelab help
```

## Workflows

### Morning Routine

Quick daily health check (5-10 minutes):

```bash
homelab morning
```

**Steps:**
1. SSH key audit (quick scan with risk scoring)
2. Network scan (delta detection for new devices)
3. Backup sync status check
4. Package update preview (dry-run)

**Options:**
- `--skip-ssh` - Skip SSH audit
- `--skip-network` - Skip network scan
- `--skip-backup` - Skip backup check
- `--skip-updates` - Skip update preview

### Weekly Maintenance

Comprehensive maintenance (30-60 minutes):

```bash
homelab weekly
```

**Steps:**
1. Disk cleanup (smart GC, venv cleanup)
2. System updates (all package managers)
3. SSH key audit (detailed with risk analysis)
4. Network scan (full port scan with delta)
5. Backup verification

**Options:**
- `--skip-cleanup` - Skip disk cleanup
- `--skip-updates` - Skip system updates
- `--skip-scans` - Skip all scans

### Emergency Cleanup

Aggressive disk space recovery (10-20 minutes):

```bash
homelab emergency
```

**Steps:**
1. Check disk space against threshold
2. Aggressive cleanup (full GC, old venvs, Docker)
3. Re-check and report freed space

**Options:**
- `--threshold GB` - Disk space threshold (default: 10GB)

### Pre-Deploy Checks

Pre-deployment validation (5-10 minutes):

```bash
homelab pre-deploy
```

**Steps:**
1. SSH key audit with risk threshold
2. Disk space check
3. Network scan with delta detection
4. Git repository status

**Options:**
- `--fail-on-risk LEVEL` - Fail if risk exceeds (low|medium|high|critical)
- `--min-disk GB` - Minimum disk space required (default: 10GB)

**Exit Codes:**
- `0` - All checks passed
- `1` - Passed with warnings (review recommended)
- `2` - Failed with critical issues (abort deployment)

## Commands

### Information

```bash
# System status dashboard
homelab status [--verbose]

# View logs (latest workflow or specific)
homelab logs [workflow]

# List available logs
homelab list-logs

# Show version and detected scripts
homelab version
```

### Configuration

```bash
# Show current configuration
homelab config show

# Edit configuration file
homelab config edit

# Validate configuration and script detection
homelab config validate
```

## Global Options

All workflows support these global options:

```bash
--dry-run          # Preview actions without executing
--verbose, -v      # Show detailed output
--quiet, -q        # Minimal output (errors only)
--no-color         # Disable color output
--config PATH      # Use custom config file
```

## Configuration

Config file: `~/.config/homelab/homelab.conf`

### Script Paths

Auto-detection searches in order:
1. Explicit config path (if set)
2. Same directory as `homelab.sh`
3. `$HOME/bin/`
4. `/usr/local/bin/`
5. `/opt/homelab/`
6. `$PATH`

Override with explicit paths:

```bash
HOMELAB_DISK_CLEANUP="/custom/path/disk-cleanup.sh"
HOMELAB_SSH_AUDIT="/opt/scripts/ssh-key-audit.sh"
```

### Workflow Defaults

Customize default options for each workflow:

```bash
# Morning routine
MORNING_SSH_AUDIT_OPTS="--all-users --risk"
MORNING_NMAP_OPTS="--delta"
MORNING_UPDATE_OPTS="--dry-run"

# Weekly maintenance
WEEKLY_CLEANUP_OPTS="--smart-gc --clean-venvs --venv-age 60"
WEEKLY_SSH_AUDIT_OPTS="--all-users --risk-detail"
WEEKLY_NMAP_OPTS="--full --delta"

# Emergency cleanup
EMERGENCY_DISK_THRESHOLD_GB=10
EMERGENCY_CLEANUP_OPTS="--full-gc --clean-venvs --venv-age 30 -y"

# Pre-deploy checks
PREDEPLOY_FAIL_ON_RISK="high"
PREDEPLOY_MIN_DISK_GB=10
```

### Display Options

```bash
HOMELAB_COLOR=true        # Enable/disable color output
HOMELAB_VERBOSE=false     # Default verbosity
HOMELAB_LOG_DIR="$HOME/homelab-logs"
HOMELAB_MAX_LOG_AGE_DAYS=90
```

## Logs

All workflows create timestamped logs:

```
~/homelab-logs/
├── homelab_morning_20250117_060000.log
├── homelab_weekly_20250115_030000.log
├── step_1_SSH_Key_Audit.log
└── step_2_Network_Scan.log
```

**Security:** Log directory has permissions `700`, files have `600` (owner-only).

**Retention:** Logs older than `HOMELAB_MAX_LOG_AGE_DAYS` (default: 90) are auto-deleted.

## Examples

### Daily Routine

```bash
# Morning health check
homelab morning

# If issues found, check details
homelab status --verbose
homelab logs morning
```

### Weekly Maintenance

```bash
# Preview first
homelab weekly --dry-run

# Execute if satisfied
homelab weekly

# Check what happened
homelab logs weekly
```

### Emergency Response

```bash
# Disk space critical!
homelab emergency

# Or with custom threshold
homelab emergency --threshold 5
```

### Pre-Deployment

```bash
# Check before deploying to production
homelab pre-deploy --fail-on-risk high --min-disk 20

# Exit code 0 = safe to deploy
# Exit code 1 = warnings (review first)
# Exit code 2 = critical issues (abort)
```

### Custom Workflows

```bash
# Morning routine without network scan (faster)
homelab morning --skip-network

# Weekly without cleanup (already done)
homelab weekly --skip-cleanup

# Pre-deploy with strict settings
homelab pre-deploy --fail-on-risk medium --min-disk 50
```

## Status Dashboard

The status dashboard shows real-time system health:

```bash
# Basic status
homelab status

# Detailed status with verbose information
homelab status --verbose
```

**Sections:**
- **Disk Space**: Usage percentage with 🟢🟡🔴 indicators
  - Verbose: Shows last cleanup run, space freed, git repos processed, virtualenvs removed
- **SSH Keys**: Latest audit age and risk summary
  - Verbose: Displays total keys scanned and users checked
- **Network**: Latest scan age and device count
  - Verbose: Shows delta changes (new/removed devices with IPs)
- **Backup Sync**: rclone sync daemon status
- **Package Updates**: Package counts by manager (Homebrew, NPM, pip)
  - Verbose: Breakdown by package manager and error detection
- **Recent Activity**: Last 5 workflow runs with duration

**Example verbose output:**

```
💾 Disk Space
  Available: 45.2 GB / 500 GB (91% used)
  Status: 🟡 Monitor
  Last cleanup: 2 days ago
  Freed: 12.4 GB
    Git repos: 15 processed
    Virtualenvs: 3 removed

🌐 Network
  Last scan: 4h ago
  Devices: 12 detected
  Changes: +1 new, -0 removed
  New devices:
    + 192.168.1.45
  Status: 🔵 Normal

📦 Package Updates
  Last check: 1h ago
  Updated: 5 packages
    Homebrew: 3
    pip: 2
  Status: 🟢 Updates applied
```

## Activity Reports

Generate comprehensive activity reports over time periods:

```bash
# Weekly activity report (last 7 days)
homelab report weekly

# Monthly activity report (last 30 days)
homelab report monthly

# Custom date range
homelab report --since "2025-01-01"

# JSON output
homelab report weekly --json

# Output to stdout instead of file
homelab report weekly --stdout
```

**Report Contents:**
- **Executive Summary**: High-level metrics (disk freed, packages updated, issues found)
- **SSH Key Security**: Audit runs, risk trends, critical/warning counts
- **Network Discovery**: Scans performed, new/removed devices with IPs
- **Disk Cleanup**: Total space freed, git repos processed, virtualenvs removed
- **Package Updates**: Update runs and package counts
- **Recommendations**: Actionable next steps based on detected issues

**Example weekly report:**

```markdown
# Homelab Activity Report

**Period:** Last 7 Days
**Generated:** 2025-11-17 14:30:00

---

## Executive Summary

- **SSH Audits:** 3 runs, 🟡 Warning status
- **Network Scans:** 7 scans performed
- **Disk Cleanup:** 18.3 GB freed across 2 runs
- **Package Updates:** 12 packages updated

---

## SSH Key Security

**Status:** 🟡 Warning

- Audit runs: 3
- Max criticals found: 0
- Max warnings found: 5
- Targets with issues: 2

---

## Network Discovery

- Scans performed: 7
- New devices detected: 2
- Devices removed: 1

### New Devices

```
192.168.1.45
192.168.1.73
```

---

## Disk Cleanup

- Cleanup runs: 2
- Total space freed: **18.3 GB**
- Git repositories processed: 28
- Virtualenvs removed: 5

---

## Recommendations

- 🟡 **Warning:** 2 new devices detected - verify authorized access
- 📦 **Updates:** Consider running `homelab weekly` for package updates
```

Reports are saved to `$HOMELAB_LOG_DIR/reports/` (default: `~/homelab-logs/reports/`) as Markdown or JSON files.

## Automated Scheduling

Automate your homelab workflows with built-in scheduling support for both cron (Linux) and launchd (macOS).

### Quick Start

```bash
# Install automated schedule
homelab schedule install

# Check schedule status
homelab schedule status

# Preview schedule without installing
homelab schedule show

# Remove schedule
homelab schedule remove
```

### Default Schedule

**Morning Routine:** Daily at 8:00 AM
- SSH key audit
- Network scan
- Backup status check
- Update preview (dry-run)

**Weekly Maintenance:** Sundays at 2:00 AM
- Disk cleanup (smart GC, virtualenv cleanup)
- System updates
- Full network scan
- SSH audit with details

### Platform Support

**macOS (launchd):**
- Creates plist files in `~/Library/LaunchAgents/`
- Jobs: `com.homelab.morning` and `com.homelab.weekly`
- Logs to `$HOMELAB_LOG_DIR/launchd_*.log` (default: `~/homelab-logs/`)
- Auto-loads on installation

**Linux (cron):**
- Adds entries to user crontab
- Logs to `$HOMELAB_LOG_DIR/cron_*.log` (default: `~/homelab-logs/`)
- Preserves existing cron jobs

### Customizing Schedule

Edit `~/.config/homelab/homelab.conf`:

```bash
# For cron (Linux) - standard cron format
HOMELAB_SCHEDULE_MORNING="0 8 * * *"    # Daily at 8 AM
HOMELAB_SCHEDULE_WEEKLY="0 2 * * 0"     # Sundays at 2 AM

# For launchd (macOS) - hour/minute/weekday
HOMELAB_SCHEDULE_MORNING_HOUR=8
HOMELAB_SCHEDULE_MORNING_MINUTE=0
HOMELAB_SCHEDULE_WEEKLY_HOUR=2
HOMELAB_SCHEDULE_WEEKLY_MINUTE=0
HOMELAB_SCHEDULE_WEEKLY_WEEKDAY=0      # 0=Sunday
```

After editing config:

```bash
# Remove old schedule
homelab schedule remove

# Install with new schedule
homelab schedule install
```

### Schedule Management

**View current schedule:**

```bash
homelab schedule status
```

Example output (macOS):

```
━━━ Workflow Schedule Status ━━━

Platform: launchd

✓ homelab schedule is active

Active jobs:
  • Morning: Daily at 8:00
  • Weekly: Sundays at 2:00

ℹ Last morning run: 2025-11-17 08:00
ℹ Last weekly run: 2025-11-17 02:00
```

**Preview schedule configuration:**

```bash
homelab schedule show
```

Shows the exact cron entries or launchd plists that would be installed without actually installing them.

**Check execution logs:**

```bash
# View morning routine logs (adjust path if HOMELAB_LOG_DIR is customized)
tail -f ~/homelab-logs/launchd_morning.log  # macOS
tail -f ~/homelab-logs/cron_morning.log     # Linux

# Or use environment variable
tail -f $HOMELAB_LOG_DIR/launchd_morning.log

# View all workflow logs
homelab logs

# View specific workflow
homelab logs morning
```

### Safety Features

1. **Backup on install**: Existing cron entries or launchd plists are backed up to `$HOMELAB_LOG_DIR/`
2. **Non-destructive removal**: Only homelab entries are removed; other cron jobs/launchd jobs are preserved
3. **Validation**: Checks that homelab is executable and accessible before installing
4. **Dry-run support**: `homelab schedule show` previews changes without applying them

### Troubleshooting

**Schedule not running:**

```bash
# Check schedule status
homelab schedule status

# Verify homelab is in PATH
which homelab

# Check logs for errors
homelab logs morning
homelab logs weekly
```

**macOS launchd issues:**

```bash
# Check if jobs are loaded
launchctl list | grep homelab

# View job status
launchctl print gui/$(id -u)/com.homelab.morning

# Reload jobs
homelab schedule remove
homelab schedule install
```

**Linux cron issues:**

```bash
# View crontab
crontab -l | grep homelab

# Check cron logs
grep homelab /var/log/syslog   # Debian/Ubuntu
grep homelab /var/log/cron     # RHEL/CentOS
```

## Notifications (Phase 2.2)

Stay informed about workflow completion and failures with multi-channel notifications.

### Overview

The notification system sends alerts when workflows complete, enabling unattended automation with proactive failure detection. Designed for scheduled workflows (cron/launchd) by default, with opt-in support for manual runs.

**Key Features**:
- **Multi-channel delivery**: Slack, webhooks, macOS native, Linux desktop, email
- **Smart triggers**: Only notify on failures/warnings by default
- **Rich formatting**: Color-coded Slack attachments, urgency levels
- **Security**: Path redaction, rate limiting, circuit breakers
- **Testing**: Dry-run mode to verify configuration

### Quick Start

**1. Enable notifications:**

```bash
# Edit configuration
homelab config edit

# Set these values:
HOMELAB_NOTIFY_ENABLED=true
HOMELAB_NOTIFY_CHANNELS="slack,macos"  # Choose your channels
HOMELAB_NOTIFY_TRIGGERS="warning,failure"  # Default: errors only
```

**2. Configure your channels:**

For Slack (recommended):
```bash
# Get webhook URL from https://api.slack.com/messaging/webhooks
HOMELAB_NOTIFY_SLACK_WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
HOMELAB_NOTIFY_SLACK_USERNAME="homelab-bot"
```

For generic webhooks (Discord, Teams, custom):
```bash
HOMELAB_NOTIFY_WEBHOOK_URL="https://your-webhook-url"
HOMELAB_NOTIFY_WEBHOOK_HEADERS="Authorization: Bearer token"  # Optional
```

For email:
```bash
HOMELAB_NOTIFY_EMAIL_TO="admin@example.com"
HOMELAB_NOTIFY_EMAIL_FROM="homelab@localhost"
```

**3. Test your setup:**

```bash
# Dry-run (preview without sending)
homelab notify test --dry-run

# Send actual test notification
homelab notify test
```

### Notification Channels

Channels are tried in priority order until one succeeds:

#### 1. Slack / Generic Webhook (Primary)

**Best for**: Team visibility, persistent history, remote access

**Slack Features**:
- Color-coded attachments (green=success, yellow=warning, red=failure)
- Structured fields (duration, steps, host)
- Failed step details
- Configurable username and icon

**Example Slack notification**:
```
🟢 Morning workflow success

Duration: 2m 15s
Steps: 4/4
Host: macbook-pro

Log: ~/homelab-logs/homelab_morning_20250118.log
```

**Generic Webhook**:
Sends JSON payload compatible with Discord, Microsoft Teams, or custom endpoints:
```json
{
  "workflow": "morning",
  "status": "success",
  "hostname": "macbook-pro",
  "timestamp": "2025-01-18T08:00:00Z",
  "duration": "2m 15s",
  "steps": {
    "completed": 4,
    "total": 4,
    "failed": [],
    "skipped": []
  },
  "log_file": "~/homelab-logs/homelab_morning_20250118.log"
}
```

#### 2. macOS Native Notifications

**Best for**: Local desktop alerts, immediate visibility

**Features**:
- System notification center integration
- Optional sound alerts
- Works only in GUI sessions (not SSH)

**Configuration**:
```bash
HOMELAB_NOTIFY_MACOS_SOUND=true  # Play notification sound
```

**Limitations**: Requires active GUI session, not persistent

#### 3. Linux Desktop (notify-send)

**Best for**: Linux desktop environments

**Features**:
- Urgency levels (critical for failures, normal for warnings, low for success)
- Desktop environment integration (GNOME, KDE, etc.)
- Requires `notify-send` command

**Limitations**: GUI session required, varies by DE

#### 4. Email

**Best for**: Universal delivery, detailed reports

**Features**:
- Plain text format with full details
- Works anywhere
- Persistent record

**Requirements**: `mail` command or SMTP configuration

**Configuration**:
```bash
HOMELAB_NOTIFY_EMAIL_TO="admin@example.com"
HOMELAB_NOTIFY_EMAIL_FROM="homelab@localhost"

# Optional SMTP (advanced)
HOMELAB_NOTIFY_EMAIL_SMTP_HOST="smtp.gmail.com"
HOMELAB_NOTIFY_EMAIL_SMTP_PORT=587
HOMELAB_NOTIFY_EMAIL_SMTP_USER="your-email@gmail.com"
HOMELAB_NOTIFY_EMAIL_SMTP_PASS="app-password"  # Warning: plaintext
```

### Notification Triggers

Control when notifications fire:

```bash
# Default: Only errors (recommended for scheduled workflows)
HOMELAB_NOTIFY_TRIGGERS="warning,failure"

# Include successes (noisy but comprehensive)
HOMELAB_NOTIFY_TRIGGERS="success,warning,failure"

# Failures only (critical errors only)
HOMELAB_NOTIFY_TRIGGERS="failure"

# Everything including workflow starts
HOMELAB_NOTIFY_TRIGGERS="start,success,warning,failure"
```

**Trigger Types**:
- `success`: All steps completed without issues
- `warning`: Some steps skipped or had non-critical errors
- `failure`: One or more steps failed critically
- `start`: Workflow beginning (verbose, rarely needed)

### Manual vs Scheduled Runs

**Default behavior**:
- **Scheduled runs** (cron/launchd): Notifications **enabled** automatically
- **Manual runs**: Notifications **disabled** by default (opt-in)

**Enable notifications for manual runs**:
```bash
# One-time notification for this run
homelab morning --notify

# Or enable globally in config
HOMELAB_NOTIFY_MANUAL=true
```

This prevents notification spam during interactive debugging while ensuring scheduled failures are always reported.

### Advanced Configuration

#### Rate Limiting

Prevent notification spam:

```bash
# Minimum seconds between notifications (default: 60)
HOMELAB_NOTIFY_MIN_INTERVAL_SECONDS=60
```

Rapid workflow runs within the interval are silently skipped. Dry-run/test invocations don't consume the rate limit.

#### Path Redaction

Hide sensitive file paths in notifications:

```bash
# Replace $HOME with ~ in all paths
HOMELAB_NOTIFY_REDACT_PATHS=true
```

**Example**:
- Before: `/Users/admin/homelab-logs/homelab_morning_20250118.log`
- After: `~/homelab-logs/homelab_morning_20250118.log`

#### Rich Formatting

Toggle color/structured formatting:

```bash
# Enable color/fields in Slack (default: true)
HOMELAB_NOTIFY_RICH_FORMAT=true

# Plain text only (simpler, more compatible)
HOMELAB_NOTIFY_RICH_FORMAT=false
```

#### Circuit Breakers

Channels that fail repeatedly are automatically disabled to prevent error loops:
- Failure tracked per channel
- Prevents infinite retry storms
- Logged for debugging

Check logs to diagnose circuit breaker activation:
```bash
homelab logs | grep "circuit breaker"
```

### Testing Notifications

Always test before deploying:

**1. Preview configuration (dry-run)**:
```bash
homelab notify test --dry-run
```

Shows what would be sent without actually delivering:
```
━━━ Slack Notification (DRY RUN) ━━━
Webhook URL: https://hooks.slack.com/services/...
Payload:
{
  "username": "homelab-bot",
  "icon_emoji": ":robot_face:",
  "attachments": [...]
}
```

**2. Send test notification**:
```bash
homelab notify test
```

Sends actual test message to verify delivery.

**3. Test with workflow**:
```bash
# Manual run with notifications enabled
homelab morning --notify --dry-run
```

### Example Configurations

#### Minimal (Slack only):
```bash
HOMELAB_NOTIFY_ENABLED=true
HOMELAB_NOTIFY_CHANNELS="slack"
HOMELAB_NOTIFY_TRIGGERS="warning,failure"
HOMELAB_NOTIFY_SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..."
```

#### Multi-channel (Slack + macOS):
```bash
HOMELAB_NOTIFY_ENABLED=true
HOMELAB_NOTIFY_CHANNELS="slack,macos"
HOMELAB_NOTIFY_TRIGGERS="warning,failure"
HOMELAB_NOTIFY_SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..."
HOMELAB_NOTIFY_MACOS_SOUND=true
```

#### Comprehensive (All channels with fallback):
```bash
HOMELAB_NOTIFY_ENABLED=true
HOMELAB_NOTIFY_CHANNELS="slack,webhook,macos,email"
HOMELAB_NOTIFY_TRIGGERS="warning,failure"
HOMELAB_NOTIFY_SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..."
HOMELAB_NOTIFY_WEBHOOK_URL="https://discord.com/api/webhooks/..."
HOMELAB_NOTIFY_EMAIL_TO="admin@example.com"
HOMELAB_NOTIFY_MACOS_SOUND=true
```

#### Verbose (Include successes):
```bash
HOMELAB_NOTIFY_ENABLED=true
HOMELAB_NOTIFY_CHANNELS="slack"
HOMELAB_NOTIFY_TRIGGERS="success,warning,failure"
HOMELAB_NOTIFY_RICH_FORMAT=true
HOMELAB_NOTIFY_SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..."
```

### Integration with Workflows

Notifications are automatically sent at workflow completion:

```bash
# Scheduled run (notifications enabled by default)
# Via cron: homelab morning --quiet --scheduled
#   → Sends notification on completion

# Manual run (notifications disabled by default)
homelab morning
#   → No notification

# Manual run with notifications
homelab morning --notify
#   → Sends notification
```

Notification status is determined by workflow outcome:
- **success**: All steps completed
- **warning**: Some steps skipped (missing scripts) but no failures
- **failure**: One or more steps failed

### Security Considerations

**Webhook URLs**: Sensitive credentials in config
```bash
# Protect config file permissions
chmod 600 ~/.config/homelab/homelab.conf

# Or use environment variables
export HOMELAB_NOTIFY_SLACK_WEBHOOK_URL="..."
homelab morning
```

**SMTP Passwords**: Stored in plaintext
```bash
# Recommendation: Use app-specific passwords, not account passwords
# Or use local mail command (no password needed)
HOMELAB_NOTIFY_EMAIL_TO="admin@example.com"
# Relies on local mail command
```

**Path Redaction**: Enable to hide sensitive paths
```bash
HOMELAB_NOTIFY_REDACT_PATHS=true
```

### Troubleshooting

**Notifications not sending**:

1. Check if notifications are enabled:
   ```bash
   homelab config show | grep NOTIFY_ENABLED
   ```

2. Verify trigger matches workflow status:
   ```bash
   # Check what triggers are enabled
   homelab config show | grep NOTIFY_TRIGGERS

   # Failed workflow needs "failure" in triggers
   # Successful workflow needs "success" in triggers
   ```

3. Test with dry-run:
   ```bash
   homelab notify test --dry-run
   ```

4. Check logs for errors:
   ```bash
   homelab logs | grep NOTIFICATION
   ```

**Slack webhook fails (HTTP 400)**:

- Webhook URL incorrect or expired
- Regenerate webhook in Slack settings
- Test URL with curl:
  ```bash
  curl -X POST -H "Content-Type: application/json" \
    -d '{"text":"Test"}' \
    "YOUR_WEBHOOK_URL"
  ```

**macOS notifications not appearing**:

- Requires GUI session (not SSH)
- Check System Settings → Notifications → Script Editor
- Run from terminal with GUI access

**Rate limiting preventing notifications**:

- Check `HOMELAB_NOTIFY_MIN_INTERVAL_SECONDS` (default: 60s)
- Wait for interval to expire before next notification
- Dry-run tests don't consume rate limit
- **Known edge case**: Start notifications are exempt from consuming the rate limit but not from the rate limit check itself
  - Intra-workflow: `start` → `completion` works correctly (start doesn't block completion)
  - Cross-workflow: `completion` → `start` may be blocked if workflows run < 60s apart
  - Example: Morning completes at 08:00:00, Weekly starts at 08:00:30 → Weekly start blocked
  - Workaround: Reduce `HOMELAB_NOTIFY_MIN_INTERVAL_SECONDS` or disable `start` trigger if running frequent workflows

**Circuit breaker activated**:

- Channel failed repeatedly, auto-disabled
- Check logs: `homelab logs | grep "circuit breaker"`
- Fix underlying issue (webhook URL, network, etc.)
- Restart homelab to reset circuit breakers

## Graceful Degradation

`homelab` handles missing scripts gracefully:

- **Missing required scripts** (disk-cleanup.sh, update-all.sh): Fatal error with install instructions
- **Missing optional scripts**: Workflow continues, skips affected steps, shows warning
- **Partial availability**: Each workflow shows which steps can run

Validate script detection:

```bash
homelab config validate
```

## Troubleshooting

### Scripts Not Detected

```bash
# Validate detection
homelab config validate

# Check search paths
homelab config show

# Set explicit paths
homelab config edit
# Add: HOMELAB_SSH_AUDIT="/path/to/ssh-key-audit.sh"
```

### Workflow Failures

```bash
# Check logs
homelab logs [workflow]

# Run with verbose output
homelab [workflow] --verbose

# Try dry-run to diagnose
homelab [workflow] --dry-run
```

### Permission Issues

```bash
# Logs directory should be 700
chmod 700 ~/homelab-logs

# homelab.sh should be executable
chmod +x /path/to/homelab.sh
```

## Architecture

### Module Organization

```
homelab/
├── homelab.sh              # Main CLI entrypoint
├── lib/
│   ├── config.sh          # Script detection, config management
│   ├── logger.sh          # Unified logging, step execution
│   ├── workflows.sh       # Workflow definitions
│   └── status.sh          # Status dashboard
└── config/
    └── homelab.conf.example
```

### Key Design Patterns

- **Script Detection**: Multi-level fallback with validation
- **Workflow Steps**: Tracked execution with skip/fail arrays
- **Logging**: Timestamped files with secure permissions
- **Error Handling**: Continue-on-failure for workflows
- **Configuration**: Bash-sourced config for flexibility

## Development

### Testing

```bash
# Validate all scripts
cd homelab
shellcheck -S warning homelab.sh lib/*.sh

# Test workflows in dry-run
./homelab.sh morning --dry-run
./homelab.sh weekly --dry-run
./homelab.sh emergency --dry-run --threshold 10
./homelab.sh pre-deploy --dry-run

# Test script detection
./homelab.sh config validate
```

### Adding Scripts

To integrate a new script:

1. Add detection to `lib/config.sh`:
   ```bash
   for script in disk-cleanup.sh update-all.sh your-script.sh; do
     # Detection logic
   done
   ```

2. Update workflow in `lib/workflows.sh`:
   ```bash
   run_step "Your Feature" "your-script.sh" --your-opts
   ```

3. Add status check to `lib/status.sh` (optional)

## License

See repository root for license information.

## Support

For issues or questions:
1. Check logs: `homelab logs`
2. Validate config: `homelab config validate`
3. Run with `--verbose` for detailed output
4. Review script documentation in repository root

## Version History

- **v1.0.0** (2025-01-17): Initial release
  - Four curated workflows (morning, weekly, emergency, pre-deploy)
  - Smart script detection with graceful degradation
  - Unified logging and status dashboard
  - Configuration management
