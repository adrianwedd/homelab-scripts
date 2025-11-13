# System Maintenance Scripts

Automated scripts for system cleanup and backup operations.

---

## Scripts

### 1. `disk-cleanup.sh`

Comprehensive system cleanup script that frees up disk space by cleaning caches and unused files.

#### What it cleans:

- **VS Code** - Cached extensions, user data, workspace storage
- **Docker** - Unused containers, images, volumes, and build cache
- **Git** - Runs `git gc --aggressive --prune=now` on all repositories
- **Homebrew** - Old formula versions and download cache
- **NPM** - Package cache
- **Playwright** - Browser binaries (Chromium, Firefox, WebKit)
- **pnpm** - Unreferenced packages from store
- **pip/Python** - Package cache and wheels
- **AWS CLI** - CLI cache and temporary files

#### Usage:

```bash
# Interactive cleanup with confirmations (default)
./disk-cleanup.sh

# Preview what would be cleaned (dry run)
./disk-cleanup.sh --dry-run

# Non-interactive cleanup (auto-confirm all)
./disk-cleanup.sh -y

# Quick cleanup, skip slow git gc
./disk-cleanup.sh -y --skip-git-gc

# Emit a machine-readable JSON summary alongside the log
./disk-cleanup.sh --dry-run --json

# Show help
./disk-cleanup.sh --help
```

#### Features:

- **Dry run mode** - Preview cleanup without making changes
- **Interactive confirmations** - Review each cleanup operation before proceeding
- **Non-interactive mode** - Automated cleanup for scripts/cron jobs
- **Accurate space tracking** - Precise byte-level calculation of freed space
- **Complete logging** - All operations logged under `./logs/`
- **JSON summary (optional)** - `--json` writes `./logs/disk_cleanup_summary_YYYYMMDD_HHMMSS.json`
- **Safe error handling** - Continues cleanup even if individual operations fail
- **Progress tracking** - Shows current/total for multi-repository operations
- **Live disk gauge** - Optional real-time header with disk usage, freed space, elapsed time
- **Desktop notifications** - macOS/Linux notifications at completion
- **Color-coded output** - Easy-to-read status indicators
- **Timeout protection** - 30-minute timeout for git gc operations
- **Cross-platform** - Works on macOS and Linux

#### Command Line Options:

| Option | Description |
|--------|-------------|
| `-d, --dry-run` | Preview cleanup without making changes |
| `-y, --yes` | Skip confirmation prompts (non-interactive) |
| `-v, --verbose` | Show detailed output |
| `--skip-git-gc` | Skip git garbage collection (faster) |
| `--smart-gc` | Enable smart git gc (default) |
| `--full-gc` | Force git gc on all repositories |
| `--gc-threshold <GB>` | Smart GC: minimum pack size to run (default: 1) |
| `--gauge` / `--no-gauge` | Enable/disable live disk gauge |
| `--no-fun` | Disable fun facts between sections |
| `--docker-wait <SECS>` | Wait up to SECS for Docker to start (default: 60) |
| `--skip-docker` | Skip Docker cleanup entirely |
| `--scan-venvs` | Scan and report Python virtualenv sizes/ages |
| `--clean-venvs` | Remove stale virtualenvs (size/age thresholds) |
| `--venv-roots <PATHS>` | Colon-separated roots to scan (e.g., `$HOME/repos:$HOME/projects`) |
| `--venv-age <DAYS>` | Minimum age in days to consider stale (default: 30) |
| `--venv-min-gb <GB>` | Minimum venv size in GB to consider (default: 0.5) |
| `-h, --help` | Show help message |

#### Expected Results:

Typical cleanup frees 5-10GB depending on your system usage. Dry run mode shows exact amounts before proceeding.

---

### 2. `rclone-sync.sh`

Intelligent backup script that syncs your repositories to Google Drive while excluding dependencies and generated files.

#### What it syncs:

✅ **Included:**
- Source code files (`.js`, `.ts`, `.py`, `.go`, etc.)
- Configuration files (`package.json`, `requirements.txt`, etc.)
- Documentation (`.md`, `.txt`, etc.)
- Assets (images, fonts, etc.)
- Build and CI/CD configurations

❌ **Excluded:**
- `.git/**` - Git history (clone from remote instead)
- `node_modules/**` - Node.js dependencies (reinstall with `npm install`)
- `**/.venv/**`, `**/venv/**` - Python virtual environments
- `**/*.pyc`, `__pycache__/**` - Python compiled files
- `.cache/**` - Cache directories
- `.DS_Store` - macOS metadata
- `*.tmp` - Temporary files

#### Usage:

```bash
# Start sync (runs in background)
./rclone-sync.sh --start
# or simply
./rclone-sync.sh

# Check status with CPU/memory usage
./rclone-sync.sh --status

# Stop sync (graceful shutdown)
./rclone-sync.sh --stop

# Preview what will be synced (dry run)
./rclone-sync.sh --dry-run

# View logs
./rclone-sync.sh --logs      # Last 50 lines
./rclone-sync.sh --logs 100  # Last 100 lines

# Manage exclude file
./rclone-sync.sh --create-exclude  # Create default exclude file
./rclone-sync.sh --edit-exclude    # Edit exclusions

# Show help
./rclone-sync.sh --help
```

#### Features:

- **Background execution** - Runs independently of terminal with proper daemonization
- **Progress logging** - All output saved to `~/rclone-sync.log` with automatic rotation
- **Log rotation** - Automatically archives logs over 50MB
- **PID tracking** - Prevents multiple instances with atomic PID file operations
- **Dry run mode** - Preview changes before syncing
- **Smart filtering** - Customizable exclusions via external file
- **Memory efficient** - Stats updated every 5 minutes
- **Configurable transfers** - Adjustable parallel transfer count (default: 8)
- **Bandwidth limiting** - Optional upload speed limits
- **Environment variables** - Configure without editing script
- **Trap handlers** - Proper cleanup on script interruption (Ctrl+C)
- **Status monitoring** - Shows runtime, CPU, memory usage
- **Orphan detection** - Finds and reports stray rclone processes
- **Graceful shutdown** - Waits up to 10 seconds before force kill
- **Startup verification** - Confirms process started successfully

#### Configuration via Environment Variables:

Set these before running the script to customize behavior without editing:

```bash
# Sync a different directory
SOURCE_DIR=~/projects ./rclone-sync.sh

# Use different remote
REMOTE_NAME=my_gdrive ./rclone-sync.sh

# Limit bandwidth to 5MB/s
BANDWIDTH_LIMIT=5M ./rclone-sync.sh

# Use only 4 parallel transfers
TRANSFERS=4 ./rclone-sync.sh

# Combine multiple settings
SOURCE_DIR=~/code TRANSFERS=4 BANDWIDTH_LIMIT=10M ./rclone-sync.sh
```

#### Exclude File:

The script uses `~/.rclone-exclude` for customizable exclusions:

```bash
# Create default exclude file
./rclone-sync.sh --create-exclude

# Edit exclusions (uses $EDITOR or nano)
./rclone-sync.sh --edit-exclude
```

Default exclusions include:
- Version control (`.git/`, `.svn/`, `.hg/`)
- Dependencies (`node_modules/`, `venv/`, `vendor/`)
- Build outputs (`dist/`, `build/`, `.next/`)
- IDE files (`.vscode/`, `.idea/`)
- OS files (`.DS_Store`, `Thumbs.db`)
- Python files (`*.pyc`, `__pycache__/`)
- Caches (`.cache/`, `.npm/`, `.pnpm-store/`)

---

### 3. `nmap-scan.sh`

Network discovery and change tracking tool that identifies active hosts on your LAN(s) and monitors changes over time.

#### What it does:

- **CIDR Auto-detection** - Automatically detects your primary network subnet
- **Fast Scan Mode** - Quick ping sweep + TCP SYN to ports 22, 80, 443 (default)
- **Full Scan Mode** - Comprehensive scan of top 1000 TCP ports
- **Delta Tracking** - Compares current scan with previous to show new/removed hosts
- **JSON Output** - Structured data for automation and analysis
- **Table Output** - Human-readable tabular format
- **Host Exclusions** - Filter out specific IPs or MAC addresses
- **Rate Limiting** - Prevents network flooding (default: 100 pps)

#### Usage:

```bash
# Fast scan on auto-detected subnet
./nmap-scan.sh

# Scan specific CIDR(s)
./nmap-scan.sh --cidr "192.168.1.0/24"

# Multi-subnet full scan
./nmap-scan.sh --cidr "192.168.1.0/24,10.0.0.0/24" --full

# Exclude specific hosts and limit rate
./nmap-scan.sh --exclude "192.168.1.10,AA:BB:CC:*" --rate 50

# JSON output only, no delta comparison
./nmap-scan.sh --output json --no-delta

# Preview scan configuration
./nmap-scan.sh --cidr "192.168.1.0/24" --dry-run

# Show help
./nmap-scan.sh --help
```

#### Command Line Options:

| Option | Description |
|--------|-------------|
| `--cidr CIDR` | Comma-separated CIDRs (auto-detects if not specified) |
| `--fast` | Fast scan: ping + TCP 22,80,443 (default) |
| `--full` | Full scan: top 1000 TCP ports (slower) |
| `--output MODE` | Output mode: json, table, or both (default: both) |
| `--no-delta` | Skip delta comparison with previous scan |
| `--exclude LIST` | Comma-separated IPs or MAC patterns to exclude |
| `--rate NUM` | Max packets per second (default: 100) |
| `--dry-run` | Show configuration without executing scan |
| `--help` | Show help message |

#### Features:

- **Non-intrusive defaults** - Ping sweep + 3 common ports only
- **Auto CIDR detection** - Uses primary interface if not specified
- **Delta tracking** - Shows new/removed hosts since last scan
- **JSON storage** - All scans saved to `./logs/nmap/` with timestamps
- **Secure logs** - Log directory permissions: 700, files: 600
- **Rate limiting** - Prevents network flooding and DoS
- **Host exclusions** - Filter noisy or sensitive hosts
- **Dual output** - Both JSON (automation) and table (human-readable)
- **Safe exit** - Graceful handling if nmap is not installed
- **Cross-platform** - Works on macOS and Linux

#### Output Example:

```
━━━ Scan Results ━━━

IP Address       MAC Address        Vendor                         Open Ports
──────────────────────────────────────────────────────────────────────────────
192.168.1.1      AA:BB:CC:DD:EE:FF  NETGEAR                        22,80,443
192.168.1.10     11:22:33:44:55:66  Apple, Inc.                    22
192.168.1.50     99:88:77:66:55:44  Raspberry Pi Foundation        22,80

━━━ Delta Analysis ━━━

✓ New hosts detected:
  + 192.168.1.50
```

#### Security & Ethics:

- **Non-intrusive by default** - Only ping + 3 common ports
- **Rate limiting** - Prevents network flooding
- **Explicit full scan** - Must use `--full` flag for deeper scans
- **Local use only** - Designed for your own network discovery
- **No stealth mode** - Scans are intentionally detectable
- **Secure storage** - All logs protected with umask 077

---

### 4. `cert-renewal-check.sh`

SSL certificate expiry monitoring and renewal tool. Checks domain certificates via HTTPS or inspects local certificate files.

#### What it checks:

- **Domain certificates** - Connects via HTTPS and inspects certificate expiry
- **Local certificate files** - Reads and validates certificate files
- **Expiry warnings** - Configurable threshold (default: 30 days)
- **Auto-renewal** - Optional certbot integration for automatic renewal

#### Usage:

```bash
# Check domains from file
./cert-renewal-check.sh --domains examples/domains.txt

# Check specific certificate file
./cert-renewal-check.sh --cert /etc/ssl/certs/homelab.pem

# Custom warning threshold (14 days)
./cert-renewal-check.sh --domains domains.txt --warn-days 14

# JSON output for monitoring integration
./cert-renewal-check.sh --domains domains.txt --json

# Auto-renew with certbot if expiring
./cert-renewal-check.sh --domains domains.txt --auto-renew

# Dry run (preview without checking)
./cert-renewal-check.sh --domains domains.txt --dry-run

# Show help
./cert-renewal-check.sh --help
```

#### Features:

- **Multiple check types** - Domain HTTPS or local certificate files
- **Table and JSON output** - Human-readable or machine-parseable
- **Configurable warnings** - Set expiry threshold in days (1-365)
- **Optional auto-renewal** - Integrates with certbot for Let's Encrypt
- **Color-coded status** - OK (green), WARNING (yellow), EXPIRED/ERROR (red)
- **Secure logging** - All logs protected in `./logs/cert/` (mode 700)
- **Dry run mode** - Preview checks without executing
- **Cross-platform** - Works on macOS and Linux

#### Command Line Options:

| Option | Description |
|--------|-------------|
| `--domains <file>` | File with domains to check (one per line) |
| `--cert <file>` | Check specific certificate file (repeatable) |
| `--warn-days <n>` | Warn if expires within N days (default: 30, range: 1-365) |
| `--auto-renew` | Attempt certbot renewal if expiring (requires sudo) |
| `--json` | JSON output format |
| `--dry-run` | Preview without executing checks |
| `--help` | Show help message |

#### Domains File Format:

```text
# One domain per line
# Lines starting with # are comments

github.com
google.com
homelab.local
192.168.1.100
```

See `examples/domains.txt` for a complete example.

#### Expected Results:

**Table Output (default):**
```
Type       Name                      Status     Days Remaining  Details
──────────────────────────────────────────────────────────────────────
domain     github.com                OK         89              Expires: Mar 15 12:00:00 2026 GMT
domain     homelab.local             WARNING    25              Expires: Dec 7 15:30:00 2025 GMT
file       /etc/ssl/cert.pem         EXPIRED    -5              Expires: Nov 7 10:00:00 2025 GMT
```

**JSON Output (--json):**
```json
{
  "timestamp": "2025-11-12T13:45:00+11:00",
  "warn_days": 30,
  "certificates": [
    {
      "type": "domain",
      "name": "github.com",
      "status": "OK",
      "days_remaining": 89,
      "message": "Expires: Mar 15 12:00:00 2026 GMT"
    }
  ]
}
```

#### Dependencies:

- **openssl** (required) - Certificate inspection
- **certbot** (optional) - For `--auto-renew` functionality

---

### 5. `db-backup.sh`

Automated database backup tool with retention policies and optional cloud sync. Supports PostgreSQL and MySQL.

#### What it does:

- **PostgreSQL backups** - Uses `pg_dump` with compression
- **MySQL backups** - Uses `mysqldump` with compression
- **Retention policies** - Configurable daily:weekly:monthly retention
- **Cloud sync** - Optional rclone upload after backup
- **Test restore** - Validates backups by restoring to temp database (PostgreSQL only)

#### Usage:

```bash
# PostgreSQL backup (DSN from environment)
export DB_DSN="postgres://user:pass@localhost:5432/mydb"
./db-backup.sh --db pg --out ./backups

# MySQL backup with custom retention
export DB_DSN="mysql://root:pass@localhost:3306/appdb"
./db-backup.sh --db mysql --retention 14:8:24

# Backup with cloud sync
./db-backup.sh --db pg --rclone gdrive:backups

# Backup with test restore
./db-backup.sh --db pg --test-restore

# JSON output for monitoring
./db-backup.sh --db pg --json

# Dry run preview
./db-backup.sh --db pg --dry-run

# Show help
./db-backup.sh --help
```

#### Features:

- **Multi-database support** - PostgreSQL and MySQL
- **Intelligent retention** - Keep daily, weekly, and monthly backups
- **Compression** - Automatic gzip compression
- **Cloud backup** - Optional rclone integration
- **Test restore** - Validates backup integrity (PostgreSQL)
- **Secure storage** - Backup files chmod 600, logs chmod 700
- **Password masking** - DSN passwords never appear in logs
- **JSON output** - Machine-readable backup metadata
- **Dry-run mode** - Preview without executing
- **Output path policy** - Output directory must be under `$HOME` (system dirs blocked)

#### Command Line Options:

| Option | Description |
|--------|-------------|
| `--db <type>` | Database type: `pg` (PostgreSQL) or `mysql` (MySQL) |
| `--dsn <url>` | Database DSN (or use `DB_DSN` environment variable) |
| `--out <dir>` | Output directory (default: `./backups`) |
| `--retention <d:w:m>` | Retention policy (default: `7:4:12`) |
| `--rclone <remote>` | Upload to rclone remote (e.g., `gdrive:backups`) |
| `--test-restore` | Verify backup by test restore (PostgreSQL only) |
| `--json` | JSON summary output |
| `--dry-run` | Preview without executing |
| `--help` | Show help message |

#### Retention Policy Format:

`daily:weekly:monthly` - Number of backups to keep in each category

- **daily**: Keep last N daily backups
- **weekly**: Keep last N weekly backups (oldest of each week)
- **monthly**: Keep last N monthly backups (oldest of each month)

Example: `7:4:12` = 7 daily, 4 weekly, 12 monthly

#### DSN Formats:

```
PostgreSQL:  postgres://username:password@host:port/database
MySQL:       mysql://username:password@host:port/database
```

**Security Note**: Use `DB_DSN` environment variable to avoid password exposure in process list.

#### Dependencies:

- **pg_dump** (PostgreSQL backups) - `brew install postgresql` or `apt install postgresql-client`
- **mysqldump** (MySQL backups) - `brew install mysql-client` or `apt install mysql-client`
- **gzip** (compression) - Usually pre-installed
- **rclone** (optional, cloud sync) - `brew install rclone` or `apt install rclone`

---

### 6. `service-health-check.sh`

Config-driven service uptime monitoring with support for HTTP, TCP, process, and container checks.

#### What it monitors:

- **HTTP endpoints** - Status code and optional body content validation
- **TCP ports** - Connection checks for network services
- **Processes** - Check if system processes are running
- **Docker containers** - Verify container status

#### Usage:

```bash
# Run once with JSON output
./service-health-check.sh --config services.conf --once --json

# Watch mode with continuous monitoring
./service-health-check.sh --config services.conf --watch --interval 60

# Watch mode with webhook notifications
./service-health-check.sh --config services.conf --watch \
    --notify webhook:http://alerts.local/webhook

# Dry run to validate config
./service-health-check.sh --config services.conf --dry-run

# Show help
./service-health-check.sh --help
```

#### Configuration Format:

INI-style configuration file with service definitions:

```ini
# HTTP health check
[api-server]
type=http
url=https://api.example.com/health
expect_status=200
expect_body=OK
timeout=5

# TCP port check
[database]
type=tcp
host=db.local
port=5432
timeout=3

# Process check
[nginx]
type=process
name=nginx

# Docker container check
[redis]
type=container
name=redis
```

#### Command Line Options:

| Option | Description |
|--------|-------------|
| `--config <file>` | Config file with service definitions (required) |
| `--once` | Run checks once and exit (default) |
| `--watch` | Continuous monitoring mode |
| `--interval <secs>` | Check interval in watch mode (default: 60) |
| `--notify <method>` | Notification method: `webhook:URL` |
| `--json` | JSON output format |
| `--dry-run` | Show what would be checked without running |
| `--help` | Show help message |

#### Check Types:

| Type | Parameters | Description |
|------|------------|-------------|
| `http` | `url`, `expect_status`, `expect_body`, `timeout` | HTTP/HTTPS endpoint checks |
| `tcp` | `host`, `port`, `timeout` | TCP port connectivity checks |
| `process` | `name` | Process running status via `pgrep` |
| `container` | `name` | Docker container status |

#### Features:

- **Multiple check types** - HTTP, TCP, process, and container monitoring
- **Watch mode** - Continuous monitoring with configurable intervals
- **State tracking** - Detect and notify only on state changes
- **Webhook notifications** - Send JSON alerts on status changes
- **JSON output** - Machine-readable format for integration
- **Dry run mode** - Validate configuration without running checks
- **Graceful degradation** - Skip unavailable check types (e.g., Docker)
- **Secure logging** - All logs under `./logs/` with permissions 700

#### Example Output:

```bash
$ ./service-health-check.sh --config examples/services.conf --once

=== Service Health Check ===

✓ google (http): HTTP 200
✓ github (http): HTTP 200
✓ ssh-local (tcp): TCP port 22 open
✓ sshd-process (process): Process running (1 instances)
⊘ nginx-container (container): Docker not installed
```

#### JSON Output Format:

```json
{
  "version": "1.0",
  "timestamp": "2025-11-13T10:30:00Z",
  "checks": [
    {"name": "api-server", "type": "http", "status": "pass", "message": "HTTP 200"},
    {"name": "database", "type": "tcp", "status": "pass", "message": "TCP port 5432 open"},
    {"name": "nginx", "type": "process", "status": "fail", "message": "Process not found"}
  ]
}
```

#### Notification Format:

Webhook notifications send JSON payloads on state changes:

```json
{
  "service": "api-server",
  "type": "http",
  "status": "fail",
  "message": "HTTP status 500 (expected 200)",
  "timestamp": "2025-11-13T10:30:15Z"
}
```

#### Dependencies:

- **curl** (HTTP checks) - Usually pre-installed
- **timeout** command (TCP checks) - Usually pre-installed
- **pgrep** (process checks) - Usually pre-installed
- **docker** (container checks, optional) - `brew install docker` or `apt install docker.io`

---

### 7. `compose-redeploy.sh`

Safe Docker Compose updates with volume backup and automatic rollback.

#### What it does:

- **Pre-flight validation** - Validates compose file syntax
- **Volume backup** - Optional backup before deployment
- **Image updates** - Pulls latest images
- **Health checks** - Validates service health after deployment
- **Automatic rollback** - Rolls back on failure

#### Usage:

```bash
# Basic redeploy
./compose-redeploy.sh

# Redeploy with volume backup
./compose-redeploy.sh --backup-volumes

# Custom compose file with extended health timeout
./compose-redeploy.sh --file production.yml --health-timeout 120

# Dry run to preview
./compose-redeploy.sh --dry-run

# Show help
./compose-redeploy.sh --help
```

#### Command Line Options:

| Option | Description |
|--------|-------------|
| `--file <yaml>` | Docker Compose file (default: docker-compose.yml) |
| `--backup-volumes` | Backup volumes before update |
| `--health-timeout <s>` | Health check timeout in seconds (default: 60, range: 1-3600) |
| `--no-pull` | Skip image pull (use existing images) |
| `--dry-run` | Show deployment plan without executing |
| `--json` | JSON summary output |
| `--help` | Show help message |

#### Features:

- **Safe updates** - Pre-flight validation prevents invalid deployments
- **Volume protection** - Optional backup before changes
- **Health validation** - Waits for services to become healthy
- **Rollback capability** - Automatic rollback on failure
- **Progress tracking** - Real-time status updates
- **Secure logging** - All logs under `./logs/` with permissions 700
- **Compose v1 & v2 support** - Works with both `docker-compose` and `docker compose`

#### Dependencies:

- **docker** - Docker Engine (`docker --version`)
- **docker-compose** or **docker compose** - Compose v1 or v2

#### Example Output:

```bash
$ ./compose-redeploy.sh --backup-volumes

━━━ Docker Compose Redeploy ━━━

ℹ Compose file: docker-compose.yml
ℹ Health timeout: 60s
ℹ Volume backup: enabled
ℹ Log file: ./logs/compose-redeploy/redeploy_20251113_120000.log

━━━ Pre-flight Checks ━━━

✓ Docker installed
✓ Docker Compose found (v2)
✓ Compose file valid
ℹ Project name: myapp
ℹ Services: 2 (web, api)
✓ Pre-flight checks passed

━━━ Backing Up Volumes ━━━

ℹ Backing up volume: web_data
✓ Volume backed up: ./backups/compose-volumes/myapp_web_data_20251113_120000.tar.gz

━━━ Pulling Images ━━━

✓ Images pulled successfully

━━━ Deploying Services ━━━

✓ Services deployed

━━━ Health Check Validation ━━━

ℹ Waiting up to 60s for services to become healthy...
✓ All services healthy

━━━ Deployment Complete ━━━

✓ All services deployed and healthy
```

---

### 8. `docker-volume-backup.sh`

Consistent Docker volume snapshots with compression and optional container management.

#### What it does:

- **Volume backup** - Backup individual or all Docker volumes
- **Container management** - Optional stop/restart for consistency
- **Compression** - Automatic tar.gz compression
- **Helper container approach** - No local volume mount required
- **JSON output** - Machine-readable backup metadata

#### Usage:

```bash
# Backup single volume
./docker-volume-backup.sh --volume postgres_data

# Backup all volumes
./docker-volume-backup.sh --all

# Backup with container stop for consistency
./docker-volume-backup.sh --all --stop

# Custom output directory
./docker-volume-backup.sh --volume app_data --out ~/backups

# Dry run to preview
./docker-volume-backup.sh --all --dry-run

# Show help
./docker-volume-backup.sh --help
```

#### Command Line Options:

| Option | Description |
|--------|-------------|
| `--volume <name>` | Backup specific volume |
| `--all` | Backup all Docker volumes |
| `--out <dir>` | Output directory (default: ./backups/volumes) |
| `--stop` | Stop dependent containers during backup |
| `--no-stop` | Backup while containers running (default) |
| `--dry-run` | Show backup plan without executing |
| `--json` | JSON summary output |
| `--help` | Show help message |

#### Features:

- **Flexible backup** - Single volume or all volumes
- **Consistency options** - Stop containers for consistent backups
- **Compression** - Automatic gzip compression
- **Helper container** - Uses Alpine container to avoid local mounts
- **Auto-restart** - Restarts stopped containers after backup
- **Progress tracking** - Real-time status updates
- **Secure storage** - Backups chmod 600, logs chmod 700

#### Dependencies:

- **docker** - Docker Engine (`docker --version`)

#### Example Output:

```bash
$ ./docker-volume-backup.sh --volume postgres_data --stop

━━━ Docker Volume Backup ━━━

ℹ Mode: Backup single volume: postgres_data
ℹ Output directory: ./backups/volumes
ℹ Container stop: enabled
ℹ Log file: ./logs/volume-backup/volume_backup_20251113_120000.log

━━━ Pre-flight Checks ━━━

✓ Docker installed
✓ Docker daemon running
✓ Volume exists: postgres_data
✓ Pre-flight checks passed

━━━ Backing Up: postgres_data ━━━

ℹ Volume used by containers: app_db
ℹ Stopping containers for consistency...
✓ Stopped: app_db
ℹ Creating backup: ./backups/volumes/postgres_data_20251113_120000.tar.gz
✓ Backup created: ./backups/volumes/postgres_data_20251113_120000.tar.gz (245MB)
ℹ Restarting containers...
✓ Restarted: app_db

━━━ Backup Summary ━━━

✓ Backed up 1 volume(s)
ℹ Total backup size: 245MB
```

---

### 9. `dyndns-update.sh`

Dynamic DNS updates for homelabs with changing public IPs. Keeps your DNS records synchronized with your current IP address.

#### What it does:

- **Public IP detection** - Detects current public IP from multiple sources
- **DNS updates** - Updates DNS records via Cloudflare API
- **IP caching** - Avoids unnecessary updates when IP unchanged
- **Rate limiting** - Prevents excessive API calls (max 1 per 5 minutes)
- **JSON output** - Machine-readable update status

#### Usage:

```bash
# Basic Cloudflare update
export CF_TOKEN="your-cloudflare-api-token"
./dyndns-update.sh --provider cloudflare --zone example.com \
    --record home --token env:CF_TOKEN

# Update with custom TTL
./dyndns-update.sh --provider cloudflare --zone example.com \
    --record home --token env:CF_TOKEN --ttl 600

# Force update (bypass cache/rate limit)
./dyndns-update.sh --provider cloudflare --zone example.com \
    --record home --token env:CF_TOKEN --force

# Dry run to preview
./dyndns-update.sh --provider cloudflare --zone example.com \
    --record home --token env:CF_TOKEN --dry-run

# Show help
./dyndns-update.sh --help
```

#### Command Line Options:

| Option | Description |
|--------|-------------|
| `--provider <name>` | DNS provider (currently: cloudflare) |
| `--zone <domain>` | DNS zone (e.g., example.com) |
| `--record <name>` | Record name (e.g., home or @) |
| `--ttl <seconds>` | DNS TTL (default: 300, range: 60-86400) |
| `--token <val>` | API token or env:VAR_NAME |
| `--force` | Force update even if IP unchanged |
| `--dry-run` | Show update plan without executing |
| `--json` | JSON summary output |
| `--help` | Show help message |

#### Features:

- **Multi-source IP detection** - Tries multiple services (ifconfig.me, icanhazip.com, etc.)
- **Smart caching** - Only updates when IP actually changes
- **Rate limiting** - Prevents API abuse (5-minute minimum between updates)
- **Secure token handling** - Supports environment variables, never logged
- **TTL configuration** - Customizable DNS TTL (60s - 24h)
- **Detailed logging** - All operations logged with timestamps
- **JSON output** - Integration-friendly output format

#### Dependencies:

- **curl** - HTTP client (usually pre-installed)
- **jq** - JSON processor (`brew install jq` / `apt install jq`)

#### Example Output:

```bash
$ export CF_TOKEN="your-token"
$ ./dyndns-update.sh --provider cloudflare --zone example.com --record home --token env:CF_TOKEN

━━━ Dynamic DNS Update ━━━

ℹ Provider: cloudflare
ℹ Zone: example.com
ℹ Record: home
ℹ TTL: 300s
ℹ Log file: ./logs/dyndns/dyndns_20251113_120000.log
ℹ Token loaded from environment variable

━━━ Pre-flight Checks ━━━

✓ curl installed
✓ jq installed
✓ Pre-flight checks passed

━━━ Detecting Public IP ━━━

ℹ Trying: https://ifconfig.me/ip
✓ Detected IP: 203.45.67.89

━━━ Updating DNS Record ━━━

ℹ Looking up zone ID for: example.com
✓ Zone ID: abc123def456
ℹ Looking up DNS record: home.example.com
ℹ Updating existing record: xyz789abc123
✓ DNS record updated: home.example.com -> 203.45.67.89

━━━ Update Complete ━━━

✓ DNS record updated successfully
ℹ Record: home.example.com
ℹ IP: 203.45.67.89
ℹ TTL: 300s
```

#### Cron Setup:

For automatic updates every 15 minutes:

```bash
# Add to crontab (crontab -e)
*/15 * * * * export CF_TOKEN="your-token" && /path/to/dyndns-update.sh --provider cloudflare --zone example.com --record home --token env:CF_TOKEN >> /var/log/dyndns.log 2>&1
```

---

## Setup Instructions

### Prerequisites

#### For `disk-cleanup.sh`:

**Bash Version:**
- Bash 3.2+ for basic cleanup (VS Code, Docker, Git, Homebrew, NPM, pip, etc.)
- **Bash 4.0+ required** for virtualenv management (`--scan-venvs`, `--clean-venvs`)
  - macOS: `brew install bash` (default is Bash 3.2)
  - Linux: Usually 4.0+ by default

No other special setup required. The script will skip any tools that aren't installed.

#### For `nmap-scan.sh`:

1. **Install nmap:**
   ```bash
   # macOS
   brew install nmap

   # Linux
   sudo apt install nmap
   ```

2. **Verify installation:**
   ```bash
   nmap --version
   ```

#### For `rclone-sync.sh`:

1. **Install rclone:**
   ```bash
   brew install rclone
   ```

2. **Configure Google Drive remote:**
   ```bash
   rclone config
   ```

   Follow the prompts to:
   - Choose "New remote"
   - Name it `gdrive_new` (or edit the script to match your name)
   - Select "Google Drive"
   - Complete the OAuth authentication

3. **Verify setup:**
   ```bash
   rclone listremotes
   # Should show: gdrive_new:
   ```

---

## Recommended Usage

### Weekly Maintenance

```bash
# Clean up system once a week
./disk-cleanup.sh

# Scan venvs and review candidates (no changes)
./disk-cleanup.sh --scan-venvs

# Clean venvs older than 60 days and larger than 1GB
./disk-cleanup.sh --clean-venvs --venv-age 60 --venv-min-gb 1

# Start weekly backup
./rclone-sync.sh --start
```

### Monthly Deep Clean

```bash
# Run cleanup script
./disk-cleanup.sh

# Check what will be synced
./rclone-sync.sh --dry-run

# Sync if everything looks good
./rclone-sync.sh --start
```

### Monitoring Ongoing Sync

```bash
# Check if sync is running
./rclone-sync.sh --status

# Watch logs in real-time
tail -f ~/rclone-sync.log

# Check last 100 lines
./rclone-sync.sh --logs 100
```

---

## Recovery Instructions

If you need to restore your repositories on a new machine:

### 1. Install rclone and configure remote

```bash
brew install rclone
rclone config
```

### 2. Download repositories

```bash
rclone sync gdrive_new:repos/ ~/repos/
```

### 3. Reinstall dependencies

#### Node.js projects:
```bash
cd project-directory
npm install      # or: pnpm install, yarn install
```

#### Python projects:
```bash
cd project-directory
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

#### Go projects:
```bash
cd project-directory
go mod download
```

### 4. Reinitialize git repositories

```bash
cd project-directory
git clone <your-remote-url> .
```

---

## Troubleshooting

### disk-cleanup.sh

**Issue:** Script fails on Docker cleanup
```bash
# Solution: Make sure Docker Desktop is running
open -a Docker
```

**Issue:** Git gc takes too long
```bash
# Solution: The script will process all repos. For large repos,
# this is expected and may take hours. Let it complete.
```

### rclone-sync.sh

**Issue:** "Remote not configured" error
```bash
# Solution: Run rclone config and set up Google Drive
rclone config
```

**Issue:** Sync seems stuck
```bash
# Check if it's actually running
./rclone-sync.sh --status

# View what it's doing
tail -f ~/rclone-sync.log
```

**Issue:** Want to change what gets excluded
```bash
# Edit the script and modify the --exclude lines
nano rclone-sync.sh
```

**Issue:** Out of memory
```bash
# The script already uses memory-efficient settings:
# - Stats updated every 5 minutes
# - Logging to file
# - Running in background
#
# If still having issues, reduce parallel transfers from 8 to 4
```

---

## Safety Notes

### disk-cleanup.sh
- ✅ Safe to run multiple times
- ✅ Only removes caches and generated files
- ✅ Does not delete source code or configurations
- ⚠️  Git gc is aggressive but safe (doesn't delete committed work)
- ⚠️  Playwright browsers will need to be reinstalled if you use Playwright

### rclone-sync.sh
- ✅ Sync operation is safer than copy (doesn't duplicate)
- ✅ Dry run mode available to preview changes
- ⚠️  Sync will delete files on remote that don't exist locally
- ⚠️  Make sure SOURCE_DIR is correct before running
- 💡 Tip: Always run `--dry-run` first when testing changes

---

## Dependencies

### Required Dependencies

All scripts require standard POSIX utilities (available by default on macOS and Linux):
- `awk` - Used for arithmetic and text processing (replaces bc for calculations)
- `sed` - Stream editing for text transformations
- `grep` - Text searching and pattern matching
- `date` - Date and time formatting
- `du` - Disk usage calculations
- `df` - Filesystem statistics

### Optional Dependencies

**For macOS users:**
- `coreutils` - Provides `gtimeout` for git gc timeout protection
  ```bash
  brew install coreutils
  ```
  Without this, git gc operations will run without timeout protection (with warning message).

**For script-specific features:**
- `docker` - Required only if cleaning Docker artifacts (disk-cleanup.sh)
- `rclone` - Required for backup sync functionality (rclone-sync.sh)
- `git` - Required for git gc operations (disk-cleanup.sh)

### Notes

- **No bc dependency:** All arithmetic operations use awk for maximum portability
- **Cross-platform:** Scripts detect platform (macOS vs Linux) and adapt automatically
- **Graceful degradation:** Scripts warn but continue if optional dependencies are missing

---

## Scheduling Automation

### Using cron (macOS/Linux)

```bash
# Edit crontab
crontab -e

# Add these lines:

# Run cleanup every Sunday at 2 AM
0 2 * * 0 /Users/adrian/repos/scripts/disk-cleanup.sh >> /Users/adrian/repos/scripts/logs/cron-disk-cleanup.log 2>&1

# Run backup every day at 3 AM
0 3 * * * /Users/adrian/repos/scripts/rclone-sync.sh --start >> /Users/adrian/repos/scripts/logs/cron-rclone-sync.log 2>&1
```

### Using launchd (macOS recommended)

Create a plist file for more reliable scheduling on macOS. See Apple's documentation on launchd.

---

## Support

For issues or improvements:
- Review logs in `~/rclone-sync.log` or `logs/disk_cleanup_*.log` and JSON summaries in `logs/disk_cleanup_summary_*.json`
- Ensure all prerequisites are installed
- Check the implementation documentation in the repo

---

**Generated by:** Claude Code
**Last Updated:** November 9, 2025
