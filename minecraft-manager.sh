#!/usr/bin/env bash
set -u

# minecraft-manager.sh - Start, stop, backup, and monitor a Minecraft server
# Version: 1.0.0
# Usage: ./minecraft-manager.sh <command> [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

LOG_DIR="${SCRIPT_DIR}/logs/minecraft"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RUN_START_TS=$(date +%s)
LOG_FILE="${LOG_DIR}/minecraft_${TIMESTAMP}.log"
JSON_FILE="${LOG_DIR}/minecraft_${TIMESTAMP}.json"

# Defaults
MC_DIR="${MC_DIR:-/home/pi/minecraft_server}"
MC_JAR="${MC_JAR:-}" # auto-detect
MC_PORT="${MC_PORT:-25565}"
MC_MEM_MIN="${MC_MEM_MIN:-512M}"
MC_MEM_MAX="${MC_MEM_MAX:-2G}"
MC_USER="${MC_USER:-pi}"
BACKUP_DIR="${MC_BACKUP_DIR:-${MC_DIR}/backups}"
BACKUP_RETAIN_DAYS=14
SCREEN_NAME="minecraft"
PID_FILE="${MC_DIR}/.minecraft.pid"

DRY_RUN=false
OUTPUT_JSON=false
COMMAND=""
STATUS_DATA=""

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_error() {
    echo -e "${RED}✗ Error:${NC} $1" >&2
    log_line "ERROR" "$1"
}
print_success() {
    echo -e "${GREEN}✓${NC} $1"
    log_line "OK" "$1"
}
print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
    log_line "WARN" "$1"
}
print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
    log_line "INFO" "$1"
}
print_section() {
    echo ""
    echo -e "${CYAN}━━━ $1 ━━━${NC}"
    echo ""
    log_line "SECTION" "$1"
}
log_line() { echo "[$(get_iso8601_timestamp)] $1: $2" >>"$LOG_FILE"; }

show_help() {
    cat <<'HELP'
minecraft-manager.sh - Start, stop, backup, and monitor a Minecraft server

USAGE:
    ./minecraft-manager.sh <COMMAND> [OPTIONS]

COMMANDS:
    start       Start the Minecraft server (in a screen session)
    stop        Send /stop command and wait for graceful shutdown
    restart     Stop then start
    status      Show server status, player count, memory usage
    backup      Create a timestamped world backup (stops server if running)
    logs        Tail server logs
    players     Show currently connected players
    console     Attach to the server console (Ctrl+A Ctrl+D to detach)
    update      Check for newer server JAR version

OPTIONS:
    --mc-dir <path>       Minecraft server directory (default: /home/pi/minecraft_server)
    --backup-dir <path>   Backup destination (default: <mc-dir>/backups)
    --mem-max <size>      JVM max heap (default: 2G)
    --retain-days <n>     Keep backups for N days (default: 14)
    --dry-run             Show what would happen without doing it
    --json                JSON output
    --help                Show this help

ENVIRONMENT:
    MC_DIR          Override server directory
    MC_JAR          Override JAR filename
    MC_PORT         Server port (default: 25565)
    MC_MEM_MAX      JVM max heap (default: 2G)
    MC_BACKUP_DIR   Override backup directory

EXAMPLES:
    # Check server status
    ./minecraft-manager.sh status

    # Start the server
    ./minecraft-manager.sh start

    # Create a backup
    ./minecraft-manager.sh backup

    # Tail logs
    ./minecraft-manager.sh logs

    # Attach to console
    ./minecraft-manager.sh console

EXIT CODES:
    0  Success
    1  Error or server not in expected state
    2  Fatal (directory not found, no JAR, etc.)
HELP
}

# ── Auto-detect JAR ───────────────────────────────────────────────────────────

detect_jar() {
    [ -n "$MC_JAR" ] && [ -f "${MC_DIR}/${MC_JAR}" ] && return
    # Look for common JAR names
    for pattern in "server.jar" "minecraft_server*.jar" "paper*.jar" "fabric*.jar" "spigot*.jar"; do
        local found
        found=$(find "$MC_DIR" -maxdepth 1 -name "$pattern" 2>/dev/null | head -1)
        if [ -n "$found" ]; then
            MC_JAR=$(basename "$found")
            return 0
        fi
    done
    return 1
}

# ── PID management ────────────────────────────────────────────────────────────

get_server_pid() {
    # Try PID file first
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return 0
        fi
    fi
    # Fall back to process search
    pgrep -f "${MC_JAR:-server.jar}" 2>/dev/null | head -1
}

is_running() {
    local pid
    pid=$(get_server_pid)
    [ -n "$pid" ]
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_status() {
    echo -e "${BOLD}━━━ Minecraft Server Status ━━━${NC}"
    echo ""
    print_info "Server dir:  $MC_DIR"
    print_info "Port:        $MC_PORT"

    if ! is_running; then
        print_warning "Server is STOPPED"
        STATUS_DATA='{"state":"stopped"}'
        return
    fi

    local pid
    pid=$(get_server_pid)

    # Memory usage
    local mem_kb mem_mb
    mem_kb=$(grep VmRSS "/proc/${pid}/status" 2>/dev/null | awk '{print $2}' || echo 0)
    mem_mb=$((mem_kb / 1024))

    # Uptime
    local start_time now_ts uptime_secs uptime_h uptime_m
    if [[ "$OSTYPE" == "darwin"* ]]; then
        start_time=$(stat -f%m "/proc/${pid}" 2>/dev/null || echo 0)
    else
        start_time=$(stat -c%Y "/proc/${pid}" 2>/dev/null || echo 0)
    fi
    now_ts=$(date +%s)
    uptime_secs=$((now_ts - start_time))
    uptime_h=$((uptime_secs / 3600))
    uptime_m=$(((uptime_secs % 3600) / 60))

    print_success "Server is RUNNING (PID: $pid)"
    printf "  Memory:    %d MB\n" "$mem_mb"
    printf "  Uptime:    %dh %dm\n" "$uptime_h" "$uptime_m"
    printf "  Port:      %d\n" "$MC_PORT"

    # Check if port is actually listening
    if ss -tlnp "sport = :${MC_PORT}" 2>/dev/null | grep -q ":${MC_PORT}"; then
        print_success "Port ${MC_PORT} is listening"
    else
        print_warning "Port ${MC_PORT} not yet listening (server may be loading)"
    fi

    # Latest log activity
    local latest_log="${MC_DIR}/logs/latest.log"
    if [ -f "$latest_log" ]; then
        echo ""
        print_info "Recent log:"
        tail -5 "$latest_log" | while read -r line; do
            echo "  $line"
        done
    fi

    STATUS_DATA=$(printf '{"state":"running","pid":%s,"mem_mb":%d,"uptime_secs":%d}' \
        "$pid" "$mem_mb" "$uptime_secs")
}

cmd_start() {
    if is_running; then
        local pid
        pid=$(get_server_pid)
        print_warning "Server already running (PID: $pid)"
        return 0
    fi

    detect_jar || {
        print_error "No server JAR found in $MC_DIR"
        return 2
    }

    if [ "$DRY_RUN" = true ]; then
        print_warning "[DRY RUN] would start: java -Xms${MC_MEM_MIN} -Xmx${MC_MEM_MAX} -jar ${MC_JAR}"
        return 0
    fi

    print_info "Starting Minecraft server..."
    print_info "JAR: $MC_JAR  Mem: ${MC_MEM_MIN}-${MC_MEM_MAX}"

    if command -v screen >/dev/null 2>&1; then
        local escaped_mc_dir escaped_mc_jar
        escaped_mc_dir=$(printf '%q' "${MC_DIR}")
        escaped_mc_jar=$(printf '%q' "${MC_JAR}")
        screen -dmS "$SCREEN_NAME" bash -c "cd ${escaped_mc_dir} && java -Xms${MC_MEM_MIN} -Xmx${MC_MEM_MAX} -jar ${escaped_mc_jar} nogui"
        sleep 3
        local new_pid
        new_pid=$(get_server_pid)
        if [ -n "$new_pid" ]; then
            echo "$new_pid" >"$PID_FILE"
            print_success "Server started in screen session '${SCREEN_NAME}' (PID: $new_pid)"
            print_info "Attach with: screen -r $SCREEN_NAME"
        else
            print_error "Server process not found after start — check logs"
            return 1
        fi
    else
        print_warning "screen not installed — starting in background with nohup"
        nohup java -Xms"${MC_MEM_MIN}" -Xmx"${MC_MEM_MAX}" -jar "${MC_DIR}/${MC_JAR}" nogui \
            >>"${MC_DIR}/logs/server.log" 2>&1 &
        echo $! >"$PID_FILE"
        print_success "Server started (PID: $!)"
    fi

    log_line "START" "server started"
}

cmd_stop() {
    if ! is_running; then
        print_warning "Server is not running"
        return 0
    fi

    local pid
    pid=$(get_server_pid)

    if [ "$DRY_RUN" = true ]; then
        print_warning "[DRY RUN] would stop server (PID: $pid)"
        return 0
    fi

    print_info "Sending /stop command to server (PID: $pid)..."

    # Send stop via screen if available
    if command -v screen >/dev/null 2>&1 && screen -list 2>/dev/null | grep -q "$SCREEN_NAME"; then
        screen -S "$SCREEN_NAME" -p 0 -X stuff "stop$(printf '\r')"
    else
        kill -SIGTERM "$pid" 2>/dev/null
    fi

    # Wait for graceful shutdown
    local waited=0
    while is_running && [ "$waited" -lt 30 ]; do
        sleep 1
        waited=$((waited + 1))
        printf "."
    done
    echo ""

    if is_running; then
        print_warning "Server didn't stop gracefully after 30s — killing"
        kill -9 "$pid" 2>/dev/null || true
    fi

    rm -f "$PID_FILE"
    print_success "Server stopped"
    log_line "STOP" "server stopped"
}

cmd_backup() {
    print_info "Starting backup..."

    local was_running=false
    if is_running; then
        was_running=true
        if [ "$DRY_RUN" = false ]; then
            print_info "Server is running — sending save-all before backup"
            if command -v screen >/dev/null 2>&1 && screen -list 2>/dev/null | grep -q "$SCREEN_NAME"; then
                screen -S "$SCREEN_NAME" -p 0 -X stuff "save-all$(printf '\r')"
                sleep 3
            fi
        fi
    fi

    mkdir -p "$BACKUP_DIR"
    local backup_name="world_backup_${TIMESTAMP}.tar.gz"
    local backup_path="${BACKUP_DIR}/${backup_name}"

    if [ "$DRY_RUN" = true ]; then
        print_warning "[DRY RUN] would backup world → $backup_path"
        return 0
    fi

    # Find world directories
    local world_dirs=()
    for d in world world_nether world_the_end; do
        [ -d "${MC_DIR}/${d}" ] && world_dirs+=("$d")
    done

    if [ ${#world_dirs[@]} -eq 0 ]; then
        print_error "No world directories found in $MC_DIR"
        return 1
    fi

    print_info "Backing up: ${world_dirs[*]}"
    tar -czf "$backup_path" -C "$MC_DIR" "${world_dirs[@]}" 2>/dev/null && {
        local sz
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sz=$(stat -f%z "$backup_path" 2>/dev/null || echo 0)
        else
            sz=$(stat -c%s "$backup_path" 2>/dev/null || echo 0)
        fi
        print_success "Backup created: $backup_name ($(numfmt --to=iec "$sz" 2>/dev/null || echo "${sz}B"))"
        log_line "BACKUP" "$backup_path"
    } || {
        print_error "Backup failed"
        return 1
    }

    # Prune old backups
    local pruned=0
    while IFS= read -r old; do
        rm -f "$old"
        pruned=$((pruned + 1))
    done < <(find "$BACKUP_DIR" -name "world_backup_*.tar.gz" -mtime "+${BACKUP_RETAIN_DAYS}" 2>/dev/null)
    [ "$pruned" -gt 0 ] && print_info "Pruned $pruned backup(s) older than ${BACKUP_RETAIN_DAYS} days"

    # List backups
    echo ""
    print_info "Backups in $BACKUP_DIR:"
    find "$BACKUP_DIR" -name "world_backup_*.tar.gz" -printf "%T@ %f %s\n" 2>/dev/null |
        sort -rn |
        head -10 |
        while read -r _ name sz; do
            printf "  %-45s %s\n" "$name" "$(numfmt --to=iec "$sz" 2>/dev/null || echo "${sz}B")"
        done
}

cmd_logs() {
    local log_file="${MC_DIR}/logs/latest.log"
    if [ ! -f "$log_file" ]; then
        print_error "Log file not found: $log_file"
        return 1
    fi
    print_info "Tailing $log_file — Ctrl+C to stop"
    tail -f "$log_file"
}

cmd_players() {
    local log_file="${MC_DIR}/logs/latest.log"
    if [ ! -f "$log_file" ]; then
        print_error "Log file not found: $log_file"
        return 1
    fi

    print_section "Player Activity (today)"

    # Logins
    local logins
    logins=$(grep "logged in with entity id\|joined the game" "$log_file" 2>/dev/null | tail -20)
    echo "  Recent joins:"
    echo "$logins" | while read -r line; do
        echo "  $line"
    done

    # Current online count from log
    local online
    online=$(grep "There are" "$log_file" 2>/dev/null | tail -1)
    [ -n "$online" ] && print_info "$online"
}

cmd_console() {
    if ! command -v screen >/dev/null 2>&1; then
        print_error "screen is not installed — cannot attach to console"
        return 1
    fi
    if ! screen -list 2>/dev/null | grep -q "$SCREEN_NAME"; then
        print_error "No screen session named '$SCREEN_NAME' found"
        print_info "Is the server running? Start with: ./minecraft-manager.sh start"
        return 1
    fi
    print_info "Attaching to console — Ctrl+A Ctrl+D to detach"
    screen -r "$SCREEN_NAME"
}

cmd_update() {
    print_section "Version Check"

    detect_jar || {
        print_error "No server JAR found"
        return 2
    }

    local current_jar="${MC_DIR}/${MC_JAR}"
    local current_size
    if [[ "$OSTYPE" == "darwin"* ]]; then
        current_size=$(stat -f%z "$current_jar" 2>/dev/null || echo 0)
    else
        current_size=$(stat -c%s "$current_jar" 2>/dev/null || echo 0)
    fi
    local current_modified
    if [[ "$OSTYPE" == "darwin"* ]]; then
        current_modified=$(stat -f "%Sm" -t "%Y-%m-%d" "$current_jar" 2>/dev/null)
    else
        current_modified=$(stat -c%y "$current_jar" 2>/dev/null | cut -d' ' -f1)
    fi

    print_info "Current JAR: $MC_JAR"
    print_info "Size: $(numfmt --to=iec "$current_size" 2>/dev/null || echo "${current_size}B")"
    print_info "Last modified: $current_modified"
    print_info ""
    print_info "To update: download new JAR from https://www.minecraft.net/en-us/download/server"
    print_info "Then: ./minecraft-manager.sh stop && mv new-server.jar $MC_DIR/$MC_JAR && ./minecraft-manager.sh start"
}

# ── Parse args ────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
    start | stop | restart | status | backup | logs | players | console | update)
        COMMAND="$1"
        shift
        ;;
    --mc-dir)
        MC_DIR="$2"
        shift 2
        ;;
    --backup-dir)
        BACKUP_DIR="$2"
        shift 2
        ;;
    --mem-max)
        MC_MEM_MAX="$2"
        shift 2
        ;;
    --retain-days)
        BACKUP_RETAIN_DAYS="$2"
        shift 2
        ;;
    --dry-run)
        DRY_RUN=true
        shift
        ;;
    --json)
        OUTPUT_JSON=true
        shift
        ;;
    --help | -h)
        show_help
        exit 0
        ;;
    *)
        echo "Unknown option: $1" >&2
        show_help
        exit 2
        ;;
    esac
done

# ── Validate user-supplied paths ─────────────────────────────────────────────

validate_output_dir "$MC_DIR" || exit 1
validate_output_dir "$BACKUP_DIR" || exit 1

# ── Setup ─────────────────────────────────────────────────────────────────────

umask 077
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

require_jq_if_json "$OUTPUT_JSON" || exit 2

if [ -z "$COMMAND" ]; then
    echo "Error: command required" >&2
    show_help
    exit 2
fi

if [ ! -d "$MC_DIR" ]; then
    print_error "Minecraft server directory not found: $MC_DIR"
    print_info "Set with --mc-dir or export MC_DIR=/path/to/minecraft"
    exit 2
fi

EXIT_CODE=0

case "$COMMAND" in
status) cmd_status ;;
start) cmd_start ;;
stop) cmd_stop ;;
restart) cmd_stop && sleep 2 && cmd_start ;;
backup) cmd_backup ;;
logs) cmd_logs ;;
players) cmd_players ;;
console) cmd_console ;;
update) cmd_update ;;
esac

EXIT_CODE=$?

RUN_END_TS=$(date +%s)
DURATION_MS=$(((RUN_END_TS - RUN_START_TS) * 1000))

if [ "$OUTPUT_JSON" = true ]; then
    jq -n \
        --arg script "minecraft-manager.sh" \
        --arg version "1.0.0" \
        --arg timestamp "$(get_iso8601_timestamp)" \
        --arg command "$COMMAND" \
        --argjson duration_ms "$DURATION_MS" \
        --argjson exit_code "$EXIT_CODE" \
        '{
            script: $script,
            version: $version,
            timestamp: $timestamp,
            status: (if $exit_code == 0 then "ok" else "error" end),
            duration_ms: $duration_ms,
            errors: [],
            result: {
                command: $command,
                exit_code: $exit_code
            }
        }' >"$JSON_FILE"
    chmod 600 "$JSON_FILE"
    print_info "JSON: $JSON_FILE"
fi

exit $EXIT_CODE
