#!/usr/bin/env bash
set -euo pipefail

# docker-volume-backup.sh - Consistent Docker volume snapshots with compression
# Version: 1.2.0
# Usage: ./docker-volume-backup.sh [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs/volume-backup"
BACKUP_DIR="${SCRIPT_DIR}/backups/volumes"

# Defaults
VOLUME_NAME=""
BACKUP_ALL=false
STOP_CONTAINERS=false
DRY_RUN=false
OUTPUT_JSON=false
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/volume_backup_${TIMESTAMP}.log"
JSON_FILE="${LOG_DIR}/volume_backup_summary_${TIMESTAMP}.json"

# State tracking
BACKED_UP_VOLUMES=()
STOPPED_CONTAINERS=()
BACKUP_FAILED=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Print functions
print_error() {
	echo -e "${RED}✗ Error:${NC} $1" >&2
	echo "[$(date -Iseconds)] ERROR: $1" >>"$LOG_FILE"
}

print_success() {
	echo -e "${GREEN}✓${NC} $1"
	echo "[$(date -Iseconds)] SUCCESS: $1" >>"$LOG_FILE"
}

print_warning() {
	echo -e "${YELLOW}⚠${NC} $1"
	echo "[$(date -Iseconds)] WARNING: $1" >>"$LOG_FILE"
}

print_info() {
	echo -e "${BLUE}ℹ${NC} $1"
	echo "[$(date -Iseconds)] INFO: $1" >>"$LOG_FILE"
}

print_section() {
	echo ""
	echo -e "${BLUE}━━━ $1 ━━━${NC}"
	echo ""
	echo "[$(date -Iseconds)] SECTION: $1" >>"$LOG_FILE"
}

# Show usage
show_help() {
	cat <<'HELP'
docker-volume-backup.sh - Consistent Docker volume snapshots

USAGE:
    ./docker-volume-backup.sh [OPTIONS]

OPTIONS:
    --volume <name>       Backup specific volume
    --all                 Backup all Docker volumes
    --out <dir>           Output directory (default: ./backups/volumes)
    --stop                Stop dependent containers during backup
    --no-stop             Backup while containers running (default)
    --dry-run             Show backup plan without executing
    --json                JSON summary output
    --help                Show this help message

EXAMPLES:
    # Backup single volume
    ./docker-volume-backup.sh --volume postgres_data

    # Backup all volumes with container stop
    ./docker-volume-backup.sh --all --stop

    # Custom output directory
    ./docker-volume-backup.sh --volume app_data --out /backup

    # Dry run to preview
    ./docker-volume-backup.sh --all --dry-run

FEATURES:
    - Backup individual or all volumes
    - Optional container stop for consistency
    - Tar.gz compression
    - Helper container approach (no local mount)
    - Detailed logging and JSON output

SAFETY:
    - All operations logged to ./logs/volume-backup/
    - Backups stored in ./backups/volumes/ (chmod 600)
    - Container restart after backup if stopped
    - Dry-run mode for preview

VERSION: 1.2.0
HELP
}

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
	case $1 in
	--volume)
		VOLUME_NAME="$2"
		shift 2
		;;
	--all)
		BACKUP_ALL=true
		shift
		;;
	--out)
		BACKUP_DIR="$2"
		shift 2
		;;
	--stop)
		STOP_CONTAINERS=true
		shift
		;;
	--no-stop)
		STOP_CONTAINERS=false
		shift
		;;
	--dry-run)
		DRY_RUN=true
		shift
		;;
	--json)
		OUTPUT_JSON=true
		shift
		;;
	--help)
		show_help
		exit 0
		;;
	*)
		echo "Error: Unknown option $1"
		show_help
		exit 1
		;;
	esac
done

# Validate arguments
if [ "$BACKUP_ALL" = false ] && [ -z "$VOLUME_NAME" ]; then
	echo "Error: Must specify --volume <name> or --all"
	show_help
	exit 1
fi

if [ "$BACKUP_ALL" = true ] && [ -n "$VOLUME_NAME" ]; then
	echo "Error: Cannot use both --volume and --all"
	show_help
	exit 1
fi

# Setup logging
mkdir -p "$LOG_DIR" && chmod 700 "$LOG_DIR" || true
mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR" || true
umask 077

# Start logging
{
	echo "================================================"
	echo "Docker Volume Backup - $(date -Iseconds)"
	echo "================================================"
	echo "Volume: ${VOLUME_NAME:-all volumes}"
	echo "Backup all: $BACKUP_ALL"
	echo "Output directory: $BACKUP_DIR"
	echo "Stop containers: $STOP_CONTAINERS"
	echo "Dry run: $DRY_RUN"
	echo "================================================"
} >>"$LOG_FILE"

print_section "Docker Volume Backup"
if [ "$BACKUP_ALL" = true ]; then
	print_info "Mode: Backup all volumes"
else
	print_info "Mode: Backup single volume: $VOLUME_NAME"
fi
print_info "Output directory: $BACKUP_DIR"
[ "$STOP_CONTAINERS" = true ] && print_info "Container stop: enabled"
print_info "Log file: $LOG_FILE"

# Check Docker
print_section "Pre-flight Checks"

if ! command -v docker >/dev/null 2>&1; then
	print_error "Docker not found. Install Docker first."
	exit 1
fi
print_success "Docker installed"

# Check if Docker daemon is running
if ! docker info >/dev/null 2>&1; then
	print_error "Docker daemon not running. Start Docker first."
	exit 1
fi
print_success "Docker daemon running"

# Get volumes to backup
if [ "$BACKUP_ALL" = true ]; then
	VOLUMES=$(docker volume ls --format '{{.Name}}' 2>/dev/null)
	if [ -z "$VOLUMES" ]; then
		print_warning "No Docker volumes found"
		exit 0
	fi
	VOLUME_COUNT=$(echo "$VOLUMES" | wc -l | tr -d ' ')
	print_info "Found $VOLUME_COUNT volumes to backup"
else
	# Validate single volume exists
	if ! docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
		print_error "Volume not found: $VOLUME_NAME"
		exit 1
	fi
	VOLUMES="$VOLUME_NAME"
	print_success "Volume exists: $VOLUME_NAME"
fi

if [ "$DRY_RUN" = true ]; then
	print_warning "DRY RUN MODE - no actual backups will be created"
	echo ""
	print_info "Would backup the following volumes:"
	echo "$VOLUMES" | while read -r vol; do
		echo "  - $vol"
	done
	echo ""
	[ "$STOP_CONTAINERS" = true ] && print_info "Would stop dependent containers during backup"
	exit 0
fi

print_success "Pre-flight checks passed"

# Function to get containers using a volume
get_volume_containers() {
	local volume=$1
	docker ps --filter "volume=$volume" --format '{{.Names}}' 2>/dev/null || echo ""
}

# Function to backup a single volume
backup_volume() {
	local volume=$1
	local backup_file="${BACKUP_DIR}/${volume}_${TIMESTAMP}.tar.gz"
	local containers
	local stopped_containers=()

	print_section "Backing Up: $volume"

	# Get containers using this volume
	containers=$(get_volume_containers "$volume")

	if [ -n "$containers" ]; then
		print_info "Volume used by containers: $(echo "$containers" | tr '\n' ', ' | sed 's/,$//')"

		# Stop containers if requested
		if [ "$STOP_CONTAINERS" = true ]; then
			print_info "Stopping containers for consistency..."
			while IFS= read -r container; do
				if [ -n "$container" ]; then
					if docker stop "$container" >>"$LOG_FILE" 2>&1; then
						print_success "Stopped: $container"
						stopped_containers+=("$container")
						STOPPED_CONTAINERS+=("$container")
					else
						print_error "Failed to stop: $container"
						BACKUP_FAILED=true
						return 1
					fi
				fi
			done <<<"$containers"
		else
			print_warning "Backing up while containers running (may be inconsistent)"
		fi
	else
		print_info "No containers using this volume"
	fi

	# Perform backup using helper container
	print_info "Creating backup: $backup_file"
	if docker run --rm \
		-v "${volume}:/data:ro" \
		-v "$BACKUP_DIR:/backup" \
		alpine tar czf "/backup/$(basename "$backup_file")" /data >>"$LOG_FILE" 2>&1; then
		chmod 600 "$backup_file"
		BACKUP_SIZE=$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null || echo "0")
		BACKUP_SIZE_MB=$((BACKUP_SIZE / 1024 / 1024))
		print_success "Backup created: $backup_file (${BACKUP_SIZE_MB}MB)"
		BACKED_UP_VOLUMES+=("$volume:$backup_file:$BACKUP_SIZE")
	else
		print_error "Failed to backup volume: $volume"
		BACKUP_FAILED=true
		return 1
	fi

	# Restart stopped containers
	if [ ${#stopped_containers[@]} -gt 0 ]; then
		print_info "Restarting containers..."
		for container in "${stopped_containers[@]}"; do
			if docker start "$container" >>"$LOG_FILE" 2>&1; then
				print_success "Restarted: $container"
			else
				print_error "Failed to restart: $container"
				BACKUP_FAILED=true
			fi
		done
	fi
}

# Backup all volumes
while IFS= read -r volume; do
	if [ -n "$volume" ]; then
		backup_volume "$volume"
	fi
done <<<"$VOLUMES"

# Summary
print_section "Backup Summary"

if [ "$BACKUP_FAILED" = true ]; then
	print_error "Some backups failed - check logs for details"
	exit 1
fi

SUCCESSFUL_COUNT=${#BACKED_UP_VOLUMES[@]}
print_success "Backed up $SUCCESSFUL_COUNT volume(s)"

# Calculate total size
TOTAL_SIZE=0
for entry in "${BACKED_UP_VOLUMES[@]}"; do
	SIZE=$(echo "$entry" | cut -d: -f3)
	TOTAL_SIZE=$((TOTAL_SIZE + SIZE))
done
TOTAL_SIZE_MB=$((TOTAL_SIZE / 1024 / 1024))
print_info "Total backup size: ${TOTAL_SIZE_MB}MB"

# JSON output
if [ "$OUTPUT_JSON" = true ]; then
	cat >"$JSON_FILE" <<EOF
{
  "timestamp": "$(date -Iseconds)",
  "backup_dir": "$BACKUP_DIR",
  "stop_containers": $STOP_CONTAINERS,
  "volumes_backed_up": $SUCCESSFUL_COUNT,
  "total_size_bytes": $TOTAL_SIZE,
  "backups": [
EOF

	FIRST=true
	for entry in "${BACKED_UP_VOLUMES[@]}"; do
		VOLUME=$(echo "$entry" | cut -d: -f1)
		FILE=$(echo "$entry" | cut -d: -f2)
		SIZE=$(echo "$entry" | cut -d: -f3)

		[ "$FIRST" = false ] && echo "," >>"$JSON_FILE"
		FIRST=false

		cat >>"$JSON_FILE" <<ENTRY
    {
      "volume": "$VOLUME",
      "file": "$FILE",
      "size_bytes": $SIZE
    }
ENTRY
	done

	cat >>"$JSON_FILE" <<EOF

  ],
  "log_file": "$LOG_FILE"
}
EOF
	chmod 600 "$JSON_FILE"
	print_info "JSON summary: $JSON_FILE"
fi

exit 0
