#!/usr/bin/env bash
set -u

# media-stats.sh - Plex library codec breakdown and re-encode candidate report
# Version: 1.0.0
# Usage: ./media-stats.sh [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

LOG_DIR="${SCRIPT_DIR}/logs/media-stats"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RUN_START_TS=$(date +%s)
LOG_FILE="${LOG_DIR}/media_stats_${TIMESTAMP}.log"
JSON_FILE="${LOG_DIR}/media_stats_${TIMESTAMP}.json"

# Defaults
PLEX_DIR="/home/plex"
BITRATE_THRESHOLD=8000 # kbps — files above this are good H.265 candidates
FILE_LIMIT=0           # 0 = no limit
DRY_RUN=false
OUTPUT_JSON=false

# Associative arrays require Bash 4+ (check deferred until after --help parsing)
# Early exit for --help so it works on Bash 3.2
for _arg in "$@"; do
	[ "$_arg" = "--help" ] && {
		_SKIP_VERSION=true
		break
	}
	[ "$_arg" = "--dry-run" ] && {
		_SKIP_VERSION=true
		break
	}
done

if [ "${_SKIP_VERSION:-false}" != true ] && [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
	echo "ERROR: media-stats.sh requires Bash 4.0+ for associative arrays (current: $BASH_VERSION)" >&2
	exit 1
fi

# Counters by codec (Bash 4+ only, guarded above)
if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
	declare -A CODEC_COUNT
	declare -A CODEC_BYTES
fi
TOTAL_FILES=0
TOTAL_BYTES=0
TOTAL_DURATION_SECS=0
CANDIDATES_COUNT=0
CANDIDATES_BYTES=0

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
media-stats.sh - Plex library codec breakdown and re-encode candidate report

USAGE:
    ./media-stats.sh [OPTIONS]

OPTIONS:
    --plex-dir <path>       Plex media root (default: /home/plex)
    --bitrate-threshold <n> Flag files > N kbps for re-encoding (default: 8000)
    --limit <n>             Only scan first N files (for testing)
    --dry-run               Show what would be scanned without scanning
    --json                  JSON summary output
    --help                  Show this help message

TOOLS USED:
    ffprobe   (part of ffmpeg) — preferred, accurate
    mediainfo — fallback if ffprobe not found

WHAT IT REPORTS:
    - Codec breakdown (H.264, H.265/HEVC, AV1, MPEG-2, etc.)
    - Storage used per codec
    - Total library duration
    - Largest files (top 15)
    - Re-encode candidates: H.264 files above --bitrate-threshold kbps
      (H.265 typically achieves 50% size reduction at same quality)

EXAMPLES:
    # Full library scan
    ./media-stats.sh

    # Scan specific directory
    ./media-stats.sh --plex-dir /home/plex/TV

    # Flag anything > 15 Mbps
    ./media-stats.sh --bitrate-threshold 15000

    # Quick test scan (first 100 files)
    ./media-stats.sh --limit 100

    # JSON output
    ./media-stats.sh --json

EXIT CODES:
    0  Scan complete
    1  No media tool found (ffprobe/mediainfo required)
    2  Fatal error
HELP
}

bytes_to_human() {
	local bytes="$1"
	if [ "$bytes" -ge 1073741824 ]; then
		awk "BEGIN {printf \"%.2f GB\", $bytes/1073741824}"
	elif [ "$bytes" -ge 1048576 ]; then
		awk "BEGIN {printf \"%.2f MB\", $bytes/1048576}"
	elif [ "$bytes" -ge 1024 ]; then
		awk "BEGIN {printf \"%.1f KB\", $bytes/1024}"
	else
		echo "${bytes} B"
	fi
}

duration_to_human() {
	local secs="$1"
	local h m s
	h=$((secs / 3600))
	m=$(((secs % 3600) / 60))
	s=$((secs % 60))
	printf "%dh %02dm %02ds" "$h" "$m" "$s"
}

# ── Detect media info tool ────────────────────────────────────────────────────

detect_tool() {
	if command -v ffprobe >/dev/null 2>&1; then
		echo "ffprobe"
	elif command -v mediainfo >/dev/null 2>&1; then
		echo "mediainfo"
	else
		echo ""
	fi
}

# ── Get codec and bitrate for a file ─────────────────────────────────────────

get_media_info() {
	local file="$1"
	local tool="$2"

	local codec="" bitrate="" duration=""

	case "$tool" in
	ffprobe)
		local info
		info=$(ffprobe -v quiet -print_format json -show_streams -show_format "$file" 2>/dev/null) || return 1

		codec=$(echo "$info" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for s in d.get('streams',[]):
    if s.get('codec_type')=='video':
        print(s.get('codec_name','?'))
        break
" 2>/dev/null || echo "?")

		bitrate=$(echo "$info" | python3 -c "
import json,sys
d=json.load(sys.stdin)
br=d.get('format',{}).get('bit_rate','0')
print(int(int(br)/1000) if br and br.isdigit() else 0)
" 2>/dev/null || echo "0")

		duration=$(echo "$info" | python3 -c "
import json,sys
d=json.load(sys.stdin)
dur=d.get('format',{}).get('duration','0')
print(int(float(dur)) if dur else 0)
" 2>/dev/null || echo "0")
		;;

	mediainfo)
		codec=$(mediainfo --Inform="Video;%Format%" "$file" 2>/dev/null | head -1 | tr '[:upper:]' '[:lower:]' || echo "?")
		bitrate=$(mediainfo --Inform="General;%OverallBitRate%" "$file" 2>/dev/null | head -1 | awk '{printf "%d", $1/1000}' || echo "0")
		duration=$(mediainfo --Inform="General;%Duration%" "$file" 2>/dev/null | head -1 | awk '{printf "%d", $1/1000}' || echo "0")
		;;
	esac

	# Normalize codec name
	case "$codec" in
	h264 | avc*) codec="H.264" ;;
	hevc | h265*) codec="H.265/HEVC" ;;
	av1) codec="AV1" ;;
	vp9) codec="VP9" ;;
	mpeg2video) codec="MPEG-2" ;;
	mpeg4) codec="MPEG-4" ;;
	divx | xvid) codec="DivX/XviD" ;;
	wmv3 | vc1) codec="WMV/VC-1" ;;
	"" | "?") codec="Unknown" ;;
	esac

	echo "${codec}|${bitrate}|${duration}"
}

# ── Scan files ────────────────────────────────────────────────────────────────

scan_media() {
	local tool="$1"

	print_info "Scanning $PLEX_DIR with $tool..."
	print_info "This may take a while on large libraries..."
	echo ""

	local video_exts="mkv|mp4|avi|m4v|mov|wmv|flv|ts|vob|mpg|mpeg|m2ts"
	local count=0

	# Temp file for largest files tracking
	local tmp_sizes
	tmp_sizes=$(mktemp)
	trap 'rm -f "$tmp_sizes"' RETURN

	while IFS= read -r file; do
		[ "$FILE_LIMIT" -gt 0 ] && [ "$count" -ge "$FILE_LIMIT" ] && break

		local sz
		if [[ "$OSTYPE" == "darwin"* ]]; then
			sz=$(stat -f%z "$file" 2>/dev/null || echo 0)
		else
			sz=$(stat -c%s "$file" 2>/dev/null || echo 0)
		fi
		[ "$sz" -eq 0 ] && continue

		local info
		info=$(get_media_info "$file" "$tool") || continue

		local codec bitrate dur
		IFS='|' read -r codec bitrate dur <<<"$info"

		[ -z "$codec" ] || [ "$codec" = "?" ] && codec="Unknown"
		bitrate="${bitrate:-0}"
		dur="${dur:-0}"

		TOTAL_FILES=$((TOTAL_FILES + 1))
		TOTAL_BYTES=$((TOTAL_BYTES + sz))
		TOTAL_DURATION_SECS=$((TOTAL_DURATION_SECS + dur))

		CODEC_COUNT[$codec]=$((${CODEC_COUNT[$codec]:-0} + 1))
		CODEC_BYTES[$codec]=$((${CODEC_BYTES[$codec]:-0} + sz))

		# Track candidate for re-encoding
		if [ "$codec" = "H.264" ] && [ "$bitrate" -gt "$BITRATE_THRESHOLD" ]; then
			CANDIDATES_COUNT=$((CANDIDATES_COUNT + 1))
			CANDIDATES_BYTES=$((CANDIDATES_BYTES + sz))
		fi

		# Record size for top-N
		printf "%s\t%s\n" "$sz" "$file" >>"$tmp_sizes"

		count=$((count + 1))
		# Progress indicator every 100 files
		[ $((count % 100)) -eq 0 ] && printf "\r  Scanned %d files..." "$count"
	done < <(find "$PLEX_DIR" -type f 2>/dev/null | grep -iE "\.(${video_exts})$")

	[ "$count" -gt 0 ] && echo ""

	# ── Codec breakdown ────────────────────────────────────────────────────────

	print_section "Codec Breakdown"

	printf "  %-20s %8s %8s %10s\n" "CODEC" "FILES" "%" "SIZE"
	printf "  %s\n" "$(printf '─%.0s' {1..55})"

	for codec in $(echo "${!CODEC_COUNT[@]}" | tr ' ' '\n' | sort); do
		local cnt="${CODEC_COUNT[$codec]}"
		local bytes="${CODEC_BYTES[$codec]}"
		local pct=0
		[ "$TOTAL_FILES" -gt 0 ] && pct=$(awk "BEGIN {printf \"%.1f\", 100*$cnt/$TOTAL_FILES}")
		printf "  %-20s %8d %7s%% %10s\n" "$codec" "$cnt" "$pct" "$(bytes_to_human "$bytes")"
	done

	# ── Library stats ──────────────────────────────────────────────────────────

	print_section "Library Overview"

	printf "  Total video files:   %d\n" "$TOTAL_FILES"
	printf "  Total size:          %s\n" "$(bytes_to_human "$TOTAL_BYTES")"
	printf "  Total duration:      %s\n" "$(duration_to_human "$TOTAL_DURATION_SECS")"

	# ── Largest files ──────────────────────────────────────────────────────────

	print_section "Largest Files (Top 15)"

	sort -rn "$tmp_sizes" | head -15 | while IFS=$'\t' read -r sz file; do
		printf "  %-8s  %s\n" "$(bytes_to_human "$sz")" "${file/$PLEX_DIR\//}"
	done

	# ── Re-encode candidates ───────────────────────────────────────────────────

	print_section "H.265 Re-encode Candidates"

	print_info "H.264 files above ${BITRATE_THRESHOLD} kbps (estimated 40-60% savings with H.265)"
	echo ""
	printf "  Candidates:    %d files\n" "$CANDIDATES_COUNT"
	printf "  Current size:  %s\n" "$(bytes_to_human "$CANDIDATES_BYTES")"
	local estimated_savings=$((CANDIDATES_BYTES / 2))
	printf "  Est. savings:  ~%s (50%% estimate)\n" "$(bytes_to_human "$estimated_savings")"

	if [ "$CANDIDATES_COUNT" -gt 0 ]; then
		echo ""
		print_info "To re-encode with HandBrakeCLI:"
		echo '    HandBrakeCLI -i input.mkv -o output.mkv --preset "H.265 MKV 1080p30"'
		print_info "Or use ffmpeg:"
		echo '    ffmpeg -i input.mkv -c:v libx265 -crf 23 -c:a copy output.mkv'
	fi
}

# ── Parse args ────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
	case "$1" in
	--plex-dir)
		PLEX_DIR="$2"
		shift 2
		;;
	--bitrate-threshold)
		BITRATE_THRESHOLD="$2"
		shift 2
		;;
	--limit)
		FILE_LIMIT="$2"
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

validate_output_dir "$PLEX_DIR" || exit 1

# ── Setup ─────────────────────────────────────────────────────────────────────

umask 077
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

require_jq_if_json "$OUTPUT_JSON" || exit 2

if [ ! -d "$PLEX_DIR" ]; then
	print_error "Directory not found: $PLEX_DIR"
	exit 2
fi

MEDIA_TOOL=$(detect_tool)

echo -e "${BOLD}━━━ Media Stats ━━━${NC}"
echo ""
print_info "Root:      $PLEX_DIR"
print_info "Tool:      ${MEDIA_TOOL:-none}"
print_info "Threshold: ${BITRATE_THRESHOLD} kbps"
[ "$FILE_LIMIT" -gt 0 ] && print_info "Limit:     $FILE_LIMIT files"

if [ "$DRY_RUN" = true ]; then
	print_warning "DRY RUN — would scan $PLEX_DIR with ${MEDIA_TOOL:-ffprobe/mediainfo}"
	exit 0
fi

if [ -z "$MEDIA_TOOL" ]; then
	print_error "Neither ffprobe nor mediainfo found"
	print_info "Install with: sudo apt install ffmpeg"
	exit 1
fi

scan_media "$MEDIA_TOOL"

# ── Summary ───────────────────────────────────────────────────────────────────

RUN_END_TS=$(date +%s)
DURATION_MS=$(((RUN_END_TS - RUN_START_TS) * 1000))

echo ""
print_info "Scan complete in $(((RUN_END_TS - RUN_START_TS) / 60))m $(((RUN_END_TS - RUN_START_TS) % 60))s"
print_info "Log: $LOG_FILE"

if [ "$OUTPUT_JSON" = true ]; then
	# Build codec JSON
	local_codec_json="{}"
	for codec in "${!CODEC_COUNT[@]}"; do
		local_codec_json=$(echo "$local_codec_json" |
			python3 -c "import json,sys; d=json.load(sys.stdin); d[sys.argv[1]]={'count':int(sys.argv[2]),'bytes':int(sys.argv[3])}; print(json.dumps(d))" "$codec" "${CODEC_COUNT[$codec]}" "${CODEC_BYTES[$codec]}" 2>/dev/null || echo "{}")
	done

	jq -n \
		--arg script "media-stats.sh" \
		--arg version "1.0.0" \
		--arg timestamp "$(get_iso8601_timestamp)" \
		--arg status "ok" \
		--argjson duration_ms "$DURATION_MS" \
		--argjson total_files "$TOTAL_FILES" \
		--argjson total_bytes "$TOTAL_BYTES" \
		--argjson total_duration_secs "$TOTAL_DURATION_SECS" \
		--argjson candidates_count "$CANDIDATES_COUNT" \
		--argjson candidates_bytes "$CANDIDATES_BYTES" \
		'{
            script: $script,
            version: $version,
            timestamp: $timestamp,
            status: $status,
            duration_ms: $duration_ms,
            errors: [],
            result: {
                total_files: $total_files,
                total_bytes: $total_bytes,
                total_duration_secs: $total_duration_secs,
                reencode_candidates: $candidates_count,
                reencode_candidate_bytes: $candidates_bytes
            }
        }' >"$JSON_FILE"
	chmod 600 "$JSON_FILE"
	print_info "JSON: $JSON_FILE"
fi

exit 0
