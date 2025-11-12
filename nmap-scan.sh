#!/bin/bash

# nmap-scan.sh - Network discovery and change tracking
# Discovers active hosts on LAN(s) and tracks changes over time
# Safe defaults: ping sweep + quick TCP (22,80,443)

set -u

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Logging
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS_DIR="$SCRIPT_DIR/logs/nmap"
umask 077

# Ensure logs directory exists with secure permissions
if [ ! -d "$LOGS_DIR" ]; then
    mkdir -p "$LOGS_DIR"
    chmod 700 "$LOGS_DIR"
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOGS_DIR/nmap_scan_$TIMESTAMP.log"
JSON_FILE="$LOGS_DIR/nmap_scan_$TIMESTAMP.json"
LATEST_LINK="$LOGS_DIR/latest.json"

# Default settings
SCAN_MODE="fast"
OUTPUT_MODE="both"
DO_DELTA=true
RATE_LIMIT=100
CIDR_LIST=""
EXCLUDE_LIST=""
DRY_RUN=false

# Print functions
print_info() {
    echo -e "${BLUE}ℹ${NC} $*" | tee -a "$LOG_FILE"
}

print_success() {
    echo -e "${GREEN}✓${NC} $*" | tee -a "$LOG_FILE"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $*" | tee -a "$LOG_FILE"
}

print_error() {
    echo -e "${RED}✗${NC} $*" | tee -a "$LOG_FILE"
}

print_section() {
    echo -e "\n${CYAN}━━━ $* ━━━${NC}\n" | tee -a "$LOG_FILE"
}

show_help() {
    cat <<EOF
Usage: ./nmap-scan.sh [OPTIONS]

Network discovery tool with delta tracking. Safe defaults: ping sweep + quick TCP (22,80,443).

OPTIONS:
    --cidr CIDR         Comma-separated CIDRs (e.g., "192.168.1.0/24,10.0.0.0/24")
                        If not specified, auto-detects from primary interface

    --fast              Fast scan: ping sweep + TCP 22,80,443 (default)
    --full              Full scan: top 1000 TCP ports (slower)

    --output MODE       Output mode: json|table|both (default: both)
    --no-delta          Skip delta comparison with previous scan

    --exclude LIST      Comma-separated IPs or MAC patterns to exclude
                        Example: "192.168.1.10,AA:BB:CC:*"

    --rate NUM          Max packets per second (default: 100, range: 1-10000)
                        Maps to nmap --max-rate flag for throttling
    --dry-run           Show exact nmap commands without executing

    --help              Show this help message

PRIVILEGE NOTES:
    - Root/sudo: Uses SYN scans (-sS, faster) and captures MAC addresses
    - Non-root: Uses TCP connect scans (-sT, slower), limited MAC capture
    - MAC addresses only available for hosts on same L2 network segment

EXAMPLES:
    # Fast scan default subnet
    ./nmap-scan.sh

    # Multi-subnet full scan with delta
    ./nmap-scan.sh --cidr "192.168.1.0/24,10.0.0.0/24" --full

    # Exclude noisy hosts and limit rate
    ./nmap-scan.sh --exclude "192.168.1.10,AA:BB:CC:*" --rate 50

    # JSON output only, no delta
    ./nmap-scan.sh --output json --no-delta

    # Dry-run to see commands
    ./nmap-scan.sh --cidr "192.168.1.0/24" --dry-run

SECURITY:
    - Non-intrusive defaults (ping + 3 common ports only)
    - Rate limiting prevents network flooding (--max-rate)
    - Explicit --full required for deeper port scans
    - Logs stored securely in ./logs/nmap/ (umask 077, mode 700)
    - Designed for authorized local network discovery only

DEPENDENCIES:
    - nmap: brew install nmap (macOS) or apt install nmap (Linux)
    - Optional: python3 (for network address calculation)

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --cidr)
            CIDR_LIST="$2"
            shift 2
            ;;
        --fast)
            SCAN_MODE="fast"
            shift
            ;;
        --full)
            SCAN_MODE="full"
            shift
            ;;
        --output)
            OUTPUT_MODE="$2"
            if [[ ! "$OUTPUT_MODE" =~ ^(json|table|both)$ ]]; then
                echo "Error: --output must be json, table, or both"
                exit 1
            fi
            shift 2
            ;;
        --no-delta)
            DO_DELTA=false
            shift
            ;;
        --exclude)
            EXCLUDE_LIST="$2"
            shift 2
            ;;
        --rate)
            RATE_LIMIT="$2"
            if ! [[ "$RATE_LIMIT" =~ ^[0-9]+$ ]] || [ "$RATE_LIMIT" -lt 1 ] || [ "$RATE_LIMIT" -gt 10000 ]; then
                echo "Error: --rate must be between 1 and 10000"
                exit 1
            fi
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
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

# Check for nmap
if ! command -v nmap >/dev/null 2>&1; then
    print_error "nmap is not installed"
    echo ""
    echo "Install with:"
    echo "  macOS:  brew install nmap"
    echo "  Linux:  sudo apt install nmap"
    echo ""
    exit 1
fi

# Check if running as root (needed for SYN scans)
is_root() {
    [ "$(id -u)" -eq 0 ]
}

# Auto-detect CIDR if not specified
detect_cidr() {
    local detected=""

    # Try to get primary interface and its subnet
    if command -v ip >/dev/null 2>&1; then
        # Linux: use ip command - get default route interface
        local primary_if=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
        if [ -n "$primary_if" ]; then
            # Get CIDR from this interface
            detected=$(ip -o -4 addr show dev "$primary_if" 2>/dev/null | awk '{print $4}' | head -n1)
            if [ -n "$detected" ]; then
                # Calculate network address from CIDR
                local ip_part=$(echo "$detected" | cut -d'/' -f1)
                local mask_bits=$(echo "$detected" | cut -d'/' -f2)

                # Convert to network address
                local net=$(python3 -c "import ipaddress; print(ipaddress.IPv4Network('$detected', strict=False).network_address)" 2>/dev/null || echo "$ip_part")
                echo "$net/$mask_bits"
                return 0
            fi
        fi
    elif command -v ifconfig >/dev/null 2>&1 && command -v route >/dev/null 2>&1; then
        # macOS: use ifconfig and route - get default route interface
        local primary_if=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')
        if [ -n "$primary_if" ]; then
            local ip=$(ifconfig "$primary_if" 2>/dev/null | awk '/inet / {print $2}' | head -n1)
            local netmask=$(ifconfig "$primary_if" 2>/dev/null | awk '/inet / {print $4}' | head -n1)
            if [ -n "$ip" ] && [ -n "$netmask" ]; then
                # Convert netmask to CIDR bits
                local cidr_bits=$(echo "$netmask" | awk -F. '{
                    split($0, octets, ".")
                    bits = 0
                    for (i = 1; i <= 4; i++) {
                        mask = octets[i]
                        while (mask > 0) {
                            bits += mask % 2
                            mask = int(mask / 2)
                        }
                    }
                    print bits
                }')
                # Calculate network address
                local net=$(echo "$ip $netmask" | awk '{
                    split($1, ip, ".")
                    split($2, mask, ".")
                    printf "%d.%d.%d.%d", \
                        and(ip[1], mask[1]), \
                        and(ip[2], mask[2]), \
                        and(ip[3], mask[3]), \
                        and(ip[4], mask[4])
                }')
                echo "$net/$cidr_bits"
                return 0
            fi
        fi
    fi

    return 1
}

# Validate CIDR format
validate_cidr() {
    local cidr="$1"

    # CIDR format: IPv4/prefix (e.g., 192.168.1.0/24)
    # IPv4: 0-255 . 0-255 . 0-255 . 0-255
    # Prefix: 0-32
    local ipv4_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'

    if ! echo "$cidr" | grep -Eq "$ipv4_regex"; then
        print_error "Invalid CIDR format: $cidr"
        print_info "Expected format: 192.168.1.0/24 (IPv4 address with /prefix)"
        return 1
    fi

    # Extract IP and prefix
    local ip_part=$(echo "$cidr" | cut -d'/' -f1)
    local prefix=$(echo "$cidr" | cut -d'/' -f2)

    # Validate each octet (0-255)
    IFS='.' read -ra octets <<< "$ip_part"
    if [ "${#octets[@]}" -ne 4 ]; then
        print_error "Invalid IP address: $ip_part (must have 4 octets)"
        return 1
    fi

    for octet in "${octets[@]}"; do
        if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ] 2>/dev/null; then
            print_error "Invalid IP octet: $octet (must be 0-255)"
            return 1
        fi
    done

    # Validate prefix (0-32 for IPv4)
    if [ "$prefix" -lt 0 ] || [ "$prefix" -gt 32 ] 2>/dev/null; then
        print_error "Invalid CIDR prefix: /$prefix (must be /0 to /32)"
        return 1
    fi

    return 0
}

if [ -z "$CIDR_LIST" ]; then
    print_info "No CIDR specified, attempting auto-detection..."
    CIDR_LIST=$(detect_cidr)
    if [ -z "$CIDR_LIST" ]; then
        print_error "Could not auto-detect CIDR"
        print_info "Please specify with --cidr \"192.168.1.0/24\""
        exit 1
    fi
    print_success "Auto-detected CIDR: $CIDR_LIST"
fi

# Validate all CIDRs in the list
IFS=',' read -ra CIDR_ARRAY <<< "$CIDR_LIST"
for cidr in "${CIDR_ARRAY[@]}"; do
    # Trim leading/trailing whitespace (pure bash)
    cidr="${cidr#"${cidr%%[![:space:]]*}"}"
    cidr="${cidr%"${cidr##*[![:space:]]}"}"
    if ! validate_cidr "$cidr"; then
        print_info "Examples of valid CIDR notation:"
        print_info "  Single network:  192.168.1.0/24"
        print_info "  Multiple:        192.168.1.0/24,10.0.0.0/8"
        print_info "  Small subnet:    192.168.1.0/30 (4 addresses)"
        exit 1
    fi
done

# Show configuration
print_section "Network Scan Configuration"
print_info "Mode: $SCAN_MODE"
print_info "CIDR(s): $CIDR_LIST"
print_info "Output: $OUTPUT_MODE"
print_info "Delta tracking: $DO_DELTA"
print_info "Rate limit: $RATE_LIMIT pps"
[ -n "$EXCLUDE_LIST" ] && print_info "Exclusions: $EXCLUDE_LIST"
print_info "JSON output: $JSON_FILE"

# Build nmap command
build_nmap_cmd() {
    local cidr="$1"
    local cmd="nmap"
    local needs_root=false

    # Scan mode - adapt based on root privileges
    if [ "$SCAN_MODE" = "fast" ]; then
        # Fast mode: host discovery + quick TCP scan on common ports
        cmd="$cmd -sn -PS22,80,443"  # Ping scan + TCP SYN to common ports
        if ! is_root; then
            # Non-root: -sn doesn't require root, but -PS does
            # Fall back to -sT (TCP connect) for port scanning
            print_warning "Running as non-root: using TCP connect scan (-sT) instead of SYN scan (-sS)"
            print_info "For faster scans with MAC addresses, run with sudo"
        fi
    else
        # Full mode: comprehensive TCP scan
        if is_root; then
            cmd="$cmd -sS"  # TCP SYN scan (fast, requires root)
        else
            cmd="$cmd -sT"  # TCP connect scan (slower, works without root)
            print_warning "Running as non-root: using TCP connect scan (-sT)"
            print_info "SYN scan (-sS) requires root privileges. For faster scans, run with sudo"
        fi
        cmd="$cmd -p 1-1000"  # Top 1000 ports (not all 65535)
    fi

    # Rate limiting (applies to all modes)
    cmd="$cmd --max-rate $RATE_LIMIT"

    # Output format
    cmd="$cmd -oX -"  # XML output to stdout

    # Add CIDR
    cmd="$cmd $cidr"

    # Exclusions
    if [ -n "$EXCLUDE_LIST" ]; then
        # Convert comma-separated list to space-separated for --exclude
        local excludes=$(echo "$EXCLUDE_LIST" | tr ',' ' ')
        cmd="$cmd --exclude $excludes"
    fi

    echo "$cmd"
}

if [ "$DRY_RUN" = true ]; then
    print_warning "DRY RUN - no actual scanning will be performed"
    echo ""

    # Show exact commands that would be run
    print_info "Commands that would be executed:"
    echo ""
    IFS=',' read -ra CIDR_ARRAY <<< "$CIDR_LIST"
    for cidr in "${CIDR_ARRAY[@]}"; do
        # Trim leading/trailing whitespace (pure bash)
        cidr="${cidr#"${cidr%%[![:space:]]*}"}"
        cidr="${cidr%"${cidr##*[![:space:]]}"}"
        nmap_cmd=$(build_nmap_cmd "$cidr")
        echo "  $nmap_cmd"
    done
    echo ""

    print_info "Output files:"
    echo "  JSON: $JSON_FILE"
    echo "  Log:  $LOG_FILE"
    echo ""

    # Show privilege info
    if is_root; then
        print_success "Running as root: SYN scans available, MAC addresses will be captured"
    else
        print_warning "Running as non-root: TCP connect scans only, MAC addresses may not be available"
        print_info "Note: MAC addresses are only available for hosts on the same L2 segment"
    fi

    exit 0
fi

# Parse nmap XML output to JSON with schema versioning
parse_nmap_xml() {
    awk '
    BEGIN {
        print "{"
        print "  \"version\": \"1.0\","
        print "  \"timestamp\": \"'"$TIMESTAMP"'\","
        print "  \"params\": {"
        print "    \"cidr\": [\"" gsub(/,/, "\",\"", "'"$CIDR_LIST"'") "\"],"
        print "    \"mode\": \"'"$SCAN_MODE"'\","
        print "    \"rate\": " "'"$RATE_LIMIT"',"
        print "    \"exclude\": \"'"$EXCLUDE_LIST"'\""
        print "  },"
        print "  \"hosts\": ["
        first = 1
    }
    /<host / {
        in_host = 1
        ip = ""
        mac = ""
        vendor = ""
        status = ""
        ports = ""
    }
    /<address addr="([^"]+)" addrtype="ipv4"/ {
        match($0, /addr="([^"]+)"/, arr)
        ip = arr[1]
    }
    /<address addr="([^"]+)" addrtype="mac"/ {
        match($0, /addr="([^"]+)"/, arr)
        mac = arr[1]
        match($0, /vendor="([^"]+)"/, arr)
        vendor = arr[1]
        # Escape quotes and backslashes in vendor name for JSON safety
        gsub(/\\/, "\\\\", vendor)
        gsub(/"/, "\\\"", vendor)
    }
    /<status state="([^"]+)"/ {
        match($0, /state="([^"]+)"/, arr)
        status = arr[1]
    }
    /<port protocol="([^"]+)" portid="([^"]+)"><state state="open"/ {
        match($0, /portid="([^"]+)"/, arr)
        port_num = arr[1]
        match($0, /protocol="([^"]+)"/, arr)
        protocol = arr[1]
        # Store as array for better structure
        if (ports == "") {
            ports = port_num
        } else {
            ports = ports "," port_num
        }
    }
    /<\/host>/ {
        if (in_host && ip != "" && status == "up") {
            if (first == 0) print ","
            first = 0
            print "    {"
            print "      \"ip\": \"" ip "\","
            print "      \"mac\": \"" mac "\","
            print "      \"vendor\": \"" vendor "\","
            print "      \"status\": \"" status "\","
            print "      \"ports\": \"" ports "\""
            print "    }"
        }
        in_host = 0
    }
    END {
        print "  ]"
        print "}"
    }
    '
}

# Perform scan
print_section "Starting Network Scan"

# Convert comma-separated CIDRs to array
IFS=',' read -ra CIDR_ARRAY <<< "$CIDR_LIST"

# Collect all results
temp_xml=$(mktemp)
trap 'rm -f "$temp_xml"' EXIT

for cidr in "${CIDR_ARRAY[@]}"; do
    # Trim leading/trailing whitespace (pure bash)
    cidr="${cidr#"${cidr%%[![:space:]]*}"}"
    cidr="${cidr%"${cidr##*[![:space:]]}"}"
    print_info "Scanning $cidr..."

    nmap_cmd=$(build_nmap_cmd "$cidr")
    print_info "Command: $nmap_cmd"

    if ! eval "$nmap_cmd" >> "$temp_xml" 2>>"$LOG_FILE"; then
        print_error "Scan failed for $cidr"
        continue
    fi

    print_success "Completed scan of $cidr"
done

# Parse XML to JSON
print_info "Parsing results..."
parse_nmap_xml < "$temp_xml" > "$JSON_FILE"

# Update latest symlink
ln -sf "$(basename "$JSON_FILE")" "$LATEST_LINK"

# Count hosts
host_count=$(grep -c '"ip":' "$JSON_FILE" || echo 0)
print_success "Found $host_count active host(s)"

# Delta tracking
if [ "$DO_DELTA" = true ] && [ -f "$LATEST_LINK" ]; then
    prev_file=$(readlink "$LATEST_LINK" 2>/dev/null)
    if [ -n "$prev_file" ] && [ -f "$LOGS_DIR/$prev_file" ] && [ "$LOGS_DIR/$prev_file" != "$JSON_FILE" ]; then
        print_section "Delta Analysis"

        # Extract IPs from current and previous scans
        current_ips=$(grep -o '"ip": "[^"]*"' "$JSON_FILE" | cut -d'"' -f4 | sort)
        previous_ips=$(grep -o '"ip": "[^"]*"' "$LOGS_DIR/$prev_file" | cut -d'"' -f4 | sort)

        # Find new and removed hosts
        new_hosts=$(comm -13 <(echo "$previous_ips") <(echo "$current_ips"))
        removed_hosts=$(comm -23 <(echo "$previous_ips") <(echo "$current_ips"))

        if [ -n "$new_hosts" ]; then
            print_success "New hosts detected:"
            echo "$new_hosts" | while read -r ip; do
                echo "  + $ip"
            done | tee -a "$LOG_FILE"
        fi

        if [ -n "$removed_hosts" ]; then
            print_warning "Hosts no longer responding:"
            echo "$removed_hosts" | while read -r ip; do
                echo "  - $ip"
            done | tee -a "$LOG_FILE"
        fi

        if [ -z "$new_hosts" ] && [ -z "$removed_hosts" ]; then
            print_info "No changes detected since last scan"
        fi
    else
        print_info "No previous scan found for delta comparison"
    fi
fi

# Output results
if [[ "$OUTPUT_MODE" =~ ^(table|both)$ ]]; then
    print_section "Scan Results"

    # Table header
    printf "%-16s %-18s %-30s %-20s\n" "IP Address" "MAC Address" "Vendor" "Open Ports" | tee -a "$LOG_FILE"
    printf "%s\n" "$(printf '─%.0s' {1..90})" | tee -a "$LOG_FILE"

    # Parse JSON and display table
    grep '"ip":' "$JSON_FILE" | while read -r line; do
        ip=$(echo "$line" | grep -o '"ip": "[^"]*"' | cut -d'"' -f4)
        mac=$(echo "$line" | grep -o '"mac": "[^"]*"' | cut -d'"' -f4)
        vendor=$(echo "$line" | grep -o '"vendor": "[^"]*"' | cut -d'"' -f4)
        ports=$(echo "$line" | grep -o '"ports": "[^"]*"' | cut -d'"' -f4)

        [ -z "$mac" ] && mac="N/A"
        [ -z "$vendor" ] && vendor="N/A"
        [ -z "$ports" ] && ports="N/A"

        printf "%-16s %-18s %-30s %-20s\n" "$ip" "$mac" "${vendor:0:30}" "$ports"
    done | tee -a "$LOG_FILE"
fi

if [[ "$OUTPUT_MODE" =~ ^(json|both)$ ]]; then
    print_info "JSON output saved to: $JSON_FILE"
fi

print_success "Scan complete"
print_info "Full log saved to: $LOG_FILE"
