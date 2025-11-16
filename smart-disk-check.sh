#!/usr/bin/env bash
set -u

# smart-disk-check.sh - S.M.A.R.T. monitoring and disk health alerts
# Version: 1.3.0
# Usage: ./smart-disk-check.sh [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

LOG_DIR="${SCRIPT_DIR}/logs/smart-check"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/smart_check_${TIMESTAMP}.log"
JSON_FILE="${LOG_DIR}/smart_check_summary_${TIMESTAMP}.json"

# Defaults
DEVICES=""
AUTO_DISCOVER=true
RUN_TEST=""
TEST_TYPE=""
DRY_RUN=false
OUTPUT_JSON=false
WARN_TEMP=50
CRIT_TEMP=60

# State tracking
DEVICES_CHECKED=0
DEVICES_HEALTHY=0
DEVICES_WARNING=0
DEVICES_CRITICAL=0
DEVICE_RESULTS=()

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Print functions
print_error() {
	echo -e "${RED}✗ Error:${NC} $1" >&2
	echo "[$(get_iso8601_timestamp)] ERROR: $1" >>"$LOG_FILE"
}

print_success() {
	echo -e "${GREEN}✓${NC} $1"
	echo "[$(get_iso8601_timestamp)] SUCCESS: $1" >>"$LOG_FILE"
}

print_warning() {
	echo -e "${YELLOW}⚠${NC} $1"
	echo "[$(get_iso8601_timestamp)] WARNING: $1" >>"$LOG_FILE"
}

print_info() {
	echo -e "${BLUE}ℹ${NC} $1"
	echo "[$(get_iso8601_timestamp)] INFO: $1" >>"$LOG_FILE"
}

print_section() {
	echo ""
	echo -e "${BLUE}━━━ $1 ━━━${NC}"
	echo ""
	echo "[$(get_iso8601_timestamp)] SECTION: $1" >>"$LOG_FILE"
}

# Show usage
show_help() {
	cat <<'HELP'
smart-disk-check.sh - S.M.A.R.T. monitoring and disk health alerts

USAGE:
    ./smart-disk-check.sh [OPTIONS]

OPTIONS:
    --devices <list>      Comma-separated device list (e.g., /dev/sda,/dev/sdb)
    --test <type>         Run S.M.A.R.T. test: short, long, conveyance
    --warn-temp <C>       Warning temperature threshold (default: 50, range: 30-80)
    --crit-temp <C>       Critical temperature threshold (default: 60, range: 40-90)
    --dry-run             Show what would be checked without executing
    --json                JSON summary output
    --help                Show this help message

EXAMPLES:
    # Auto-discover and check all drives
    ./smart-disk-check.sh

    # Check specific drives
    ./smart-disk-check.sh --devices /dev/sda,/dev/sdb

    # Schedule short test
    ./smart-disk-check.sh --test short

    # Custom temperature thresholds
    ./smart-disk-check.sh --warn-temp 45 --crit-temp 55

    # Dry run to preview
    ./smart-disk-check.sh --dry-run

FEATURES:
    - Auto-discovery via smartctl --scan
    - Health attribute monitoring (pre-fail, reallocated sectors, etc.)
    - Temperature monitoring with configurable thresholds
    - Optional short/long/conveyance test scheduling
    - Detailed logging and JSON output

SAFETY:
    - All operations logged to ./logs/smart-check/
    - Dry-run mode for preview without changes
    - Graceful handling when smartctl not available

DEPENDENCIES:
    - smartmontools (smartctl command)
      Install: brew install smartmontools / apt install smartmontools

VERSION: 1.3.0
HELP
}

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
	case $1 in
	--devices)
		DEVICES="$2"
		AUTO_DISCOVER=false
		shift 2
		;;
	--test)
		TEST_TYPE="$2"
		if [[ ! "$TEST_TYPE" =~ ^(short|long|conveyance)$ ]]; then
			echo "Error: --test must be one of: short, long, conveyance"
			exit 1
		fi
		RUN_TEST=true
		shift 2
		;;
	--warn-temp)
		WARN_TEMP="$2"
		if ! [[ "$WARN_TEMP" =~ ^[0-9]+$ ]] || [ "$WARN_TEMP" -lt 30 ] || [ "$WARN_TEMP" -gt 80 ]; then
			echo "Error: --warn-temp must be between 30 and 80°C"
			exit 1
		fi
		shift 2
		;;
	--crit-temp)
		CRIT_TEMP="$2"
		if ! [[ "$CRIT_TEMP" =~ ^[0-9]+$ ]] || [ "$CRIT_TEMP" -lt 40 ] || [ "$CRIT_TEMP" -gt 90 ]; then
			echo "Error: --crit-temp must be between 40 and 90°C"
			exit 1
		fi
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

# Validate temperature thresholds
if [ "$CRIT_TEMP" -le "$WARN_TEMP" ]; then
	echo "Error: --crit-temp ($CRIT_TEMP) must be greater than --warn-temp ($WARN_TEMP)"
	exit 1
fi

# Create log directory
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"
umask 077

# Check jq if JSON output requested
if ! require_jq_if_json "$OUTPUT_JSON"; then
	exit 1
fi
if [ "$OUTPUT_JSON" = true ]; then
	print_success "jq installed"
fi

# Start logging
{
	echo "================================================"
	echo "S.M.A.R.T. Disk Check - $(get_iso8601_timestamp)"
	echo "================================================"
	echo "Auto-discover: $AUTO_DISCOVER"
	echo "Devices: ${DEVICES:-auto}"
	echo "Warning temp: ${WARN_TEMP}°C"
	echo "Critical temp: ${CRIT_TEMP}°C"
	echo "Run test: ${TEST_TYPE:-none}"
	echo "Dry run: $DRY_RUN"
	echo "JSON output: $OUTPUT_JSON"
	echo "================================================"
} >>"$LOG_FILE"

# Check for smartctl
if ! command -v smartctl >/dev/null 2>&1; then
	print_error "smartctl not found. Install smartmontools:"
	echo "  macOS:  brew install smartmontools"
	echo "  Linux:  sudo apt install smartmontools"
	exit 1
fi
print_success "smartctl found"

# Dry-run preview
if [ "$DRY_RUN" = true ]; then
	print_section "Dry Run - Preview"

	if [ "$AUTO_DISCOVER" = true ]; then
		print_info "Would auto-discover devices via: smartctl --scan"
		echo "  Example devices: /dev/sda, /dev/sdb"
	else
		print_info "Would check specified devices: $DEVICES"
	fi

	echo ""
	echo "For each device, would check:"
	echo "  • Overall health status (PASSED/FAILED)"
	echo "  • Temperature (warn: ${WARN_TEMP}°C, crit: ${CRIT_TEMP}°C)"
	echo "  • Pre-fail attributes (5, 187, 188, 197, 198)"
	echo "  • Reallocated/Pending sectors"

	if [ -n "$RUN_TEST" ]; then
		echo ""
		print_info "Would schedule $TEST_TYPE S.M.A.R.T. test on all devices"
	fi

	echo ""
	print_success "Dry-run complete. Use without --dry-run to execute."
	exit 0
fi

# Device discovery
print_section "Device Discovery"

if [ "$AUTO_DISCOVER" = true ]; then
	print_info "Auto-discovering devices..."
	DEVICE_LIST=$(smartctl --scan 2>/dev/null | awk '{print $1}' || echo "")

	if [ -z "$DEVICE_LIST" ]; then
		print_error "No devices found via smartctl --scan"
		echo "Try specifying devices explicitly with --devices"
		exit 1
	fi

	DEVICES="$DEVICE_LIST"
	print_success "Found devices: $(echo "$DEVICE_LIST" | tr '\n' ' ')"
else
	# Convert comma-separated to space-separated
	DEVICE_LIST=$(echo "$DEVICES" | tr ',' ' ')
	print_info "Using specified devices: $DEVICE_LIST"
fi

# Check each device
print_section "Health Checks"

for device in $DEVICE_LIST; do
	echo ""
	print_info "Checking device: $device"
	DEVICES_CHECKED=$((DEVICES_CHECKED + 1))

	# Check if device exists
	if [ ! -e "$device" ]; then
		print_error "Device not found: $device"
		DEVICES_CRITICAL=$((DEVICES_CRITICAL + 1))
		DEVICE_RESULTS+=("$device:CRITICAL:Device not found")
		continue
	fi

	# Get S.M.A.R.T. info
	SMART_INFO=$(smartctl -i "$device" 2>&1)
	if [ $? -ne 0 ]; then
		print_warning "Unable to read S.M.A.R.T. info from $device"
		DEVICES_WARNING=$((DEVICES_WARNING + 1))
		DEVICE_RESULTS+=("$device:WARNING:S.M.A.R.T. not available")
		continue
	fi

	# Get overall health
	HEALTH=$(smartctl -H "$device" 2>&1 | grep -i "SMART overall-health" | awk '{print $NF}' || echo "UNKNOWN")

	# Get attributes
	ATTRIBUTES=$(smartctl -A "$device" 2>/dev/null || echo "")

	# Check temperature
	TEMP=$(echo "$ATTRIBUTES" | grep -i "Temperature" | awk '{print $10}' | head -1 || echo "0")
	if ! [[ "$TEMP" =~ ^[0-9]+$ ]]; then
		TEMP=0
	fi

	# Check critical attributes
	PREFAIL_ATTRS="5 187 188 197 198"
	CRITICAL_ATTRS=""
	for attr_id in $PREFAIL_ATTRS; do
		ATTR_LINE=$(echo "$ATTRIBUTES" | grep "^[[:space:]]*$attr_id " || echo "")
		if [ -n "$ATTR_LINE" ]; then
			RAW_VALUE=$(echo "$ATTR_LINE" | awk '{print $NF}')
			if [ "$RAW_VALUE" -gt 0 ] 2>/dev/null; then
				ATTR_NAME=$(echo "$ATTR_LINE" | awk '{print $2}')
				CRITICAL_ATTRS="${CRITICAL_ATTRS}${ATTR_NAME}:${RAW_VALUE} "
			fi
		fi
	done

	# Determine status
	STATUS="HEALTHY"
	if [ "$HEALTH" != "PASSED" ]; then
		STATUS="CRITICAL"
	elif [ -n "$CRITICAL_ATTRS" ]; then
		STATUS="WARNING"
	elif [ "$TEMP" -ge "$CRIT_TEMP" ]; then
		STATUS="CRITICAL"
	elif [ "$TEMP" -ge "$WARN_TEMP" ]; then
		STATUS="WARNING"
	fi

	# Report results
	if [ "$STATUS" = "HEALTHY" ]; then
		print_success "$device: $STATUS (health: $HEALTH, temp: ${TEMP}°C)"
		DEVICES_HEALTHY=$((DEVICES_HEALTHY + 1))
	elif [ "$STATUS" = "WARNING" ]; then
		print_warning "$device: $STATUS (health: $HEALTH, temp: ${TEMP}°C)"
		if [ -n "$CRITICAL_ATTRS" ]; then
			echo "  ⚠ Critical attributes: $CRITICAL_ATTRS"
		fi
		DEVICES_WARNING=$((DEVICES_WARNING + 1))
	else
		print_error "$device: $STATUS (health: $HEALTH, temp: ${TEMP}°C)"
		if [ -n "$CRITICAL_ATTRS" ]; then
			echo "  ✗ Critical attributes: $CRITICAL_ATTRS"
		fi
		DEVICES_CRITICAL=$((DEVICES_CRITICAL + 1))
	fi

	DEVICE_RESULTS+=("$device:$STATUS:$HEALTH:${TEMP}°C:${CRITICAL_ATTRS:-none}")
done

# Schedule tests if requested
if [ -n "$RUN_TEST" ]; then
	print_section "Test Scheduling"

	for device in $DEVICE_LIST; do
		if [ ! -e "$device" ]; then
			continue
		fi

		print_info "Scheduling $TEST_TYPE test on $device..."
		if smartctl -t "$TEST_TYPE" "$device" >>"$LOG_FILE" 2>&1; then
			print_success "Test scheduled on $device"
		else
			print_error "Failed to schedule test on $device"
		fi
	done
fi

# Summary
print_section "Summary"
echo "Devices checked: $DEVICES_CHECKED"
echo "  Healthy: $DEVICES_HEALTHY"
echo "  Warning: $DEVICES_WARNING"
echo "  Critical: $DEVICES_CRITICAL"

# JSON output
if [ "$OUTPUT_JSON" = true ]; then
	{
		echo "{"
		echo "  \"timestamp\": \"$(get_iso8601_timestamp)\","
		echo "  \"devices_checked\": $DEVICES_CHECKED,"
		echo "  \"devices_healthy\": $DEVICES_HEALTHY,"
		echo "  \"devices_warning\": $DEVICES_WARNING,"
		echo "  \"devices_critical\": $DEVICES_CRITICAL,"
		echo "  \"warn_temp\": $WARN_TEMP,"
		echo "  \"crit_temp\": $CRIT_TEMP,"
		echo "  \"devices\": ["

		FIRST=true
		for result in "${DEVICE_RESULTS[@]}"; do
			IFS=':' read -r dev status health temp attrs <<<"$result"
			if [ "$FIRST" = false ]; then
				echo "    ,"
			fi
			FIRST=false
			echo "    {"
			echo "      \"device\": \"$dev\","
			echo "      \"status\": \"$status\","
			echo "      \"health\": \"$health\","
			echo "      \"temperature\": \"$temp\","
			echo "      \"critical_attributes\": \"$attrs\""
			echo -n "    }"
		done
		echo ""
		echo "  ]"
		echo "}"
	} >"$JSON_FILE"
	chmod 600 "$JSON_FILE"
	print_success "JSON summary written to: $JSON_FILE"
fi

# Exit with appropriate code
if [ "$DEVICES_CRITICAL" -gt 0 ]; then
	exit 2
elif [ "$DEVICES_WARNING" -gt 0 ]; then
	exit 1
else
	exit 0
fi
