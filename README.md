# Homelab Scripts

A production-grade collection of Bash automation scripts for Linux/macOS homelab and server maintenance — covering disk cleanup, monitoring, backups, deployment, security auditing, and network discovery.

All scripts follow a consistent design philosophy: safe defaults, `--dry-run` before you commit, JSON output for integrations, and comprehensive logging.

---

## Contents

- [Quick Start](#quick-start)
- [Script Reference](#script-reference)
  - [Disk & System Cleanup](#disk--system-cleanup) — `disk-cleanup.sh`, `smart-cleanup.sh`, `plex-cleanup.sh`, `update-all.sh`, `log-manager.sh`
  - [Monitoring & Health](#monitoring--health) — `service-health-check.sh`, `smart-disk-check.sh`, `nmap-scan.sh`, `docker-health.sh`, `system-monitor.sh`, `network-monitor.sh`, `media-stats.sh`
  - [Backup & Sync](#backup--sync) — `rclone-sync.sh`, `db-backup.sh`, `docker-volume-backup.sh`, `backup-verify.sh`
  - [Infrastructure & Deployment](#infrastructure--deployment) — `new-vm-setup.sh`, `deploy-scripts.sh`, `compose-redeploy.sh`, `dyndns-update.sh`, `minecraft-manager.sh`
  - [Security & Audit](#security--audit) — `ssh-key-audit.sh`, `ci-health-audit.sh`, `secrets-scan.sh`, `auth-log-audit.sh`, `cron-audit.sh`, `firewall-audit.sh`, `package-cve-check.sh`
  - [Development & QA](#development--qa) — `qa-all.sh`
- [Common Patterns](#common-patterns)
- [Cron Integration](#cron-integration)
- [Security Model](#security-model)
- [Troubleshooting](#troubleshooting)

---

## Quick Start

```bash
# Clone and enter
git clone https://github.com/adrianwedd/homelab-scripts.git
cd homelab-scripts
chmod +x *.sh

# Always dry-run first
./disk-cleanup.sh --dry-run --no-gauge --no-fun

# Then run for real
./disk-cleanup.sh -y --skip-docker --no-gauge --no-fun
```

Every script supports `--help` and `--dry-run`. Run those first.

---

## Script Reference

### Disk & System Cleanup

---

#### `disk-cleanup.sh`

The main cleanup workhorse. Removes caches and generated files across VS Code, Docker, Git, Homebrew, NPM, pnpm, pip, and Python virtualenvs.

**What it touches:**

| Target | What's removed |
|--------|----------------|
| VS Code | Extension cache, user data, workspace storage |
| Docker | Unused containers, images, volumes, build cache |
| Git | Runs `git gc` on repos in `~/repos` |
| Homebrew | Old formula versions, download cache |
| NPM | Package cache |
| Playwright | Browser binaries |
| pnpm | Unreferenced store packages |
| pip/Python | Wheel cache |
| AWS CLI | CLI cache |
| Virtualenvs | Stale `.venv` / `venv` directories (opt-in) |

**Usage:**

```bash
# Preview — always run this first
./disk-cleanup.sh --dry-run --no-gauge --no-fun

# Interactive cleanup (asks before each section)
./disk-cleanup.sh

# Non-interactive (for cron/automation)
./disk-cleanup.sh -y --skip-docker --no-gauge --no-fun

# Quick cleanup — skip slow git gc
./disk-cleanup.sh -y --skip-git-gc --no-gauge

# Deep git gc — only repos with large packs
./disk-cleanup.sh --smart-gc --gc-threshold 2

# Force git gc on everything
./disk-cleanup.sh --full-gc -y

# Virtualenv management
./disk-cleanup.sh --scan-venvs                         # Report sizes/ages only
./disk-cleanup.sh --clean-venvs --venv-age 60 --venv-min-gb 1  # Remove stale ones

# Machine-readable output
./disk-cleanup.sh -y --json --no-gauge --no-fun
```

**Key flags:**

| Flag | Default | Description |
|------|---------|-------------|
| `--dry-run` / `-d` | off | Preview only, no changes |
| `--yes` / `-y` | off | Skip all confirmations |
| `--skip-docker` | off | Skip Docker (use in headless/cron) |
| `--skip-git-gc` | off | Skip git gc entirely |
| `--smart-gc` | on | Only gc repos with large/old packs |
| `--full-gc` | off | Force gc on all repos |
| `--gc-threshold GB` | 1 | Minimum pack size to trigger gc |
| `--no-gauge` | auto | Disable live disk gauge (auto off in non-TTY) |
| `--no-fun` | off | Disable fun facts between sections |
| `--scan-venvs` | off | Scan and report virtualenv sizes |
| `--clean-venvs` | off | Remove stale virtualenvs |
| `--venv-age DAYS` | 30 | Min age threshold for venv removal |
| `--venv-min-gb GB` | 0.5 | Min size threshold for venv removal |
| `--docker-wait SECS` | 60 | Seconds to wait for Docker to start |
| `--json` | off | Write JSON summary to `logs/` |

**Bounds validation:**

| Parameter | Valid range |
|-----------|-------------|
| `--gc-threshold` | 0.1 – 1000 GB |
| `--venv-age` | 1 – 3650 days |
| `--venv-min-gb` | 0.01 – 100 GB |

**Logs:** `logs/disk_cleanup_YYYYMMDD_HHMMSS.log` (mode 600)

> **Safety:** Never removes source code or configs. Active virtualenvs are always skipped. System directories (`/usr`, `/etc`, `/var`, `/bin`, `/sbin`) are blocked from venv root scanning.

---

#### `smart-cleanup.sh`

An interactive wrapper around `disk-cleanup.sh` with a menu UI and before/after disk comparison. Runs a dry-run analysis first, then lets you choose what to clean.

```bash
# Check what can be cleaned, then exit
./smart-cleanup.sh --status

# Run quick cleanup (skip git gc)
./smart-cleanup.sh --auto-best

# Run full cleanup (include git gc)
./smart-cleanup.sh --auto-full

# Use a named profile
./smart-cleanup.sh --profile emergency    # Docker only, ~30 sec
./smart-cleanup.sh --profile quick        # Caches, ~2-3 min
./smart-cleanup.sh --profile thorough     # Everything, ~3-6 hrs

# Virtualenv options (passed through to disk-cleanup.sh)
./smart-cleanup.sh --scan-venvs
./smart-cleanup.sh --clean-venvs --venv-age 60
```

**Profiles:**

| Profile | Runs | Time |
|---------|------|------|
| `emergency` | Docker prune only, no confirmations | ~30 sec |
| `quick` | Caches, skip git gc | ~2-3 min |
| `thorough` | Everything including git gc | ~3-6 hrs |

**Logs:** `logs/cleanup_YYYYMMDD_HHMMSS.log`

---

#### `plex-cleanup.sh`

Cleans up Plex Media Server junk, cache, and duplicate files. Auto-detects the Plex data directory. Safe to run with Plex running — caches are always regenerated.

```bash
# Dry run — see what would be cleaned
./plex-cleanup.sh --dry-run

# Clean everything (with confirmation prompts)
./plex-cleanup.sh

# Clean everything, no prompts
./plex-cleanup.sh -y

# Only clean Plex cache and transcoder (skip duplicate scan)
./plex-cleanup.sh --skip-duplicates --skip-thumbnails --skip-empties

# Target a different Plex root
./plex-cleanup.sh --plex-dir /mnt/media

# JSON output
./plex-cleanup.sh --dry-run --json
```

**What it cleans:**

| Section | What's removed |
|---------|----------------|
| Plex cache/logs | `Cache/`, `Codecs/`, `Crash Reports/`, `Logs/`, `.db-wal`, `.db-shm` temp files |
| Plex Versions | Transcoded versions of originals (saves space; Plex regenerates if needed) |
| System junk | `.DS_Store`, `Thumbs.db`, `desktop.ini`, `._*`, `.AppleDouble` |
| Empty directories | Leftover directories after moves/deletions |
| Duplicate media | Same-size + MD5 match; keeps first occurrence |

**Auto-detected Plex data paths:**
- `/var/lib/plexmediaserver/Library/Application Support/Plex Media Server`
- `~/.local/share/Plex Media Server`
- `<plex-dir>/.local/share/Plex Media Server`

**Logs:** `logs/plex-cleanup/`

---

#### `update-all.sh`

Updates all detected package managers in one shot. Auto-detects what's installed; skips what isn't.

**Update order:** Homebrew → NPM globals → pnpm → pip → RubyGems → macOS Software Update

```bash
# Preview updates
./update-all.sh --dry-run

# Run all updates
./update-all.sh

# Non-interactive
./update-all.sh -y

# Override PEP 668 (use with care on Debian/Ubuntu)
./update-all.sh --pip-system
```

> **PEP 668:** On Debian/Ubuntu systems with externally-managed Python, `pip` updates are skipped by default to protect the system Python. Use `--pip-system` with `--break-system-packages` semantics, or use a virtualenv.

**Logs:** `logs/update_YYYYMMDD_HHMMSS.log`

---

#### `log-manager.sh`

Compresses old log files, enforces retention policies, vacuums the systemd journal, and rotates large rclone logs. Keeps `logs/` directories from growing unbounded.

```bash
# Preview what would be compressed/deleted
./log-manager.sh --dry-run

# Run with defaults (compress >7 days, delete >30 days)
./log-manager.sh

# Custom retention
./log-manager.sh --compress-days 3 --retention-days 14

# Include additional directories
./log-manager.sh --dirs "/var/log/myapp:/opt/service/logs"

# JSON summary output
./log-manager.sh --json
```

**What it manages:**

| Action | Default threshold | Scope |
|--------|-----------------|-------|
| Compress `.log` → `.log.gz` | Older than 7 days | `logs/` subdirs + `--dirs` |
| Delete `.log` / `.log.gz` | Older than 30 days | Same |
| Journal vacuum | Older than 30 days | `journalctl --vacuum-time` |
| Rotate rclone log | > 50 MB | `~/rclone-sync.log` |

**Flags:**

| Flag | Default | Description |
|------|---------|-------------|
| `--compress-days N` | 7 | Compress logs older than N days |
| `--retention-days N` | 30 | Delete logs older than N days |
| `--dirs PATHS` | (auto) | Colon-separated extra directories |

**Logs:** `logs/log-manager/`

---

### Monitoring & Health

---

#### `service-health-check.sh`

Config-driven uptime monitoring for HTTP endpoints, TCP ports, processes, and Docker containers. Supports webhooks for alerting.

**Config format** (`services.conf`):

```ini
[my-api]
type=http
url=https://api.example.com/health
expect_status=200
expect_body=ok
timeout=5

[postgres]
type=tcp
host=localhost
port=5432
timeout=5

[sshd]
type=process
name=sshd

[nginx-container]
type=container
name=nginx
```

**Usage:**

```bash
# Run once
./service-health-check.sh --config services.conf

# Continuous watch mode (every 60 seconds)
./service-health-check.sh --config services.conf --watch --interval 60

# With webhook notification on failure
./service-health-check.sh --config services.conf --notify webhook:https://hooks.example.com/alert

# JSON output for Grafana/monitoring stack
./service-health-check.sh --config services.conf --json

# Dry run
./service-health-check.sh --config examples/services.conf --dry-run
```

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | All services healthy |
| 1 | One or more services down |
| 2 | Config error |

**Logs:** `logs/service-health/`

---

#### `smart-disk-check.sh`

S.M.A.R.T. disk health monitoring. Auto-discovers drives, checks health attributes and temperature, and can schedule short/long tests.

**Requires:** `smartmontools` (`sudo apt install smartmontools`)

```bash
# Auto-discover and check all drives
./smart-disk-check.sh

# Check specific drives
./smart-disk-check.sh --devices /dev/sda,/dev/nvme0n1

# Schedule a short SMART test
./smart-disk-check.sh --test short

# Custom temperature thresholds
./smart-disk-check.sh --warn-temp 45 --crit-temp 55

# JSON output
./smart-disk-check.sh --json

# Preview without running
./smart-disk-check.sh --dry-run
```

**Monitored attributes:**

| Attribute ID | Name | Meaning |
|---|---|---|
| 5 | Reallocated Sectors | Bad sector remaps (any > 0 = concern) |
| 187 | Reported Uncorrectable | Unrecoverable errors |
| 188 | Command Timeout | Commands timing out |
| 197 | Current Pending | Sectors awaiting reallocation |
| 198 | Offline Uncorrectable | Uncorrectable during offline scan |

**Temperature ranges:**

| Threshold | Default | Range |
|-----------|---------|-------|
| `--warn-temp` | 50°C | 30–80°C |
| `--crit-temp` | 60°C | 40–90°C |

**Logs:** `logs/smart-check/`

---

#### `cert-renewal-check.sh`

Monitors SSL/TLS certificate expiry for domains and local certificate files. Optionally triggers certbot renewal.

```bash
# Check domains from file
./cert-renewal-check.sh --domains domains.txt

# Check a specific local cert
./cert-renewal-check.sh --cert /etc/ssl/certs/homelab.pem --warn-days 14

# Auto-renew via certbot
./cert-renewal-check.sh --domains domains.txt --auto-renew

# JSON output
./cert-renewal-check.sh --domains domains.txt --json

# Dry run
./cert-renewal-check.sh --domains examples/domains.txt --dry-run
```

**Domains file format:**

```
# Lines starting with # are ignored
example.com
homelab.local
api.internal.example.com
```

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | All certs valid and not expiring soon |
| 1 | One or more certs expiring within warn threshold |
| 2 | One or more certs already expired or unreachable |

**Logs:** `logs/cert/`

---

#### `nmap-scan.sh`

Network discovery with delta tracking. Scans subnets, records results as JSON, and highlights new/removed hosts since the last scan.

**Requires:** `nmap` (`sudo apt install nmap` / `brew install nmap`)

```bash
# Auto-detect subnet and scan
./nmap-scan.sh

# Specific subnet
./nmap-scan.sh --cidr "192.168.1.0/24"

# Multiple subnets
./nmap-scan.sh --cidr "192.168.1.0/24,10.0.0.0/24"

# Full scan (top 1000 ports, slower)
./nmap-scan.sh --cidr "192.168.1.0/24" --full

# Exclude specific hosts
./nmap-scan.sh --exclude "192.168.1.1,192.168.1.10"

# Rate-limit for quiet operation
./nmap-scan.sh --rate 50

# JSON only, skip delta
./nmap-scan.sh --output json --no-delta

# Dry run — shows nmap commands without executing
./nmap-scan.sh --cidr "192.168.1.0/24" --dry-run
```

**Scan modes:**

| Mode | Ports | Speed | Use |
|------|-------|-------|-----|
| `--fast` (default) | 22, 80, 443 + ping | Fast | Daily discovery |
| `--full` | Top 1000 TCP | Slow | Weekly/monthly audit |

**Privilege note:** Run with `sudo` for SYN scans and MAC address capture. Without sudo, falls back to TCP connect scans (slower, no MAC).

**Logs:** `logs/nmap/` (mode 600, dir 700)

---

#### `docker-health.sh`

Docker container health dashboard, image inventory, orphaned resource detector, and disk summary in one command. Supports continuous watch mode.

```bash
# One-shot health check
./docker-health.sh

# Watch mode, refresh every 15 seconds
./docker-health.sh --watch --interval 15

# Alert if a container has restarted more than 3 times
./docker-health.sh --restart-threshold 3

# Clean up dangling images and orphaned volumes
./docker-health.sh --prune-dangling

# JSON output for monitoring integrations
./docker-health.sh --json

# Dry run (show current state, no changes)
./docker-health.sh --dry-run
```

**Sections:**

| Section | What's shown |
|---------|-------------|
| Container status | Name, state, CPU%, memory, restart count, health check status |
| Image inventory | All images sorted by size; dangling images flagged |
| Volumes | All volumes, orphaned (unused) ones highlighted |
| Networks | Custom networks, orphaned ones flagged |
| Disk summary | `docker system df` — total space used by images/containers/volumes/cache |

**Alerts:**
- Container in `restarting` state (restart loop)
- Container `exited`/`dead` unexpectedly
- `HEALTHCHECK` status = `unhealthy`
- Restart count exceeds `--restart-threshold`
- Dangling images / orphaned volumes present

**Exit codes:** 0 = all healthy, 1 = issues found, 2 = Docker unavailable

**Logs:** `logs/docker-health/`

---

#### `system-monitor.sh`

Real-time CPU, memory, disk, and process monitoring for Linux systems. Includes Raspberry Pi temperature, configurable alert thresholds, watch mode, and optional webhook notifications.

```bash
# One-shot snapshot
./system-monitor.sh

# Continuous watch mode (refresh every 10s)
./system-monitor.sh --watch --interval 10

# Custom alert thresholds
./system-monitor.sh --cpu-threshold 70 --mem-threshold 80 --disk-threshold 85

# POST alerts to a webhook URL
./system-monitor.sh --webhook https://hooks.example.com/alert

# Show top 5 processes instead of 10
./system-monitor.sh --top 5

# JSON output
./system-monitor.sh --json

# Dry run (show thresholds, exit without checking)
./system-monitor.sh --dry-run
```

**Sections:**

| Section | What's shown |
|---------|-------------|
| CPU & Load | 1-second CPU sample, load averages (1/5/15m), Pi temperature |
| Memory | MemTotal, used, available, swap usage |
| Disk | All non-tmpfs mounts, used% color-coded by threshold |
| Processes | Top N by CPU%, top N by MEM% |

**Alert thresholds:**

| Flag | Default | Triggers on |
|------|---------|------------|
| `--cpu-threshold` | 80% | 1-second CPU usage |
| `--mem-threshold` | 85% | Memory used% |
| `--disk-threshold` | 90% | Any mount point used% |
| `--load-threshold` | 4.0 | 1-minute load average |

**Exit codes:** 0 = all within thresholds, 1 = threshold exceeded

**Logs:** `logs/system-monitor/`

---

#### `network-monitor.sh`

Pings targets, measures DNS resolution times, logs latency history to a `.jsonl` timeseries file, and alerts on packet loss or slow response.

```bash
# Check defaults (1.1.1.1 and 8.8.8.8)
./network-monitor.sh

# Custom targets
./network-monitor.sh --targets "192.168.1.1,8.8.8.8,1.0.0.1"

# Continuous watch mode
./network-monitor.sh --watch --interval 30

# Alert thresholds
./network-monitor.sh --latency-threshold 100 --loss-threshold 5 --dns-threshold 500

# JSON output (current run)
./network-monitor.sh --json

# Dry run
./network-monitor.sh --dry-run
```

**What it checks:**

| Check | How |
|-------|-----|
| Ping latency | `ping -c 5` per target, avg/min/max/loss |
| DNS resolution | `host google.com` timing |
| History | Appended to `logs/network-monitor/timeseries.jsonl` |

**Flags:**

| Flag | Default | Description |
|------|---------|-------------|
| `--targets LIST` | `1.1.1.1,8.8.8.8` | Comma-separated IPs/hostnames |
| `--latency-threshold N` | 200ms | Alert if avg latency exceeds |
| `--loss-threshold N` | 10% | Alert if packet loss exceeds |
| `--dns-threshold N` | 1000ms | Alert if DNS resolution exceeds |

**Exit codes:** 0 = all OK, 1 = threshold exceeded, 2 = fatal error

**Logs:** `logs/network-monitor/` (timeseries at `timeseries.jsonl`)

---

#### `media-stats.sh`

Scans a Plex (or any media) library and reports codec breakdown, total size and duration, largest files, and H.265 re-encode candidates with estimated savings.

**Requires:** `ffprobe` (part of `ffmpeg`) or `mediainfo` as fallback.

```bash
# Full library scan (Plex default dir)
./media-stats.sh

# Scan a specific directory
./media-stats.sh --plex-dir /mnt/media/TV

# Flag files above 15 Mbps as re-encode candidates
./media-stats.sh --bitrate-threshold 15000

# Scan only first 100 files (for testing)
./media-stats.sh --limit 100

# JSON output
./media-stats.sh --json

# Dry run
./media-stats.sh --plex-dir /mnt/media --dry-run
```

**Reports:**

| Section | Content |
|---------|---------|
| Codec breakdown | H.264, H.265/HEVC, AV1, VP9, MPEG-2, etc. — file count, %, storage |
| Library overview | Total files, total size, total duration |
| Largest files | Top 15 by size |
| Re-encode candidates | H.264 files above bitrate threshold, estimated 50% savings with H.265 |

**Re-encode tools:**

```bash
# HandBrakeCLI
HandBrakeCLI -i input.mkv -o output.mkv --preset "H.265 MKV 1080p30"

# ffmpeg
ffmpeg -i input.mkv -c:v libx265 -crf 23 -c:a copy output.mkv
```

**Exit codes:** 0 = scan complete, 1 = no media tool found, 2 = fatal error

**Logs:** `logs/media-stats/`

---

### Backup & Sync

---

#### `rclone-sync.sh`

Background daemon that continuously syncs `~/repos` to Google Drive (or any rclone remote). Handles PID management, log rotation, graceful shutdown, and smart exclusions.

**Setup:**

```bash
# Configure your rclone remote first
rclone config

# Start syncing
./rclone-sync.sh --start

# Check status
./rclone-sync.sh --status

# Preview what would be synced
./rclone-sync.sh --dry-run

# Stop gracefully
./rclone-sync.sh --stop

# View recent log entries
./rclone-sync.sh --logs 100
```

**Environment variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `SOURCE_DIR` | `~/repos` | Source directory to sync |
| `REMOTE_NAME` | `gdrive_new` | rclone remote name |
| `REMOTE_PATH` | `repos/` | Destination path on remote |
| `TRANSFERS` | `8` | Parallel upload streams |
| `BANDWIDTH_LIMIT` | (none) | e.g. `10M` for 10 MB/s cap |

**Default exclusions** (auto-created at `~/.rclone-exclude`):

```
.git/**
node_modules/**
**/.venv/**
**/venv/**
**/*.pyc
__pycache__/**
dist/
build/
.next/
.vscode/
.idea/
```

Customise: `./rclone-sync.sh --edit-exclude`

**Process management:**

- PID file at `~/.rclone-sync.pid` with atomic write
- First `Ctrl+C` → graceful shutdown (10 sec timeout)
- Second `Ctrl+C` → force kill
- Log rotation at 50 MB
- Orphan process detection on startup

**Log:** `~/rclone-sync.log`

---

#### `db-backup.sh`

Automated PostgreSQL and MySQL backups with a three-tier retention policy (daily/weekly/monthly) and optional cloud sync via rclone.

**Setup:**

```bash
# Set DSN (keep out of shell history)
export DB_DSN="postgres://user:password@localhost:5432/mydb"

# Preview backup plan
./db-backup.sh --db pg --dry-run

# Run a backup
./db-backup.sh --db pg

# MySQL
export DB_DSN="mysql://root:password@localhost:3306/appdb"
./db-backup.sh --db mysql

# Custom retention: 14 daily, 8 weekly, 24 monthly
./db-backup.sh --db pg --retention 14:8:24

# Upload to cloud after backup
./db-backup.sh --db pg --rclone gdrive:db-backups

# Verify backup integrity (PostgreSQL only)
./db-backup.sh --db pg --test-restore

# JSON output
./db-backup.sh --db pg --json
```

**DSN formats:**

```
# PostgreSQL
postgres://username:password@host:5432/database
postgresql://username:password@host:5432/database

# MySQL
mysql://username:password@host:3306/database
```

**Retention policy:**

| Format | Meaning |
|--------|---------|
| `7:4:12` (default) | 7 daily, 4 weekly, 12 monthly |
| `14:8:24` | 14 daily, 8 weekly, 24 monthly |
| `3:0:0` | 3 daily, no weekly/monthly |

**Security:** Passwords are masked in all log output. Backup files are created with mode 600. Use `DB_DSN` env var rather than `--dsn` to avoid credentials in shell history.

**Logs:** `logs/db-backup/`

---

#### `docker-volume-backup.sh`

Creates compressed tar.gz snapshots of Docker volumes using a helper container approach — no local filesystem mount required.

```bash
# Backup a specific volume
./docker-volume-backup.sh --volume postgres_data

# Backup all volumes
./docker-volume-backup.sh --all

# Stop containers during backup (for consistency)
./docker-volume-backup.sh --volume postgres_data --stop

# Custom output location
./docker-volume-backup.sh --all --out /mnt/nas/backups

# Custom helper image
./docker-volume-backup.sh --all --backup-image busybox:latest

# JSON output
./docker-volume-backup.sh --all --json

# Dry run
./docker-volume-backup.sh --all --dry-run
```

> **Note:** `--volume` and `--all` are mutually exclusive. At least one must be specified.

**Backup location:** `./backups/volumes/` (files mode 600)

**Logs:** `logs/volume-backup/`

---

#### `backup-verify.sh`

Verifies that backups created by companion scripts actually exist and are healthy. Checks db-backup files, rclone remote reachability and recency, and docker-volume-backup archive integrity.

```bash
# Full verification (all backup types)
./backup-verify.sh

# Dry run (show what would be checked)
./backup-verify.sh --dry-run

# JSON output for monitoring
./backup-verify.sh --json
```

**Checks performed:**

| Backup type | Checks |
|-------------|--------|
| Database backups | Recent file exists, size > 0, SQLite integrity or SQL keyword check |
| rclone remote | Remote reachable via `rclone lsd`, files present within 24 hours |
| Docker volume backups | Recent `.tar.gz` exists, archive readable by `tar -tzf` |

**Auto-detected locations:**

- DB backups: `logs/db-backup/`, `/var/backups/db/`
- Volume backups: `./backups/volumes/`, `/var/backups/docker-volumes/`
- rclone remote: from `~/.rclone.conf` or env `RCLONE_REMOTE`

**Exit codes:** 0 = all verified, 1 = verification failures, 2 = fatal error

**Logs:** `logs/backup-verify/`

---

### Infrastructure & Deployment

---

#### `compose-redeploy.sh`

Safe Docker Compose updates with pre-flight validation, optional volume backup, health check verification, and automatic rollback on failure.

```bash
# Basic redeploy (uses docker-compose.yml in current dir)
./compose-redeploy.sh

# Specific compose file
./compose-redeploy.sh --file app.yml

# Backup volumes before update
./compose-redeploy.sh --backup-volumes

# Longer health check timeout
./compose-redeploy.sh --health-timeout 120

# Skip image pull (use cached images)
./compose-redeploy.sh --no-pull

# JSON output for CI/CD pipelines
./compose-redeploy.sh --json

# Dry run — shows full plan without changes
./compose-redeploy.sh --dry-run
```

**Deployment flow:**

1. Validate compose file syntax
2. Backup volumes (if `--backup-volumes`)
3. Pull latest images
4. Recreate containers
5. Wait for health checks (up to `--health-timeout` seconds)
6. **Rollback automatically** if health checks fail

**Logs:** `logs/compose-redeploy/`  
**Backups:** `./backups/compose-volumes/`

---

#### `deploy-scripts.sh`

Deploys this script collection to one or more remote hosts. Tries git first (fast, preserves history), falls back to rsync (always works).

```bash
# Deploy to one host
./deploy-scripts.sh --hosts "pi@192.168.1.100"

# Deploy to multiple hosts
./deploy-scripts.sh --hosts "pi@192.168.1.100,pi@192.168.1.101"

# Deploy from a hosts file (one per line)
./deploy-scripts.sh --hosts-file examples/hosts.txt

# Custom remote path
./deploy-scripts.sh --hosts "pi@192.168.1.100" --path "$HOME/homelab"

# Force rsync (skip git)
./deploy-scripts.sh --hosts "pi@192.168.1.100" --rsync-only

# Dry run
./deploy-scripts.sh --hosts "pi@192.168.1.100" --dry-run
```

**Hosts file format:**

```
# One host per line, comments supported
pi@192.168.1.100
admin@10.0.0.50
deploy@homelab.local
```

**Post-deploy sanity check:** Automatically runs `bash -n *.sh` and `--help` on key scripts on the remote to verify the deployment is functional.

---

#### `new-vm-setup.sh`

Bootstraps a fresh Linux VM: sets hostname, creates a sudo user, installs SSH key, installs packages, and optionally clones dotfiles.

```bash
# Minimal setup
./new-vm-setup.sh \
  --hostname web-01 \
  --user deploy \
  --ssh-key-path ~/.ssh/id_ed25519.pub

# Full setup
./new-vm-setup.sh \
  --hostname dev-box \
  --user admin \
  --ssh-key "ssh-ed25519 AAAA..." \
  --packages "git,curl,htop,vim,tmux" \
  --dotfiles https://github.com/user/dotfiles.git \
  --shell /bin/zsh

# Non-interactive
./new-vm-setup.sh \
  --hostname prod-01 \
  --user deploy \
  --ssh-key-path ~/.ssh/deploy.pub \
  --yes

# Dry run (no sudo required)
./new-vm-setup.sh \
  --hostname test-vm \
  --user testuser \
  --ssh-key-path ~/.ssh/id_rsa.pub \
  --dry-run
```

**Validation rules:**

| Field | Rules |
|-------|-------|
| `--hostname` | RFC-1123: lowercase, digits, hyphens; max 63 chars; no leading hyphen |
| `--user` | Lowercase, starts with letter; not `root` |
| `--ssh-key` | Must start with `ssh-ed25519`, `ssh-rsa`, `ecdsa-sha2-*`, or `sk-*` |
| `--dotfiles` | Must use `https://` or `git@` scheme |

**Logs:** `logs/new-vm-setup/`

---

#### `dyndns-update.sh`

Updates a DNS A record with your current public IP. Caches the last-known IP to avoid unnecessary API calls. Supports Cloudflare (additional providers can be added).

```bash
# Set token securely via environment variable
export CF_TOKEN="your-cloudflare-api-token"

# Update DNS record
./dyndns-update.sh \
  --provider cloudflare \
  --zone example.com \
  --record home \
  --token env:CF_TOKEN

# Custom TTL
./dyndns-update.sh \
  --provider cloudflare \
  --zone example.com \
  --record home \
  --token env:CF_TOKEN \
  --ttl 600

# Force update (bypass IP cache)
./dyndns-update.sh \
  --provider cloudflare \
  --zone example.com \
  --record home \
  --token env:CF_TOKEN \
  --force

# Dry run
./dyndns-update.sh \
  --provider cloudflare \
  --zone example.com \
  --record home \
  --token env:CF_TOKEN \
  --dry-run
```

**TTL range:** 60 – 86400 seconds (Cloudflare minimum: 60)

**Rate limiting:** At most one update per 5 minutes (cached IP prevents redundant calls).

**IP detection:** Tries multiple public IP sources with fallback.

**Logs:** `logs/dyndns/`

---

#### `minecraft-manager.sh`

Full lifecycle management for a Minecraft Java Edition server: start/stop/restart, status monitoring, world backups, log tailing, player listing, and console access via `screen`.

```bash
# Start the server
./minecraft-manager.sh start

# Check status (players, uptime, memory)
./minecraft-manager.sh status

# Stop gracefully (sends "stop" to console)
./minecraft-manager.sh stop

# Restart
./minecraft-manager.sh restart

# Backup worlds (tar.gz with timestamp)
./minecraft-manager.sh backup

# Tail server log
./minecraft-manager.sh logs

# List online players
./minecraft-manager.sh players

# Send command to server console
./minecraft-manager.sh console "say Hello"

# Check for server JAR updates
./minecraft-manager.sh update

# Dry run (show config without starting)
./minecraft-manager.sh status --dry-run
```

**Configuration via environment variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `MC_DIR` | `~/minecraft` | Server directory |
| `MC_JAR` | auto-detect | Server JAR filename |
| `MC_PORT` | `25565` | Server port |
| `MC_MEM_MAX` | `2G` | JVM max heap (`-Xmx`) |
| `MC_BACKUP_DIR` | `~/minecraft/backups` | Backup output directory |

**Auto-detects JARs:** `server.jar`, `paper*.jar`, `fabric*.jar`, `spigot*.jar`

**Screen session:** Server runs in a `screen` session named `minecraft`. Falls back to `nohup` if `screen` is unavailable.

**Backup retention:** Configurable with `--retain-days` (default: 14). Backs up `world/`, `world_nether/`, `world_the_end/`.

**Logs:** `logs/minecraft-manager/`

---

### Security & Audit

---

#### `ssh-key-audit.sh`

Read-only audit of `authorized_keys` files across all users (or selected users). Flags weak key types, bad permissions, stale keys, duplicates, and unsafe options. Supports risk scoring.

```bash
# Audit all users
./ssh-key-audit.sh --all-users

# Audit specific users
./ssh-key-audit.sh --users "alice,bob,deploy"

# Custom home root (e.g., for fixture testing)
./ssh-key-audit.sh --users "alice" --home-root /srv/homes

# Include system authorized_keys
./ssh-key-audit.sh --all-users --system

# Forbid RSA keys, fail if any found
./ssh-key-audit.sh --all-users \
  --forbid-types ssh-rsa \
  --fail-on weak-type

# Flag keys older than 365 days
./ssh-key-audit.sh --all-users --max-age 365

# Full risk scoring with detail
./ssh-key-audit.sh --all-users --risk-detail

# JSON output for SIEM/monitoring
./ssh-key-audit.sh --all-users --json

# Dry run (no filesystem reads)
./ssh-key-audit.sh --dry-run
```

**Checks performed:**

| Check | Flagged condition |
|-------|------------------|
| Key type | `ssh-rsa` (forbidden by default), DSA |
| Permissions | `~/.ssh` not 700, `authorized_keys` not 600 |
| Duplicates | Same key blob present more than once |
| Stale keys | Older than `--max-age` days |
| Unsafe options | `no-auth`, command injection patterns |

**Fail-on rules** (exit code 2 if triggered):

| Rule | Triggers on |
|------|-------------|
| `weak-type` | Forbidden key type found |
| `perms` | Bad file permissions |
| `stale` | Key exceeds max-age |
| `duplicate` | Duplicate key detected |
| `unsafe-options` | Dangerous authorized_keys options |

**Note:** This script is read-only. It makes no changes to any files.

**Logs:** `logs/ssh-key-audit/`

---

#### `ci-health-audit.sh`

Scans all Git repositories in `REPOS_DIR` for GitHub Actions workflow problems: YAML syntax errors, scheduled workflows missing branch guards (wasting CI minutes), and Python/JS heredocs needing sed fixes.

```bash
# Scan all repos
./ci-health-audit.sh

# Scan repos in a specific directory
REPOS_DIR=/path/to/repos ./ci-health-audit.sh

# Dry run (scan and report, apply no fixes)
./ci-health-audit.sh --dry-run

# Auto-fix broken YAML
./ci-health-audit.sh --fix-broken

# Add branch guards to unguarded schedules
./ci-health-audit.sh --add-guards

# Fix Python/JS heredocs
./ci-health-audit.sh --fix-heredocs
```

**Checks performed:**

| Check | Risk |
|-------|------|
| YAML syntax | Workflow never runs; silently broken |
| Unguarded schedules | Runs on every branch — wastes CI minutes, estimated monthly cost shown |
| Python/JS heredocs | Potential runtime parse errors in CI |

**Environment:**

| Variable | Default | Description |
|----------|---------|-------------|
| `REPOS_DIR` | `$HOME/repos` | Root directory containing git repos |

---

#### `secrets-scan.sh`

Scans git repositories for accidentally committed secrets. Detects API keys, private keys, database DSNs, JWTs, and more across four severity levels. Values are always masked in output — never printed in full.

```bash
# Scan all repos (dry run first to see scope)
./secrets-scan.sh --dry-run

# Scan all repos
./secrets-scan.sh

# Scan a specific directory
./secrets-scan.sh --dir ~/projects

# Only report critical and high severity
./secrets-scan.sh --severity high

# Also scan git commit history (slow but thorough)
./secrets-scan.sh --history

# JSON output for integrations
./secrets-scan.sh --json
```

**Severity levels:**

| Level | Examples |
|-------|---------|
| CRITICAL | Private keys (`BEGIN RSA PRIVATE KEY`), AWS access keys, database DSNs with passwords |
| HIGH | GitHub PATs, Google API keys, Stripe live keys, JWTs, Anthropic/OpenAI keys |
| MEDIUM | Slack tokens, Bearer tokens, generic API key assignments |
| LOW | Hardcoded passwords, private key file paths |

**Safe by design:**
- Secret values are masked (`sk-ant-****...`) — never printed in full
- Binary files skipped automatically
- Noise directories skipped: `.git`, `node_modules`, `.venv`, `dist`, `build`
- Exit 0 = clean, 1 = findings, 2 = error

**Logs:** `logs/secrets-scan/`

---

#### `auth-log-audit.sh`

Parses SSH authentication logs to surface brute-force attacks, successful logins, sudo usage, and new user creation. Alerts on high-volume attackers.

```bash
# Audit last 7 days (default)
./auth-log-audit.sh

# Longer history
./auth-log-audit.sh --days 30

# Alert if any IP has 20+ failures (default: 50)
./auth-log-audit.sh --alert-threshold 20

# Show top 20 attacking IPs
./auth-log-audit.sh --top 20

# JSON output for SIEM
sudo ./auth-log-audit.sh --json

# Dry run
./auth-log-audit.sh --dry-run
```

> **Note:** Requires read access to `/var/log/auth.log`. Run with `sudo` for full access on systems with restricted log permissions.

**Sections:**

| Section | What's shown |
|---------|-------------|
| Failed SSH attempts | Total count, top N attacking IPs, most-tried invalid usernames |
| Successful logins | Method (password/publickey), user, source IP, timestamp |
| Sudo usage | Last 30 sudo commands with user and command |
| User/group changes | `useradd`, `userdel`, `groupadd`, `groupdel` events |

**Reads:** `/var/log/auth.log`, `/var/log/secure`, plus rotated `.gz` variants

**Exit codes:** 0 = no alerts, 1 = high-volume attack detected, 2 = no readable logs

**Logs:** `logs/auth-audit/`

---

#### `cron-audit.sh`

Audits all cron jobs and systemd timers for common misconfigurations: missing executables, wildcard schedules, missing output redirection, and non-executable drop-in scripts.

```bash
# Full audit
./cron-audit.sh

# Dry run
./cron-audit.sh --dry-run

# JSON output
./cron-audit.sh --json
```

**Sources checked:**

| Source | Path |
|--------|------|
| System crontab | `/etc/crontab` |
| Cron drop-ins | `/etc/cron.d/*` |
| User crontabs | `/var/spool/cron/*` |
| Periodic scripts | `/etc/cron.{hourly,daily,weekly,monthly}/*` |
| Systemd timers | `systemctl list-timers` |

**Findings flagged:**

| Finding | Severity |
|---------|---------|
| Command path not found | ERROR |
| Command not executable | WARN |
| `* * * * *` wildcard schedule | WARN |
| No output redirection | INFO |
| Drop-in script not executable | WARN |

**Exit codes:** 0 = no issues, 1 = findings detected, 2 = fatal error

**Logs:** `logs/cron-audit/`

---

#### `firewall-audit.sh`

Audits UFW status, iptables INPUT chain policy, all listening ports, and optionally runs a localhost nmap scan. Compares listening ports against a configurable baseline to flag unexpected open ports.

```bash
# Basic audit (no sudo = limited iptables view)
./firewall-audit.sh

# Full audit with nmap
sudo ./firewall-audit.sh

# Compare against a port baseline
sudo ./firewall-audit.sh --baseline config/firewall-baseline.conf

# Skip nmap (faster)
./firewall-audit.sh --skip-nmap

# JSON output
sudo ./firewall-audit.sh --json

# Dry run
./firewall-audit.sh --dry-run
```

**Baseline file format** (`config/firewall-baseline.conf`):

```
# port/proto  description
22/tcp        SSH
80/tcp        HTTP
443/tcp       HTTPS
25565/tcp     Minecraft
```

**Checks:**

| Check | What's flagged |
|-------|---------------|
| UFW status | Inactive/disabled — host unprotected |
| iptables INPUT | Default policy `ACCEPT` — all traffic allowed |
| Listening ports | Ports not in baseline marked `[UNEXPECTED]` |
| nmap localhost | Open ports from outside perspective |

**Exit codes:** 0 = no issues, 1 = unexpected ports or firewall issues, 2 = fatal error

**Logs:** `logs/firewall-audit/`

---

#### `package-cve-check.sh`

Checks installed packages for available security updates using `apt`, optionally runs `debsecan` for CVE database lookups, verifies `unattended-upgrades` is configured, and checks if a reboot is needed for a new kernel.

```bash
# Check with existing package lists
./package-cve-check.sh

# Update package lists first (requires sudo)
sudo ./package-cve-check.sh --update-lists

# JSON output for monitoring
sudo ./package-cve-check.sh --json

# Dry run
./package-cve-check.sh --dry-run
```

**Checks performed:**

| Check | How |
|-------|-----|
| Security package upgrades | `apt-get --simulate upgrade` filtered to `security.*` sources |
| CVE database | `debsecan` (optional — install with `sudo apt install debsecan`) |
| Auto-updates | `unattended-upgrades` config present and enabled |
| Kernel reboot | Installed kernel version vs running kernel |

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | No critical security issues |
| 1 | Security updates available or CVEs found |
| 2 | Fatal error |

> **Note:** This script is read-only — it never installs anything.

**Logs:** `logs/package-cve/`

---

### Development & QA

---

#### `qa-all.sh`

The unified QA harness. Runs shellcheck, shfmt format checks, bash syntax validation, `--help` smoke tests, `--dry-run` execution tests, JSON contract validation, config precedence tests, and bounds validation — all in one command.

```bash
# Run all QA checks
./qa-all.sh

# CI mode (same checks, structured output)
./qa-all.sh --ci
```

**Test categories:**

| Category | What's tested |
|----------|--------------|
| Static analysis | `shellcheck`, `shfmt` format, `bash -n` syntax |
| Smoke tests | `--help` on all scripts |
| Dry-run execution | `--dry-run` on all scripts (44 total tests) |
| JSON contracts | JSON output schema on 5 scripts |
| Config precedence | Config file overrides env/defaults |
| Bounds validation | Out-of-range values rejected correctly |

**Requirements:** `shellcheck`, `shfmt`, `jq` (`sudo apt install shellcheck shfmt jq`)

**Artifacts:** `logs/qa/run_YYYYMMDD_HHMMSS/`

---

## Common Patterns

### Always dry-run first

Every script supports `--dry-run`. Use it before any real run:

```bash
./disk-cleanup.sh --dry-run --no-gauge --no-fun
./db-backup.sh --db pg --dry-run
./compose-redeploy.sh --dry-run
./new-vm-setup.sh --hostname vm01 --user admin --ssh-key-path ~/.ssh/id_ed25519.pub --dry-run
```

### JSON output for integrations

Scripts that support `--json` write a structured summary to `logs/`. Useful for Grafana, Prometheus pushgateway, SIEM ingestion, or CI artifact uploads.

```bash
./cert-renewal-check.sh --domains domains.txt --json
./smart-disk-check.sh --json
./service-health-check.sh --config services.conf --json
./db-backup.sh --db pg --json
./ssh-key-audit.sh --all-users --json
```

JSON schema (consistent across all scripts):

```json
{
  "script": "cert-renewal-check.sh",
  "version": "1.1.0",
  "timestamp": "2026-03-07T12:00:00Z",
  "status": "ok",
  "duration_ms": 1234,
  "errors": [],
  "result": { ... }
}
```

### Passing tokens securely

Never pass secrets as CLI arguments (they appear in `ps` output and shell history). Use environment variables:

```bash
# Good
export CF_TOKEN="your-token"
./dyndns-update.sh --token env:CF_TOKEN ...

# Good
export DB_DSN="postgres://user:pass@host/db"
./db-backup.sh --db pg

# Bad — token visible in process list
./dyndns-update.sh --token "your-token-literal" ...
```

---

## Cron Integration

Recommended cron schedule (`crontab -e`):

```cron
# SSL certificate check — daily at 8 AM
0 8 * * * ./cert-renewal-check.sh --domains /etc/ssl/domains.txt --json >> /tmp/cert-check.log 2>&1

# Disk cleanup — weekly Sunday at 3 AM (headless-safe flags)
0 3 * * 0 cd /home/pi/repos/scripts && ./disk-cleanup.sh -y --skip-docker --no-gauge --no-fun >> /tmp/cleanup.log 2>&1

# Package updates — weekly Sunday at 4 AM
0 4 * * 0 cd /home/pi/repos/scripts && ./update-all.sh -y >> /tmp/update.log 2>&1

# Database backup — daily at 2 AM
0 2 * * * cd /home/pi/repos/scripts && DB_DSN="postgres://user:pass@localhost/db" ./db-backup.sh --db pg --json >> /tmp/db-backup.log 2>&1

# Network scan — daily at 6 AM
0 6 * * * cd /home/pi/repos/scripts && ./nmap-scan.sh --no-gauge >> /tmp/nmap.log 2>&1

# SMART disk check — weekly Monday at 5 AM
0 5 * * 1 cd /home/pi/repos/scripts && ./smart-disk-check.sh --json >> /tmp/smart.log 2>&1

# Dynamic DNS — every 5 minutes
*/5 * * * * cd /home/pi/repos/scripts && CF_TOKEN="..." ./dyndns-update.sh --provider cloudflare --zone example.com --record home --token env:CF_TOKEN >> /tmp/dyndns.log 2>&1

# SSH key audit — weekly
0 9 * * 1 cd /home/pi/repos/scripts && ./ssh-key-audit.sh --all-users --json >> /tmp/ssh-audit.log 2>&1
```

> For cron, always use `--no-gauge --no-fun` with `disk-cleanup.sh`, and `--skip-docker` unless Docker is guaranteed running.

---

## Security Model

### Log security

All logs are written with:
- Log directory: mode `700` (owner only)
- Log files: mode `600` (owner read/write only)

### Credential handling

- Passwords are masked in all log output
- `DB_DSN` and API tokens are read from environment variables, not CLI args
- `--token env:VAR_NAME` pattern avoids credential exposure in process lists

### Path validation

`disk-cleanup.sh` enforces:
- Virtualenv roots must be under `$HOME`
- System directories (`/usr`, `/etc`, `/var`, `/bin`, `/sbin`) are blocked

### Sudo transparency

When sudo is required (e.g., Docker on Linux), scripts:
1. Print a clear warning listing what operations need elevation
2. Ask for explicit confirmation before proceeding

### Pre-commit hook

The repo includes a pre-commit hook for code quality:

```bash
# Install once
ln -sf ../../.githooks/pre-commit .git/hooks/pre-commit
```

**Enforces:**
- `shellcheck` — blocks on errors
- `shfmt` — warns on format issues
- `bc` usage — blocks (use `awk` instead)
- Unsafe `rm` with unquoted variables — warns

---

## Troubleshooting

### Disk gauge not visible (SSH / cron)

The live disk gauge requires a TTY. In non-interactive sessions it auto-disables, but you can be explicit:

```bash
./disk-cleanup.sh --no-gauge --no-fun
```

### Docker not starting within wait window

```bash
# Start Docker Desktop manually (macOS)
open -a Docker

# Or increase the wait time
./disk-cleanup.sh --docker-wait 120

# Or skip Docker entirely (recommended for headless/cron)
./disk-cleanup.sh --skip-docker
```

### Git gc timeout

Git gc has a 30-minute timeout per repo. For large repos:

```bash
# Skip git gc
./disk-cleanup.sh --skip-git-gc

# Use smart GC with higher threshold
./disk-cleanup.sh --smart-gc --gc-threshold 5

# Run gc manually with no timeout
git -C ~/repos/myrepo gc --aggressive
```

### Stale rclone PID file

```bash
rm -f ~/.rclone-sync.pid
pgrep -f "rclone sync" | xargs kill -9
```

### rclone remote not configured

```bash
rclone config
# Follow prompts to add your Google Drive or other remote
rclone listremotes  # Verify it's listed
```

### Bounds validation errors

| Error | Fix |
|-------|-----|
| `gc-threshold out of range` | Must be 0.1–1000 GB |
| `venv-age out of range` | Must be 1–3650 days |
| `venv-min-gb out of range` | Must be 0.01–100 GB |
| `warn-temp out of range` | Must be 30–80°C |
| `crit-temp out of range` | Must be 40–90°C |
| `TTL out of range` | Must be 60–86400 seconds |

### Virtualenv path validation error

Virtualenv roots must be under `$HOME`:

```bash
# Good
./disk-cleanup.sh --venv-roots "$HOME/repos:$HOME/projects"

# Bad — will be rejected
./disk-cleanup.sh --venv-roots "/var/lib/venvs"
```

### `smartctl not found`

```bash
sudo apt install smartmontools   # Debian/Ubuntu
brew install smartmontools        # macOS
```

### CI health audit shows broken workflows

```bash
# See what's broken
REPOS_DIR=/path/to/repos ./ci-health-audit.sh --dry-run

# Fix YAML syntax errors (review changes first)
REPOS_DIR=/path/to/repos ./ci-health-audit.sh --fix-broken

# Add branch guards to scheduled workflows
REPOS_DIR=/path/to/repos ./ci-health-audit.sh --add-guards
```

---

## Prerequisites

| Script | Required | Optional |
|--------|----------|---------|
| `disk-cleanup.sh` | bash | `coreutils` (macOS, for timeout) |
| `smart-cleanup.sh` | bash, `disk-cleanup.sh` in same dir | — |
| `update-all.sh` | bash | `brew`, `npm`, `pnpm`, `pip`, `gem` |
| `service-health-check.sh` | bash, `curl` | `docker` (for container checks) |
| `smart-disk-check.sh` | bash, `smartmontools` | — |
| `cert-renewal-check.sh` | bash, `openssl` | `certbot` (for `--auto-renew`) |
| `nmap-scan.sh` | bash, `nmap` | `sudo` (for SYN scans and MAC) |
| `rclone-sync.sh` | bash, `rclone` | — |
| `db-backup.sh` | bash, `pg_dump` or `mysqldump` | `rclone` (for upload) |
| `docker-volume-backup.sh` | bash, `docker` | — |
| `compose-redeploy.sh` | bash, `docker`, `docker compose` | — |
| `deploy-scripts.sh` | bash, `ssh`, `rsync` | — |
| `new-vm-setup.sh` | bash, `sudo` on remote | — |
| `dyndns-update.sh` | bash, `curl` | — |
| `ssh-key-audit.sh` | bash | — |
| `ci-health-audit.sh` | bash, `python3 -m yaml` | — |
| `qa-all.sh` | bash, `shellcheck`, `shfmt`, `jq` | — |

---

## Log File Reference

| Script | Log Location |
|--------|-------------|
| `disk-cleanup.sh` | `logs/disk_cleanup_YYYYMMDD_HHMMSS.log` |
| `smart-cleanup.sh` | `logs/cleanup_YYYYMMDD_HHMMSS.log` |
| `update-all.sh` | `logs/update_YYYYMMDD_HHMMSS.log` |
| `service-health-check.sh` | `logs/service-health/` |
| `smart-disk-check.sh` | `logs/smart-check/` |
| `cert-renewal-check.sh` | `logs/cert/` |
| `nmap-scan.sh` | `logs/nmap/` |
| `rclone-sync.sh` | `~/rclone-sync.log` |
| `db-backup.sh` | `logs/db-backup/` |
| `docker-volume-backup.sh` | `logs/volume-backup/` |
| `compose-redeploy.sh` | `logs/compose-redeploy/` |
| `dyndns-update.sh` | `logs/dyndns/` |
| `new-vm-setup.sh` | `logs/new-vm-setup/` |
| `ssh-key-audit.sh` | `logs/ssh-key-audit/` |
| `qa-all.sh` | `logs/qa/run_YYYYMMDD_HHMMSS/` |

All log directories: mode `700`. All log files: mode `600`.
