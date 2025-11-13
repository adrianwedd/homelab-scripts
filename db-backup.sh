#!/bin/bash

# db-backup.sh - Automated database backups with retention and cloud sync
# Version: 1.1.0
# Supports PostgreSQL and MySQL with configurable retention policies

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
LOGS_DIR="$SCRIPT_DIR/logs/db-backup"
umask 077

# Ensure logs directory exists with secure permissions
if [ ! -d "$LOGS_DIR" ]; then
    mkdir -p "$LOGS_DIR"
    chmod 700 "$LOGS_DIR"
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOGS_DIR/backup_$TIMESTAMP.log"
JSON_FILE="$LOGS_DIR/backup_$TIMESTAMP.json"

# Default settings
DB_TYPE=""
DB_DSN="${DB_DSN:-}"  # From environment variable
OUTPUT_DIR="./backups"
RETENTION="7:4:12"  # daily:weekly:monthly
RCLONE_REMOTE=""
TEST_RESTORE=false
OUTPUT_JSON=false
DRY_RUN=false

# Retention counts
DAILY_KEEP=7
WEEKLY_KEEP=4
MONTHLY_KEEP=12

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

# Sanitize DSN for logging (mask password)
sanitize_dsn() {
    local dsn="$1"
    # Mask password in DSN (support postgres:// and mysql:// formats)
    echo "$dsn" | sed -E 's|://([^:]+):([^@]+)@|://\1:****@|g'
}

show_help() {
    cat <<EOF
Usage: ./db-backup.sh [OPTIONS]

Automated database backup tool with retention policies and optional cloud sync.

OPTIONS:
    --db <type>           Database type: pg (PostgreSQL) or mysql (MySQL)
    --dsn <url>           Database DSN (or set DB_DSN environment variable)
    --out <dir>           Output directory (default: ./backups)
    --retention <d:w:m>   Retention: daily:weekly:monthly (default: 7:4:12)
    --rclone <remote>     Upload to rclone remote (e.g., gdrive:backups)
    --test-restore        Verify backup by test restore (PostgreSQL only)
    --json                JSON summary output
    --dry-run             Show backup plan without executing
    --help                Show this help message

RETENTION POLICY:
    Format: daily:weekly:monthly
    - daily: Number of daily backups to keep
    - weekly: Number of weekly backups to keep (one per week)
    - monthly: Number of monthly backups to keep (one per month)

    Example: 7:4:12
    - Keep last 7 daily backups
    - Keep last 4 weekly backups (oldest of each week)
    - Keep last 12 monthly backups (oldest of each month)

DSN FORMATS:
    PostgreSQL:
        postgres://username:password@host:port/database
        postgresql://username:password@host:port/database

    MySQL:
        mysql://username:password@host:port/database

SECURITY:
    - DSN passwords are masked in logs
    - Backup files: chmod 600 (owner read/write only)
    - Logs directory: chmod 700 (owner access only)
    - Use DB_DSN environment variable to avoid CLI exposure

DEPENDENCIES:
    - pg_dump (PostgreSQL backups)
    - mysqldump (MySQL backups)
    - gzip (compression)
    - rclone (optional, for cloud sync)

EXAMPLES:
    # PostgreSQL backup with DSN from environment
    export DB_DSN="postgres://user:pass@localhost/mydb"
    ./db-backup.sh --db pg --out ./backups

    # MySQL backup with custom retention
    ./db-backup.sh --db mysql --dsn "mysql://root:pass@localhost/app" --retention 14:8:24

    # Backup with cloud sync to rclone remote
    ./db-backup.sh --db pg --out ./backups --rclone gdrive:backups

    # Test restore after backup (PostgreSQL only)
    ./db-backup.sh --db pg --test-restore

    # Dry run to preview
    ./db-backup.sh --db pg --dry-run

OUTPUT:
    Backup files: {OUTPUT_DIR}/{DB_TYPE}_{DATABASE}_{TIMESTAMP}.sql.gz
    Example: ./backups/pg_mydb_20251112_140530.sql.gz

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --db)
            DB_TYPE="$2"
            if [[ ! "$DB_TYPE" =~ ^(pg|mysql)$ ]]; then
                echo "Error: --db must be 'pg' or 'mysql'"
                exit 1
            fi
            shift 2
            ;;
        --dsn)
            DB_DSN="$2"
            shift 2
            ;;
        --out)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --retention)
            RETENTION="$2"
            if [[ ! "$RETENTION" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]]; then
                echo "Error: --retention must be in format daily:weekly:monthly (e.g., 7:4:12)"
                exit 1
            fi
            IFS=':' read -r DAILY_KEEP WEEKLY_KEEP MONTHLY_KEEP <<< "$RETENTION"

            # Validate retention bounds
            if [ "$DAILY_KEEP" -lt 1 ] || [ "$DAILY_KEEP" -gt 3650 ]; then
                echo "Error: Daily retention must be between 1 and 3650 days"
                exit 1
            fi
            if [ "$WEEKLY_KEEP" -lt 1 ] || [ "$WEEKLY_KEEP" -gt 520 ]; then
                echo "Error: Weekly retention must be between 1 and 520 weeks (~10 years)"
                exit 1
            fi
            if [ "$MONTHLY_KEEP" -lt 1 ] || [ "$MONTHLY_KEEP" -gt 360 ]; then
                echo "Error: Monthly retention must be between 1 and 360 months (30 years)"
                exit 1
            fi

            shift 2
            ;;
        --rclone)
            RCLONE_REMOTE="$2"
            shift 2
            ;;
        --test-restore)
            TEST_RESTORE=true
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

# Validation
if [ -z "$DB_TYPE" ]; then
    echo "Error: --db is required"
    show_help
    exit 1
fi

if [ -z "$DB_DSN" ]; then
    echo "Error: DSN required (use --dsn or set DB_DSN environment variable)"
    echo ""
    echo "Example:"
    echo "  export DB_DSN=\"postgres://user:pass@localhost/mydb\""
    echo "  ./db-backup.sh --db pg"
    exit 1
fi

# Validate output directory path (security)
validate_output_dir() {
    local dir="$1"

    # Attempt to get canonical path (multiple fallbacks for cross-platform)
    local canonical=""
    if command -v realpath >/dev/null 2>&1; then
        canonical=$(realpath -m "$dir" 2>/dev/null) || canonical=""
    elif command -v readlink >/dev/null 2>&1; then
        canonical=$(readlink -f "$dir" 2>/dev/null) || canonical=""
    elif command -v python3 >/dev/null 2>&1; then
        canonical=$(python3 -c "import os; print(os.path.realpath('$dir'))" 2>/dev/null) || canonical=""
    fi

    # If no canonicalization available, check for traversal sequences
    if [ -z "$canonical" ]; then
        if [[ "$dir" == *"/../"* ]] || [[ "$dir" == *"/.."* ]] || [[ "$dir" == *"../"* ]]; then
            echo "Error: Path contains traversal sequences and cannot be validated"
            echo "       Rejecting for safety: $dir"
            exit 1
        fi
        canonical="$dir"
    fi

    # Block system directories
    local blocked_prefixes=("/usr" "/etc" "/var" "/bin" "/sbin" "/boot" "/sys" "/proc" "/dev")
    for prefix in "${blocked_prefixes[@]}"; do
        if [[ "$canonical" == "$prefix"* ]]; then
            echo "Error: Output directory cannot be in system directory: $prefix"
            echo "       Use a directory under \$HOME instead"
            echo "       Example: $HOME/backups/db"
            exit 1
        fi
    done

    # Require path to be under $HOME
    if [[ "$canonical" != "$HOME"* ]] && [[ "$canonical" != "."* ]] && [[ "$canonical" != "./"* ]]; then
        echo "Error: Output directory must be under \$HOME for safety"
        echo "       Provided: $canonical"
        echo "       Required: Under $HOME"
        echo "       Example: $HOME/backups/db"
        exit 1
    fi
}

# Validate output directory
validate_output_dir "$OUTPUT_DIR"

# URL decode helper
url_decode() {
    local encoded="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import sys, urllib.parse as u; print(u.unquote(sys.argv[1]))" "$encoded" 2>/dev/null || echo "$encoded"
    else
        # Fallback: no decoding if python3 unavailable
        echo "$encoded"
    fi
}

# Parse DSN to extract database name and connection details
parse_dsn() {
    local dsn="$1"

    # Extract protocol
    if [[ "$dsn" =~ ^postgres(ql)?:// ]]; then
        DB_PROTOCOL="postgresql"
    elif [[ "$dsn" =~ ^mysql:// ]]; then
        DB_PROTOCOL="mysql"
    else
        print_error "Invalid DSN format. Must start with postgres://, postgresql://, or mysql://"
        exit 1
    fi

    # Extract components with support for IPv6 ([::1]) and URL-encoded credentials
    # Pattern handles: protocol://user:pass@host:port/database or protocol://user:pass@[::1]:port/database
    if [[ "$dsn" =~ ://([^:]+):([^@]+)@\[([^\]]+)\]:?([0-9]+)?/(.+)$ ]]; then
        # IPv6 format with brackets
        DB_USER=$(url_decode "${BASH_REMATCH[1]}")
        DB_PASS=$(url_decode "${BASH_REMATCH[2]}")
        DB_HOST="${BASH_REMATCH[3]}"
        DB_PORT="${BASH_REMATCH[4]:-}"
        DB_NAME="${BASH_REMATCH[5]%%\?*}"  # Strip query params
    elif [[ "$dsn" =~ ://([^:]+):([^@]+)@([^:/]+):?([0-9]+)?/(.+)$ ]]; then
        # Standard format (IPv4 or hostname)
        DB_USER=$(url_decode "${BASH_REMATCH[1]}")
        DB_PASS=$(url_decode "${BASH_REMATCH[2]}")
        DB_HOST="${BASH_REMATCH[3]}"
        DB_PORT="${BASH_REMATCH[4]:-}"
        DB_NAME="${BASH_REMATCH[5]%%\?*}"  # Strip query params
    else
        print_error "Failed to parse DSN"
        echo ""
        echo "Supported formats:"
        echo "  postgres://user:pass@host:port/database"
        echo "  postgres://user:pass@[::1]:port/database  (IPv6)"
        echo "  mysql://user:pass@host:port/database"
        echo ""
        echo "Note: Credentials with special characters should be URL-encoded"
        echo "      Query parameters (?sslmode=require) are stripped and ignored"
        exit 1
    fi

    # Set default ports
    if [ -z "$DB_PORT" ]; then
        if [ "$DB_PROTOCOL" = "postgresql" ]; then
            DB_PORT="5432"
        else
            DB_PORT="3306"
        fi
    fi
}

# Check dependencies
check_dependencies() {
    if [ "$DB_TYPE" = "pg" ]; then
        if ! command -v pg_dump >/dev/null 2>&1; then
            print_error "pg_dump not found"
            echo ""
            echo "Install PostgreSQL client tools:"
            echo "  macOS:  brew install postgresql"
            echo "  Linux:  sudo apt install postgresql-client"
            exit 1
        fi
    elif [ "$DB_TYPE" = "mysql" ]; then
        if ! command -v mysqldump >/dev/null 2>&1; then
            print_error "mysqldump not found"
            echo ""
            echo "Install MySQL client tools:"
            echo "  macOS:  brew install mysql-client"
            echo "  Linux:  sudo apt install mysql-client"
            exit 1
        fi
    fi

    if ! command -v gzip >/dev/null 2>&1; then
        print_error "gzip not found (required for compression)"
        exit 1
    fi

    if [ -n "$RCLONE_REMOTE" ] && ! command -v rclone >/dev/null 2>&1; then
        print_error "rclone not found (required for --rclone)"
        echo ""
        echo "Install rclone:"
        echo "  macOS:  brew install rclone"
        echo "  Linux:  sudo apt install rclone"
        exit 1
    fi
}

# Perform backup
perform_backup() {
    local output_file="$1"
    local success=false

    if [ "$DB_TYPE" = "pg" ]; then
        print_info "Running pg_dump for database: $DB_NAME"

        # Use PGPASSWORD environment variable for authentication
        if PGPASSWORD="$DB_PASS" pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
            --no-owner --no-privileges --clean --if-exists 2>>"$LOG_FILE" | gzip > "$output_file"; then
            success=true
        fi

    elif [ "$DB_TYPE" = "mysql" ]; then
        print_info "Running mysqldump for database: $DB_NAME"

        # Create secure credentials file to avoid password in process list
        local creds_file
        creds_file=$(mktemp) || { print_error "Failed to create temp file"; return 1; }
        chmod 600 "$creds_file"

        # Write credentials to temp file
        cat > "$creds_file" << EOF
[client]
user=$DB_USER
password=$DB_PASS
host=$DB_HOST
port=$DB_PORT
EOF

        # Use --defaults-extra-file for secure credential passing
        if mysqldump --defaults-extra-file="$creds_file" \
            --single-transaction --routines --triggers "$DB_NAME" 2>>"$LOG_FILE" | gzip > "$output_file"; then
            success=true
        fi

        # Clean up credentials file
        rm -f "$creds_file"
    fi

    if [ "$success" = true ]; then
        # Set secure permissions
        chmod 600 "$output_file"

        local size=$(du -sh "$output_file" | awk '{print $1}')
        print_success "Backup created: $output_file ($size)"
        echo "$output_file"
        return 0
    else
        print_error "Backup failed - check log for details"
        rm -f "$output_file"
        return 1
    fi
}

# Apply retention policy
apply_retention() {
    local backup_dir="$1"
    local pattern="${DB_TYPE}_${DB_NAME}_*.sql.gz"

    print_section "Applying Retention Policy"
    print_info "Policy: Keep $DAILY_KEEP daily, $WEEKLY_KEEP weekly, $MONTHLY_KEEP monthly"

    # Get all backups sorted by date (newest first)
    local all_backups=()
    while IFS= read -r backup; do
        all_backups+=("$backup")
    done < <(find "$backup_dir" -name "$pattern" -type f 2>/dev/null | sort -r)

    if [ "${#all_backups[@]}" -eq 0 ]; then
        print_info "No existing backups found"
        return 0
    fi

    print_info "Found ${#all_backups[@]} existing backup(s)"

    # Track which backups to keep
    declare -A keep_backups

    # Keep daily backups (last N days)
    local daily_count=0
    for backup in "${all_backups[@]}"; do
        if [ $daily_count -lt "$DAILY_KEEP" ]; then
            keep_backups["$backup"]=1
            daily_count=$((daily_count + 1))
        fi
    done

    # Keep weekly backups (oldest of each week for last N weeks)
    declare -A weeks_seen
    for backup in "${all_backups[@]}"; do
        # Extract date from filename
        local backup_date=$(basename "$backup" | grep -oE '[0-9]{8}' | head -1)
        if [ -n "$backup_date" ]; then
            # Get week number (YYYYWW format)
            local week_num=$(date -j -f "%Y%m%d" "$backup_date" "+%Y%U" 2>/dev/null || date -d "$backup_date" "+%Y%U" 2>/dev/null)

            if [ -n "$week_num" ] && [ -z "${weeks_seen[$week_num]:-}" ]; then
                keep_backups["$backup"]=1
                weeks_seen["$week_num"]=1

                if [ "${#weeks_seen[@]}" -ge "$WEEKLY_KEEP" ]; then
                    break
                fi
            fi
        fi
    done

    # Keep monthly backups (oldest of each month for last N months)
    declare -A months_seen
    for backup in "${all_backups[@]}"; do
        local backup_date=$(basename "$backup" | grep -oE '[0-9]{8}' | head -1)
        if [ -n "$backup_date" ]; then
            # Get month (YYYYMM format)
            local month_num="${backup_date:0:6}"

            if [ -n "$month_num" ] && [ -z "${months_seen[$month_num]:-}" ]; then
                keep_backups["$backup"]=1
                months_seen["$month_num"]=1

                if [ "${#months_seen[@]}" -ge "$MONTHLY_KEEP" ]; then
                    break
                fi
            fi
        fi
    done

    # Remove backups not in keep list
    local removed_count=0
    for backup in "${all_backups[@]}"; do
        if [ -z "${keep_backups[$backup]:-}" ]; then
            if [ "$DRY_RUN" = true ]; then
                print_info "[DRY RUN] Would remove: $(basename "$backup")"
            else
                rm -f "$backup"
                print_info "Removed old backup: $(basename "$backup")"
            fi
            removed_count=$((removed_count + 1))
        fi
    done

    if [ $removed_count -eq 0 ]; then
        print_info "No backups removed (all within retention policy)"
    else
        print_success "Removed $removed_count old backup(s)"
    fi

    print_info "Kept ${#keep_backups[@]} backup(s) per retention policy"
}

# Upload to rclone
upload_to_rclone() {
    local backup_file="$1"

    print_section "Uploading to Cloud"
    print_info "Destination: $RCLONE_REMOTE"

    if rclone copy "$backup_file" "$RCLONE_REMOTE" --progress 2>&1 | tee -a "$LOG_FILE"; then
        print_success "Upload complete"
        return 0
    else
        print_error "Upload failed"
        return 1
    fi
}

# Test restore (PostgreSQL only)
test_restore() {
    local backup_file="$1"

    if [ "$DB_TYPE" != "pg" ]; then
        print_warning "Test restore only supported for PostgreSQL"
        return 0
    fi

    print_section "Test Restore"

    local test_db="${DB_NAME}_restore_test_$$"
    print_info "Creating temporary database: $test_db"

    # Create test database
    if ! PGPASSWORD="$DB_PASS" createdb -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$test_db" 2>>"$LOG_FILE"; then
        print_error "Failed to create test database"
        return 1
    fi

    # Restore backup
    print_info "Restoring backup to test database..."
    if gunzip -c "$backup_file" | PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$test_db" >/dev/null 2>>"$LOG_FILE"; then
        print_success "Test restore successful"

        # Drop test database
        print_info "Cleaning up test database..."
        PGPASSWORD="$DB_PASS" dropdb -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$test_db" 2>>"$LOG_FILE"
        return 0
    else
        print_error "Test restore failed"
        PGPASSWORD="$DB_PASS" dropdb -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$test_db" 2>>"$LOG_FILE" || true
        return 1
    fi
}

# Main execution
parse_dsn "$DB_DSN"

print_section "Database Backup"
print_info "Database type: $DB_TYPE"
print_info "Database name: $DB_NAME"
print_info "Host: $DB_HOST:$DB_PORT"
print_info "DSN: $(sanitize_dsn "$DB_DSN")"
print_info "Output directory: $OUTPUT_DIR"
print_info "Retention policy: $RETENTION (daily:weekly:monthly)"
[ -n "$RCLONE_REMOTE" ] && print_info "Rclone remote: $RCLONE_REMOTE"
[ "$TEST_RESTORE" = true ] && print_info "Test restore: enabled"
print_info "Log file: $LOG_FILE"

if [ "$DRY_RUN" = true ]; then
    print_warning "DRY RUN MODE - no actual backup will be performed"
    echo ""
    print_info "Would create backup in: $OUTPUT_DIR"
    print_info "Filename pattern: ${DB_TYPE}_${DB_NAME}_YYYYMMDD_HHMMSS.sql.gz"
    print_info "Would apply retention policy after backup"
    [ -n "$RCLONE_REMOTE" ] && print_info "Would upload to: $RCLONE_REMOTE"
    [ "$TEST_RESTORE" = true ] && print_info "Would perform test restore"
    exit 0
fi

# Check dependencies
check_dependencies

# Create output directory
if [ ! -d "$OUTPUT_DIR" ]; then
    mkdir -p "$OUTPUT_DIR"
    chmod 700 "$OUTPUT_DIR"
fi

# Create backup filename
BACKUP_FILE="$OUTPUT_DIR/${DB_TYPE}_${DB_NAME}_${TIMESTAMP}.sql.gz"

# Perform backup
print_section "Creating Backup"
if ! backup_path=$(perform_backup "$BACKUP_FILE"); then
    print_error "Backup failed - exiting"
    exit 1
fi

# Apply retention
apply_retention "$OUTPUT_DIR"

# Upload to rclone if specified
if [ -n "$RCLONE_REMOTE" ]; then
    upload_to_rclone "$BACKUP_FILE" || print_warning "Backup created but upload failed"
fi

# Test restore if requested
if [ "$TEST_RESTORE" = true ]; then
    test_restore "$BACKUP_FILE" || print_warning "Backup created but test restore failed"
fi

# JSON output
if [ "$OUTPUT_JSON" = true ]; then
    cat > "$JSON_FILE" <<EOF
{
  "timestamp": "$(date -Iseconds)",
  "database": {
    "type": "$DB_TYPE",
    "name": "$DB_NAME",
    "host": "$DB_HOST",
    "port": $DB_PORT
  },
  "backup": {
    "file": "$BACKUP_FILE",
    "size": "$(du -sh "$BACKUP_FILE" | awk '{print $1}')",
    "compressed": true
  },
  "retention": {
    "daily": $DAILY_KEEP,
    "weekly": $WEEKLY_KEEP,
    "monthly": $MONTHLY_KEEP
  },
  "rclone": {
    "enabled": $([ -n "$RCLONE_REMOTE" ] && echo "true" || echo "false"),
    "remote": "$RCLONE_REMOTE"
  },
  "test_restore": $TEST_RESTORE
}
EOF
    print_success "JSON summary: $JSON_FILE"
fi

print_section "Backup Complete"
print_success "Backup file: $BACKUP_FILE"
print_success "Size: $(du -sh "$BACKUP_FILE" | awk '{print $1}')"
print_info "Full log: $LOG_FILE"
