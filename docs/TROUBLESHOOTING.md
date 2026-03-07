# Troubleshooting

Solutions to the most common issues across all scripts.

---

## General

### "Permission denied" when running a script

```bash
chmod +x *.sh
```

### Script crashes immediately

Check for syntax errors first:

```bash
bash -n scriptname.sh
shellcheck -S warning scriptname.sh
```

### Logs aren't visible

Log directory `logs/` has permission `700` and files `600` — they're only readable by the owner. Check you're running as the right user:

```bash
ls -la logs/
```

---

## `disk-cleanup.sh`

### Disk gauge not visible over SSH or in cron

Gauge requires a TTY. Disable it explicitly:

```bash
./disk-cleanup.sh --no-gauge --no-fun
```

### Docker cleanup fails or hangs

```bash
# Skip Docker entirely (recommended for cron/headless)
./disk-cleanup.sh --skip-docker

# Or give Docker more time to start
./disk-cleanup.sh --docker-wait 120

# On Linux, start Docker manually
sudo systemctl start docker
```

### Git gc takes too long

Git gc has a 30-minute timeout per repo. Options:

```bash
# Skip git gc entirely
./disk-cleanup.sh --skip-git-gc

# Only run gc on repos with >= 2GB packs
./disk-cleanup.sh --smart-gc --gc-threshold 2

# Run on a specific repo manually (no timeout)
git -C ~/repos/myrepo gc --aggressive --prune=now
```

### Virtualenv path rejected

Roots must be under `$HOME`. System paths are blocked:

```bash
# Valid
./disk-cleanup.sh --venv-roots "$HOME/repos:$HOME/projects"

# Invalid — will be rejected
./disk-cleanup.sh --venv-roots "/var/lib/venvs"
```

### Bounds validation error

| Parameter | Valid range |
|-----------|-------------|
| `--gc-threshold` | 0.1 – 1000 GB |
| `--venv-age` | 1 – 3650 days |
| `--venv-min-gb` | 0.01 – 100 GB |

---

## `rclone-sync.sh`

### "Remote not configured" error

```bash
rclone config          # Add or reconfigure your remote
rclone listremotes     # Verify it appears

# Use a different remote name
REMOTE_NAME=my_gdrive ./rclone-sync.sh --start
```

### Stale PID file (sync won't start)

```bash
rm -f ~/.rclone-sync.pid
pgrep -f "rclone sync" | xargs kill -9 2>/dev/null || true
./rclone-sync.sh --start
```

### Sync deleting remote files unexpectedly

`rclone sync` mirrors the source. Files deleted locally will be deleted remotely. Use `--dry-run` first to confirm:

```bash
./rclone-sync.sh --dry-run
```

If you need to preserve remote-only files, use `rclone copy` instead (not supported by this script).

### Log file growing too large

Logs auto-rotate at 50 MB. To check size:

```bash
du -sh ~/rclone-sync.log
```

---

## `db-backup.sh`

### "DSN required" error

```bash
export DB_DSN="postgres://user:pass@localhost/mydb"
./db-backup.sh --db pg
```

Never pass DSN as `--dsn` in cron (it appears in process lists). Always use the env var.

### `pg_dump` / `mysqldump` not found

```bash
sudo apt install postgresql-client    # pg_dump
sudo apt install default-mysql-client # mysqldump
```

### Backup verification fails (`--test-restore`)

Test restore requires a running PostgreSQL server with permission to create temporary databases. Check:

```bash
psql "$DB_DSN" -c "SELECT 1"    # Test connection
```

---

## `service-health-check.sh`

### Config file not found

```bash
# Use the example as a starting point
cp examples/services.conf my-services.conf
./service-health-check.sh --config my-services.conf
```

### HTTP check always fails

Check the endpoint directly:

```bash
curl -v http://your-endpoint/health
```

Then check your config:
- Is the `url` correct (including scheme)?
- Does `expect_status` match the actual response code?
- Does `expect_body` appear in the response?

### Container check says "not running" when it is

The check uses `docker inspect`. Ensure the container name matches exactly:

```bash
docker ps --format '{{.Names}}'
```

---

## `nmap-scan.sh`

### `nmap` not found

```bash
sudo apt install nmap    # Debian/Ubuntu/Raspberry Pi OS
brew install nmap         # macOS
```

### MAC addresses missing

MAC addresses are only available when:
1. Running as root/sudo AND
2. The target host is on the same L2 network segment (same switch/VLAN)

```bash
sudo ./nmap-scan.sh
```

### CIDR auto-detection fails

Specify manually:

```bash
./nmap-scan.sh --cidr "192.168.1.0/24"
```

### Scan rate too high (affecting network)

```bash
./nmap-scan.sh --rate 25    # 25 packets/sec is very gentle
```

---

## `smart-disk-check.sh`

### `smartctl` not found

```bash
sudo apt install smartmontools    # Debian/Ubuntu
brew install smartmontools         # macOS
```

### "Permission denied" accessing device

SMART checks require root access to raw block devices:

```bash
sudo ./smart-disk-check.sh
```

Or add your user to the `disk` group (less preferred):

```bash
sudo usermod -aG disk $USER
```

### Temperature thresholds

| Parameter | Valid range |
|-----------|-------------|
| `--warn-temp` | 30–80°C |
| `--crit-temp` | 40–90°C |

`crit-temp` must be greater than `warn-temp`.

---

## `cert-renewal-check.sh`

### Check fails for an internal hostname

Internal hostnames may not have publicly verifiable certs. Use `--cert` to check a local cert file directly:

```bash
./cert-renewal-check.sh --cert /etc/ssl/certs/internal.pem
```

### `certbot` auto-renew fails

certbot requires root and a running web server. Check:

```bash
sudo certbot renew --dry-run
```

---

## `ssh-key-audit.sh`

### "No authorized_keys found" for a user

The user may not have SSH configured, or the file may be in a non-standard location. Use `--home-root` to specify a custom home directory root:

```bash
./ssh-key-audit.sh --users alice --home-root /srv/users
```

### Audit includes system users

By default only users under `--home-root` (default: `/home`) are scanned. To include system-level files:

```bash
./ssh-key-audit.sh --all-users --system \
  --system-paths "/etc/ssh/authorized_keys:/etc/ssh/authorized_keys.d"
```

---

## `compose-redeploy.sh`

### Health checks keep timing out

```bash
# Increase timeout
./compose-redeploy.sh --health-timeout 300

# Check what's happening during startup
docker compose logs -f
```

### Rollback happened unexpectedly

Rollback triggers when health checks fail. Check the container logs:

```bash
docker compose ps
docker compose logs servicename
```

### "Compose file invalid" error

```bash
docker compose -f your-file.yml config    # Validate manually
```

---

## `deploy-scripts.sh`

### SSH connection refused

```bash
# Test SSH connectivity manually
ssh pi@192.168.1.100 "echo ok"

# Check known_hosts (key changed?)
ssh-keygen -R 192.168.1.100
ssh pi@192.168.1.100
```

### Git sync fails, rsync takes over

This is expected — `deploy-scripts.sh` tries git first and falls back to rsync. If you always want rsync:

```bash
./deploy-scripts.sh --hosts "pi@192.168.1.100" --rsync-only
```

---

## `new-vm-setup.sh`

### Hostname validation rejects your name

Hostnames must follow RFC-1123:
- Lowercase letters, digits, and hyphens only
- Max 63 characters
- Cannot start or end with a hyphen

```bash
# Bad: has uppercase
./new-vm-setup.sh --hostname MyServer ...

# Good
./new-vm-setup.sh --hostname my-server ...
```

### User validation rejects your username

Usernames must:
- Start with a lowercase letter
- Contain only lowercase letters, digits, underscores, hyphens
- Not be `root`

---

## `dyndns-update.sh`

### "Token not found in environment"

Use `env:VAR_NAME` syntax and make sure the variable is exported:

```bash
export CF_TOKEN="your-token"
./dyndns-update.sh --token env:CF_TOKEN ...
```

### Update not happening (IP unchanged)

The script caches your last known IP to avoid redundant API calls. Use `--force` to bypass:

```bash
./dyndns-update.sh ... --force
```

### Rate limit: "Too soon since last update"

Updates are rate-limited to one per 5 minutes. This is intentional. For cron, run at a 5-minute interval at most.

---

## `ci-health-audit.sh`

### All workflows showing as broken

This usually means `python3-yaml` (PyYAML) isn't installed:

```bash
python3 -c "import yaml; print('ok')"

# If that fails:
pip3 install pyyaml
# or
sudo apt install python3-yaml
```

### "Estimated waste" seems wrong

The estimate assumes 7 branches × 10 min × $0.008/min per unguarded scheduled workflow. It's a rough indicator only.

---

## `qa-all.sh`

### `shfmt` not found

```bash
sudo apt install shfmt    # Debian/Ubuntu
brew install shfmt         # macOS
```

### `shellcheck` not found

```bash
sudo apt install shellcheck    # Debian/Ubuntu
brew install shellcheck         # macOS
```

### `jq` not found

```bash
sudo apt install jq    # Debian/Ubuntu
brew install jq         # macOS
```

### A test fails unexpectedly

Check the artifact log for that test:

```bash
ls logs/qa/run_*/
cat logs/qa/run_LATEST/testname.log
```

---

## Still stuck?

1. Check the relevant log file in `logs/` (all scripts log there)
2. Run with `--dry-run` to isolate the issue
3. Run `bash -n scriptname.sh` to check for syntax errors
4. Run `shellcheck scriptname.sh` for static analysis
5. Open an issue: https://github.com/adrianwedd/homelab-scripts/issues
