# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- N/A

### Changed
- N/A

### Fixed
- N/A

## [2.2.0] - 2025-11-19

### Added

**Homelab Orchestration System - Phase 2.2: Multi-Channel Notification System**

- **homelab/lib/notifications.sh** - Comprehensive notification delivery engine (676 lines)
  - Multi-channel support: Slack webhooks, generic webhooks (Discord/Teams), macOS native, Linux notify-send, email
  - Smart trigger system: success, warning, failure, start (configurable per notification type)
  - Manual vs scheduled run differentiation (opt-in `--notify` flag for manual runs)
  - Rich formatting with Slack attachments (color-coded, fields, footer)
  - Plain text fallback with proper JSON escaping
  - Rate limiting with configurable interval (default: 60s, prevents notification spam)
  - Circuit breakers for failing channels (auto-disable after repeated failures)
  - Path redaction for privacy (`$HOME` → `~` when enabled)
  - Dry-run mode for testing without sending
  - Failed steps list rendering (displays step names in notifications)
  - Start trigger support (workflow initialization notifications)
  - bash 3.2 compatible (macOS default bash)

- **Notification CLI commands**:
  - `homelab notify test` - Send test notification to configured channels
  - `homelab notify test --dry-run` - Preview notification without sending

- **Workflow integration**:
  - Start notifications fired at workflow begin (optional, trigger-based)
  - Completion notifications with status (success/warning/failure)
  - Duration tracking and step counts
  - Failed/skipped step names in notifications
  - Automatic status determination (failure > warning > success)

- **Configuration options** (homelab.conf):
  - `HOMELAB_NOTIFY_ENABLED` - Global enable/disable
  - `HOMELAB_NOTIFY_CHANNELS` - Comma-separated channel list
  - `HOMELAB_NOTIFY_TRIGGERS` - Comma-separated trigger list
  - `HOMELAB_NOTIFY_MANUAL` - Require `--notify` flag for manual runs
  - `HOMELAB_NOTIFY_RICH_FORMAT` - Enable/disable color and fields
  - `HOMELAB_NOTIFY_REDACT_PATHS` - Enable path redaction
  - `HOMELAB_NOTIFY_MIN_INTERVAL_SECONDS` - Rate limit interval
  - Channel-specific configs (Slack webhook URL, email addresses, etc.)

- **Cross-platform compatibility**:
  - macOS: osascript for native notifications
  - Linux: notify-send for desktop notifications
  - Both: Slack, generic webhooks, email

- **Test coverage**:
  - 6 comprehensive test scripts validating all fixes
  - Edge case test for cross-workflow rate limiting
  - JSON escaping validation
  - Path redaction validation
  - Failed steps rendering validation
  - Rate limit behavior validation

### Changed

- **homelab/lib/logger.sh** - Added notification hooks to `complete_workflow_logging()`
  - Determines notification status based on failed/skipped steps
  - Passes workflow metrics to notification system
  - Supports `is_scheduled` flag for manual vs scheduled differentiation

- **homelab/lib/workflows.sh** - Added start notifications to all workflows
  - Morning routine: fires start notification before step execution
  - Weekly maintenance: fires start notification before step execution
  - Emergency cleanup: fires start notification before step execution
  - Pre-deploy checks: fires start notification before step execution

- **homelab/lib/scheduler.sh** - Added `--scheduled` flag to cron/launchd entries
  - Allows notifications to differentiate scheduled vs manual runs
  - Prevents notification spam during interactive debugging

- **homelab/homelab.sh** - Added notification commands and `--notify` flag
  - All workflows support `--notify` flag for manual notification override
  - New `notify` command namespace for testing

- **homelab/homelab.conf** - Added 82 lines of notification configuration
  - Comprehensive comments explaining each setting
  - Examples for Slack, Discord, custom webhooks
  - Edge case documentation for rate limiting

- **homelab/README.md** - Added 425-line notification system documentation
  - Channel-by-channel setup guides
  - Trigger configuration examples
  - Security considerations
  - Comprehensive troubleshooting section
  - Edge case documentation

### Fixed

**Round 1 (3 critical bugs identified in code review):**

1. **Invalid JSON in Slack fallback payload** (HIGH severity)
   - Problem: Plain text with newlines and quotes embedded directly in JSON without escaping
   - Impact: Slack webhook calls failed with HTTP 400 due to malformed JSON
   - Fix: Created `json_escape()` function escaping backslashes, quotes, newlines, CR, tabs
   - Location: `homelab/lib/notifications.sh:16-25`

2. **Path redaction flag unused** (MEDIUM severity)
   - Problem: `HOMELAB_NOTIFY_REDACT_PATHS` flag read but never applied to output
   - Impact: Sensitive paths like `/Users/admin/homelab-logs/` leaked in all notifications
   - Fix: Applied redaction in both `format_notification_plain()` and `format_notification_slack()`
   - Location: `homelab/lib/notifications.sh:122-125, 182-185`

3. **Dry-run consuming rate limit** (MEDIUM severity)
   - Problem: `is_rate_limited()` always updated `LAST_NOTIFICATION_TIME`, even for dry-run tests
   - Impact: Running `homelab notify test --dry-run` prevented next real notification for 60s
   - Fix: Added `dry_run` parameter, only update timestamp when `dry_run != true`
   - Location: `homelab/lib/notifications.sh:61, 84-86`

**Round 2 (2 critical bugs identified in code review):**

4. **Failed step names lost in subshell** (HIGH severity)
   - Problem: Pipeline `echo | tr | while read` ran loop in subshell, message updates lost on exit
   - Impact: Notifications showed "Failed: 3" but never listed which steps failed
   - Fix: Replaced pipeline with array read `IFS=',' read -ra array` to avoid subshell
   - Location: `homelab/lib/notifications.sh:144-147`

5. **Start trigger never fired** (MEDIUM severity)
   - Problem: `start` trigger documented and handled by `should_notify()` but no workflow called it
   - Impact: Users enabling `start` trigger saw no effect, broken feature
   - Fix: Added start notification hook to all 4 workflows (morning, weekly, emergency, pre-deploy)
   - Location: `homelab/lib/workflows.sh:31-33, 96-98, 167-169, 248-250`

**Round 3 (1 critical bug identified in code review):**

6. **Start trigger consuming rate limit blocked completion** (HIGH severity)
   - Problem: Start notification updated `LAST_NOTIFICATION_TIME`, then completion fired seconds later and was rate-limited
   - Impact: Workflows <60s only sent start notification, never completion (defeating Phase 2.2's primary goal)
   - Fix: Modified `is_rate_limited()` to accept `trigger` parameter, skip timestamp update for `trigger == "start"`
   - Location: `homelab/lib/notifications.sh:62, 84-86`

### Documentation

- **Edge case documentation** - Cross-workflow rate limiting behavior
  - Start notifications don't consume rate limit but are subject to rate limit check
  - Intra-workflow: start → completion works correctly (primary use case)
  - Cross-workflow: completion → start may be blocked if workflows run <60s apart
  - Documented in: `homelab/lib/notifications.sh:61-65`, `homelab.conf:112-118`, `README.md:1056-1060`
  - Test coverage: `/tmp/test_cross_workflow_rate_limit.sh`
  - Workarounds: Reduce `HOMELAB_NOTIFY_MIN_INTERVAL_SECONDS`, disable `start` trigger, or schedule workflows >60s apart

### Testing

- **Raspberry Pi validation** (ARM64 Linux/Debian Bookworm)
  - Tested on 2× Raspberry Pi 5 systems (192.168.1.100, 192.168.1.250)
  - All phases verified: Config (1.1), Scheduling (2.1), Notifications (2.2)
  - Cross-platform compatibility confirmed: macOS (M1) vs Linux (ARM64)
  - Performance validated: <100ms config load, <1s workflow, <10MB memory
  - Linux-specific features tested: cron, systemd, notify-send, bash 5.2
  - Detailed report: `/tmp/PI_TEST_REPORT.md`

- **Comprehensive test suite**:
  - `/tmp/test_start_rate_limit.sh` - Rate limit bypass validation
  - `/tmp/test_start_trigger.sh` - Start trigger recognition
  - `/tmp/test_failed_steps.sh` - Failed steps rendering
  - `/tmp/test_json_escape.sh` - JSON escaping validation
  - `/tmp/test_notification_flow.sh` - End-to-end flow validation
  - `/tmp/test_cross_workflow_rate_limit.sh` - Edge case validation
  - All tests passed on both macOS and Linux

### Security

- **Secure log permissions** - Maintained throughout notification system
  - Log directory: 700 (owner-only access)
  - Log files: 600 (owner-only read/write)
  - Consistent with existing homelab security posture

- **Path redaction** - Privacy feature for notifications
  - Optional redaction of `$HOME` to `~` in log paths
  - Prevents sensitive path disclosure in external channels
  - Configurable via `HOMELAB_NOTIFY_REDACT_PATHS`

- **Webhook security** - Best practices for external integrations
  - Webhook URLs configured via environment/config (never hardcoded)
  - HTTPS-only recommendations in documentation
  - Circuit breakers prevent retry storms on failing endpoints

### Breaking Changes

- None (notifications are opt-in via `HOMELAB_NOTIFY_ENABLED=false` default)

### Known Limitations

- **Cross-workflow start notification edge case**: Start notifications from one workflow may be rate-limited if another workflow completed <60s prior. This is by design to prevent notification spam. See documentation for workarounds.
- **Desktop notifications require GUI**: macOS osascript and Linux notify-send require active desktop session (not available over SSH)
- **Email requires mail command**: Email notifications depend on system `mail` command with SMTP configuration

## [1.5.1] - 2025-11-17

### Fixed
- **ssh-key-audit.sh**: Critical risk scoring bugs that prevented high-severity issues from being scored:
  - **Token mismatch**: Risk engine expected `unsafe-options:value` and `duplicate:count` but audit emitted bare `unsafe-options` and `duplicate`, causing 35pt and 20pt issues to be invisible in risk scores. Now emits `unsafe-options:<options>` and `duplicate:<count>` matching scorer expectations.
  - **Pipe delimiter corruption**: Used single `|` as delimiter in keys_data serialization, but SSH key comments can contain `|` characters (e.g., "prod|blue"), causing record corruption and misattributed issues. Changed to `|||` (triple-pipe) delimiter to avoid conflicts.
  - Impact: Without these fixes, duplicate keys and unsafe options (two of the highest-severity conditions) were completely missing from risk_score/risk_level/risk_factors output, defeating core v1.5.0 functionality.

## [1.5.0] - 2025-11-17

### Added
- **ssh-key-audit.sh**: Comprehensive risk scoring system for prioritizing SSH key hygiene issues
  - Pure bash risk calculation engine (no jq dependency)
  - Configurable weights via config files or environment variables
  - Risk formula: `final_score = min(target_score + max_key_score, 100) × multiplier`
  - System multiplier (1.25×) for critical targets (/root, /etc/ssh)
  - Stale key buckets: 90/180/365 days (non-additive, uses >= threshold logic)
  - Risk levels: CRITICAL (85+), HIGH (50-84), MEDIUM (20-49), LOW (1-19), CLEAN (0)
  - Color-coded console summary showing risk distribution and top N risky targets
  - Detailed risk breakdown with `--risk-detail` flag
  - Config discovery priority: `--risk-config` → `./.ssh-audit.conf` → `~/.ssh-audit.conf` → `/etc/ssh-audit/config.conf`
  - New CLI flags: `--risk`, `--risk-detail`, `--risk-config PATH`
  - JSON output includes `risk_score`, `risk_level`, `risk_factors` fields when `--risk` enabled
  - Example config file: `examples/ssh-audit.conf`

### Changed
- **ssh-key-audit.sh**: Version bumped from 1.4.3 to 1.5.0
- **ssh-key-audit.sh**: Default risk weights:
  - ssh-rsa/ssh-dss weak crypto: 50 pts (critical)
  - Unsafe options: 35 pts
  - Bad .ssh permissions: 40 pts
  - Bad authorized_keys permissions: 35 pts
  - Stale 365+ days: 25 pts
  - Stale 180+ days: 15 pts
  - Stale 90+ days: 8 pts
  - Duplicate keys: 20 pts
  - Missing authorized_keys: 5 pts (informational)
  - NIST ECDSA curves: 0 pts (opt-in via config)

### Fixed
- N/A

### Breaking Changes
- None (risk scoring is opt-in via `--risk` flag)

## [1.4.3] - 2025-11-17

### Fixed
- **ssh-key-audit.sh**: Incomplete JSON traceability - Added `target_issues` array field to JSON output containing structured target-level warnings (ssh-dir-perms:XXX, auth-keys-perms:XXX, auth-keys-missing). This completes the v1.4.2 fix by making permission issues machine-readable for SIEM/CI automation.

### Added
- **ssh-key-audit.sh**: Console summary now shows "Targets with missing authorized_keys: N (informational)" when N > 0, ensuring operators are aware of missing key files even without --json flag

### Changed
- **ssh-key-audit.sh**: JSON schema now includes `target_issues` field in every target object (breaking change for JSON consumers)
- **ssh-key-audit.sh**: Missing authorized_keys files are tracked in JSON but do NOT increment warning counts or affect exit codes (informational only)

## [1.4.2] - 2025-11-16

### Fixed
- **ssh-key-audit.sh**: Incomplete certificate regex - Added `@openssh.com` suffix to FIDO certificate patterns (sk-ssh-ed25519@openssh.com-cert-v01@openssh.com, sk-ecdsa-sha2-nistp256@openssh.com-cert-v01@openssh.com) and added ssh-ed448-cert-v01@openssh.com support
- **ssh-key-audit.sh**: Early return JSON inconsistency - Targets with permission warnings but no authorized_keys file now properly appear in JSON output with `targets_with_issues` count matching actual issues
- **ssh-key-audit.sh**: Version string updated from 1.4.0 to 1.4.2

### Added
- **Test fixtures**: Enhanced tests/fixtures/ssh/charlie with FIDO certificate keys (sk-ssh-ed25519@openssh.com-cert-v01@openssh.com, sk-ecdsa-sha2-nistp256@openssh.com-cert-v01@openssh.com) and Ed448 certificate (ssh-ed448-cert-v01@openssh.com)
- **Test fixtures**: Added tests/fixtures/ssh/david for early-return edge case testing (user with .ssh permission issues but no authorized_keys file)

## [1.4.1] - 2025-11-16

### Fixed
- **ssh-key-audit.sh**: Parser coverage - Added support for modern OpenSSH key types (FIDO sk-*, certificates *-cert-v01@openssh.com, ssh-dss, ssh-ed448)
- **ssh-key-audit.sh**: Options parsing bug - Fixed greedy sed collision when comment repeats key type (e.g., "command='/bin/sync' ssh-ed25519 AAAA... ssh-ed25519 backup")
- **ssh-key-audit.sh**: JSON schema mismatch - Updated output to match documented schema (`targets` not `users`, added `home_root`, `system_targets_scanned`, `total_targets`, `targets_with_issues`, `is_system` per target)
- **ssh-key-audit.sh**: JSON string escaping - Escaped all string fields (target_user, path, log_file) not just comments, preventing parse errors on paths with spaces/quotes
- **ssh-key-audit.sh**: Whitespace handling - Added trim() to all comma/colon list parsing (--users, --forbid-types, --fail-on, --system-paths) to handle realistic inputs like "alice, bob"

### Added
- **Test fixtures**: tests/fixtures/ssh/charlie with FIDO, certificate, DSA keys and options collision test case

## [1.4.0] - 2025-11-16

### Added
- **ssh-key-audit.sh** - SSH key hygiene auditing and compliance validation
  - User-scoped audits with `--users` or `--all-users` under configurable `--home-root`
  - System-wide coverage with `--system` (includes `/etc/ssh/authorized_keys`, `/etc/ssh/authorized_keys.d`, `/root/.ssh/authorized_keys`)
  - Custom system paths via `--system-paths` (colon-separated)
  - Weak key detection with configurable `--forbid-types` (default: `ssh-rsa`)
  - Permission validation for `~/.ssh` (700) and `authorized_keys` (600)
  - Stale key detection with `--max-age` threshold (0 disables)
  - Duplicate detection via exact match on `keytype:base64blob`
  - Unsafe options detection (command=, from=, etc.)
  - Fail-on rules via `--fail-on` (weak-type, perms, stale, duplicate, unsafe-options)
  - JSON output with per-user key details and age tracking
  - Dry-run mode for preview
  - Exit codes: 0 (healthy), 1 (warnings), 2 (critical via --fail-on)
  - Bash 3.x compatible (macOS default bash)
  - Cross-platform permission checks (Linux stat -c, macOS stat -f)
  - Example: `examples/ssh-key-audit-example.sh`
  - Documentation: README section 12

### Changed
- N/A

### Fixed
- **ssh-key-audit.sh**: Missing user-visible warnings - Added `print_warning` calls for all issue types (weak-type, unsafe-options, stale, duplicate)
- **ssh-key-audit.sh**: Duplicate detection substring bug - Changed `grep -qF` to `grep -qFx` for exact matching
- **ssh-key-audit.sh**: Insufficient JSON escaping - Created comprehensive `json_escape()` function handling backslash, quotes, tab, CR, LF, and control characters
- **ssh-key-audit.sh**: System-only audit counter bug - Added `TOTAL_SYSTEM_TARGETS` tracking for accurate statistics
- **ssh-key-audit.sh**: Bash 3.x compatibility - Replaced `${var,,}` with `tr` for lowercase conversion
- **ssh-key-audit.sh**: Bash 3.x compatibility - Changed associative arrays to newline-separated strings
- **ssh-key-audit.sh**: Empty array handling - Added `[ -n "$FAIL_ON" ]` guards for `set -u` compliance

## [1.3.0] - 2025-11-16

### Added
- **smart-disk-check.sh** - S.M.A.R.T. monitoring and disk health alerts
  - Auto-discovery via `smartctl --scan`
  - Health attribute monitoring (pre-fail attributes: 5, 187, 188, 197, 198)
  - Temperature monitoring with configurable thresholds (default: warn 50°C, crit 60°C)
  - Optional short/long/conveyance test scheduling
  - Reallocated and pending sector detection
  - JSON output with per-device health status
  - Dry-run mode for preview
  - Exit codes: 0 (healthy), 1 (warnings), 2 (critical)
  - Graceful handling when smartctl not available
  - Example: `examples/smart-disk-check-example.sh`

- **new-vm-setup.sh** - VM bootstrapping and initial configuration
  - OS detection via `/etc/os-release` (Ubuntu, Debian, RHEL, CentOS, Fedora, Rocky, AlmaLinux)
  - Package manager auto-detection (apt-get, dnf, yum)
  - RFC-1123 hostname validation and configuration via `hostnamectl`
  - POSIX-compliant user creation with sudo/wheel group mapping
  - SSH public key setup with proper permissions (700/.ssh, 600/authorized_keys)
  - Package installation with idempotent checks (skip if already installed)
  - Optional dotfiles cloning from Git (https://, ssh://, git@ URLs)
  - Configurable login shell (default: /bin/bash)
  - Optional passwordless sudo with explicit security warning
  - Comprehensive input validation (hostname, username, SSH key, dotfiles URL)
  - Sudo transparency with interactive confirmation prompts
  - Idempotent operations (safe to re-run)
  - JSON output with installation summary
  - Dry-run mode for preview
  - Exit codes: 0 (success), 1 (warnings)
  - Secure logging in `./logs/new-vm-setup/` (mode 700)
  - Example: `examples/new-vm-setup-example.sh`

- **Release documentation**
  - Added `docs/releases/v1.3.0-release-notes.md` with comprehensive feature documentation
  - Phase 3 completion milestone

## [1.2.1] - 2025-11-14

### Added
- **Shared Functions Library** (`lib/common.sh`)
  - `get_iso8601_timestamp()` - BSD/GNU compatible timestamp function (solves macOS date portability)
  - `require_jq_if_json()` - Unified JSON dependency checking
  - `print_status()` - Reusable colored output functions
  - `validate_output_dir()` - Shared path validation with security checks
  - `ensure_docker_image()` - Docker image availability helper

- **Air-Gapped Environment Support**
  - compose-redeploy.sh: `--backup-image <img>` flag (default: alpine:latest)
  - docker-volume-backup.sh: `--backup-image <img>` flag (default: alpine:latest)
  - Allows custom helper images for offline/restricted environments

### Changed
- **Policy Compliance - `set -u` Only**
  - Updated all Phase 0/1 scripts to use `set -u` (removed `set -euo pipefail`):
    - rclone-sync.sh, update-all.sh, service-health-check.sh, disk-cleanup.sh
  - Aligns with repository policy to allow cleanup continuation on non-critical errors

- **Portability Improvements**
  - All Phase 1/2 scripts now use `get_iso8601_timestamp()` instead of `date -Iseconds`
  - Fixes timestamp failures on macOS BSD date (falls back gracefully)

- **Code Reuse and Consistency**
  - All Phase 1/2 scripts now source `lib/common.sh`
  - Replaced ad-hoc jq checks with unified `require_jq_if_json()`
  - Replaced manual Docker image pulls with `ensure_docker_image()`
  - Removed duplicate `validate_output_dir()` from docker-volume-backup.sh

### Fixed
- Timestamp portability on macOS (BSD date doesn't support `-Iseconds`)
- Code duplication across Phase 2 scripts

## [1.2.0] - 2025-11-13

### Added
- **compose-redeploy.sh** - Safe Docker Compose updates with rollback
  - Pre-flight compose file validation
  - Optional volume backup before deployment
  - Image pull with progress tracking
  - Health check validation after deployment
  - Automatic rollback on failure
  - Support for both Compose v1 (docker-compose) and v2 (docker compose)
  - Configurable health check timeout (default: 60s, range: 1-3600s)
  - Volume backup using helper containers
  - Detailed logging in `./logs/compose-redeploy/` (mode 700)
  - JSON summary output
  - Dry-run mode for preview
  - Example: `examples/compose-redeploy-example.sh` and `examples/test-app-compose.yml`

- **docker-volume-backup.sh** - Consistent Docker volume snapshots
  - Backup individual volumes or all volumes
  - Optional container stop/restart for consistency
  - Tar.gz compression via helper container
  - Automatic container restart after backup
  - Container dependency detection (which containers use which volumes)
  - Detailed logging in `./logs/volume-backup/` (mode 700)
  - JSON summary output with backup sizes
  - Dry-run mode for preview
  - Example: `examples/docker-volume-backup-example.sh`

- **dyndns-update.sh** - Dynamic DNS updates for homelabs
  - Cloudflare DNS API integration
  - Public IP detection with fallback sources (ifconfig.me, icanhazip.com, ipinfo.io, ipify.org)
  - IP caching to avoid unnecessary API calls
  - Rate limiting (max 1 update per 5 minutes)
  - Configurable TTL (default: 300s, range: 60-86400s)
  - Secure token handling via environment variables
  - Automatic DNS record creation if not exists
  - Support for apex (@) and subdomain records
  - Detailed logging in `./logs/dyndns/` (mode 700)
  - JSON summary output
  - Dry-run mode for preview
  - Example: `examples/dyndns-update-example.sh`

### Fixed
- **Policy compliance** - All Phase 2 scripts updated to use `set -u` only (removed `set -e` per CLAUDE.md)
- **Dependency management** - compose-redeploy now checks for jq before using `--json`
- **Image availability** - compose-redeploy and docker-volume-backup pre-check/pull alpine:latest
- **Path security** - docker-volume-backup now validates output paths (blocks system dirs, requires $HOME)
- **Documentation** - Removed duplicate CHANGELOG [1.1.1] section; added jq dependency note to README

## [1.1.1] - 2025-11-13

### Security

**Critical Fixes:**
- **db-backup.sh: MySQL password exposure** (CVSS 7.5)
  - Changed from `--password=` CLI arg to secure `--defaults-extra-file` with mktemp
  - Credentials file created with chmod 600 and cleaned up after use
  - Impact: Prevents password leakage via process listing (ps aux)

- **db-backup.sh: Output path validation** (CVSS 7.5)
  - Added `validate_output_dir()` function with path canonicalization
  - Blocks system directories: /usr, /etc, /var, /bin, /sbin, /boot, /sys, /proc, /dev
  - Requires paths under $HOME or relative (./)
  - Detects and rejects path traversal sequences (/../)
  - Impact: Prevents unauthorized writes to system directories

**Medium Fixes:**
- **db-backup.sh: Retention bounds validation** (CVSS 5.3)
  - Daily retention: 1-3650 days
  - Weekly retention: 1-520 weeks
  - Monthly retention: 1-360 months
  - Impact: Prevents DoS through extreme retention values

### Changed
- **db-backup.sh**: Enhanced DSN parsing
  - Support IPv6 addresses with brackets: `postgres://user:pass@[::1]:5432/db`
  - URL decode percent-encoded credentials (%20, %40, etc.)
  - Strip query parameters (?sslmode=require) automatically
  - Better error messages showing supported formats

### Fixed
- **examples/db-backup-example.sh**: Changed `/var/backups/mysql` to `$HOME/backups/mysql` to comply with security policy

## [1.1.0] - 2025-11-13

### Added
- **cert-renewal-check.sh** - SSL certificate expiry monitoring and renewal
  - Check domain certificates via HTTPS connection
  - Inspect local certificate files
  - Configurable warning threshold (default: 30 days, range: 1-365)
  - Table and JSON output formats
  - Optional certbot auto-renewal integration
  - Dry-run mode for testing
  - Cross-platform (macOS/Linux)
  - Secure logging in `./logs/cert/` (mode 700)
  - Example config: `examples/domains.txt`

- **db-backup.sh** - Automated database backups with retention policies
  - PostgreSQL and MySQL support with DSN-based configuration
  - Configurable retention (daily:weekly:monthly format, default: 7:4:12)
  - Automatic compression with gzip
  - Optional rclone cloud sync for off-site backups
  - Test restore validation (PostgreSQL only)
  - Table and JSON output formats
  - Dry-run mode for testing
  - DSN password masking in all output
  - Cross-platform (macOS/Linux)
  - Secure logging in `./logs/db-backup/` (mode 700)
  - Example usage: `examples/db-backup-example.sh`

- **service-health-check.sh** - Config-driven uptime monitoring
  - HTTP endpoint checks with status code and body validation
  - TCP port connectivity checks
  - Process monitoring via pgrep
  - Docker container status checks
  - Watch mode with continuous monitoring (configurable interval)
  - State tracking with change detection
  - Webhook notifications on state changes
  - INI-style configuration format
  - Table and JSON output formats
  - Dry-run mode for config validation
  - Graceful degradation for unavailable check types
  - Cross-platform (macOS/Linux)
  - Secure logging in `./logs/` (mode 700)
  - Example config: `examples/services.conf`

### Fixed
- **disk-cleanup.sh**: Fixed unbound variable error in manifest check for `--scan-venvs`
  - Added default value check: `${#MANIFEST_OPERATIONS[@]:-0}`

## [1.0.1] - 2025-11-12

### Security

**Critical Fixes:**
- **Temp file race conditions** - Replaced all predictable `/tmp/` files with `mktemp` (CVSS 7.1)
  - Fixed: `docker_cleanup.log`, `brew_cleanup.log`, `pnpm_cleanup.log`, `pip_cleanup.log`
  - Fixed: `dockerd.out` with secure temp file generation
  - Impact: Prevents symlink attacks and file overwrite vulnerabilities
- **Path traversal protection** - Added validation for `--venv-roots` parameter (CVSS 7.5)
  - Multiple fallbacks for path canonicalization: `realpath`, `readlink -f`, `python3`
  - Rejects paths with traversal sequences (`/../`, `/..`) if no canonicalization available
  - Validates paths are under `$HOME` after canonicalization
  - Prevents system directory access (`/usr`, `/etc`, `/var`, `/bin`, `/sbin`)
  - Impact: Prevents unauthorized file deletion outside intended directories

**Medium Fixes:**
- **Bounds checking** - Added validation ranges for numeric parameters (CVSS 5.3)
  - `--gc-threshold`: 0.1 to 1000 GB
  - `--venv-age`: 1 to 3650 days
  - `--venv-min-gb`: 0.01 to 100 GB
  - Impact: Prevents DoS through resource exhaustion
- **Secure log permissions** - Implemented secure log file creation (CVSS 4.4)
  - Set `umask 077` for log files (owner read/write only)
  - Log directory permissions: `700`
  - New log files: `-rw-------` (600)
  - Impact: Prevents information disclosure
- **Explicit sudo warnings** - Added warnings before privilege escalation (CVSS 6.7)
  - User informed before Docker daemon operations
  - Clear listing of operations requiring sudo
  - Interactive confirmation in non-dry-run mode
  - Impact: Prevents silent privilege escalation

### Changed
- Improved error messages for security validation failures
- Enhanced input validation with detailed bounds information

## [1.0.0] - 2025-11-12

### Added

**disk-cleanup.sh:**
- Virtualenv cleanup feature with `--scan-venvs` and `--clean-venvs` flags
- Smart git gc with dual heuristics (pack size >= 1GB OR age >= 30 days)
- Live disk gauge with real-time progress tracking (`--gauge` / `--no-gauge`)
- Fun facts between sections for better UX (`--no-fun` to disable)
- Configurable git gc thresholds (`--gc-threshold`, `--gc-max-age`)
- Docker startup control (`--docker-wait`, `--skip-docker`)
- Comprehensive interrupt handling (graceful Ctrl+C with force option)
- Manifest-based audit trail in JSON format
- Desktop notifications on completion (macOS/Linux)

**smart-cleanup.sh:**
- Virtualenv flag passthrough to disk-cleanup.sh
- Enhanced dry-run mode with detailed preview

**update-all.sh:**
- PEP 668 compliance for externally-managed Python environments
- TTY detection for cron/CI compatibility
- Configurable pip system updates (`--pip-system` flag)

**Documentation:**
- LICENSE (MIT)
- CODE_OF_CONDUCT.md (Contributor Covenant 2.1)
- SECURITY.md (vulnerability reporting, PEP 668 notes)
- CONTRIBUTING.md (setup, checks, pre-commit hook guidance)
- Comprehensive README.md with all flags and examples

### Fixed

- Gauge process race condition (removed misleading GAUGE_RUNNING flag, added proper wait)
- Fun facts frequency (reduced from ~10 to ~3-4 per run)
- Unsafe rm in venv cleanup (added `${vdir:?}` protection)
- SC2069 redirect order in update-all.sh (4 occurrences)
- SC2024 sudo redirect in disk-cleanup.sh
- Input validation for venv flags (--venv-age, --venv-min-gb)
- VENV_ROOTS parsing (changed to colon-separated for paths with spaces)
- PEP 668 pip flags (changed from scalar to array for proper quoting)

### Changed

- Moved logs from `/tmp/` to `$SCRIPT_DIR/logs/` for persistence
- Moved manifest files to logs directory
- Moved notify_complete function to functions section
- Added `-maxdepth 5` to virtualenv scanning for performance
- Improved error handling throughout all scripts

### Security

- Hardened venv removal with variable expansion protection
- Input validation on all numeric parameters
- Proper sudo usage in Docker daemon startup
- Safe defaults for PEP 668 (system pip updates disabled by default)

## [0.9.0] - 2025-11-09

### Added

- Initial release with core functionality
- disk-cleanup.sh: VS Code, Docker, Git, Homebrew, NPM, Playwright, pnpm, pip, AWS CLI cleanup
- rclone-sync.sh: Background sync with Google Drive
- smart-cleanup.sh: Combined cleanup orchestration
- update-all.sh: System-wide package updates

---

**Legend:**
- **Added**: New features
- **Changed**: Changes to existing functionality
- **Deprecated**: Soon-to-be removed features
- **Removed**: Removed features
- **Fixed**: Bug fixes
- **Security**: Security improvements
