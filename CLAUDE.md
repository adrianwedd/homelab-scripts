# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

A collection of Bash system maintenance and homelab DevOps scripts for macOS/Linux. Scripts cover disk cleanup, system updates, network scanning, Docker management, SSH auditing, certificate monitoring, database backups, and more. All scripts support `--dry-run`, `--help`, and structured JSON output.

## Architecture

### Script Organization

**Root scripts** (independently executable):

| Script | Purpose |
|--------|---------|
| `auth-log-audit.sh` | SSH authentication log analysis and threat detection |
| `backup-verify.sh` | Verify backup integrity, recency, and completeness |
| `cert-renewal-check.sh` | SSL certificate expiry monitoring |
| `ci-health-audit.sh` | GitHub Actions workflow analysis across repositories |
| `compose-redeploy.sh` | Docker Compose updates with volume backup and rollback |
| `cron-audit.sh` | Audit cron jobs and systemd timers for issues |
| `db-backup.sh` | Database backups (PostgreSQL, MySQL) with retention and cloud sync |
| `deploy-scripts.sh` | Sync this repository to remote hosts (git or rsync) |
| `disk-assistant.sh` | Interactive Claude Code session for guided disk cleanup |
| `disk-cleanup.sh` | Cache cleanup (VS Code, Docker, Git, Homebrew, NPM, pip, virtualenvs) |
| `docker-health.sh` | Docker container health, image inventory, and disk report |
| `docker-volume-backup.sh` | Docker volume snapshots with compression |
| `dyndns-update.sh` | Dynamic DNS updates for changing IPs |
| `firewall-audit.sh` | UFW/iptables rule audit against baseline |
| `log-manager.sh` | Log rotation, compression, and retention management |
| `media-stats.sh` | Plex library codec analysis and re-encode candidates |
| `minecraft-manager.sh` | Minecraft server lifecycle (start/stop/backup/monitor) |
| `network-monitor.sh` | Latency, packet loss, and DNS monitoring with timeseries |
| `new-vm-setup.sh` | Bootstrap fresh VMs with standard configuration |
| `nmap-scan.sh` | Network discovery and change tracking with delta analysis |
| `package-cve-check.sh` | Check installed packages for known CVEs (Debian/Ubuntu) |
| `plex-cleanup.sh` | Plex Media Server cache and duplicate cleanup |
| `qa-all.sh` | Unified QA harness (shellcheck, shfmt, syntax, dry-run) |
| `rclone-sync.sh` | Background daemon for continuous Google Drive backup |
| `secrets-scan.sh` | Scan git repositories for accidentally committed secrets |
| `service-health-check.sh` | Config-driven uptime monitoring |
| `smart-cleanup.sh` | Interactive wrapper around disk-cleanup.sh with analysis UI |
| `smart-disk-check.sh` | S.M.A.R.T. monitoring and disk health alerts |
| `ssh-key-audit.sh` | SSH authorized_keys hygiene and risk scoring |
| `system-monitor.sh` | CPU, memory, disk, and process resource monitoring |
| `update-all.sh` | System-wide package manager updates (Homebrew, NPM, pnpm, pip, gem, macOS) |

**Shared library** (`lib/common.sh`):
- Sourced by most scripts via `source "${SCRIPT_DIR}/lib/common.sh"`
- Provides: `print_status`, `validate_output_dir`, `ensure_docker_image`, `acquire_lock`/`release_lock`, `load_script_config_chain`, `apply_env_overrides`, `get_iso8601_timestamp`, `require_jq_if_json`
- Config precedence: defaults < system (`/etc/homelab-scripts.conf`) < user (`~/.config/homelab-scripts/`) < env vars < CLI flags

**Homelab orchestrator** (`homelab/`):
- `homelab/homelab.sh` - Unified CLI that composes root scripts into workflows
- `homelab/lib/` - Modular libraries: `config.sh`, `logger.sh`, `workflows.sh`, `status.sh`, `notifications.sh`, `scheduler.sh`, `conditions.sh`, `state.sh`, `report.sh`
- Workflows: `morning`, `weekly`, `emergency`, `pre-deploy`
- Features: smart script detection, graceful degradation, scheduling (cron/launchd), multi-channel notifications (Slack, webhooks, macOS native, email)
- Config: `~/.config/homelab/homelab.conf`

### Key Design Patterns

- **Error handling**: Scripts use `set -u` but NOT `set -e` to allow continue-on-failure
- **Tool detection**: Check with `command -v` before use; skip gracefully if unavailable
- **Logging**: Timestamped files in `./logs/` with `umask 077`, directory 700, files 600
- **Temp files**: Always use `mktemp` (never predictable paths)
- **Path validation**: Must be under `$HOME`; system dirs blocked (`/usr`, `/etc`, `/var`, `/bin`, `/sbin`)
- **Process management**: PID files with atomic operations, trap handlers, graceful shutdown
- **Cross-platform**: macOS (`du -sk`, `stat -f%z`, `diskutil`) vs Linux (`du -sb`, `stat -c%s`, `df`)
- **Locking**: `acquire_lock`/`release_lock` in `lib/common.sh` using mkdir + PID file semantics
- **JSON output**: Most scripts support `--json` flag; requires `jq`

## Coding Style

- **Language**: Bash (`#!/bin/bash` or `#!/usr/bin/env bash`)
- **Indentation**: 4 spaces
- **Naming**: files `kebab-case.sh`, functions `snake_case`, constants `UPPER_SNAKE`
- **Flags**: Long options (`--dry-run`, `--status`)
- **Output**: `print_info`, `print_success`, `print_warning`, `print_error`, `print_section`
- **Arrays over scalars**: Prefer `flags=("--option")` over `FLAG="--option"`
- **Arithmetic**: Use `awk` for all math (never `bc`)

## Quality Assurance

### Unified QA harness (preferred)

```bash
./qa-all.sh          # Run all checks locally
./qa-all.sh --ci     # CI-friendly output
```

### Individual checks

```bash
# ShellCheck (policy: exclude SC2034, SC2155)
shellcheck -S warning -e SC2034,SC2155 *.sh

# Format check (4-space indent)
shfmt -d -i 4 *.sh

# Syntax validation
bash -n *.sh
```

### Dry-run smoke tests

```bash
./disk-cleanup.sh --dry-run -y --no-gauge --no-fun --json
./update-all.sh --dry-run
./nmap-scan.sh --dry-run
./smart-cleanup.sh --status
./ssh-key-audit.sh --dry-run
./docker-health.sh --dry-run
./network-monitor.sh --dry-run
./system-monitor.sh --dry-run
./backup-verify.sh --dry-run
./homelab/homelab.sh morning --dry-run
```

### Pre-commit hook

```bash
ln -sf ../../.githooks/pre-commit .git/hooks/pre-commit
```

Checks: shellcheck (blocks on errors), shfmt (warns), bc usage (blocks), unsafe rm patterns (warns).

### CI/CD

GitHub Actions via `.github/workflows/qa-all.yml` runs `qa-all.sh --ci` on every push/PR touching `*.sh` files. Legacy individual workflows (shellcheck.yml, shfmt.yml, smoke-tests.yml) also exist.

## Commit Conventions

Conventional Commits style with scope:
```
feat(venv): add virtualenv cleanup with age/size thresholds
fix(docker): handle daemon startup timeout gracefully
security: replace predictable temp files with mktemp
docs: update CLAUDE.md with v1.0.1 features
```

## Platform Considerations

- **macOS**: `du -sk` (KB), `stat -f%z`, `diskutil info /` for APFS, BSD `date`
- **Linux**: `du -sb` (bytes), `stat -c%s`, `df -h /`, GNU `date -Iseconds`
- **Docker on macOS**: Requires Docker Desktop GUI; use `--skip-docker` for headless
- **Docker on Linux**: Requires sudo for systemctl/service; scripts warn before escalation
- **Bash version**: Scripts target Bash 3.2+ compatibility (macOS default)

## Dependencies

- **Required**: `bash`, `git`, `awk`, `sed`, `grep`, `du`, `df`
- **Optional**: `rclone`, `nmap`, `docker`, `jq`, `smartctl`, `openssl`, `pg_dump`/`mysqldump`, `ffprobe`, `ss`, `md5sum`/`md5`
- **Dev tools**: `shellcheck`, `shfmt` (`brew install shellcheck shfmt`)
