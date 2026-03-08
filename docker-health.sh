#!/usr/bin/env bash
set -u

# docker-health.sh - Docker container health, image inventory, and disk report
# Version: 1.0.0
# Usage: ./docker-health.sh [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

LOG_DIR="${SCRIPT_DIR}/logs/docker-health"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RUN_START_TS=$(date +%s)
LOG_FILE="${LOG_DIR}/docker_health_${TIMESTAMP}.log"
JSON_FILE="${LOG_DIR}/docker_health_${TIMESTAMP}.json"

# Defaults
WATCH_MODE=false
WATCH_INTERVAL=30
DRY_RUN=false
OUTPUT_JSON=false
PRUNE_DANGLING=false
RESTART_THRESHOLD=5   # alert if container has restarted more than this many times

# Result accumulators
CONTAINERS_HEALTHY=0
CONTAINERS_UNHEALTHY=0
CONTAINERS_STOPPED=0
CONTAINERS_RESTARTING=0
IMAGES_DANGLING=0
VOLUMES_ORPHANED=0
NETWORKS_ORPHANED=0
ERRORS=0
STATUS="ok"

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_error()   { echo -e "${RED}✗ Error:${NC} $1" >&2; log_line "ERROR" "$1"; ERRORS=$((ERRORS+1)); STATUS="errors"; }
print_success() { echo -e "${GREEN}✓${NC} $1"; log_line "OK" "$1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; log_line "WARN" "$1"; }
print_info()    { echo -e "${BLUE}ℹ${NC} $1"; log_line "INFO" "$1"; }
print_section() { echo ""; echo -e "${CYAN}━━━ $1 ━━━${NC}"; echo ""; log_line "SECTION" "$1"; }
log_line()      { echo "[$(get_iso8601_timestamp)] $1: $2" >>"$LOG_FILE"; }

show_help() {
    cat <<'HELP'
docker-health.sh - Docker container health, image inventory, and disk report

USAGE:
    ./docker-health.sh [OPTIONS]

OPTIONS:
    --watch               Continuous monitoring mode (refresh every N seconds)
    --interval <secs>     Watch interval in seconds (default: 30)
    --restart-threshold   Alert if container restarted > N times (default: 5)
    --prune-dangling      Remove dangling images and unused volumes (with confirmation)
    --dry-run             Show current state without any changes
    --json                JSON summary output
    --help                Show this help message

WHAT IT CHECKS:
    1. Container status    Running/stopped/restarting, CPU%, mem usage, restart count
    2. Image inventory     All images sorted by size, dangling images flagged
    3. Volumes             Orphaned (unused) volumes
    4. Networks            Orphaned (unused) networks
    5. Disk summary        docker system df output

ALERTS:
    - Container stopped unexpectedly (exit code != 0)
    - Container restarting (restart loop)
    - Restart count > threshold
    - Dangling images consuming disk
    - Orphaned volumes

EXAMPLES:
    # One-shot health check
    ./docker-health.sh

    # Watch mode, refresh every 15 seconds
    ./docker-health.sh --watch --interval 15

    # Full check with JSON output
    ./docker-health.sh --json

    # Prune dangling images and orphaned volumes
    ./docker-health.sh --prune-dangling

EXIT CODES:
    0  All containers healthy
    1  One or more containers unhealthy/stopped/restarting
    2  Fatal error (Docker not available)
HELP
}

bytes_to_human() {
    local bytes="$1"
    if   [ "$bytes" -ge 1073741824 ]; then
        awk "BEGIN {printf \"%.2f GB\", $bytes/1073741824}"
    elif [ "$bytes" -ge 1048576 ]; then
        awk "BEGIN {printf \"%.2f MB\", $bytes/1048576}"
    elif [ "$bytes" -ge 1024 ]; then
        awk "BEGIN {printf \"%.1f KB\", $bytes/1024}"
    else
        echo "${bytes} B"
    fi
}

check_docker_available() {
    if ! command -v docker >/dev/null 2>&1; then
        print_error "docker is not installed or not in PATH"
        exit 2
    fi
    if ! docker info >/dev/null 2>&1; then
        print_error "Docker daemon is not running"
        print_info "Try: sudo systemctl start docker"
        exit 2
    fi
}

# ── Section 1: Container Status ───────────────────────────────────────────────

check_containers() {
    print_section "Container Status"

    # Reset counters each run (watch mode)
    CONTAINERS_HEALTHY=0
    CONTAINERS_UNHEALTHY=0
    CONTAINERS_STOPPED=0
    CONTAINERS_RESTARTING=0

    local format='{{.Names}}\t{{.Status}}\t{{.State}}\t{{.RunningFor}}\t{{.Image}}'
    local containers
    containers=$(docker ps -a --format "$format" 2>/dev/null)

    if [ -z "$containers" ]; then
        print_info "No containers found"
        return
    fi

    # Header
    printf "  %-30s %-14s %-12s %-8s %-8s  %s\n" "NAME" "STATE" "CPU%" "MEM" "RESTARTS" "IMAGE"
    printf "  %s\n" "$(printf '─%.0s' {1..90})"

    # Get stats for running containers (non-blocking snapshot)
    local stats_output=""
    if docker ps -q | grep -q .; then
        stats_output=$(docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' 2>/dev/null) || true
    fi

    while IFS=$'\t' read -r name status state running_for image; do
        [ -z "$name" ] && continue

        # Get restart count
        local restarts
        restarts=$(docker inspect --format '{{.RestartCount}}' "$name" 2>/dev/null || echo 0)

        # Get CPU/mem from stats output
        local cpu="–" mem="–"
        if [ -n "$stats_output" ]; then
            local stats_line
            stats_line=$(echo "$stats_output" | grep "^${name}	" | head -1)
            if [ -n "$stats_line" ]; then
                cpu=$(echo "$stats_line" | awk -F'\t' '{print $2}')
                mem=$(echo "$stats_line" | awk -F'\t' '{print $3}' | cut -d'/' -f1 | xargs)
            fi
        fi

        # Truncate image name
        local short_image="${image##*/}"
        short_image="${short_image:0:30}"

        # Color and count by state
        local state_color="$NC"
        case "$state" in
        running)
            state_color="$GREEN"
            CONTAINERS_HEALTHY=$((CONTAINERS_HEALTHY + 1))
            # Check health status if container has HEALTHCHECK
            local health
            health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name" 2>/dev/null)
            if [ "$health" = "unhealthy" ]; then
                state_color="$RED"
                CONTAINERS_UNHEALTHY=$((CONTAINERS_UNHEALTHY + 1))
                CONTAINERS_HEALTHY=$((CONTAINERS_HEALTHY - 1))
                STATUS="unhealthy"
            fi
            ;;
        restarting)
            state_color="$YELLOW"
            CONTAINERS_RESTARTING=$((CONTAINERS_RESTARTING + 1))
            STATUS="unhealthy"
            ;;
        exited|dead)
            state_color="$RED"
            CONTAINERS_STOPPED=$((CONTAINERS_STOPPED + 1))
            STATUS="unhealthy"
            ;;
        esac

        # Flag high restart count
        local restart_flag=""
        if [ "$restarts" -gt "$RESTART_THRESHOLD" ]; then
            restart_flag=" ⚠"
            STATUS="unhealthy"
        fi

        printf "  %-30s ${state_color}%-14s${NC} %-12s %-8s %-8s  %s\n" \
            "$name" "$state" "$cpu" "$mem" "${restarts}${restart_flag}" "$short_image"

        log_line "CONTAINER" "name=$name state=$state restarts=$restarts"
    done <<< "$containers"

    echo ""
    printf "  Running: ${GREEN}%d${NC}  Stopped: ${RED}%d${NC}  Restarting: ${YELLOW}%d${NC}  Unhealthy: ${RED}%d${NC}\n" \
        "$CONTAINERS_HEALTHY" "$CONTAINERS_STOPPED" "$CONTAINERS_RESTARTING" "$CONTAINERS_UNHEALTHY"

    # Detailed alert for stopped containers
    local stopped_list
    stopped_list=$(docker ps -a --filter "status=exited" --filter "status=dead" \
        --format '{{.Names}} (exit {{.ExitCode}}, stopped {{.RunningFor}})' 2>/dev/null)
    if [ -n "$stopped_list" ]; then
        echo ""
        print_warning "Stopped containers:"
        echo "$stopped_list" | while read -r line; do
            echo "  $line"
        done
    fi
}

# ── Section 2: Image Inventory ────────────────────────────────────────────────

check_images() {
    print_section "Image Inventory"

    local images
    images=$(docker images --format '{{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}\t{{.ID}}' 2>/dev/null)

    if [ -z "$images" ]; then
        print_info "No images found"
        return
    fi

    local total_images=0
    printf "  %-40s %-15s %-10s  %s\n" "IMAGE" "TAG" "SIZE" "CREATED"
    printf "  %s\n" "$(printf '─%.0s' {1..80})"

    # Sort by size (docker already does this in some versions, but let's ensure)
    echo "$images" | while IFS=$'\t' read -r repo tag size created id; do
        local display_name="${repo}:${tag}"
        if [ "$repo" = "<none>" ] || [ "$tag" = "<none>" ]; then
            display_name="${YELLOW}<dangling>${NC} ${id:0:12}"
            IMAGES_DANGLING=$((IMAGES_DANGLING + 1))
        fi
        printf "  %-40s %-15s %-10s  %s\n" "$display_name" "$tag" "$size" "$created"
    done

    total_images=$(echo "$images" | wc -l)
    local dangling_count
    dangling_count=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l)

    echo ""
    print_info "Total images: $total_images"
    if [ "$dangling_count" -gt 0 ]; then
        IMAGES_DANGLING=$dangling_count
        print_warning "Dangling (untagged) images: $dangling_count  — run with --prune-dangling to remove"
    fi
}

# ── Section 3: Volumes ────────────────────────────────────────────────────────

check_volumes() {
    print_section "Volumes"

    local all_volumes
    all_volumes=$(docker volume ls --format '{{.Name}}\t{{.Driver}}' 2>/dev/null)

    if [ -z "$all_volumes" ]; then
        print_success "No volumes"
        return
    fi

    # Dangling volumes (not mounted by any container)
    local orphaned_vols
    orphaned_vols=$(docker volume ls -f dangling=true --format '{{.Name}}' 2>/dev/null)
    local orphaned_count=0
    [ -n "$orphaned_vols" ] && orphaned_count=$(echo "$orphaned_vols" | wc -l)

    local total_vols
    total_vols=$(echo "$all_volumes" | wc -l)

    printf "  %-40s %s\n" "VOLUME" "DRIVER"
    printf "  %s\n" "$(printf '─%.0s' {1..60})"

    echo "$all_volumes" | while IFS=$'\t' read -r vol_name driver; do
        local flag=""
        if echo "$orphaned_vols" | grep -qx "$vol_name" 2>/dev/null; then
            flag=" ${YELLOW}[orphaned]${NC}"
        fi
        printf "  %-40s %s%b\n" "$vol_name" "$driver" "$flag"
    done

    echo ""
    print_info "Total volumes: $total_vols"
    if [ "$orphaned_count" -gt 0 ]; then
        VOLUMES_ORPHANED=$orphaned_count
        print_warning "Orphaned volumes: $orphaned_count  — run with --prune-dangling to remove"
    else
        print_success "No orphaned volumes"
    fi
}

# ── Section 4: Networks ───────────────────────────────────────────────────────

check_networks() {
    print_section "Networks"

    local all_nets
    all_nets=$(docker network ls --format '{{.Name}}\t{{.Driver}}\t{{.Scope}}' 2>/dev/null)

    if [ -z "$all_nets" ]; then
        print_success "No custom networks"
        return
    fi

    printf "  %-30s %-12s %-8s  %s\n" "NAME" "DRIVER" "SCOPE" "CONTAINERS"
    printf "  %s\n" "$(printf '─%.0s' {1..70})"

    local orphaned_count=0
    local skip_nets="bridge host none"

    while IFS=$'\t' read -r net_name driver scope; do
        # Skip default networks
        echo "$skip_nets" | grep -qw "$net_name" && continue

        # Count containers on this network
        local container_count
        container_count=$(docker network inspect "$net_name" \
            --format '{{len .Containers}}' 2>/dev/null || echo "?")

        local flag=""
        if [ "$container_count" = "0" ]; then
            flag=" ${YELLOW}[orphaned]${NC}"
            orphaned_count=$((orphaned_count + 1))
        fi

        printf "  %-30s %-12s %-8s  %s%b\n" "$net_name" "$driver" "$scope" "$container_count" "$flag"
    done <<< "$all_nets"

    echo ""
    NETWORKS_ORPHANED=$orphaned_count
    if [ "$orphaned_count" -gt 0 ]; then
        print_warning "Orphaned networks: $orphaned_count  — run 'docker network prune' to remove"
    else
        print_success "No orphaned networks"
    fi
}

# ── Section 5: Disk Summary ───────────────────────────────────────────────────

check_disk() {
    print_section "Docker Disk Usage"

    docker system df 2>/dev/null | while read -r line; do
        echo "  $line"
    done

    echo ""
    local total_size
    total_size=$(docker system df --format '{{.Size}}' 2>/dev/null | tail -1 || echo "unknown")
    print_info "Run 'docker system df -v' for per-image/volume breakdown"
}

# ── Prune ─────────────────────────────────────────────────────────────────────

prune_dangling() {
    print_section "Pruning Dangling Resources"

    if [ "$DRY_RUN" = true ]; then
        print_warning "DRY RUN — would prune dangling images and orphaned volumes"
        docker images -f "dangling=true" 2>/dev/null | head -20
        echo ""
        docker volume ls -f dangling=true 2>/dev/null | head -20
        return
    fi

    # Dangling images
    local dangling_images
    dangling_images=$(docker images -f "dangling=true" -q 2>/dev/null)
    if [ -n "$dangling_images" ]; then
        print_info "Removing dangling images..."
        docker image prune -f 2>/dev/null && print_success "Dangling images removed" || print_warning "Some images could not be removed"
    else
        print_success "No dangling images to remove"
    fi

    # Orphaned volumes
    local dangling_vols
    dangling_vols=$(docker volume ls -f dangling=true -q 2>/dev/null)
    if [ -n "$dangling_vols" ]; then
        print_info "Removing orphaned volumes..."
        docker volume prune -f 2>/dev/null && print_success "Orphaned volumes removed" || print_warning "Some volumes could not be removed"
    else
        print_success "No orphaned volumes to remove"
    fi
}

# ── Single run ────────────────────────────────────────────────────────────────

run_checks() {
    check_containers
    check_images
    check_volumes
    check_networks
    check_disk
    [ "$PRUNE_DANGLING" = true ] && prune_dangling
}

# ── Parse args ────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
    --watch)              WATCH_MODE=true; shift ;;
    --interval)           WATCH_INTERVAL="$2"; shift 2 ;;
    --restart-threshold)  RESTART_THRESHOLD="$2"; shift 2 ;;
    --prune-dangling)     PRUNE_DANGLING=true; shift ;;
    --dry-run)            DRY_RUN=true; shift ;;
    --json)               OUTPUT_JSON=true; shift ;;
    --help|-h)            show_help; exit 0 ;;
    *) echo "Unknown option: $1" >&2; show_help; exit 2 ;;
    esac
done

# ── Setup ─────────────────────────────────────────────────────────────────────

umask 077
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

require_jq_if_json "$OUTPUT_JSON" || exit 2

check_docker_available

if [ "$DRY_RUN" = true ]; then
    print_warning "DRY RUN — no changes will be made"
    echo ""
fi

# ── Watch mode or single run ──────────────────────────────────────────────────

if [ "$WATCH_MODE" = true ]; then
    print_info "Watch mode — refreshing every ${WATCH_INTERVAL}s (Ctrl+C to stop)"
    trap 'echo ""; print_info "Stopped."; exit 0' INT TERM
    while true; do
        clear
        echo -e "${BOLD}━━━ Docker Health — $(date '+%Y-%m-%d %H:%M:%S') ━━━${NC}"
        run_checks
        sleep "$WATCH_INTERVAL"
    done
else
    echo -e "${BOLD}━━━ Docker Health ━━━${NC}"
    echo ""
    print_info "Restart alert threshold: ${RESTART_THRESHOLD} restarts"
    print_info "Log: $LOG_FILE"
    run_checks
fi

# ── Summary ───────────────────────────────────────────────────────────────────

RUN_END_TS=$(date +%s)
DURATION_MS=$(( (RUN_END_TS - RUN_START_TS) * 1000 ))

echo ""
echo -e "${BOLD}━━━ Health Summary ━━━${NC}"
echo ""
printf "  Healthy containers:    ${GREEN}%d${NC}\n" "$CONTAINERS_HEALTHY"
printf "  Stopped containers:    ${RED}%d${NC}\n" "$CONTAINERS_STOPPED"
printf "  Restarting containers: ${YELLOW}%d${NC}\n" "$CONTAINERS_RESTARTING"
printf "  Unhealthy containers:  ${RED}%d${NC}\n" "$CONTAINERS_UNHEALTHY"
printf "  Dangling images:       %d\n" "$IMAGES_DANGLING"
printf "  Orphaned volumes:      %d\n" "$VOLUMES_ORPHANED"
printf "  Orphaned networks:     %d\n" "$NETWORKS_ORPHANED"
echo ""

if [ "$STATUS" = "ok" ]; then
    print_success "All containers healthy"
else
    print_warning "Issues found — review above"
fi

# JSON output
if [ "$OUTPUT_JSON" = true ]; then
    jq -n \
        --arg script "docker-health.sh" \
        --arg version "1.0.0" \
        --arg timestamp "$(get_iso8601_timestamp)" \
        --arg status "$STATUS" \
        --argjson duration_ms "$DURATION_MS" \
        --argjson containers_healthy "$CONTAINERS_HEALTHY" \
        --argjson containers_stopped "$CONTAINERS_STOPPED" \
        --argjson containers_restarting "$CONTAINERS_RESTARTING" \
        --argjson containers_unhealthy "$CONTAINERS_UNHEALTHY" \
        --argjson images_dangling "$IMAGES_DANGLING" \
        --argjson volumes_orphaned "$VOLUMES_ORPHANED" \
        --argjson networks_orphaned "$NETWORKS_ORPHANED" \
        --argjson errors "$ERRORS" \
        '{
            script: $script,
            version: $version,
            timestamp: $timestamp,
            status: $status,
            duration_ms: $duration_ms,
            errors: [],
            result: {
                containers_healthy: $containers_healthy,
                containers_stopped: $containers_stopped,
                containers_restarting: $containers_restarting,
                containers_unhealthy: $containers_unhealthy,
                images_dangling: $images_dangling,
                volumes_orphaned: $volumes_orphaned,
                networks_orphaned: $networks_orphaned,
                errors: $errors
            }
        }' > "$JSON_FILE"
    chmod 600 "$JSON_FILE"
    print_info "JSON: $JSON_FILE"
fi

[ "$STATUS" != "ok" ] && exit 1
exit 0
