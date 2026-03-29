#!/usr/bin/env bash
set -u

# disk-assistant.sh - Launch an interactive Claude Code session focused on
# safely freeing disk space on this system.
#
# Claude will be given live context: current disk usage, largest directories,
# available cleanup scripts, and recent log output. It will NOT delete anything
# without explaining what it is and why it is safe to remove.
#
# Usage: ./disk-assistant.sh [--dry-run] [--no-scan]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=false
SKIP_SCAN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
    --dry-run)
        DRY_RUN=true
        shift
        ;;
    --no-scan)
        SKIP_SCAN=true
        shift
        ;;
    --help | -h)
        cat <<'HELP'
disk-assistant.sh - Interactive Claude Code disk cleanup session

USAGE:
    ./disk-assistant.sh [OPTIONS]

OPTIONS:
    --dry-run   Show the system prompt that would be sent, then exit
    --no-scan   Skip the du top-directories scan (faster startup)
    --help      Show this help

WHAT IT DOES:
    1. Gathers live disk usage, mount points, and largest directories
    2. Lists available cleanup scripts and their last-run dates
    3. Launches an interactive Claude Code session with that context
    4. Claude will suggest cleanup actions, run dry-runs first, and ask
       before deleting anything

REQUIREMENTS:
    claude   Claude Code CLI must be installed and authenticated
             Install: https://github.com/anthropics/claude-code
HELP
        exit 0
        ;;
    *)
        echo "Unknown option: $1" >&2
        exit 1
        ;;
    esac
done

# ── Pre-flight ────────────────────────────────────────────────────────────────

if ! command -v claude >/dev/null 2>&1; then
    echo "Error: 'claude' CLI not found." >&2
    echo "Install Claude Code: https://github.com/anthropics/claude-code" >&2
    exit 1
fi

# ── Gather system context ─────────────────────────────────────────────────────

gather_context() {
    # Disk usage overview
    local disk_info
    disk_info=$(df -h --output=source,size,used,avail,pcent,target 2>/dev/null |
        grep -v "^tmpfs\|^udev\|^devtmpfs\|^overlay\|^none\|^Filesystem" ||
        df -h | tail -n +2)

    # Top space consumers (optional — can be slow on large trees)
    local top_dirs=""
    if [ "$SKIP_SCAN" = false ]; then
        top_dirs=$(du -sh "${HOME}"/* 2>/dev/null |
            sort -rn |
            head -10 |
            awk '{printf "  %-10s %s\n", $1, $2}' ||
            true)
        # Also check /var/log and /tmp if accessible
        local extra
        extra=$(du -sh /var/log /tmp /var/cache 2>/dev/null |
            sort -rn |
            awk '{printf "  %-10s %s\n", $1, $2}' ||
            true)
        [ -n "$extra" ] && top_dirs="${top_dirs}
${extra}"
    fi

    # Available cleanup scripts in SCRIPT_DIR
    local scripts_list
    scripts_list=$(find "${SCRIPT_DIR}" -maxdepth 1 -name "*.sh" -printf "%f\n" 2>/dev/null |
        grep -v "^disk-assistant" |
        sort |
        tr '\n' ' ')

    # Most recent QA run result (if any)
    local last_qa=""
    local last_qa_json
    last_qa_json=$(ls -t "${SCRIPT_DIR}/logs/qa/run_"*/summary.json 2>/dev/null | head -1)
    if [ -n "$last_qa_json" ] && command -v jq >/dev/null 2>&1; then
        local total passed failed
        total=$(jq -r '.totals.total' "$last_qa_json" 2>/dev/null || echo "?")
        passed=$(jq -r '.totals.passed' "$last_qa_json" 2>/dev/null || echo "?")
        failed=$(jq -r '.totals.failed' "$last_qa_json" 2>/dev/null || echo "?")
        last_qa="Last QA run: ${passed}/${total} passed, ${failed} failed"
    fi

    # Last disk-cleanup run
    local last_cleanup=""
    local last_cleanup_log
    last_cleanup_log=$(ls -t "${SCRIPT_DIR}/logs/disk_cleanup_"*.log 2>/dev/null | head -1)
    if [ -n "$last_cleanup_log" ]; then
        last_cleanup="Last disk-cleanup run: $(basename "$last_cleanup_log" .log | sed 's/disk_cleanup_//')"
    fi

    # OS info
    local os_info
    os_info=$(uname -srm 2>/dev/null || echo "unknown")

    # Current user and hostname
    local whoami_out hostname_out
    whoami_out=$(id -un 2>/dev/null || echo "$USER")
    hostname_out=$(hostname -s 2>/dev/null || echo "unknown")

    # Docker disk usage (if available)
    local docker_info=""
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        docker_info=$(docker system df 2>/dev/null | tail -n +2 |
            awk '{printf "  %-20s %s reclaimable\n", $1, $NF}' || true)
    fi

    cat <<CONTEXT
=== DISK SPACE CLEANUP ASSISTANT — SYSTEM CONTEXT ===

Host:    ${hostname_out} (${whoami_out})
OS:      ${os_info}
Scripts: ${SCRIPT_DIR}

--- Disk Usage ---
${disk_info}

--- Largest directories under \$HOME ---
${top_dirs:-  (scan skipped — run without --no-scan to include)}

--- Docker disk usage ---
${docker_info:-  (Docker not available or not running)}

--- Available cleanup scripts ---
${scripts_list}

--- Recent activity ---
${last_cleanup:-  No disk-cleanup run found}
${last_qa:-  No QA run found}

=== END CONTEXT ===
CONTEXT
}

# ── Build system prompt ───────────────────────────────────────────────────────

build_system_prompt() {
    local ctx="$1"

    cat <<PROMPT
You are a disk space management assistant for this Linux system. Your only goal
is to help the user safely reclaim disk space without losing any data they need.

GROUND RULES — follow these absolutely:
1. NEVER delete files without first explaining exactly what they are and why
   they are safe to remove.
2. ALWAYS run --dry-run first for any cleanup script before running for real.
3. NEVER remove source code, configuration files, dotfiles, SSH keys, database
   files, or anything in a git repository's working tree.
4. If unsure whether something is safe to delete, say so and suggest the user
   verify manually before proceeding.
5. Prefer the existing scripts in ${SCRIPT_DIR} over ad-hoc shell commands —
   they have safety checks, dry-run modes, and logging built in.
6. When you run a script, capture and show the output so the user can review it.
7. After any real cleanup, show before/after disk usage with df -h.

AVAILABLE TOOLS IN ${SCRIPT_DIR}:
- disk-cleanup.sh      Main cleanup: Docker, Git gc, NPM/pip caches, virtualenvs
                       Key flags: --dry-run, -y, --skip-docker, --no-gauge, --no-fun
                       Start with: ./disk-cleanup.sh --dry-run --no-gauge --no-fun
- smart-cleanup.sh     Interactive wrapper with analysis and before/after comparison
                       Start with: ./smart-cleanup.sh --status
- plex-cleanup.sh      Plex cache, transcoder, duplicate media
                       Start with: ./plex-cleanup.sh --dry-run
- log-manager.sh       Compress/delete old logs, vacuum systemd journal
                       Start with: ./log-manager.sh --dry-run
- docker-health.sh     Docker resource inventory, prune dangling images/volumes
                       Start with: ./docker-health.sh --dry-run
- update-all.sh        Package manager updates (can free space by cleaning caches)

WHAT IS SAFE TO REMOVE (generally):
- Package manager caches (npm, pip, apt, brew): always regeneratable
- Docker build cache, dangling images, stopped containers, orphaned volumes
  (if not needed for rollback)
- Git gc / loose objects in bare or archived repos
- Log files older than your retention policy (compress first, delete later)
- Plex transcode cache, codec cache, crash reports
- Browser caches, IDE caches, VS Code extension caches
- Python .pyc files and __pycache__ directories
- tmp files in /tmp older than a day

WHAT IS NOT SAFE TO REMOVE (never touch these):
- Anything in a git working tree (source code)
- Configuration files (.env, *.conf, *.yaml, *.toml, *.json that aren't caches)
- SSH keys (~/.ssh/)
- Database files (*.db, *.sqlite, *.sql, backup dumps)
- Docker volumes that are actively used by running containers
- The user's home directory files unless explicitly cache directories

LIVE SYSTEM CONTEXT:
${ctx}

Start by summarising the current disk situation based on the context above,
identify the biggest opportunities for safe cleanup, and ask the user where
they'd like to start.
PROMPT
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo "Gathering system context..."
CONTEXT=$(gather_context)
SYSTEM_PROMPT=$(build_system_prompt "$CONTEXT")

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "=== System prompt that would be sent to Claude ==="
    echo ""
    echo "$SYSTEM_PROMPT"
    echo ""
    echo "=== (dry-run — not launching claude) ==="
    exit 0
fi

echo ""
echo "Launching Claude Code disk cleanup session..."
echo "(Type 'exit' or Ctrl+D to end the session)"
echo ""

cd "$SCRIPT_DIR" || exit 1
exec claude \
    --append-system-prompt "$SYSTEM_PROMPT" \
    "Please analyse the disk situation from the system context you've been given and suggest the safest, highest-impact cleanup actions."
