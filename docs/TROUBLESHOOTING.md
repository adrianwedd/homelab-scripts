# Troubleshooting Guide

Common issues and their solutions when using homelab scripts.

---

## Table of Contents

1. [General Issues](#general-issues)
2. [disk-cleanup.sh](#disk-cleanupsh)
3. [service-health-check.sh](#service-health-checksh)
4. [db-backup.sh](#db-backupsh)
5. [cert-renewal-check.sh](#cert-renewal-checksh)
6. [rclone-sync.sh](#rclone-syncsh)
7. [nmap-scan.sh](#nmap-scansh)

---

## General Issues

### Permission Denied When Running Scripts

**Symptom:**
```
bash: ./disk-cleanup.sh: Permission denied
```

**Solution:**
Make scripts executable:
```bash
chmod +x *.sh
```

---

### Command Not Found

**Symptom:**
```
./disk-cleanup.sh: command not found
```

**Solution:**
Ensure you're in the correct directory:
```bash
cd /path/to/homelab-scripts
ls -la *.sh  # Verify scripts exist
```

---

### Script Fails with "unbound variable"

**Symptom:**
```
./script.sh: line 123: VARIABLE_NAME: unbound variable
```

**Solution:**
This is a safety check (`set -u`). The script detected an undefined variable. Please report this as a bug with:
- Script name and version
- Command you ran
- Full error output

---

## disk-cleanup.sh

### Docker Won't Start

**Symptom:**
```
⚠ Docker daemon is not running
⚠ Waiting up to 60 seconds for Docker to start...
✗ Docker daemon failed to start within 60 seconds
```

**Solutions:**

1. **Start Docker Desktop manually** (macOS):
   ```bash
   open -a Docker
   # Wait for Docker to fully start, then re-run
   ./disk-cleanup.sh
   ```

2. **Increase wait time**:
   ```bash
   ./disk-cleanup.sh --docker-wait 120
   ```

3. **Skip Docker cleanup entirely**:
   ```bash
   ./disk-cleanup.sh --skip-docker
   ```

4. **For headless/SSH environments**, start Docker manually before running:
   ```bash
   # Linux
   sudo systemctl start docker
   
   # Then run cleanup
   ./disk-cleanup.sh
   ```

---

### Git GC Takes Too Long

**Symptom:**
```
Running git gc on large repositories (30+ minutes per repo)
```

**Solutions:**

1. **Use smart GC** (default, only processes large repos):
   ```bash
   ./disk-cleanup.sh --smart-gc --gc-threshold 2
   ```

2. **Skip git gc entirely**:
   ```bash
   ./disk-cleanup.sh --skip-git-gc
   ```

3. **Run in background with nohup**:
   ```bash
   nohup ./disk-cleanup.sh -y > cleanup.log 2>&1 &
   tail -f cleanup.log
   ```

---

### Virtualenv Cleanup Errors

**Symptom:**
```
✗ Error: Bash 4.0+ required for virtualenv features
```

**Solution:**
Install Bash 4.0+ (macOS ships with Bash 3.2):
```bash
# macOS
brew install bash

# Verify version
bash --version  # Should show 4.0+

# Run with new bash
/usr/local/bin/bash ./disk-cleanup.sh --scan-venvs
```

**Alternative:** Skip virtualenv features and use older Bash:
```bash
./disk-cleanup.sh   # Without --scan-venvs or --clean-venvs
```

---

### Gauge Not Visible Over SSH

**Symptom:**
Live disk gauge doesn't display when connected via SSH.

**Solution:**
Disable gauge for non-TTY sessions:
```bash
./disk-cleanup.sh --no-gauge --no-fun
```

For automation (cron):
```bash
./disk-cleanup.sh -y --skip-docker --no-gauge --no-fun
```

---

### Path Validation Errors

**Symptom:**
```
✗ Error: Path must be under $HOME for safety
```

**Solution:**
Virtual environment roots must be within your home directory:
```bash
# ✗ Bad: system path
./disk-cleanup.sh --venv-roots /usr/local/lib

# ✓ Good: user path
./disk-cleanup.sh --venv-roots "$HOME/repos:$HOME/projects"
```

---

## service-health-check.sh

### Config File Not Found

**Symptom:**
```
✗ Error: Config file not found: services.conf
```

**Solution:**
Provide full path to config:
```bash
./service-health-check.sh --config examples/services.conf
```

Or create your own config:
```bash
cp examples/services.conf ~/.homelab-scripts/my-services.conf
# Edit the file to add your services
./service-health-check.sh --config ~/.homelab-scripts/my-services.conf
```

---

### Docker Container Checks Failing

**Symptom:**
```
⊘ nginx-container (container): Docker not installed
```

**Solution:**
1. Install Docker if needed
2. Or remove Docker container checks from your config file
3. The script continues gracefully - this is informational, not an error

---

### HTTP Checks Timing Out

**Symptom:**
```
✗ api-server (http): HTTP status 000 (expected 200)
```

**Solutions:**

1. **Increase timeout** in config:
   ```ini
   [api-server]
   type=http
   url=https://slow-api.local
   timeout=10   # Increase from default 5
   ```

2. **Check network connectivity**:
   ```bash
   curl -v https://slow-api.local
   ```

3. **Verify URL is correct** in config file

---

### Webhook Notifications Not Working

**Symptom:**
```
⚠ Failed to send webhook notification
```

**Solutions:**

1. **Test webhook manually**:
   ```bash
   curl -X POST -H "Content-Type: application/json" \
     -d '{"test": "message"}' \
     http://your-webhook-url
   ```

2. **Check webhook URL format**:
   ```bash
   # Correct format
   --notify webhook:http://alerts.local/webhook
   
   # Not: --notify http://alerts.local/webhook
   ```

3. **Verify webhook endpoint is accessible** from script location

---

## db-backup.sh

### DSN Connection Failures

**Symptom:**
```
✗ Error: Failed to connect to database
```

**Solutions:**

1. **Verify DSN format**:
   ```bash
   # PostgreSQL
   export DB_DSN="postgres://username:password@host:5432/database"
   
   # MySQL
   export DB_DSN="mysql://username:password@host:3306/database"
   ```

2. **Test connection manually**:
   ```bash
   # PostgreSQL
   psql "postgresql://username:password@host:5432/database"
   
   # MySQL
   mysql -h host -u username -p database
   ```

3. **Check firewall/network access** to database server

---

### Password Visible in Logs

**Symptom:**
Concerned about password security in backup logs.

**Solution:**
The script automatically masks passwords in output. Verify:
```bash
./db-backup.sh --db pg --dry-run 2>&1 | grep -i password
# Should show: postgres://user:****@host/db
```

If you see plaintext passwords, please report as a security bug.

---

### Retention Policy Not Working

**Symptom:**
```
Too many old backups not being deleted
```

**Solution:**

1. **Check retention format**:
   ```bash
   # Correct: daily:weekly:monthly
   --retention 7:4:12
   
   # Wrong: --retention 7-4-12  (use colons, not dashes)
   ```

2. **Verify backup file naming** matches expected pattern:
   ```
   database_20251113_103000.sql.gz   # Correct format
   ```

3. **Run with verbose logging** to see retention decisions:
   ```bash
   ./db-backup.sh --db pg -v
   ```

---

### Rclone Upload Fails

**Symptom:**
```
✗ Error: Failed to upload backup to rclone remote
```

**Solutions:**

1. **Verify rclone remote exists**:
   ```bash
   rclone listremotes
   ```

2. **Test rclone manually**:
   ```bash
   rclone ls gdrive:database-backups
   ```

3. **Check rclone authentication**:
   ```bash
   rclone config reconnect gdrive:
   ```

---

## cert-renewal-check.sh

### OpenSSL Command Not Found

**Symptom:**
```
openssl: command not found
```

**Solution:**
Install OpenSSL (usually pre-installed):
```bash
# macOS (should be pre-installed)
brew install openssl

# Ubuntu/Debian
sudo apt install openssl

# Verify
openssl version
```

---

### Domain Check Failures

**Symptom:**
```
✗ example.com: Failed to connect
```

**Solutions:**

1. **Check domain is reachable**:
   ```bash
   curl -I https://example.com
   ```

2. **Verify firewall allows HTTPS** (port 443)

3. **Try with verbose output**:
   ```bash
   openssl s_client -connect example.com:443 -servername example.com
   ```

4. **Check if domain has valid DNS**:
   ```bash
   dig example.com
   nslookup example.com
   ```

---

### Local Certificate File Errors

**Symptom:**
```
✗ Error: Certificate file not found
```

**Solution:**
Provide full path to certificate:
```bash
./cert-renewal-check.sh --cert /etc/ssl/certs/my-cert.pem

# Verify file exists
ls -la /etc/ssl/certs/my-cert.pem
```

---

## rclone-sync.sh

### Rclone Not Configured

**Symptom:**
```
✗ Error: rclone remote 'gdrive_new' not found
```

**Solution:**
Configure rclone:
```bash
rclone config
# Choose: New remote → Name: gdrive_new → Google Drive → Complete OAuth
```

Verify:
```bash
rclone listremotes
# Should show: gdrive_new:
```

---

### Sync Process Crashes

**Symptom:**
```
Sync process died unexpectedly
```

**Solutions:**

1. **Check logs**:
   ```bash
   tail -100 ~/rclone-sync.log
   ```

2. **Test sync manually**:
   ```bash
   rclone sync ~/repos gdrive_new:repos --dry-run -v
   ```

3. **Check disk space** on local and remote

4. **Verify exclude file**:
   ```bash
   cat ~/.rclone-exclude
   ```

---

### Stale PID File

**Symptom:**
```
✗ Error: Sync process already running (PID: 12345)
```
But no process is actually running.

**Solution:**
Remove stale PID file:
```bash
rm -f ~/.rclone-sync.pid

# Verify no rclone process running
ps aux | grep rclone
```

---

## nmap-scan.sh

### Nmap Not Installed

**Symptom:**
```
✗ Error: nmap is not installed
```

**Solution:**
Install nmap:
```bash
# macOS
brew install nmap

# Ubuntu/Debian
sudo apt install nmap

# Verify
nmap --version
```

---

### Permission Denied (Scanning)

**Symptom:**
```
✗ Error: Insufficient privileges for SYN scan
```

**Solution:**
Some scan types require root. Use TCP connect scan instead:
```bash
# Default (safe, no root needed)
./nmap-scan.sh --cidr "192.168.1.0/24"
```

For SYN scans:
```bash
sudo ./nmap-scan.sh --cidr "192.168.1.0/24" --full
```

---

### CIDR Auto-Detection Fails

**Symptom:**
```
✗ Error: Could not auto-detect CIDR
```

**Solution:**
Manually specify CIDR:
```bash
# Single subnet
./nmap-scan.sh --cidr "192.168.1.0/24"

# Multiple subnets
./nmap-scan.sh --cidr "192.168.1.0/24,10.0.0.0/24"
```

Find your network:
```bash
# macOS
ifconfig | grep "inet "

# Linux
ip addr show
```

---

## Still Having Issues?

### Check Logs

All scripts log to `./logs/`:
```bash
# Find recent logs
ls -lt logs/ | head -10

# View specific log
tail -100 logs/disk_cleanup_20251113_103000.log
```

### Run in Dry-Run Mode

Test without making changes:
```bash
./disk-cleanup.sh --dry-run
./db-backup.sh --db pg --dry-run
./service-health-check.sh --config services.conf --dry-run
```

### Enable Verbose Output

Get more details:
```bash
./disk-cleanup.sh -v
./service-health-check.sh --config services.conf -v
```

### Report a Bug

If you've tried the solutions above and still have issues:

1. **Check existing issues:** [GitHub Issues](https://github.com/adrianwedd/homelab-scripts/issues)
2. **Create a new issue** with:
   - Script name and command run
   - Full error message
   - Operating system and version
   - Bash version (`bash --version`)
   - Relevant log excerpts

### Security Issues

For security vulnerabilities, see [SECURITY.md](../SECURITY.md) for responsible disclosure.

---

**Last Updated:** 2025-11-13 (v1.1.0)
