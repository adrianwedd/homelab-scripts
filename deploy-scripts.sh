#!/bin/bash

# deploy-scripts.sh - Sync this repository to remote hosts (git or rsync)
# Cross-platform safe: tries remote git fetch/clone; falls back to rsync.

set -u

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_info() { echo -e "${BLUE}ℹ${NC} $*"; }
print_success() { echo -e "${GREEN}✓${NC} $*"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $*"; }
print_error() { echo -e "${RED}✗${NC} $*"; }
print_section() { echo -e "\n${CYAN}━━━ $* ━━━${NC}\n"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HOSTS=()
REMOTE_PATH="\$HOME/repos/scripts"
RSYNC_ONLY=false
DRY_RUN=false

show_help() {
	cat <<EOF
Usage: ./deploy-scripts.sh [OPTIONS]

Sync the current repo to remote hosts using git (preferred) or rsync fallback.

Options:
    --hosts <list>         Comma-separated list of hosts (e.g., pi@192.168.1.100,pi@192.168.1.250)
    --hosts-file <path>    File with one host per line (e.g., examples/hosts.txt)
    --path <remote-path>   Remote path (default: \$HOME/repos/scripts)
    --rsync-only           Force rsync (skip git attempts)
    --dry-run              Show what would be done without changing remote
    --help                 Show this help

Examples:
    ./deploy-scripts.sh --hosts "pi@192.168.1.100,pi@192.168.1.250"
    ./deploy-scripts.sh --hosts-file examples/hosts.txt --path "\$HOME/homelab-scripts"
    ./deploy-scripts.sh --rsync-only --hosts "pi@192.168.1.100"
EOF
}

parse_hosts_file() {
	local file="$1"
	if [ ! -f "$file" ]; then
		print_error "Hosts file not found: $file"
		exit 1
	fi
	while IFS= read -r line; do
		line="${line%%#*}"
		line="${line%%[[:space:]]*}"
		if [ -n "${line:-}" ]; then
			HOSTS+=("$line")
		fi
	done <"$file"
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--hosts)
		IFS=',' read -r -a HOSTS <<<"$2"
		shift 2
		;;
	--hosts-file)
		parse_hosts_file "$2"
		shift 2
		;;
	--path)
		REMOTE_PATH="$2"
		shift 2
		;;
	--rsync-only)
		RSYNC_ONLY=true
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
		print_error "Unknown option: $1"
		show_help
		exit 1
		;;
	esac
done

if [ ${#HOSTS[@]} -eq 0 ]; then
	# Default hosts (can be overridden via flags)
	HOSTS=("pi@192.168.1.100" "pi@192.168.1.250")
fi

# Validate REMOTE_PATH: block dangerous characters and system directories
if [[ "$REMOTE_PATH" == *"'"* ]] || [[ "$REMOTE_PATH" == *'"'* ]] || [[ "$REMOTE_PATH" == *'`'* ]] || [[ "$REMOTE_PATH" == *'$('* ]] || [[ "$REMOTE_PATH" == *';'* ]]; then
	print_error "Remote path contains unsafe characters: $REMOTE_PATH"
	exit 1
fi
# Block obvious system directories
case "$REMOTE_PATH" in
/ | /usr* | /etc* | /var* | /bin* | /sbin* | /boot* | /sys* | /proc* | /dev*)
	print_error "Remote path cannot be a system directory: $REMOTE_PATH"
	exit 1
	;;
esac

print_section "Deploying to ${#HOSTS[@]} host(s)"
print_info "Remote path: $REMOTE_PATH"
print_info "Mode: $([ "$RSYNC_ONLY" = true ] && echo rsync-only || echo git-first)"
print_info "Dry-run: $DRY_RUN"

sync_rsync() {
	local host="$1"
	print_info "[$host] rsync syncing..."
	if [ "$DRY_RUN" = true ]; then
		print_info "[DRY RUN][$host] rsync -az --delete (excluding .git/, logs/, .claude/) to $REMOTE_PATH"
		return 0
	fi
	local escaped_path
	escaped_path=$(printf '%q' "$REMOTE_PATH")
	rsync -az --delete \
		--rsync-path="mkdir -p ${escaped_path} && rsync" \
		--exclude '.git/' --exclude 'logs/' --exclude '.claude/' \
		"$SCRIPT_DIR/" "$host":"$REMOTE_PATH/"
}

sync_git() {
	local host="$1"
	print_info "[$host] attempting git sync..."
	if [ "$DRY_RUN" = true ]; then
		print_info "[DRY RUN][$host] would run remote git fetch/reset or clone"
		return 0
	fi
	ssh -o BatchMode=yes -o ConnectTimeout=12 "${host}" RPATH="$REMOTE_PATH" bash -s <<'REMOTE'
set -euo pipefail
# RPATH carries a literal like "$HOME/repos/scripts"; expand leading $HOME on remote
REPO_PATH="${RPATH:-$HOME/repos/scripts}"
case "$REPO_PATH" in
    \$HOME/*) REPO_PATH="${HOME}${REPO_PATH#\$HOME}" ;;
    "") REPO_PATH="$HOME/repos/scripts" ;;
esac
mkdir -p "$REPO_PATH"
if command -v git >/dev/null 2>&1; then
    if [ -d "$REPO_PATH/.git" ]; then
        cd "$REPO_PATH"
        if git remote | grep -q '^origin$'; then :; else
            git remote add origin https://github.com/adrianwedd/homelab-scripts.git || true
        fi
        git fetch --depth=1 origin main || git fetch origin main
        git reset --hard origin/main
        echo GIT_SYNC_OK
    else
        rm -rf "$REPO_PATH"
        git clone --depth=1 https://github.com/adrianwedd/homelab-scripts.git "$REPO_PATH"
        echo GIT_CLONE_OK
    fi
else
    exit 42
fi
REMOTE
	rc=$?
	return $rc
}

sanity_check() {
	local host="$1"
	local remote_path_q
	remote_path_q=$(printf '%q' "$REMOTE_PATH")
	print_info "[$host] running sanity checks (syntax/help)..."
	if [ "$DRY_RUN" = true ]; then
		print_info "[DRY RUN][$host] would run: bash -n *.sh; ./db-backup.sh --help; ./cert-renewal-check.sh --help; ./nmap-scan.sh --help"
		return 0
	fi
	ssh -o BatchMode=yes -o ConnectTimeout=12 "$host" "REMOTE_PATH=$remote_path_q bash -s" <<'REMOTE'
set -euo pipefail
cd "$REMOTE_PATH"
bash -n *.sh
./db-backup.sh --help >/dev/null
./cert-renewal-check.sh --help >/dev/null
./nmap-scan.sh --help >/dev/null
echo SANITY_OK
REMOTE
}

overall_rc=0
for host in "${HOSTS[@]}"; do
	print_section "Host $host"
	if [ "$RSYNC_ONLY" = true ]; then
		if ! sync_rsync "$host"; then
			overall_rc=1
			print_error "[$host] rsync failed"
			continue
		fi
	else
		if ! sync_git "$host"; then
			print_warning "[$host] git sync failed or unavailable; falling back to rsync"
			if ! sync_rsync "$host"; then
				overall_rc=1
				print_error "[$host] rsync failed"
				continue
			fi
		fi
	fi
	if ! sanity_check "$host"; then
		overall_rc=1
		print_error "[$host] sanity check failed"
		continue
	fi
	print_success "[$host] deploy complete"
done

exit $overall_rc
