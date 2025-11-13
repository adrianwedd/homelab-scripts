# Getting Started with Homelab Scripts

Welcome! This guide will help you get up and running with the homelab automation scripts in under 10 minutes.

---

## 📋 Prerequisites

### Required
- **macOS** or **Linux** operating system
- **Bash 3.2+** (comes pre-installed on macOS/Linux)
- **Git** for cloning the repository

### Optional (installed automatically when needed)
- **Docker** - For container management (disk-cleanup.sh, service-health-check.sh)
- **nmap** - For network scanning (nmap-scan.sh)
- **rclone** - For cloud backups (rclone-sync.sh, db-backup.sh)
- **PostgreSQL/MySQL clients** - For database backups (db-backup.sh)

---

## 🚀 Quick Start (3 steps)

### Step 1: Clone the Repository

```bash
git clone https://github.com/adrianwedd/homelab-scripts.git
cd homelab-scripts
```

### Step 2: Make Scripts Executable

```bash
chmod +x *.sh
```

### Step 3: Run Your First Script

Let's check for SSL certificates expiring soon:

```bash
# Create a simple test file with a domain
echo "google.com" > test-domains.txt

# Check certificate expiry
./cert-renewal-check.sh --domains test-domains.txt --warn-days 30

# Expected output:
# ✓ google.com: Valid (expires in X days)
```

**🎉 Success!** You've run your first homelab script.

---

## 📚 Common Use Cases

### Use Case 1: Free Up Disk Space

The most popular script - clean up caches and free disk space:

```bash
# Preview what will be cleaned (safe, no changes)
./disk-cleanup.sh --dry-run

# Run actual cleanup with confirmations
./disk-cleanup.sh

# Non-interactive cleanup (for automation)
./disk-cleanup.sh -y --skip-docker
```

**Typical results:** 5-10GB freed in 2-5 minutes

---

### Use Case 2: Monitor Service Uptime

Check if your services are running properly:

```bash
# Use the example config
./service-health-check.sh --config examples/services.conf --once

# Watch mode (continuous monitoring every 60 seconds)
./service-health-check.sh --config examples/services.conf --watch --interval 60

# JSON output for integration with monitoring tools
./service-health-check.sh --config examples/services.conf --once --json
```

**Configuration:** Edit `examples/services.conf` to add your services.

---

### Use Case 3: Backup Your Database

Automated PostgreSQL/MySQL backups with retention:

```bash
# Set database connection (never use CLI args for passwords!)
export DB_DSN="postgres://username:password@localhost:5432/mydb"

# Preview backup plan
./db-backup.sh --db pg --dry-run

# Run backup with 7 daily, 4 weekly, 12 monthly retention
./db-backup.sh --db pg --out ./backups --retention 7:4:12

# Backup with cloud sync
./db-backup.sh --db pg --out ./backups --rclone gdrive:database-backups
```

**Security Note:** Always use environment variables for credentials, never CLI arguments.

---

### Use Case 4: Monitor SSL Certificates

Never let certificates expire unexpectedly:

```bash
# Check multiple domains from a file
cat > my-domains.txt << 'DOMAINS'
example.com
api.example.com
admin.example.com
DOMAINS

# Check expiry with 30-day warning
./cert-renewal-check.sh --domains my-domains.txt --warn-days 30

# JSON output for automation
./cert-renewal-check.sh --domains my-domains.txt --warn-days 30 --json

# Check local certificate file
./cert-renewal-check.sh --cert /etc/ssl/certs/my-cert.pem --warn-days 21
```

---

## 🛠️ Installation of Optional Tools

### Install nmap (network scanning)

```bash
# macOS
brew install nmap

# Ubuntu/Debian
sudo apt install nmap

# Verify
nmap --version
```

### Install rclone (cloud sync)

```bash
# macOS
brew install rclone

# Ubuntu/Debian
curl https://rclone.org/install.sh | sudo bash

# Configure Google Drive
rclone config
# Choose: New remote → Google Drive → Follow OAuth flow
```

### Install Database Clients

```bash
# PostgreSQL client
brew install postgresql       # macOS
sudo apt install postgresql-client  # Linux

# MySQL client
brew install mysql-client     # macOS
sudo apt install mysql-client       # Linux
```

---

## 🔧 Configuration Tips

### 1. Create a Config Directory

Keep your configurations organized:

```bash
mkdir -p ~/.homelab-scripts
cp examples/*.conf ~/.homelab-scripts/
cp examples/*.txt ~/.homelab-scripts/
```

### 2. Set Up Environment Variables

Add to your `~/.bashrc` or `~/.zshrc`:

```bash
# Database credentials (example - use your actual credentials)
export DB_DSN="postgres://user:pass@localhost:5432/mydb"

# Rclone remote name
export RCLONE_REMOTE="gdrive:homelab-backups"
```

### 3. Schedule Automated Runs

Add to crontab (`crontab -e`):

```cron
# Daily cleanup at 2 AM (non-interactive, skip Docker)
0 2 * * * cd /path/to/homelab-scripts && ./disk-cleanup.sh -y --skip-docker --no-gauge --no-fun

# Check certificates weekly on Monday at 9 AM
0 9 * * 1 cd /path/to/homelab-scripts && ./cert-renewal-check.sh --domains ~/.homelab-scripts/domains.txt --warn-days 30

# Database backup daily at 1 AM
0 1 * * * cd /path/to/homelab-scripts && ./db-backup.sh --db pg --out ~/backups/db --retention 7:4:12

# Service health check every hour
0 * * * * cd /path/to/homelab-scripts && ./service-health-check.sh --config ~/.homelab-scripts/services.conf --once --json
```

---

## 🎯 Next Steps

### Explore More Scripts

```bash
# List all available scripts
ls -1 *.sh

# Get help for any script
./disk-cleanup.sh --help
./service-health-check.sh --help
./db-backup.sh --help
./cert-renewal-check.sh --help
```

### Read Detailed Documentation

- **[README.md](../README.md)** - Complete feature reference
- **[CHANGELOG.md](../CHANGELOG.md)** - Version history and changes
- **[ROADMAP.md](../ROADMAP.md)** - Upcoming features
- **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** - Common issues and solutions

### Join the Community

- **Report bugs:** [GitHub Issues](https://github.com/adrianwedd/homelab-scripts/issues)
- **Request features:** [GitHub Discussions](https://github.com/adrianwedd/homelab-scripts/discussions)
- **Contribute:** See [CONTRIBUTING.md](../CONTRIBUTING.md)

---

## ❓ Quick FAQ

**Q: Are these scripts safe to run?**  
A: Yes! All scripts support `--dry-run` mode to preview changes before executing. The scripts never modify source code, only clean caches and generated files.

**Q: Will disk-cleanup.sh delete my files?**  
A: No. It only removes caches, build artifacts, and temporary files. Your source code, documents, and configurations are never touched.

**Q: Do I need to install all dependencies?**  
A: No. Scripts gracefully skip unavailable tools. For example, if Docker isn't installed, disk-cleanup.sh will skip Docker cleanup.

**Q: Can I use these on a production server?**  
A: Yes, but test in `--dry-run` mode first. Many scripts are designed for automation (cron jobs).

**Q: How do I update to the latest version?**  
A: Pull the latest changes:
```bash
cd homelab-scripts
git pull origin main
```

---

## 🆘 Need Help?

- **Troubleshooting:** See [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
- **Issues:** [GitHub Issues](https://github.com/adrianwedd/homelab-scripts/issues)
- **Security:** See [SECURITY.md](../SECURITY.md) for reporting vulnerabilities

**Happy automation! 🎉**
