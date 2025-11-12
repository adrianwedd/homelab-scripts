# Repository Guidelines for AI Agents

## Project Structure & Modules

- **Root**: Executable Bash scripts: `disk-cleanup.sh`, `rclone-sync.sh`, `nmap-scan.sh`, `smart-cleanup.sh`, `update-all.sh`
- **Documentation**: `README.md`, `CLAUDE.md`, `GEMINI.md`, `AGENTS.md`, `SECURITY.md`, `CONTRIBUTING.md`
- **Logs**: `./logs/` (Git-ignored, secure perms 700) - all cleanup/update logs and manifests
- **CI/CD**: `.github/workflows/` - shellcheck, shfmt, smoke tests
- **Hooks**: `.githooks/pre-commit` - local validation before commit

## Build, Test, and Dev Commands

### Basic Usage
```bash
# Interactive cleanup
./disk-cleanup.sh

# Dry run (preview only)
./disk-cleanup.sh --dry-run

# Quick reclaim (skip slow git gc)
./disk-cleanup.sh -y --skip-git-gc --no-gauge --no-fun

# Smart GC (only large/old repos)
./disk-cleanup.sh -y --smart-gc --gc-threshold 1
```

### New Flags (v1.0.1)
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

### Background Sync
```bash
# Start/stop/status
./rclone-sync.sh --start
./rclone-sync.sh --status
./rclone-sync.sh --stop

# View logs
./rclone-sync.sh --logs 100
tail -f ~/rclone-sync.log
```

### Network Discovery
```bash
# Fast scan (auto-detect CIDR)
./nmap-scan.sh

# Multi-subnet full scan
./nmap-scan.sh --cidr "192.168.1.0/24,10.0.0.0/24" --full

# Exclude hosts and limit rate
./nmap-scan.sh --exclude "192.168.1.10" --rate 50

# JSON only, no delta
./nmap-scan.sh --output json --no-delta

# Dry run
./nmap-scan.sh --cidr "192.168.1.0/24" --dry-run
```

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

## Agent Expectations & Approvals

- Always prefer `./logs/` for writing logs; never write to `/tmp` for persistent logs.
- Use dry-run modes by default (`--dry-run`, `--status`, `--help`) when testing.
- When installing dependencies or accessing network/SSH, request approval first.
- Respect cross-platform constraints (macOS vs Linux) and avoid assumptions about available daemons.
- When unsure, surface a short plan and ask before running long or destructive commands.

## Coding Style & Naming

### Language & Structure
- **Language**: Bash (`#!/bin/bash`)
- **Indentation**: 4 spaces; wrap lines > 100 chars thoughtfully
- **Naming**:
  - Files: `kebab-case` (`disk-cleanup.sh`)
  - Functions: `snake_case` (`safe_remove`, `bytes_to_human`)
  - Constants: `UPPER_SNAKE` (`TOTAL_FREED_BYTES`)
- **Flags**: Long options (`--dry-run`, `--status`, `--venv-age`)

### Patterns Used
- **Colored output**: `print_info`, `print_success`, `print_warning`, `print_error`
- **Sections**: `print_section "Cleaning Docker"`
- **Safety**: Use `set -u` but NOT `set -e`; check tools with `command -v`
- **Arrays over scalars**: Prefer `pip_flags=("--break-system-packages")` over `PIP_FLAG="--break-system-packages"`

### ShellCheck Policy
- **Exclude SC2034**: Unused variables (ok if documented/reserved)
- **Exclude SC2155**: Declare and assign separately (non-critical style)
- **All other warnings**: Treated as errors

## Testing Guidelines

### Local Testing
```bash
# Dry run patterns (used by CI)
./disk-cleanup.sh --dry-run -y --no-gauge --no-fun
./update-all.sh --dry-run
./smart-cleanup.sh --status

# Help flags (smoke test)
./disk-cleanup.sh --help
./smart-cleanup.sh --help
./update-all.sh --help
```

### Validation Checklist
- Run `shellcheck -S warning -e SC2034,SC2155 *.sh`
- Run `bash -n *.sh` for syntax
- Test with `--dry-run` for safety
- Check logs in `./logs/` for errors
- Verify secure permissions: `ls -la logs/` (should show `drwx------`)
 - If emitting JSON: verify `logs/disk_cleanup_summary_*.json` exists and is valid JSON

### Security Testing
```bash
# Test bounds checking
./disk-cleanup.sh --gc-threshold 9999999  # Should reject
./disk-cleanup.sh --venv-age 99999        # Should reject

# Test path validation
./disk-cleanup.sh --venv-roots "/etc"          # Should reject
./disk-cleanup.sh --venv-roots "$HOME/../etc"  # Should reject
```

## Pre-commit Hook

### Activation
```bash
ln -sf ../../.githooks/pre-commit .git/hooks/pre-commit
```

### What It Checks
1. **ShellCheck**: Blocks on errors (excluding SC2034, SC2155)
2. **shfmt**: Warns on format issues (doesn't block)
3. **bc usage**: Blocks (use awk instead)
4. **Unsafe patterns**: Warns on unprotected `rm` commands

### Dependencies
```bash
brew install shellcheck shfmt  # macOS
apt install shellcheck shfmt   # Linux
```

## Security & Safety (v1.0.1)

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

## Commit & Pull Requests

### Commit Messages
Use imperative, scoped messages (Conventional Commits style):
```
feat(venv): add virtualenv cleanup with age/size thresholds
fix(docker): handle daemon startup timeout gracefully
security: replace predictable temp files with mktemp
docs: update CLAUDE.md with v1.0.1 features
```

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

## Configuration & External Deps

### Dependencies
- **Required**: `bash`, `git`, `awk`, `sed`, `grep`, `du`, `df`
- **Optional**:
  - `rclone` (backup sync)
  - `nmap` (network discovery)
  - `docker` (Docker cleanup)
  - `coreutils` (macOS timeout protection)
  - `shellcheck`, `shfmt` (development)

### Configuration Files
- `~/.rclone-exclude`: rclone exclusions (auto-generated)
- `./logs/`: All cleanup/update logs (Git-ignored)
- `.github/workflows/`: CI configuration

### Never Commit
- Secrets or credentials
- Personal paths (beyond `$HOME` examples)
- Log files
- PID files
- Temporary files

## Troubleshooting

### Common Issues

**Gauge not visible over SSH:**
```bash
./disk-cleanup.sh --no-gauge --no-fun
```

**Docker not starting:**
```bash
# Start manually
open -a Docker  # macOS
sudo systemctl start docker  # Linux

# Or skip Docker
./disk-cleanup.sh --skip-docker
```

**Path validation errors:**
- Venv roots must be under `$HOME`
- Use colon-separated paths: `"$HOME/repos:$HOME/projects"`
 - Paths with spaces are allowed when quoted; separate multiple roots with colons

**ShellCheck warnings:**
- SC2034/SC2155 are excluded per policy
- All other warnings must be fixed

## CI/CD Integration

### GitHub Actions
Workflows run on every push/PR:
- **ShellCheck**: `shellcheck -S warning -e SC2034,SC2155 *.sh`
- **shfmt**: Format check (warns only)
- **Smoke tests**: Syntax, `--help`, `--dry-run`

### Status Badges
```markdown
[![ShellCheck](https://github.com/USER/scripts/workflows/ShellCheck/badge.svg)]
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)]
```

See `CONTRIBUTING.md` for detailed contribution guidelines.
