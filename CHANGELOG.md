# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added - v1.1.0 (In Progress)
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

### Fixed - v1.1.0 (In Progress)
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
