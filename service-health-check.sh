#!/usr/bin/env bash
set -u

# service-health-check.sh - Config-driven uptime monitoring
# Version: 1.1.0
# Usage: ./service-health-check.sh [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
STATE_DIR="${HOME}/.cache/service-health-check"
STATE_FILE="${STATE_DIR}/state.json"

# Defaults
CONFIG_FILE=""
WATCH_MODE=false
CHECK_INTERVAL=60
NOTIFY_METHOD=""
JSON_OUTPUT=false
DRY_RUN=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Print functions
print_error() {
    echo -e "${RED}✗ Error:${NC} $1" >&2
}

print_success() {
    echo -e "${GREEN}✓${NC} $1" >&2
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1" >&2
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1" >&2
}

# Show usage
show_help() {
    cat << EOF
service-health-check.sh - Config-driven uptime monitoring

USAGE:
    ./service-health-check.sh [OPTIONS]

OPTIONS:
    --config <file>       Config file with service definitions (required)
    --once                Run checks once and exit (default)
    --watch               Continuous monitoring mode
    --interval <secs>     Check interval in watch mode (default: 60)
    --notify <method>     Notification method: webhook:URL
    --json                JSON output
    --dry-run             Show what would be checked without running
    --help                Show this help message

CONFIG FORMAT (INI):
    [service_name]
    type=http|tcp|process|container

    # For type=http:
    url=https://example.com
    expect_status=200
    expect_body=optional_substring
    timeout=5

    # For type=tcp:
    host=example.com
    port=80
    timeout=5

    # For type=process:
    name=sshd

    # For type=container:
    name=nginx

EXAMPLES:
    # Run once with JSON output
    ./service-health-check.sh --config services.conf --once --json

    # Watch mode with notifications
    ./service-health-check.sh --config services.conf --watch --interval 60 \\
        --notify webhook:http://alerts.local/webhook

    # Dry run to validate config
    ./service-health-check.sh --config services.conf --dry-run

VERSION: 1.1.0
EOF
}

# Parse CLI arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help)
                show_help
                exit 0
                ;;
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --once)
                WATCH_MODE=false
                shift
                ;;
            --watch)
                WATCH_MODE=true
                shift
                ;;
            --interval)
                CHECK_INTERVAL="$2"
                shift 2
                ;;
            --notify)
                NOTIFY_METHOD="$2"
                shift 2
                ;;
            --json)
                JSON_OUTPUT=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Run with --help for usage information"
                exit 1
                ;;
        esac
    done
}

# Validate arguments
validate_args() {
    if [ -z "$CONFIG_FILE" ]; then
        print_error "Missing required --config argument"
        echo "Run with --help for usage information"
        exit 1
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "Config file not found: $CONFIG_FILE"
        exit 1
    fi

    if ! [[ "$CHECK_INTERVAL" =~ ^[0-9]+$ ]] || [ "$CHECK_INTERVAL" -lt 1 ]; then
        print_error "Invalid interval: $CHECK_INTERVAL (must be positive integer)"
        exit 1
    fi

    if [ -n "$NOTIFY_METHOD" ] && ! [[ "$NOTIFY_METHOD" =~ ^webhook: ]]; then
        print_error "Invalid notification method: $NOTIFY_METHOD"
        print_info "Supported formats: webhook:URL"
        exit 1
    fi
}

# Parse INI config file
parse_config() {
    local config_file="$1"
    local section=""
    local service_data=""

    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Remove leading/trailing whitespace
        line=$(echo "$line" | xargs)

        # Section header
        if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
            # Output previous service if exists
            if [ -n "$section" ]; then
                echo "$section|$service_data"
            fi

            section="${BASH_REMATCH[1]}"
            service_data=""
            continue
        fi

        # Key=value pairs
        if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"

            # Append to service data
            if [ -z "$service_data" ]; then
                service_data="${key}=${value}"
            else
                service_data="${service_data} ${key}=${value}"
            fi
        fi
    done < "$config_file"

    # Output last service
    if [ -n "$section" ]; then
        echo "$section|$service_data"
    fi
}

# HTTP health check
check_http() {
    local name="$1"
    local url="$2"
    local expect_status="${3:-200}"
    local expect_body="${4:-}"
    local timeout="${5:-5}"

    local status
    local body
    local http_code

    if [ "$DRY_RUN" = true ]; then
        echo "dry_run|Would check HTTP: $url (expect status $expect_status)"
        return 0
    fi

    # Perform HTTP check
    local response
    response=$(curl -s -w "\n%{http_code}" -m "$timeout" "$url" 2>/dev/null || echo -e "\n000")

    body=$(echo "$response" | head -n -1)
    http_code=$(echo "$response" | tail -n 1)

    # Check status code
    if [ "$http_code" != "$expect_status" ]; then
        echo "fail|HTTP status $http_code (expected $expect_status)"
        return 1
    fi

    # Check body substring if specified
    if [ -n "$expect_body" ] && ! echo "$body" | grep -qF "$expect_body"; then
        echo "fail|Response body missing expected text: $expect_body"
        return 1
    fi

    echo "pass|HTTP $http_code"
    return 0
}

# TCP port check
check_tcp() {
    local name="$1"
    local host="$2"
    local port="$3"
    local timeout="${4:-5}"

    if [ "$DRY_RUN" = true ]; then
        echo "dry_run|Would check TCP: $host:$port"
        return 0
    fi

    # Try to connect using bash TCP
    if timeout "$timeout" bash -c "cat < /dev/null > /dev/tcp/$host/$port" 2>/dev/null; then
        echo "pass|TCP port $port open"
        return 0
    else
        echo "fail|TCP port $port closed or unreachable"
        return 1
    fi
}

# Process check
check_process() {
    local name="$1"
    local process_name="$2"

    if [ "$DRY_RUN" = true ]; then
        echo "dry_run|Would check process: $process_name"
        return 0
    fi

    if pgrep -x "$process_name" > /dev/null 2>&1; then
        local pid_count
        pid_count=$(pgrep -x "$process_name" | wc -l | xargs)
        echo "pass|Process running (${pid_count} instances)"
        return 0
    else
        echo "fail|Process not found"
        return 1
    fi
}

# Container check
check_container() {
    local name="$1"
    local container_name="$2"

    if [ "$DRY_RUN" = true ]; then
        echo "dry_run|Would check container: $container_name"
        return 0
    fi

    if ! command -v docker >/dev/null 2>&1; then
        echo "skip|Docker not installed"
        return 2
    fi

    local status
    status=$(docker inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null || echo "not_found")

    if [ "$status" = "running" ]; then
        echo "pass|Container running"
        return 0
    elif [ "$status" = "not_found" ]; then
        echo "fail|Container not found"
        return 1
    else
        echo "fail|Container status: $status"
        return 1
    fi
}

# Run a single check
run_check() {
    local name="$1"
    local type="$2"
    shift 2
    local -A params=()

    # Parse remaining args into params
    for arg in "$@"; do
        if [[ "$arg" =~ ^\[([^]]+)\]=(.*)$ ]]; then
            params[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
        fi
    done

    local result
    case "$type" in
        http)
            result=$(check_http "$name" "${params[url]}" "${params[expect_status]:-200}" \
                "${params[expect_body]:-}" "${params[timeout]:-5}")
            ;;
        tcp)
            result=$(check_tcp "$name" "${params[host]}" "${params[port]}" "${params[timeout]:-5}")
            ;;
        process)
            result=$(check_process "$name" "${params[name]}")
            ;;
        container)
            result=$(check_container "$name" "${params[name]}")
            ;;
        *)
            result="error|Unknown check type: $type"
            ;;
    esac

    echo "$result"
}

# Notify via webhook
notify_webhook() {
    local url="$1"
    local name="$2"
    local type="$3"
    local status="$4"
    local message="$5"

    if [ "$DRY_RUN" = true ]; then
        print_info "Dry run: Would notify webhook: $url"
        return 0
    fi

    local payload
    payload=$(cat <<EOF
{
  "service": "$name",
  "type": "$type",
  "status": "$status",
  "message": "$message",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
)

    if curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$url" >/dev/null 2>&1; then
        return 0
    else
        print_warning "Failed to send webhook notification"
        return 1
    fi
}

# Send notification if method configured
send_notification() {
    local name="$1"
    local type="$2"
    local status="$3"
    local message="$4"

    [ -z "$NOTIFY_METHOD" ] && return 0

    if [[ "$NOTIFY_METHOD" =~ ^webhook:(.+)$ ]]; then
        notify_webhook "${BASH_REMATCH[1]}" "$name" "$type" "$status" "$message"
    fi
}

# Load previous state
load_state() {
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE"
    else
        echo "{}"
    fi
}

# Save current state
save_state() {
    local state="$1"
    mkdir -p "$STATE_DIR"
    echo "$state" > "$STATE_FILE"
}

# Check if state changed (for notification filtering)
state_changed() {
    local name="$1"
    local new_status="$2"
    local prev_state="$3"

    # Extract previous status for this service
    local prev_status
    prev_status=$(echo "$prev_state" | grep -oP "\"$name\":\s*\"\K[^\"]+")

    [ "$prev_status" != "$new_status" ]
}

# Main check loop
run_checks() {
    local services
    services=$(parse_config "$CONFIG_FILE")

    if [ -z "$services" ]; then
        print_error "No services found in config file"
        exit 1
    fi

    local -a results=()
    local prev_state
    prev_state=$(load_state)
    local new_state="{"
    local first=true

    if [ "$JSON_OUTPUT" = false ] && [ "$DRY_RUN" = false ]; then
        echo -e "${BLUE}=== Service Health Check ===${NC}"
        echo ""
    fi

    while IFS= read -r service_line; do
        # Parse service line (basic parsing, real implementation would be more robust)
        local name type params
        name=$(echo "$service_line" | cut -d'|' -f1)
        type=$(echo "$service_line" | cut -d'|' -f2)
        params=$(echo "$service_line" | cut -d'|' -f3-)

        # Run check
        local check_result
        check_result=$(run_check "$name" "$type" $params)

        local check_status check_message
        check_status=$(echo "$check_result" | cut -d'|' -f1)
        check_message=$(echo "$check_result" | cut -d'|' -f2-)

        # Store result
        results+=("$name|$type|$check_status|$check_message")

        # Update state
        [ "$first" = false ] && new_state+=","
        new_state+="\"$name\":\"$check_status\""
        first=false

        # Display result
        if [ "$JSON_OUTPUT" = false ]; then
            case "$check_status" in
                pass)
                    echo -e "${GREEN}✓${NC} $name ($type): $check_message"
                    ;;
                fail)
                    echo -e "${RED}✗${NC} $name ($type): $check_message"
                    ;;
                skip)
                    echo -e "${YELLOW}⊘${NC} $name ($type): $check_message"
                    ;;
                dry_run)
                    echo -e "${BLUE}→${NC} $name ($type): $check_message"
                    ;;
                *)
                    echo -e "${YELLOW}?${NC} $name ($type): $check_message"
                    ;;
            esac
        fi

        # Send notification on state change
        if [ "$WATCH_MODE" = true ] && state_changed "$name" "$check_status" "$prev_state"; then
            send_notification "$name" "$type" "$check_status" "$check_message"
        fi
    done <<< "$services"

    new_state+="}"
    save_state "$new_state"

    # JSON output
    if [ "$JSON_OUTPUT" = true ]; then
        echo "{"
        echo "  \"version\": \"1.0\","
        echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
        echo "  \"checks\": ["

        local first_result=true
        for result in "${results[@]}"; do
            local r_name r_type r_status r_message
            r_name=$(echo "$result" | cut -d'|' -f1)
            r_type=$(echo "$result" | cut -d'|' -f2)
            r_status=$(echo "$result" | cut -d'|' -f3)
            r_message=$(echo "$result" | cut -d'|' -f4-)

            [ "$first_result" = false ] && echo ","
            echo -n "    {\"name\": \"$r_name\", \"type\": \"$r_type\", \"status\": \"$r_status\", \"message\": \"$r_message\"}"
            first_result=false
        done

        echo ""
        echo "  ]"
        echo "}"
    fi
}

# Main
main() {
    parse_args "$@"
    validate_args

    # Setup logging
    mkdir -p "$LOG_DIR" && chmod 700 "$LOG_DIR" || true
    umask 077

    if [ "$WATCH_MODE" = true ]; then
        print_info "Watch mode enabled (interval: ${CHECK_INTERVAL}s)"
        print_info "Press Ctrl+C to stop"
        echo ""

        while true; do
            run_checks
            sleep "$CHECK_INTERVAL"

            if [ "$JSON_OUTPUT" = false ]; then
                echo ""
                echo -e "${BLUE}--- Next check in ${CHECK_INTERVAL}s ---${NC}"
                echo ""
            fi
        done
    else
        run_checks
    fi
}

main "$@"
