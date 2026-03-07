# Getting Started

Get up and running with the homelab scripts in under 5 minutes.

---

## Prerequisites

**Required:**
- Linux or macOS
- Bash 3.2+ (comes pre-installed)
- Git

**Per-script (only needed when you use that script):**

```bash
# Network scanning
sudo apt install nmap

# Cloud sync
sudo apt install rclone && rclone config

# SMART disk monitoring
sudo apt install smartmontools

# Database backups
sudo apt install postgresql-client   # for pg_dump
sudo apt install mysql-client        # for mysqldump

# QA harness
sudo apt install shellcheck shfmt jq
```

---

## Install

```bash
git clone https://github.com/adrianwedd/homelab-scripts.git
cd homelab-scripts
chmod +x *.sh
```

---

## Your First Run

**Rule #1:** Always `--dry-run` before you do anything real.

```bash
# What would disk-cleanup.sh remove?
./disk-cleanup.sh --dry-run --no-gauge --no-fun

# What services are down?
./service-health-check.sh --config examples/services.conf --dry-run

# Which SSL certs are about to expire?
./cert-renewal-check.sh --domains examples/domains.txt --dry-run

# What's on my network?
./nmap-scan.sh --dry-run
```

---

## Five Common Tasks

### 1. Free up disk space

```bash
# See what would be removed
./disk-cleanup.sh --dry-run --no-gauge --no-fun

# Clean caches (skip Docker, safe for headless)
./disk-cleanup.sh -y --skip-docker --no-gauge --no-fun

# Interactive with live disk gauge
./disk-cleanup.sh
```

### 2. Monitor your services

Create a config file:

```bash
cat > services.conf << 'EOF'
[my-app]
type=http
url=http://localhost:8080/health
expect_status=200

[ssh]
type=tcp
host=localhost
port=22

[sshd]
type=process
name=sshd
EOF

./service-health-check.sh --config services.conf
```

### 3. Back up your database

```bash
export DB_DSN="postgres://myuser:mypass@localhost/mydb"

# Dry run first
./db-backup.sh --db pg --dry-run

# Real backup
./db-backup.sh --db pg
```

### 4. Sync repos to Google Drive

```bash
# Set up rclone first (one-time)
rclone config

# Preview what would be synced
./rclone-sync.sh --dry-run

# Start background sync
./rclone-sync.sh --start
./rclone-sync.sh --status
```

### 5. Audit SSH keys

```bash
./ssh-key-audit.sh --all-users

# Fail if any RSA keys found
./ssh-key-audit.sh --all-users --forbid-types ssh-rsa --fail-on weak-type
```

---

## Set Up Automation (Cron)

```bash
crontab -e
```

Add:

```cron
# Daily: check SSL certs at 8 AM
0 8 * * * ./cert-renewal-check.sh --domains /etc/ssl/domains.txt >> /tmp/cert.log 2>&1

# Weekly: disk cleanup Sunday 3 AM
0 3 * * 0 cd /home/pi/repos/scripts && ./disk-cleanup.sh -y --skip-docker --no-gauge --no-fun >> /tmp/cleanup.log 2>&1

# Daily: DB backup at 2 AM
0 2 * * * cd /home/pi/repos/scripts && DB_DSN="postgres://user:pass@localhost/mydb" ./db-backup.sh --db pg >> /tmp/db-backup.log 2>&1
```

---

## Set Up the Pre-commit Hook

Catches shellcheck errors, shfmt formatting issues, and unsafe `bc` usage before you commit:

```bash
ln -sf ../../.githooks/pre-commit .git/hooks/pre-commit
```

Requires: `shellcheck`, `shfmt` (`sudo apt install shellcheck shfmt`)

---

## Run the QA Suite

```bash
# Install dependencies
sudo apt install shellcheck shfmt jq

# Run all checks
./qa-all.sh

# Expected: 31/31 PASS
```

---

## Next Steps

- **Full reference:** [README.md](../README.md) — every flag for every script
- **Troubleshooting:** [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — common issues and fixes
- **Examples:** `examples/` directory — sample config files and scripts
