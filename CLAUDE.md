# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a collection of Bash system maintenance scripts for macOS/Linux focused on disk cleanup, system updates, and automated backups. All scripts are written in Bash and designed to be run directly from the command line.

## Architecture

### Script Organization

The repository contains four main scripts that work independently:

1. **disk-cleanup.sh** - Comprehensive cache cleanup (VS Code, Docker, Git, Homebrew, NPM, pip, etc.)
2. **rclone-sync.sh** - Background daemon for continuous Google Drive backup with smart exclusions
3. **update-all.sh** - System-wide package manager updates (Homebrew, NPM, pnpm, pip, gem, macOS)
4. **smart-cleanup.sh** - Interactive wrapper around disk-cleanup.sh with beautiful UI and analysis

### Key Design Patterns

**Process Management**
- `rclone-sync.sh` implements proper daemon pattern with PID files, trap handlers, and graceful shutdown
- Atomic PID file operations using temp files and `mv` for safe concurrent access
- Background processes use `nohup` for terminal independence

**Error Handling**
- Scripts use `set -u` (fail on undefined variables) but NOT `set -e` to allow cleanup continuation
- Individual operations wrapped in error checking with continue-on-failure approach
- Comprehensive logging to timestamped files in `/tmp` or `~/logs`

**User Experience**
- Color-coded output with ANSI escape sequences (RED, GREEN, YELLOW, BLUE)
- Unicode symbols (✓, ✗, ⚠, ℹ) for visual feedback
- Dry run modes for safe preview
- Interactive confirmations with `-y` flag override
- Progress tracking with spinners and real-time updates

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

### Debugging

Check log files:
```bash
# Cleanup logs
tail -f /tmp/disk_cleanup_*.log

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

## Script-Specific Details

### disk-cleanup.sh

**Key Functions:**
- `size_to_bytes()` / `bytes_to_human()` - Size unit conversions
- `get_dir_size_bytes()` - Cross-platform directory size with macOS vs Linux handling
- `track_freed_space()` - Accumulates total freed space
- `safe_remove()` - Safe deletion with size tracking

**Cleanup Sequence:**
1. VS Code caches (multiple directories)
2. Docker (with daemon startup if needed)
3. Git gc on all repos in `~/repos` (skippable with `--skip-git-gc`)
4. Homebrew, NPM, Playwright, pnpm, pip, AWS CLI

**Important:** Git gc uses 30-minute timeout protection and can take hours on large repos.

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

### update-all.sh

**Update Order:**
1. Homebrew (update, upgrade, cleanup)
2. NPM global packages
3. pnpm (self-update)
4. pip (self-update then packages)
5. RubyGems (system then gems)
6. macOS Software Update (check only, manual install)

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

### Docker Daemon

Scripts detect Docker daemon status and offer to start on macOS:
```bash
open -a Docker  # macOS
systemctl start docker  # Linux
```

Wait up to 60 seconds for daemon startup before proceeding.

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

### For smart-cleanup.sh:
- Requires `disk-cleanup.sh` in same directory
- Uses `awk` for all arithmetic operations (no bc dependency)
- Uses `stty` for single-char input in interactive menu

## Log Files

All scripts use timestamped logs:
- `/tmp/disk_cleanup_YYYYMMDD_HHMMSS.log` (disk-cleanup.sh)
- `~/rclone-sync.log` (rclone-sync.sh, with auto-rotation)
- `logs/update_YYYYMMDD_HHMMSS.log` (update-all.sh)
- `logs/cleanup_YYYYMMDD_HHMMSS.log` (smart-cleanup.sh)

## Error Recovery

### Stale PID Files

Scripts detect and clean stale PID files automatically. If issues persist:
```bash
rm -f ~/.rclone-sync.pid
pgrep -f "rclone sync" | xargs kill  # If orphaned
```

### Docker Not Starting

```bash
# macOS
open -a Docker

# Linux
sudo systemctl start docker
```

### Git gc Timeout

Git gc operations timeout after 30 minutes per repository. To skip:
```bash
./disk-cleanup.sh --skip-git-gc
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
```

See `.githooks/README.md` for detailed documentation.
