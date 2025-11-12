#!/bin/bash

# cert-renewal-check.sh - SSL certificate expiry monitoring
# Checks domain certificates and local files for expiration

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
LOGS_DIR="$SCRIPT_DIR/logs/cert"
umask 077

# Ensure logs directory exists with secure permissions
if [ ! -d "$LOGS_DIR" ]; then
    mkdir -p "$LOGS_DIR"
    chmod 700 "$LOGS_DIR"
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOGS_DIR/cert_check_$TIMESTAMP.log"
JSON_FILE="$LOGS_DIR/cert_check_$TIMESTAMP.json"

# Default settings
WARN_DAYS=30
AUTO_RENEW=false
OUTPUT_JSON=false
DRY_RUN=false
DOMAINS_FILE=""
CERT_FILES=()

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
Usage: ./cert-renewal-check.sh [OPTIONS]

SSL certificate expiry monitoring and renewal tool.

OPTIONS:
    --domains <file>      File with domains to check (one per line)
    --cert <file>         Check specific certificate file (can be used multiple times)
    --warn-days <n>       Warn if cert expires within N days (default: 30)
    --auto-renew          Attempt certbot renewal if expiring (requires sudo)
    --json                JSON output
    --dry-run             Show what would be checked without executing
    --help                Show this help message

DEPENDENCIES:
    - openssl: Required for certificate inspection
    - certbot: Optional, for --auto-renew functionality

EXAMPLES:
    # Check domains from file
    ./cert-renewal-check.sh --domains domains.txt

    # Check specific certificate file
    ./cert-renewal-check.sh --cert /etc/ssl/certs/homelab.pem --warn-days 14

    # Check and auto-renew with certbot
    ./cert-renewal-check.sh --domains domains.txt --auto-renew

    # JSON output for monitoring integration
    ./cert-renewal-check.sh --domains domains.txt --json

DOMAINS FILE FORMAT:
    One domain per line:
    example.com
    homelab.local
    192.168.1.100

OUTPUT:
    - Table format (default): Human-readable table with status
    - JSON format (--json): Structured data for monitoring systems

SECURITY:
    - Logs stored securely in ./logs/cert/ (mode 700)
    - No credentials stored or logged
    - Certbot renewal requires explicit --auto-renew flag

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --domains)
            DOMAINS_FILE="$2"
            shift 2
            ;;
        --cert)
            CERT_FILES+=("$2")
            shift 2
            ;;
        --warn-days)
            WARN_DAYS="$2"
            if ! [[ "$WARN_DAYS" =~ ^[0-9]+$ ]] || [ "$WARN_DAYS" -lt 1 ] || [ "$WARN_DAYS" -gt 365 ]; then
                echo "Error: --warn-days must be between 1 and 365"
                exit 1
            fi
            shift 2
            ;;
        --auto-renew)
            AUTO_RENEW=true
            shift
            ;;
        --json)
            OUTPUT_JSON=true
            shift
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

# Check for openssl
if ! command -v openssl >/dev/null 2>&1; then
    print_error "openssl is not installed"
    echo ""
    echo "Install with:"
    echo "  macOS:  brew install openssl"
    echo "  Linux:  sudo apt install openssl"
    echo ""
    exit 1
fi

# Check inputs
if [ -z "$DOMAINS_FILE" ] && [ "${#CERT_FILES[@]}" -eq 0 ]; then
    echo "Error: Must specify --domains or --cert"
    show_help
    exit 1
fi

# Validate domains file
if [ -n "$DOMAINS_FILE" ] && [ ! -f "$DOMAINS_FILE" ]; then
    print_error "Domains file not found: $DOMAINS_FILE"
    exit 1
fi

# Check domains from file
check_domain() {
    local domain="$1"
    local days_remaining
    local expiry_date
    local status
    local color

    # Get certificate
    local cert_info
    cert_info=$(timeout 10 openssl s_client -connect "${domain}:443" -servername "$domain" </dev/null 2>/dev/null | openssl x509 -noout -dates 2>/dev/null)

    if [ $? -ne 0 ] || [ -z "$cert_info" ]; then
        echo "domain|$domain|ERROR|N/A|Failed to retrieve certificate"
        return 1
    fi

    # Extract expiry date
    expiry_date=$(echo "$cert_info" | grep "notAfter=" | cut -d= -f2)
    local expiry_epoch
    expiry_epoch=$(date -j -f "%b %d %T %Y %Z" "$expiry_date" +%s 2>/dev/null || date -d "$expiry_date" +%s 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo "domain|$domain|ERROR|N/A|Failed to parse expiry date"
        return 1
    fi

    # Calculate days remaining
    local now_epoch
    now_epoch=$(date +%s)
    days_remaining=$(( (expiry_epoch - now_epoch) / 86400 ))

    # Determine status
    if [ "$days_remaining" -lt 0 ]; then
        status="EXPIRED"
        color="$RED"
    elif [ "$days_remaining" -le "$WARN_DAYS" ]; then
        status="WARNING"
        color="$YELLOW"
    else
        status="OK"
        color="$GREEN"
    fi

    echo "domain|$domain|$status|$days_remaining|Expires: $expiry_date"
}

# Check certificate file
check_cert_file() {
    local cert_file="$1"
    local days_remaining
    local expiry_date
    local status
    local color

    if [ ! -f "$cert_file" ]; then
        echo "file|$cert_file|ERROR|N/A|File not found"
        return 1
    fi

    # Get certificate info
    local cert_info
    cert_info=$(openssl x509 -in "$cert_file" -noout -dates 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo "file|$cert_file|ERROR|N/A|Invalid certificate file"
        return 1
    fi

    # Extract expiry date
    expiry_date=$(echo "$cert_info" | grep "notAfter=" | cut -d= -f2)
    local expiry_epoch
    expiry_epoch=$(date -j -f "%b %d %T %Y %Z" "$expiry_date" +%s 2>/dev/null || date -d "$expiry_date" +%s 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo "file|$cert_file|ERROR|N/A|Failed to parse expiry date"
        return 1
    fi

    # Calculate days remaining
    local now_epoch
    now_epoch=$(date +%s)
    days_remaining=$(( (expiry_epoch - now_epoch) / 86400 ))

    # Determine status
    if [ "$days_remaining" -lt 0 ]; then
        status="EXPIRED"
    elif [ "$days_remaining" -le "$WARN_DAYS" ]; then
        status="WARNING"
    else
        status="OK"
    fi

    echo "file|$cert_file|$status|$days_remaining|Expires: $expiry_date"
}

# Main execution
print_section "Certificate Expiry Check"
print_info "Warning threshold: $WARN_DAYS days"
print_info "Log file: $LOG_FILE"

if [ "$DRY_RUN" = true ]; then
    print_warning "DRY RUN - no actual checks will be performed"

    if [ -n "$DOMAINS_FILE" ]; then
        print_info "Would check domains from: $DOMAINS_FILE"
        while IFS= read -r domain || [ -n "$domain" ]; do
            [[ -z "$domain" || "$domain" =~ ^# ]] && continue
            echo "  - $domain"
        done < "$DOMAINS_FILE"
    fi

    if [ "${#CERT_FILES[@]}" -gt 0 ]; then
        print_info "Would check certificate files:"
        for cert_file in "${CERT_FILES[@]}"; do
            echo "  - $cert_file"
        done
    fi

    exit 0
fi

# Collect results
declare -a results=()

# Check domains
if [ -n "$DOMAINS_FILE" ]; then
    print_info "Checking domains from: $DOMAINS_FILE"
    while IFS= read -r domain || [ -n "$domain" ]; do
        # Skip empty lines and comments
        [[ -z "$domain" || "$domain" =~ ^# ]] && continue

        result=$(check_domain "$domain")
        results+=("$result")
    done < "$DOMAINS_FILE"
fi

# Check certificate files
if [ "${#CERT_FILES[@]}" -gt 0 ]; then
    print_info "Checking certificate files"
    for cert_file in "${CERT_FILES[@]}"; do
        result=$(check_cert_file "$cert_file")
        results+=("$result")
    done
fi

# Output results
if [ "$OUTPUT_JSON" = true ]; then
    # JSON output
    echo "{" > "$JSON_FILE"
    echo "  \"timestamp\": \"$(date -Iseconds)\"," >> "$JSON_FILE"
    echo "  \"warn_days\": $WARN_DAYS," >> "$JSON_FILE"
    echo "  \"certificates\": [" >> "$JSON_FILE"

    first=true
    for result in "${results[@]}"; do
        IFS='|' read -r type name status days message <<< "$result"

        [ "$first" = false ] && echo "," >> "$JSON_FILE"
        first=false

        cat >> "$JSON_FILE" <<EOF
    {
      "type": "$type",
      "name": "$name",
      "status": "$status",
      "days_remaining": $days,
      "message": "$message"
    }
EOF
    done

    echo "  ]" >> "$JSON_FILE"
    echo "}" >> "$JSON_FILE"

    print_success "JSON output saved to: $JSON_FILE"
    cat "$JSON_FILE"
else
    # Table output
    print_section "Results"

    printf "%-10s %-40s %-10s %-15s %s\n" "Type" "Name" "Status" "Days Remaining" "Details" | tee -a "$LOG_FILE"
    printf "%s\n" "$(printf '─%.0s' {1..120})" | tee -a "$LOG_FILE"

    for result in "${results[@]}"; do
        IFS='|' read -r type name status days message <<< "$result"

        case "$status" in
            OK)
                color="$GREEN"
                ;;
            WARNING)
                color="$YELLOW"
                ;;
            EXPIRED|ERROR)
                color="$RED"
                ;;
            *)
                color="$NC"
                ;;
        esac

        printf "${color}%-10s %-40s %-10s %-15s %s${NC}\n" "$type" "${name:0:40}" "$status" "$days" "$message" | tee -a "$LOG_FILE"
    done
fi

# Auto-renew if requested
if [ "$AUTO_RENEW" = true ]; then
    # Count expiring certificates
    expiring_count=0
    for result in "${results[@]}"; do
        IFS='|' read -r type name status days message <<< "$result"
        if [ "$status" = "WARNING" ] || [ "$status" = "EXPIRED" ]; then
            expiring_count=$((expiring_count + 1))
        fi
    done

    if [ $expiring_count -gt 0 ]; then
        print_section "Auto-Renewal"
        print_warning "Found $expiring_count certificate(s) expiring within $WARN_DAYS days"

        if ! command -v certbot >/dev/null 2>&1; then
            print_error "certbot not installed - cannot auto-renew"
            print_info "Install with: sudo apt install certbot (Linux) or brew install certbot (macOS)"
        else
            print_info "Running certbot renewal (dry-run)..."
            if sudo certbot renew --dry-run 2>&1 | tee -a "$LOG_FILE"; then
                print_success "Dry-run successful"
                print_info "Running actual renewal..."
                if sudo certbot renew 2>&1 | tee -a "$LOG_FILE"; then
                    print_success "Certificates renewed successfully"
                else
                    print_error "Renewal failed - check log for details"
                fi
            else
                print_error "Dry-run failed - skipping actual renewal"
            fi
        fi
    else
        print_info "No certificates need renewal"
    fi
fi

print_success "Certificate check complete"
print_info "Full log: $LOG_FILE"
