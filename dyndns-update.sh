#!/usr/bin/env bash
set -u

# dyndns-update.sh - Dynamic DNS updates for homelabs with changing IPs
# Version: 1.2.0
# Usage: ./dyndns-update.sh [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs/dyndns"
CACHE_DIR="${HOME}/.cache/dyndns"

# Defaults
PROVIDER=""
ZONE=""
RECORD=""
TTL=300
TOKEN=""
DRY_RUN=false
OUTPUT_JSON=false
FORCE_UPDATE=false
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/dyndns_${TIMESTAMP}.log"
JSON_FILE="${LOG_DIR}/dyndns_summary_${TIMESTAMP}.json"
CACHE_FILE="${CACHE_DIR}/last-update.cache"
RATE_LIMIT_SECONDS=300 # 5 minutes

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
dyndns-update.sh - Dynamic DNS updates for homelabs

USAGE:
    ./dyndns-update.sh [OPTIONS]

OPTIONS:
    --provider <name>     DNS provider (currently: cloudflare)
    --zone <domain>       DNS zone (e.g., example.com)
    --record <name>       Record name (e.g., home or @)
    --ttl <seconds>       DNS TTL (default: 300, range: 60-86400)
    --token <val>         API token or env:VAR_NAME
    --force               Force update even if IP unchanged
    --dry-run             Show update plan without executing
    --json                JSON summary output
    --help                Show this help message

EXAMPLES:
    # Cloudflare update with environment variable token
    export CF_TOKEN="your-cloudflare-api-token"
    ./dyndns-update.sh --provider cloudflare --zone example.com \
        --record home --token env:CF_TOKEN

    # Update with custom TTL
    ./dyndns-update.sh --provider cloudflare --zone example.com \
        --record home --token env:CF_TOKEN --ttl 600

    # Force update regardless of cached IP
    ./dyndns-update.sh --provider cloudflare --zone example.com \
        --record home --token env:CF_TOKEN --force

    # Dry run to preview
    ./dyndns-update.sh --provider cloudflare --zone example.com \
        --record home --token env:CF_TOKEN --dry-run

FEATURES:
    - Cloudflare DNS API integration
    - Public IP detection with fallback sources
    - IP caching to avoid unnecessary API calls
    - Rate limiting (max 1 update per 5 minutes)
    - Configurable TTL
    - JSON output for automation

SAFETY:
    - All operations logged to ./logs/dyndns/
    - IP cache in ~/.cache/dyndns/
    - Rate limiting prevents API abuse
    - Token never appears in logs

VERSION: 1.2.0
HELP
}

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
	case $1 in
	--provider)
		PROVIDER="$2"
		shift 2
		;;
	--zone)
		ZONE="$2"
		shift 2
		;;
	--record)
		RECORD="$2"
		shift 2
		;;
	--ttl)
		TTL="$2"
		if ! [[ "$TTL" =~ ^[0-9]+$ ]] || [ "$TTL" -lt 60 ] || [ "$TTL" -gt 86400 ]; then
			echo "Error: --ttl must be between 60 and 86400 seconds"
			exit 1
		fi
		shift 2
		;;
	--token)
		TOKEN="$2"
		shift 2
		;;
	--force)
		FORCE_UPDATE=true
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

# Validate required arguments
if [ -z "$PROVIDER" ] || [ -z "$ZONE" ] || [ -z "$RECORD" ] || [ -z "$TOKEN" ]; then
	echo "Error: Missing required arguments"
	echo "Required: --provider, --zone, --record, --token"
	show_help
	exit 1
fi

# Validate provider
if [ "$PROVIDER" != "cloudflare" ]; then
	echo "Error: Unsupported provider: $PROVIDER"
	echo "Currently supported: cloudflare"
	exit 1
fi

# Setup logging and cache
mkdir -p "$LOG_DIR" && chmod 700 "$LOG_DIR" || true
mkdir -p "$CACHE_DIR" && chmod 700 "$CACHE_DIR" || true
umask 077

# Start logging
{
	echo "================================================"
	echo "Dynamic DNS Update - $(date -Iseconds)"
	echo "================================================"
	echo "Provider: $PROVIDER"
	echo "Zone: $ZONE"
	echo "Record: $RECORD"
	echo "TTL: $TTL"
	echo "Force update: $FORCE_UPDATE"
	echo "Dry run: $DRY_RUN"
	echo "================================================"
} >>"$LOG_FILE"

print_section "Dynamic DNS Update"
print_info "Provider: $PROVIDER"
print_info "Zone: $ZONE"
print_info "Record: $RECORD"
print_info "TTL: ${TTL}s"
print_info "Log file: $LOG_FILE"

# Resolve token from environment if needed
if [[ "$TOKEN" == env:* ]]; then
	TOKEN_VAR="${TOKEN#env:}"
	TOKEN="${!TOKEN_VAR:-}"
	if [ -z "$TOKEN" ]; then
		print_error "Environment variable not set: $TOKEN_VAR"
		exit 1
	fi
	print_info "Token loaded from environment variable"
else
	print_info "Token provided directly"
fi

# Check dependencies
print_section "Pre-flight Checks"

if ! command -v curl >/dev/null 2>&1; then
	print_error "curl not found. Install curl first."
	exit 1
fi
print_success "curl installed"

if ! command -v jq >/dev/null 2>&1; then
	print_error "jq not found. Install jq first (brew install jq / apt install jq)"
	exit 1
fi
print_success "jq installed"

print_success "Pre-flight checks passed"

# Detect public IP
print_section "Detecting Public IP"

CURRENT_IP=""
IP_SOURCES=(
	"https://ifconfig.me/ip"
	"https://icanhazip.com"
	"https://ipinfo.io/ip"
	"https://api.ipify.org"
)

for source in "${IP_SOURCES[@]}"; do
	print_info "Trying: $source"
	if IP=$(curl -sf --max-time 5 "$source" 2>>"$LOG_FILE"); then
		# Validate IP format
		if [[ "$IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
			CURRENT_IP="$IP"
			print_success "Detected IP: $CURRENT_IP"
			break
		fi
	fi
done

if [ -z "$CURRENT_IP" ]; then
	print_error "Failed to detect public IP from all sources"
	exit 1
fi

# Check cache and rate limiting
CACHED_IP=""
LAST_UPDATE=0

if [ -f "$CACHE_FILE" ]; then
	CACHED_IP=$(jq -r '.ip // ""' "$CACHE_FILE" 2>/dev/null || echo "")
	LAST_UPDATE=$(jq -r '.timestamp // 0' "$CACHE_FILE" 2>/dev/null || echo "0")
	CACHED_RECORD=$(jq -r '.record // ""' "$CACHE_FILE" 2>/dev/null || echo "")

	# Only use cache if it's for the same record
	if [ "$CACHED_RECORD" != "${ZONE}:${RECORD}" ]; then
		CACHED_IP=""
		LAST_UPDATE=0
	fi
fi

CURRENT_TIME=$(date +%s)
TIME_SINCE_UPDATE=$((CURRENT_TIME - LAST_UPDATE))

if [ -n "$CACHED_IP" ]; then
	print_info "Cached IP: $CACHED_IP (updated ${TIME_SINCE_UPDATE}s ago)"

	if [ "$CACHED_IP" = "$CURRENT_IP" ] && [ "$FORCE_UPDATE" = false ]; then
		print_success "IP unchanged since last update - no update needed"

		if [ "$TIME_SINCE_UPDATE" -lt "$RATE_LIMIT_SECONDS" ]; then
			print_warning "Rate limit: Updates allowed every ${RATE_LIMIT_SECONDS}s"
		fi

		exit 0
	fi

	if [ "$TIME_SINCE_UPDATE" -lt "$RATE_LIMIT_SECONDS" ] && [ "$FORCE_UPDATE" = false ]; then
		WAIT_TIME=$((RATE_LIMIT_SECONDS - TIME_SINCE_UPDATE))
		print_warning "Rate limit: Please wait ${WAIT_TIME}s before updating again"
		print_info "Use --force to override rate limiting"
		exit 0
	fi
fi

if [ "$DRY_RUN" = true ]; then
	print_warning "DRY RUN MODE - no actual DNS update will be made"
	echo ""
	print_info "Would update DNS record:"
	echo "  Provider: $PROVIDER"
	echo "  Zone: $ZONE"
	echo "  Record: $RECORD"
	echo "  IP: $CURRENT_IP"
	echo "  TTL: ${TTL}s"
	[ -n "$CACHED_IP" ] && echo "  Previous IP: $CACHED_IP"
	exit 0
fi

# Update DNS record (Cloudflare)
print_section "Updating DNS Record"

if [ "$PROVIDER" = "cloudflare" ]; then
	# Get zone ID
	print_info "Looking up zone ID for: $ZONE"
	ZONE_RESPONSE=$(curl -sf -X GET "https://api.cloudflare.com/client/v4/zones?name=$ZONE" \
		-H "Authorization: Bearer $TOKEN" \
		-H "Content-Type: application/json" 2>>"$LOG_FILE")

	if [ -z "$ZONE_RESPONSE" ]; then
		print_error "Failed to contact Cloudflare API"
		exit 1
	fi

	ZONE_ID=$(echo "$ZONE_RESPONSE" | jq -r '.result[0].id // ""')
	if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "null" ]; then
		print_error "Zone not found: $ZONE"
		echo "$ZONE_RESPONSE" | jq '.' >>"$LOG_FILE"
		exit 1
	fi
	print_success "Zone ID: $ZONE_ID"

	# Get DNS record ID
	FULL_RECORD="${RECORD}.${ZONE}"
	[ "$RECORD" = "@" ] && FULL_RECORD="$ZONE"

	print_info "Looking up DNS record: $FULL_RECORD"
	RECORD_RESPONSE=$(curl -sf -X GET \
		"https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$FULL_RECORD&type=A" \
		-H "Authorization: Bearer $TOKEN" \
		-H "Content-Type: application/json" 2>>"$LOG_FILE")

	RECORD_ID=$(echo "$RECORD_RESPONSE" | jq -r '.result[0].id // ""')

	if [ -z "$RECORD_ID" ] || [ "$RECORD_ID" = "null" ]; then
		# Create new record
		print_info "Record not found - creating new A record"
		CREATE_RESPONSE=$(curl -sf -X POST \
			"https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
			-H "Authorization: Bearer $TOKEN" \
			-H "Content-Type: application/json" \
			--data "{\"type\":\"A\",\"name\":\"$FULL_RECORD\",\"content\":\"$CURRENT_IP\",\"ttl\":$TTL,\"proxied\":false}" 2>>"$LOG_FILE")

		SUCCESS=$(echo "$CREATE_RESPONSE" | jq -r '.success // false')
		if [ "$SUCCESS" = "true" ]; then
			print_success "DNS record created: $FULL_RECORD -> $CURRENT_IP"
		else
			print_error "Failed to create DNS record"
			echo "$CREATE_RESPONSE" | jq '.' >>"$LOG_FILE"
			exit 1
		fi
	else
		# Update existing record
		print_info "Updating existing record: $RECORD_ID"
		UPDATE_RESPONSE=$(curl -sf -X PUT \
			"https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
			-H "Authorization: Bearer $TOKEN" \
			-H "Content-Type: application/json" \
			--data "{\"type\":\"A\",\"name\":\"$FULL_RECORD\",\"content\":\"$CURRENT_IP\",\"ttl\":$TTL,\"proxied\":false}" 2>>"$LOG_FILE")

		SUCCESS=$(echo "$UPDATE_RESPONSE" | jq -r '.success // false')
		if [ "$SUCCESS" = "true" ]; then
			print_success "DNS record updated: $FULL_RECORD -> $CURRENT_IP"
		else
			print_error "Failed to update DNS record"
			echo "$UPDATE_RESPONSE" | jq '.' >>"$LOG_FILE"
			exit 1
		fi
	fi
fi

# Update cache
cat >"$CACHE_FILE" <<EOF
{
  "ip": "$CURRENT_IP",
  "record": "${ZONE}:${RECORD}",
  "timestamp": $CURRENT_TIME,
  "updated_at": "$(date -Iseconds)"
}
EOF
chmod 600 "$CACHE_FILE"

print_section "Update Complete"
print_success "DNS record updated successfully"
print_info "Record: $FULL_RECORD"
print_info "IP: $CURRENT_IP"
print_info "TTL: ${TTL}s"

# JSON output
if [ "$OUTPUT_JSON" = true ]; then
	cat >"$JSON_FILE" <<EOF
{
  "timestamp": "$(date -Iseconds)",
  "provider": "$PROVIDER",
  "zone": "$ZONE",
  "record": "$RECORD",
  "full_record": "$FULL_RECORD",
  "ip": "$CURRENT_IP",
  "previous_ip": "${CACHED_IP:-null}",
  "ttl": $TTL,
  "success": true,
  "log_file": "$LOG_FILE"
}
EOF
	chmod 600 "$JSON_FILE"
	print_info "JSON summary: $JSON_FILE"
fi

exit 0
