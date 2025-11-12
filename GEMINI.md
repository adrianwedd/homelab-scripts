# Guidance for Gemini

## Purpose

This document provides guidance for Gemini when working in this repository of shell scripts for system maintenance, focusing on disk cleanup and remote backups. The scripts are cross-platform (macOS/Linux) and designed for both interactive and automated use.

## Repository Structure

- **Root**: Executable Bash scripts
  - `disk-cleanup.sh`: Comprehensive disk space recovery (Docker, VS Code, Git, Homebrew, npm, pip, etc.)
  - `rclone-sync.sh`: Intelligent backup sync to remote storage (Google Drive via rclone)
  - `nmap-scan.sh`: Network discovery and change tracking with delta analysis
  - `smart-cleanup.sh`: Combined cleanup orchestration
  - `update-all.sh`: System-wide package updates
- **Logs**: `./logs/` (Git-ignored, secure permissions 700) - all cleanup/update logs and manifests
- **Documentation**: README.md, CLAUDE.md, GEMINI.md, AGENTS.md, SECURITY.md, CONTRIBUTING.md
- **CI/CD**: `.github/workflows/` - shellcheck, shfmt, smoke tests
- **Hooks**: `.githooks/pre-commit` - local validation before commit

## Building and Running

These are shell scripts and do not require a build process. They can be executed directly.

### `disk-cleanup.sh`

**Basic Usage:**
```bash
# Interactive cleanup
./disk-cleanup.sh

# Non-interactive cleanup
./disk-cleanup.sh -y

# Preview cleanup (dry run)
./disk-cleanup.sh --dry-run
```

**New Flags (v1.0.1):**
```bash
# Virtualenv management
./disk-cleanup.sh --scan-venvs
./disk-cleanup.sh --clean-venvs --venv-age 60 --venv-min-gb 1
./disk-cleanup.sh --venv-roots "$HOME/repos:$HOME/projects"

# Docker control
./disk-cleanup.sh --docker-wait 120  # Wait longer for Docker startup
./disk-cleanup.sh --skip-docker      # Skip Docker entirely (headless/cron)

# Git GC control
./disk-cleanup.sh --smart-gc --gc-threshold 2  # Only repos >= 2GB
./disk-cleanup.sh --full-gc                    # Force GC on all repos

# UX control
./disk-cleanup.sh --no-gauge  # Disable live gauge (SSH/cron)
./disk-cleanup.sh --no-fun    # Disable fun facts
```

**JSON Output:**
```bash
# Emit a machine-readable summary (saved under ./logs/)
./disk-cleanup.sh --dry-run --json
```

### `rclone-sync.sh`

```bash
# Start background sync
./rclone-sync.sh --start

# Check sync status
./rclone-sync.sh --status

# Stop sync
./rclone-sync.sh --stop

# View logs
./rclone-sync.sh --logs 100
tail -f ~/rclone-sync.log
```

## Safe Operations Checklist

When working with these scripts, always follow these safety practices:

- **Always test with --dry-run first** - Preview changes before executing
- **Understand Docker constraints**:
  - macOS: Requires GUI (`open -a Docker`), cannot autostart in headless/SSH/cron
  - Linux: Requires sudo for systemctl/service/dockerd
  - Use `--skip-docker` in non-interactive/cron environments
- **Don't delete virtualenvs without confirmation**:
  - Use `--scan-venvs` to preview before using `--clean-venvs`
  - Verify size and age thresholds are reasonable for your environment
- **Respect secure logging**:
  - All logs under `./logs/` with umask 077 (owner-only read/write)
  - Directory permissions: 700
  - New log files: -rw------- (600)
  - JSON summaries: `logs/disk_cleanup_summary_*.json`
- **Validate paths**:
  - Virtualenv roots must be under `$HOME`
  - System directories (`/usr`, `/etc`, `/var`, `/bin`, `/sbin`) are blocked
- **Check bounds**:
  - `--gc-threshold`: 0.1-1000 GB
  - `--venv-age`: 1-3650 days
  - `--venv-min-gb`: 0.01-100 GB

## Useful Recipes

### Virtualenv Management
```bash
# Scan for old/large virtualenvs
./disk-cleanup.sh --scan-venvs

# Clean virtualenvs older than 60 days and >= 1GB
./disk-cleanup.sh --clean-venvs --venv-age 60 --venv-min-gb 1

# Specify custom virtualenv roots
./disk-cleanup.sh --scan-venvs --venv-roots "$HOME/repos:$HOME/projects"
```

### Quick Disk Reclaim
```bash
# Fast cleanup (skip slow git gc)
./disk-cleanup.sh -y --skip-git-gc

# Non-interactive with no UX features (ideal for cron/SSH)
./disk-cleanup.sh -y --skip-git-gc --no-gauge --no-fun

# JSON summary for dashboards
./disk-cleanup.sh --dry-run --json
```

### Smart Git GC (20-30x faster than full GC)
```bash
# GC only repos >= 1GB or 30+ days old
./disk-cleanup.sh -y --smart-gc --gc-threshold 1

# Off-hours GC (threshold 1GB, no gauge/fun)
./disk-cleanup.sh -y --smart-gc --gc-threshold 1 --no-gauge --no-fun
```

### Docker Management
```bash
# Wait longer for Docker startup
./disk-cleanup.sh --docker-wait 120

# Skip Docker entirely (headless/cron)
./disk-cleanup.sh --skip-docker
```

## Coding & PR Guidelines

### Shell Style
- **Language**: Bash (`#!/bin/bash`)
- **Indentation**: 4 spaces; wrap lines > 100 chars thoughtfully
- **Naming**:
  - Files: `kebab-case` (`disk-cleanup.sh`)
  - Functions: `snake_case` (`safe_remove`, `bytes_to_human`)
  - Constants: `UPPER_SNAKE` (`TOTAL_FREED_BYTES`)
- **Flags**: Long options (`--dry-run`, `--status`, `--venv-age`)
- **Patterns**:
  - Colored output: `print_info`, `print_success`, `print_warning`, `print_error`
  - Sections: `print_section "Cleaning Docker"`
  - Safety: Use `set -u` but NOT `set -e`; check tools with `command -v`
  - Arrays over scalars: Prefer `pip_flags=("--break-system-packages")` over `PIP_FLAG="--break-system-packages"`

### ShellCheck Requirements
- **Exclude SC2034**: Unused variables (ok if documented/reserved)
- **Exclude SC2155**: Declare and assign separately (non-critical style)
- **All other warnings**: Treated as errors
- **Run before commit**: `shellcheck -S warning -e SC2034,SC2155 *.sh`

### Quality Assurance
```bash
# ShellCheck (policy: exclude SC2034, SC2155)
shellcheck -S warning -e SC2034,SC2155 *.sh

# Format check (4-space indent)
shfmt -d -i 4 *.sh

# Syntax validation
bash -n *.sh

# Pre-commit hook activation
ln -sf ../../.githooks/pre-commit .git/hooks/pre-commit
```

### CI Expectations
- GitHub Actions run on every push/PR:
  - **ShellCheck**: `shellcheck -S warning -e SC2034,SC2155 *.sh`
  - **shfmt**: Format check (warns only)
  - **Smoke tests**: Syntax, `--help`, `--dry-run`
- All checks must pass before merge

### PR Checklist
- [ ] Summary, rationale, and impact described
- [ ] Before/after sample output (or log snippets)
- [ ] Validation steps (commands to reproduce/test)
- [ ] Linked issue (if applicable)
- [ ] Ran `shellcheck -S warning -e SC2034,SC2155 *.sh`
- [ ] Ran `bash -n *.sh`
- [ ] Tested with `--dry-run`
- [ ] Reviewed security implications
- [ ] Updated documentation (README, CLAUDE.md, CHANGELOG)

## Security (v1.0.1)

### Security Hardening
- **Secure logs**: `umask 077` set; logs dir `700`, files `600`
- **mktemp usage**: All temp files use `mktemp` (no predictable `/tmp/` files)
- **Path validation**: Venv roots must be under `$HOME`; system dirs blocked
- **Bounds checking**: All numeric params have validation ranges
- **Sudo transparency**: Explicit warnings before Docker privilege escalation

### Path Validation Rules
- **Allowed**: Any path under `$HOME`
- **Blocked**: `/usr`, `/etc`, `/var`, `/bin`, `/sbin`
- **Format**: Colon-separated for multiple paths
- **Canonicalization**: Uses `realpath`, fallback to `readlink -f`, fallback to `python3`

### Bounds Checking
- `--gc-threshold`: 0.1-1000 GB
- `--venv-age`: 1-3650 days
- `--venv-min-gb`: 0.01-100 GB

### Docker Behavior
- **macOS**: Attempts `open -a Docker` (GUI required)
- **Linux**: Requires sudo for `systemctl`/`service`/`dockerd`
- **Warnings**: Scripts warn and ask for confirmation before sudo
- **Recommendation**: Use `--skip-docker` in headless/cron environments

## Don'ts

### Prohibited Operations
- **Don't edit files outside `$HOME`**: All cleanup operations are designed to work under user directories only. System directories are explicitly blocked for safety.
- **Don't change ShellCheck policy**: The exclusion of SC2034 and SC2155 is intentional. All other warnings must be addressed.
- **Don't force Docker on non-GUI macOS**: Docker Desktop requires a GUI session. Use `--skip-docker` in SSH/cron environments.
- **Don't commit secrets**: Never commit credentials, personal paths (beyond `$HOME` examples), log files, PID files, or temporary files.
- **Don't skip --dry-run testing**: Always test with `--dry-run` before running cleanup operations, especially with new flags.
- **Don't use predictable temp files**: All temporary files must use `mktemp` for security (symlink attack prevention).
- **Don't bypass path validation**: The venv root validation is a security feature. Never modify code to allow paths outside `$HOME`.
- **Don't ignore bounds checking failures**: Bounds checking prevents resource exhaustion. Adjust your thresholds to within valid ranges instead of bypassing validation.

### Development Constraints
- **Never use `bc`**: Use `awk` for arithmetic instead (enforced by pre-commit hook)
- **Never use `set -e`**: Scripts use explicit error checking instead of errexit
- **Never commit unformatted code**: Run `shfmt -d -i 4 *.sh` before committing
- **Never skip CI checks**: All ShellCheck and smoke tests must pass

## Troubleshooting

### Gauge not visible over SSH
```bash
./disk-cleanup.sh --no-gauge --no-fun
```

### Docker not starting
```bash
# Start manually
open -a Docker  # macOS
sudo systemctl start docker  # Linux

# Or skip Docker
./disk-cleanup.sh --skip-docker
```

### Path validation errors
- Venv roots must be under `$HOME`
- Use colon-separated paths: `"$HOME/repos:$HOME/projects"`

### ShellCheck warnings
- SC2034/SC2155 are excluded per policy
- All other warnings must be fixed

## Dependencies

### Required
- `bash`, `git`, `awk`, `sed`, `grep`, `du`, `df`

### Optional
- `rclone` (backup sync)
- `nmap` (network discovery)
- `docker` (Docker cleanup)
- `coreutils` (macOS timeout protection)
- `shellcheck`, `shfmt` (development)

## Configuration Files

- `~/.rclone-exclude`: rclone exclusions (auto-generated)
- `./logs/`: All cleanup/update logs (Git-ignored)
- `.github/workflows/`: CI configuration

See `CONTRIBUTING.md` for detailed contribution guidelines and `README.md` for comprehensive usage documentation.
