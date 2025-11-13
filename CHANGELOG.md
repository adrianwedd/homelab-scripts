# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

## [1.1.1] - 2025-11-13

### Security
- MySQL password exposure fix (CVSS 7.5)
  - Switched from CLI password arg to secure temp defaults file (`--defaults-extra-file`)
  - Prevents process list password leakage
- Output path validation (CVSS 7.5)
  - Blocked system directories (`/usr`, `/etc`, `/var`, `/bin`, `/sbin`, etc.)
  - Require output paths under `$HOME` with traversal protection and canonicalization
- Retention bounds checking (CVSS 5.3)
  - Enforce ranges: daily 1–3650, weekly 1–520, monthly 1–360
  - Prevents DoS via extreme retention values
- Enhanced DSN parsing
  - IPv6 `[::1]` support
  - URL-encoded credentials decoding
  - Query parameter stripping (e.g., `?sslmode=require`)
- Example fix
  - Updated MySQL example output path to `$HOME/backups/mysql`

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
