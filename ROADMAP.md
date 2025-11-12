# Homelab Scripts Roadmap

This document outlines planned additions to the homelab-scripts repository, organized by priority and implementation phases.

## Design Principles

All new scripts follow these established patterns:

- **Security**: Secure logs (`umask 077`, `chmod 600`), path validation, bounds checking, no secrets in CLI args
- **Usability**: `--help`, `--dry-run`, `--json` output, clear error messages, interactive confirmations
- **Portability**: Cross-platform (macOS + Linux) where reasonable, graceful feature degradation
- **Quality**: ShellCheck clean, `shfmt` formatted, smoke-tested in CI
- **Consistency**: 4-space indentation, kebab-case files, snake_case functions, UPPER_SNAKE constants

## Phase 1: Foundation (Weeks 1-2)

High-impact, low-complexity scripts that establish core monitoring and backup capabilities.

### 1.1 service-health-check.sh ⭐ PRIORITY
**Purpose**: Config-driven uptime monitoring for HTTP/TCP/processes/containers
**Effort**: 1-2 days
**Dependencies**: `curl`, `jq` (optional), `docker` (optional)

**Features**:
- Multiple check types: HTTP (status + body substring), TCP port, process name, container status
- Config file support (INI or JSON format)
- Watch mode with configurable intervals
- Optional webhook/email notifications
- JSON output for integration with dashboards

**Flags**:
```bash
--config <file>       Config file with service definitions
--once                Run checks once and exit (default)
--watch               Continuous monitoring mode
--interval <secs>     Check interval in watch mode (default: 60)
--notify <method>     Notification method: webhook:URL or email:addr
--json                JSON output
--dry-run             Show what would be checked without running
```

**Example**:
```bash
./service-health-check.sh --config services.conf --watch --interval 60 --json
./service-health-check.sh --config services.conf --once --notify webhook:http://alerts.local
```

**Config format**:
```ini
[web]
type=http
url=https://homelab.local
expect_status=200
expect_body=
interval=60

[docker-nginx]
type=container
name=nginx
expect_running=true

[sshd]
type=process
name=sshd
expect_running=true
```

**Cross-platform notes**:
- `curl` for HTTP checks (universal)
- `pgrep` for process checks (macOS + Linux)
- `docker ps` for container checks (universal)
- `systemctl` only on Linux (graceful skip on macOS)

---

### 1.2 cert-renewal-check.sh
**Purpose**: SSL certificate expiry monitoring and renewal
**Effort**: 1 day
**Dependencies**: `openssl`, `certbot` (optional)

**Features**:
- Check domain certificates (via HTTPS connection)
- Check local certificate files
- Configurable warning threshold (days until expiry)
- Optional automatic renewal via certbot
- Table and JSON output

**Flags**:
```bash
--domains <file>      File with domains to check (one per line)
--cert <file>         Check specific certificate file
--warn-days <n>       Warn if cert expires within N days (default: 30)
--auto-renew          Attempt certbot renewal if expiring
--json                JSON output
```

**Example**:
```bash
./cert-renewal-check.sh --domains domains.txt --warn-days 21 --json
./cert-renewal-check.sh --cert /etc/ssl/certs/homelab.pem --warn-days 30 --auto-renew
```

**Implementation notes**:
- Domain check: `openssl s_client -connect ${domain}:443 | openssl x509 -noout -dates`
- File check: `openssl x509 -in ${cert} -noout -dates`
- Date parsing: Convert to epoch, calculate days remaining
- Certbot integration: `certbot renew --dry-run` first, then actual renewal

---

### 1.3 db-backup.sh
**Purpose**: Automated PostgreSQL/MySQL backups with retention and cloud sync
**Effort**: 1-2 days
**Dependencies**: `pg_dump`, `mysqldump`, `rclone` (optional)

**Features**:
- Support PostgreSQL and MySQL
- Configurable retention (daily:weekly:monthly)
- Compression (gzip)
- Optional rclone upload to cloud storage
- DSN via environment variable (no CLI exposure)
- Optional test-restore validation

**Flags**:
```bash
--db <type>           Database type: pg or mysql
--dsn <url>           Database DSN (or env var: DB_DSN)
--out <dir>           Output directory (default: ./backups)
--retention <d:w:m>   Retention policy (default: 7:4:12)
--rclone <remote>     Upload to rclone remote (e.g., remote:bucket)
--test-restore        Verify backup by restoring to temp database
--json                JSON summary
--dry-run             Show backup plan without executing
```

**Example**:
```bash
export DB_DSN="postgres://user:pass@localhost/mydb"
./db-backup.sh --db pg --out ./backups --retention 7:4:12
./db-backup.sh --db mysql --dsn "mysql://root:pass@localhost/app" --rclone remote:backups
```

**Security notes**:
- DSN must be in environment variable (never CLI args)
- Backup files: `chmod 600` (owner read/write only)
- Logs: Sanitize DSN (mask password in output)
- Future: Optional GPG encryption for backups

**Retention logic**:
```
7 daily   = Keep last 7 days
4 weekly  = Keep last 4 weeks (1 per week)
12 monthly = Keep last 12 months (1 per month)
```

---

## Phase 2: Operations (Weeks 3-4)

Scripts that automate deployment and infrastructure management.

### 2.1 compose-redeploy.sh
**Purpose**: Safe Docker Compose updates with volume backup and rollback
**Effort**: 1 day
**Dependencies**: `docker`, `docker-compose` (or compose v2)

**Features**:
- Pull latest images
- Optional volume backup before update
- Health check verification after deployment
- Automatic rollback on failure
- Dry-run mode showing deployment plan

**Flags**:
```bash
--file <yaml>         Docker Compose file (default: docker-compose.yml)
--backup-volumes      Backup volumes before update
--health-timeout <s>  Wait N seconds for health checks (default: 60)
--no-pull             Skip image pull (use existing images)
--dry-run             Show deployment plan
--json                JSON summary
```

**Example**:
```bash
./compose-redeploy.sh --file docker-compose.yml --backup-volumes --health-timeout 60
./compose-redeploy.sh --file app.yml --dry-run
```

**Implementation phases**:
1. Pre-flight: `docker-compose config` validation
2. Backup: Pause containers, tar volumes, unpause
3. Deploy: Pull images, up with detach
4. Health: Poll `docker inspect` for health status
5. Rollback: Restore volumes + redeploy old images on failure

---

### 2.2 docker-volume-backup.sh
**Purpose**: Consistent Docker volume snapshots
**Effort**: 1 day
**Dependencies**: `docker`

**Features**:
- Backup individual volumes or all volumes
- Optional container stop/start for consistency
- Tar.gz compression
- Backup via helper container (no local mount required)

**Flags**:
```bash
--volume <name>       Backup specific volume
--all                 Backup all volumes
--out <dir>           Output directory (default: ./backups/volumes)
--stop                Stop dependent containers during backup
--no-stop             Backup while containers running (default)
--dry-run             Show backup plan
--json                JSON summary
```

**Example**:
```bash
./docker-volume-backup.sh --volume postgres_data --out ./backups/volumes
./docker-volume-backup.sh --all --stop --out ./backups
```

**Backup strategy**:
```bash
docker run --rm \
  -v ${volume_name}:/data:ro \
  -v $(pwd):/backup \
  alpine tar czf /backup/${volume_name}.tar.gz /data
```

---

### 2.3 dyndns-update.sh
**Purpose**: Dynamic DNS updates for homelabs with changing IPs
**Effort**: 1 day
**Dependencies**: `curl`, `jq`

**Features**:
- Multi-provider support (Cloudflare, Namecheap, etc.)
- Public IP detection with fallback sources
- IP caching (avoid unnecessary API calls)
- Rate limiting (max 1 update per 5 minutes)
- TTL configuration

**Flags**:
```bash
--provider <name>     DNS provider: cloudflare, namecheap
--zone <domain>       DNS zone (e.g., example.com)
--record <name>       Record name (e.g., home)
--ttl <seconds>       DNS TTL (default: 300)
--token <val>         API token (or env:VAR_NAME)
--json                JSON output
--dry-run             Show update plan
```

**Example**:
```bash
export CF_TOKEN="your-cloudflare-api-token"
./dyndns-update.sh --provider cloudflare --zone example.com --record home --token env:CF_TOKEN
./dyndns-update.sh --provider cloudflare --zone example.com --record home --ttl 600 --json
```

**IP detection strategy**:
```bash
# Try multiple sources, use first successful response
sources=(
  "https://ifconfig.me"
  "https://icanhazip.com"
  "https://ipinfo.io/ip"
)
```

---

## Phase 3: Specialized Tools (Future)

Lower priority scripts for specific use cases.

### 3.1 smart-disk-check.sh
**Purpose**: S.M.A.R.T. monitoring and disk health alerts
**Effort**: 2 days
**Dependencies**: `smartmontools`

**Features**: Scan all drives, warn on critical attributes, schedule tests, JSON output.

---

### 3.2 new-vm-setup.sh
**Purpose**: Bootstrap fresh VMs with standard config
**Effort**: 1-2 days
**Dependencies**: `apt`/`yum`, `ssh`

**Features**: Hostname, package install, user creation, SSH key setup, dotfiles clone.

---

### 3.3 zfs-snapshot-manager.sh
**Purpose**: Automated ZFS snapshots with retention
**Effort**: 1-2 days
**Dependencies**: `zfs`

**Features**: Daily/weekly/monthly snapshots, recursive support, pruning policy.

---

### 3.4 ssh-key-audit.sh
**Purpose**: SSH key hygiene and rotation
**Effort**: 1 day
**Dependencies**: `ssh`

**Features**: Scan authorized_keys, flag weak options, optional key rotation.

---

### 3.5 fail2ban-report.sh
**Purpose**: Ban summaries and top offenders
**Effort**: 1 day
**Dependencies**: `fail2ban-client`

**Features**: Jail summaries, recent bans, top IPs, webhook notifications.

---

## Implementation Guidelines

### Code Standards
- All scripts start with this template:
  ```bash
  #!/usr/bin/env bash
  set -euo pipefail

  # <Script Name> - <One-line description>
  # Version: 1.0.0
  # Usage: ./<script>.sh [options]

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LOG_DIR="${SCRIPT_DIR}/logs"
  ```

- Consistent flag parsing:
  ```bash
  while [[ $# -gt 0 ]]; do
      case $1 in
          --help) show_help; exit 0 ;;
          --dry-run) DRY_RUN=true; shift ;;
          --json) JSON_OUTPUT=true; shift ;;
          *) print_error "Unknown option: $1"; exit 1 ;;
      esac
  done
  ```

### Security Checklist
- [ ] Secure log directory: `mkdir -p "${LOG_DIR}" && chmod 700 "${LOG_DIR}"`
- [ ] Secure log files: `umask 077` before writing
- [ ] Path validation: Use `realpath` or parameter expansion
- [ ] Bounds checking: Validate all numeric inputs
- [ ] No secrets in CLI args: Use environment variables
- [ ] ShellCheck clean: `shellcheck -x script.sh`

### Testing Checklist
- [ ] `--help` flag works
- [ ] `--dry-run` shows correct plan without executing
- [ ] `--json` output is valid JSON with schema version
- [ ] Cross-platform: Test on both macOS and Linux
- [ ] CI smoke test added to `.github/workflows/smoke-tests.yml`
- [ ] `shfmt` formatted: `shfmt -w script.sh`

### Documentation Checklist
- [ ] Usage examples in `--help` output
- [ ] README.md updated with new script
- [ ] CHANGELOG.md entry added
- [ ] Security considerations documented (if applicable)

---

## Release Planning

### v1.1.0 - Foundation Release
**Target**: 2 weeks
**Contents**:
- service-health-check.sh
- cert-renewal-check.sh
- db-backup.sh

### v1.2.0 - Operations Release
**Target**: 4 weeks
**Contents**:
- compose-redeploy.sh
- docker-volume-backup.sh
- dyndns-update.sh

### v1.3.0+ - Specialized Tools
**Target**: TBD
**Contents**: Remaining scripts based on user feedback and demand

---

## Contributing

When implementing scripts from this roadmap:

1. Create feature branch: `git checkout -b feature/service-health-check`
2. Follow all code standards and checklists above
3. Add CI smoke tests
4. Update README.md and CHANGELOG.md
5. Test on both macOS and Linux (if cross-platform)
6. Submit PR with description of implementation choices

---

## Feedback

This roadmap is a living document. Priorities may shift based on:
- User requests and feedback
- Security considerations
- Maintenance complexity
- Community contributions

To suggest changes or new scripts, open an issue with the `enhancement` label.
