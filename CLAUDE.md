# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a collection of Bash system maintenance scripts for macOS/Linux focused on disk cleanup, system updates, and automated backups. All scripts are written in Bash and designed to be run directly from the command line with comprehensive security hardening (v1.0.1).

## Architecture

### Script Organization

The repository contains five main scripts that work independently:

1. **disk-cleanup.sh** - Comprehensive cache cleanup (VS Code, Docker, Git, Homebrew, NPM, pip, virtualenvs, etc.)
2. **rclone-sync.sh** - Background daemon for continuous Google Drive backup with smart exclusions
3. **nmap-scan.sh** - Network discovery and change tracking with delta analysis
4. **update-all.sh** - System-wide package manager updates (Homebrew, NPM, pnpm, pip, gem, macOS) with PEP 668 compliance
5. **smart-cleanup.sh** - Interactive wrapper around disk-cleanup.sh with beautiful UI and analysis

### Key Design Patterns

**Process Management**
- `rclone-sync.sh` implements proper daemon pattern with PID files, trap handlers, and graceful shutdown
- Atomic PID file operations using temp files and `mv` for safe concurrent access
- Background processes use `nohup` for terminal independence
- **Interrupt handling**: First Ctrl+C = graceful shutdown, second Ctrl+C = force kill

**Error Handling**
- Scripts use `set -u` (fail on undefined variables) but NOT `set -e` to allow cleanup continuation
- Individual operations wrapped in error checking with continue-on-failure approach
- Comprehensive logging to timestamped files in `./logs/` with secure permissions (600)

**Security (v1.0.1)**
- **Secure logs**: All logs under `./logs/` with `umask 077`, directory permissions `700`
- **mktemp usage**: All temporary files use `mktemp` for symlink/race protection
- **Path validation**: Virtualenv roots must be under `$HOME`; system directories blocked (`/usr`, `/etc`, `/var`, `/bin`, `/sbin`)
- **Bounds checking**:
  - GC threshold: 0.1-1000 GB
  - Venv age: 1-3650 days
  - Venv size: 0.01-100 GB
- **Sudo transparency**: Explicit warnings before privilege escalation with interactive confirmation

**User Experience**
- Color-coded output with ANSI escape sequences (RED, GREEN, YELLOW, BLUE)
- Unicode symbols (✓, ✗, ⚠, ℹ) for visual feedback
- Dry run modes for safe preview
- Interactive confirmations with `-y` flag override
- **Live disk gauge**: Real-time progress tracking (TTY-only, use `--no-gauge` for non-interactive)
- **Fun facts**: Reduced frequency (every 3rd section, ~3-4 per run, disable with `--no-fun`)

**Space Tracking**
- `disk-cleanup.sh` uses byte-level calculations for accuracy
- Size conversion functions handle KB/MB/GB/TB units
- Pre/post comparison to show actual freed space
- Uses `du -sb` (Linux) or `du -sk` (macOS) for cross-platform compatibility

## Common Development Tasks

### Testing Scripts

Run with dry-run mode to preview without changes:
```bash
./disk-cleanup.sh --dry-run
./rclone-sync.sh --dry-run
./update-all.sh --dry-run
./smart-cleanup.sh --status
```

### First-Run Checklist (for agents)

1. Syntax check: `bash -n *.sh`
2. ShellCheck: `shellcheck -S warning -e SC2034,SC2155 *.sh`
3. Dry-run sanity:
   - `./disk-cleanup.sh --dry-run --skip-docker --no-gauge --no-fun --json`
   - `./update-all.sh --dry-run`
   - `./nmap-scan.sh --dry-run` (or specify `--cidr`)
4. Verify outputs:
   - Logs under `./logs/` (mode 600)
   - JSON summary exists: `logs/disk_cleanup_summary_*.json`
5. Deps (ask before installing): `nmap`, `rclone`, `shellcheck`, `shfmt`

### Common Tasks

Quick reference for typical operations:

```bash
# Scan virtualenvs
./disk-cleanup.sh --scan-venvs

# Clean old virtualenvs (60+ days, 1+ GB)
./disk-cleanup.sh --clean-venvs --venv-age 60 --venv-min-gb 1

# Quick reclaim (skip slow git gc)
./disk-cleanup.sh -y --skip-git-gc

# Smart GC off-hours (threshold 1GB, no gauge/fun)
./disk-cleanup.sh -y --smart-gc --gc-threshold 1 --no-gauge --no-fun

# Full cleanup with confirmation
./disk-cleanup.sh --full-gc

# Skip Docker entirely (headless/cron)
./disk-cleanup.sh --skip-docker

# Increase Docker wait time
./disk-cleanup.sh --docker-wait 120
```

### Debugging

Check log files:
```bash
# Cleanup logs (secure: -rw-------)
tail -f logs/disk_cleanup_*.log

# Rclone logs
tail -f ~/rclone-sync.log

# Update logs
tail -f logs/update_*.log

# Smart cleanup logs
tail -f logs/cleanup_*.log
```

### Testing Background Processes

For `rclone-sync.sh`:
```bash
# Start sync
./rclone-sync.sh --start

# Check status with CPU/memory
./rclone-sync.sh --status

# Stop gracefully
./rclone-sync.sh --stop
```

### Network Discovery

For `nmap-scan.sh`:
```bash
# Fast scan (auto-detect CIDR)
./nmap-scan.sh

# Scan specific subnet
./nmap-scan.sh --cidr "192.168.1.0/24"

# Multi-subnet full scan
./nmap-scan.sh --cidr "192.168.1.0/24,10.0.0.0/24" --full

# Exclude hosts and limit rate
./nmap-scan.sh --exclude "192.168.1.10" --rate 50

# JSON only, no delta tracking
./nmap-scan.sh --output json --no-delta

# Dry run
./nmap-scan.sh --cidr "192.168.1.0/24" --dry-run
```

## Script-Specific Details

### disk-cleanup.sh

**New Flags (v1.0.1):**
- `--scan-venvs` - Scan and report Python virtualenv sizes/ages
- `--clean-venvs` - Remove stale virtualenvs based on thresholds
- `--venv-roots <PATHS>` - Colon-separated roots to scan (must be under `$HOME`)
- `--venv-age <DAYS>` - Minimum age in days (default: 30, range: 1-3650)
- `--venv-min-gb <GB>` - Minimum size in GB (default: 0.5, range: 0.01-100)
- `--docker-wait <SECS>` - Wait up to SECS for Docker to start (default: 60)
- `--skip-docker` - Skip Docker cleanup entirely (recommended for headless/cron)
- `--smart-gc` - Smart git gc (default: only large/old repos)
- `--full-gc` - Force git gc on all repositories
- `--gc-threshold <GB>` - Minimum pack size for GC (default: 1, range: 0.1-1000)
- `--gauge` / `--no-gauge` - Enable/disable live disk gauge (auto-disabled if not TTY)
- `--no-fun` - Disable fun facts between sections

**Key Functions:**
- `size_to_bytes()` / `bytes_to_human()` - Size unit conversions
- `get_dir_size_bytes()` - Cross-platform directory size with macOS vs Linux handling
- `track_freed_space()` - Accumulates total freed space
- `safe_remove()` - Safe deletion with size tracking
- `is_active_venv()` - Detects if virtualenv is currently active (skips deletion)
- `scan_virtualenvs()` - Reports venv candidates meeting thresholds
- `clean_virtualenvs()` - Removes stale venvs with safety checks

**Cleanup Sequence:**
1. VS Code caches (multiple directories)
2. Docker (with daemon startup if needed)
3. Git gc on repos in `~/repos` (smart or full mode)
4. Homebrew, NPM, Playwright, pnpm, pip, AWS CLI
5. Python virtualenvs (if `--clean-venvs`)

**Important:**
- Git gc uses 30-minute timeout protection and can take hours on large repos
- Smart GC only processes repos with pack >= 1GB OR age >= 30 days (20-30x faster)
- Active virtualenvs are never removed (safety check)

### Docker Behavior

**macOS Startup Strategies:**
- `open --background -a Docker` (preferred)
- `open -a Docker` (fallback)
- `open -a /Applications/Docker.app` (explicit path)
- `osascript -e 'tell application "Docker" to launch'` (AppleScript)

**Linux Startup Strategies:**
- `systemctl start docker` (systemd, requires sudo)
- `service docker start` (init.d, requires sudo)
- `dockerd` (direct daemon spawn, requires sudo)

**Sudo Warning:** On Linux, Docker operations prompt for sudo with explicit confirmation:
```
⚠ Docker startup requires elevated privileges
ℹ Operations that will use sudo:
  - systemctl start docker (or service docker start)
  - docker system prune (if needed)
? Grant sudo privileges for Docker operations? [y/N]
```

**Recommendations:**
- Start Docker Desktop manually when running from non-GUI shells (SSH, cron)
- Use `--skip-docker` in automated/headless environments
- Increase `--docker-wait` if startup is slow (default: 60s)

### rclone-sync.sh

**Architecture:**
- Background daemon with PID tracking at `~/.rclone-sync.pid`
- Excludes defined in `~/.rclone-exclude` (created automatically)
- Log rotation when exceeding 50MB
- Default: 8 parallel transfers, 5-minute stats interval

**Environment Variables:**
- `SOURCE_DIR` - Source directory (default: `~/repos`)
- `REMOTE_NAME` - rclone remote (default: `gdrive_new`)
- `TRANSFERS` - Parallel transfers (default: 8)
- `BANDWIDTH_LIMIT` - Upload speed limit (e.g., "10M")

**Process Management:**
- Uses trap handlers for SIGINT/SIGTERM cleanup
- Atomic PID file operations prevent race conditions
- Graceful shutdown with 10-second timeout before force kill
- Orphan process detection

### nmap-scan.sh

**Architecture:**
- CIDR auto-detection from primary network interface
- JSON output stored in `./logs/nmap/` with timestamps
- Latest scan symlinked for delta comparisons
- Secure logs: directory 700, files 600

**Scan Modes:**
- **Fast (default)**: Ping sweep + TCP SYN to ports 22, 80, 443
- **Full**: Top 1000 TCP ports (slower, requires `--full` flag)

**Key Features:**
- **Delta tracking**: Compares current scan with previous to show new/removed hosts
- **Rate limiting**: Default 100 pps, configurable with `--rate` (range: 1-10000)
- **Host exclusions**: Filter specific IPs or MAC patterns
- **Output modes**: JSON, table, or both
- **CIDR validation**: Supports comma-separated multi-subnet scans

**Command Options:**
- `--cidr CIDR` - Comma-separated CIDRs (auto-detects if not specified)
- `--fast` / `--full` - Scan intensity (default: fast)
- `--output MODE` - json, table, or both (default: both)
- `--no-delta` - Skip delta comparison
- `--exclude LIST` - Comma-separated IPs/MACs to exclude
- `--rate NUM` - Max packets per second (default: 100, range: 1-10000)
- `--dry-run` - Show configuration without scanning

**Security & Ethics:**
- Non-intrusive defaults (ping + 3 common ports only)
- Rate limiting prevents network flooding
- Explicit `--full` required for deeper scans
- Designed for local network discovery only
- All scans are detectable (no stealth mode)

**Important:**
- Requires `nmap` installed (brew install nmap / apt install nmap)
- Auto-detection works on both macOS (ifconfig + route) and Linux (ip command)
- XML parsing uses awk for cross-platform compatibility
 - CIDR input is validated; provide comma-separated values for multi-subnet scans

### update-all.sh

**Update Order:**
1. Homebrew (update, upgrade, cleanup)
2. NPM global packages
3. pnpm (self-update)
4. pip (self-update then packages, PEP 668 compliant)
5. RubyGems (system then gems)
6. macOS Software Update (check only, manual install)

**PEP 668 Compliance:**
- Detects externally-managed Python environments
- Skips system pip updates by default (safe)
- Use `--pip-system` to override (adds `--break-system-packages`)
- TTY detection for cron/CI compatibility

**Logging:** All output saved to `logs/update_YYYYMMDD_HHMMSS.log`

### smart-cleanup.sh

**Architecture:**
- Wrapper around `disk-cleanup.sh` with enhanced UI
- Two-phase: analysis (dry-run) then optional execution
- Real-time progress tracking with spinner animations
- Single-character input using `stty` for better UX

**Key Features:**
- Size calculations with color coding (RED >= 5GB, YELLOW >= 1GB, GREEN < 1GB)
- APFS container stats on macOS for accuracy
- Before/after disk comparison
- Interactive menu with options 1-4

**Auto Modes:**
- `--auto-best` - Quick cleanup (skip git gc)
- `--auto-full` - Full cleanup (include git gc)
- `--status` - Show analysis and exit

**Virtualenv Support (v1.0.1):**
- `--scan-venvs` - Scan Python virtualenvs
- `--clean-venvs` - Clean stale virtualenvs
- `--venv-roots <PATHS>` - Colon-separated roots
- `--venv-age <DAYS>` - Minimum age threshold
- `--venv-min-gb <GB>` - Minimum size threshold

## Platform Considerations

### macOS vs Linux

**Disk Usage:**
- macOS: Use `diskutil info /` for APFS container stats (more accurate)
- Linux: Use `df -h /`

**Directory Size:**
- macOS: `du -sk` (KB output)
- Linux: `du -sb` (byte output)

**File Stats:**
- macOS: `stat -f%z`
- Linux: `stat -c%s`

## Configuration Files

### Exclude File (~/.rclone-exclude)

Auto-generated by `rclone-sync.sh`. Edit with:
```bash
./rclone-sync.sh --edit-exclude
```

Default exclusions:
- `.git/**` - Git history
- `node_modules/**` - Node dependencies
- `**/.venv/**`, `**/venv/**` - Python virtual environments
- `**/*.pyc`, `__pycache__/**` - Python compiled files
- Build outputs (`dist/`, `build/`, `.next/`)
- IDE files (`.vscode/`, `.idea/`)

## Safety Notes

**disk-cleanup.sh:**
- Only removes caches and generated files
- Never touches source code or configurations
- Git gc is aggressive but safe (doesn't delete committed work)
- Playwright browsers need reinstall after cleanup
- Active virtualenvs are never removed (safety check)
- Path validation prevents deletion outside `$HOME`

**rclone-sync.sh:**
- Sync operation deletes remote files not present locally
- Always verify `SOURCE_DIR` before running
- Use `--dry-run` before first sync
- PID file prevents multiple instances

## Prerequisites

### For disk-cleanup.sh:
- No special requirements (skips unavailable tools)
- Optional: `coreutils` on macOS for timeout protection (`brew install coreutils`)
  - Without it, git gc runs without timeout (with warning)

### For rclone-sync.sh:
1. Install rclone: `brew install rclone`
2. Configure remote: `rclone config`
3. Verify: `rclone listremotes`

### For update-all.sh:
- Detects available package managers automatically
- PEP 668 compliant (safe for externally-managed Python)

### For smart-cleanup.sh:
- Requires `disk-cleanup.sh` in same directory
- Uses `awk` for all arithmetic operations (no bc dependency)
- Uses `stty` for single-char input in interactive menu

## Log Files

All scripts use timestamped logs with secure permissions:
- `logs/disk_cleanup_YYYYMMDD_HHMMSS.log` (disk-cleanup.sh, mode 600)
- `~/rclone-sync.log` (rclone-sync.sh, with auto-rotation)
- `logs/update_YYYYMMDD_HHMMSS.log` (update-all.sh, mode 600)
- `logs/cleanup_YYYYMMDD_HHMMSS.log` (smart-cleanup.sh, mode 600)

**Security:** Logs directory has permissions `700`, new logs have `600` (owner-only read/write)

## Error Recovery

### Stale PID Files

Scripts detect and clean stale PID files automatically. If issues persist:
```bash
rm -f ~/.rclone-sync.pid
pgrep -f "rclone sync" | xargs kill  # If orphaned
```

### Docker Not Starting

```bash
# macOS - start Docker Desktop
open -a Docker

# Linux - use systemctl
sudo systemctl start docker

# Or increase wait time
./disk-cleanup.sh --docker-wait 120
```

### Git gc Timeout

Git gc operations timeout after 30 minutes per repository. To skip:
```bash
./disk-cleanup.sh --skip-git-gc

# Or use smart GC (only large/old repos)
./disk-cleanup.sh --smart-gc --gc-threshold 2
```

### Gauge Not Visible

Live gauge requires TTY. For SSH/cron:
```bash
./disk-cleanup.sh --no-gauge --no-fun
```

## Development Workflow

### Installing the Pre-commit Hook

The repository includes a pre-commit hook for code quality checks:

```bash
# Install the hook (one-time setup)
ln -sf ../../.githooks/pre-commit .git/hooks/pre-commit

# Or copy it manually
cp .githooks/pre-commit .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```

**What the hook checks:**
- shellcheck validation (blocks on errors, excludes SC2034/SC2155)
- shfmt formatting (warns only, doesn't block)
- bc usage detection (blocks - use awk instead)
- Unsafe variable expansions in rm commands (warns)

**Dependencies:**
```bash
brew install shellcheck shfmt  # macOS
apt install shellcheck shfmt   # Linux
```

### CI/CD

GitHub Actions workflows run on every push/PR:
- **ShellCheck**: `shellcheck -S warning -e SC2034,SC2155 *.sh`
- **shfmt**: Format check (warns only)
- **Smoke tests**: Syntax validation, `--help`, `--dry-run`

**ShellCheck Policy:**
- Exclude SC2034: Unused variables (ok if documented/reserved)
- Exclude SC2155: Declare and assign separately (non-critical style)
- All other warnings are errors

See `.githooks/README.md` for detailed documentation.

## Troubleshooting

**Gauge not visible over SSH:**
- Requires TTY; use `--no-gauge` for non-interactive sessions

**Docker not starting within wait window:**
- Start Docker Desktop manually
- Or increase: `--docker-wait 120`
- Or skip entirely: `--skip-docker` (recommended for cron/headless)

**Path validation errors:**
- Venv roots must be under `$HOME`
- System directories blocked: `/usr`, `/etc`, `/var`, `/bin`, `/sbin`
- Use colon-separated paths: `--venv-roots "$HOME/repos:$HOME/projects"`

**Bounds validation errors:**
- `--gc-threshold`: Must be 0.1-1000 GB
- `--venv-age`: Must be 1-3650 days
- `--venv-min-gb`: Must be 0.01-100 GB
