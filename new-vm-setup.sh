#!/usr/bin/env bash
set -u

# new-vm-setup.sh - Bootstrap fresh VMs with standard configuration
# Version: 1.3.0
# Usage: ./new-vm-setup.sh [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

LOG_DIR="${SCRIPT_DIR}/logs/new-vm-setup"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/vm_setup_${TIMESTAMP}.log"
JSON_FILE="${LOG_DIR}/vm_setup_summary_${TIMESTAMP}.json"

# Create log directory early (needed by print functions)
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"
umask 077

# Defaults
HOSTNAME=""
USERNAME=""
SSH_KEY=""
SSH_KEY_PATH=""
PACKAGES=""
DOTFILES_URL=""
SHELL_PATH="/bin/bash"
AUTO_YES=false
NO_SUDO=false
NO_DOTFILES=false
SUDO_NOPASS=false
DRY_RUN=false
OUTPUT_JSON=false

# State tracking
HOSTNAME_BEFORE=""
HOSTNAME_AFTER=""
USER_CREATED=false
SSH_KEY_ADDED=false
PACKAGES_INSTALLED=()
DOTFILES_CLONED=false
WARNINGS=()
OS_DISTRO=""
PKG_MANAGER=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Print functions
print_error() {
	echo -e "${RED}✗ Error:${NC} $1" >&2
	echo "[$(get_iso8601_timestamp)] ERROR: $1" >>"$LOG_FILE"
}

print_success() {
	echo -e "${GREEN}✓${NC} $1"
	echo "[$(get_iso8601_timestamp)] SUCCESS: $1" >>"$LOG_FILE"
}

print_warning() {
	echo -e "${YELLOW}⚠${NC} $1"
	echo "[$(get_iso8601_timestamp)] WARNING: $1" >>"$LOG_FILE"
	WARNINGS+=("$1")
}

print_info() {
	echo -e "${BLUE}ℹ${NC} $1"
	echo "[$(get_iso8601_timestamp)] INFO: $1" >>"$LOG_FILE"
}

print_section() {
	echo ""
	echo -e "${BLUE}━━━ $1 ━━━${NC}"
	echo ""
	echo "[$(get_iso8601_timestamp)] SECTION: $1" >>"$LOG_FILE"
}

# Validate hostname (RFC-1123)
validate_hostname() {
	local name="$1"

	# Check length
	if [ ${#name} -gt 63 ]; then
		echo "Error: Hostname exceeds 63 characters"
		return 1
	fi

	# Check RFC-1123 format: ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$
	if ! [[ "$name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
		echo "Error: Invalid hostname format. Must be lowercase alphanumeric with hyphens"
		echo "       Valid: test-host-01, myserver, web1"
		echo "       Invalid: Test-Host, my_server, -web"
		return 1
	fi

	return 0
}

# Validate username (POSIX)
validate_username() {
	local name="$1"

	# Check reserved names
	if [[ "$name" == "root" ]]; then
		echo "Error: Cannot use 'root' username. Create a regular user instead."
		return 1
	fi

	# Check length (typically 1-32 chars)
	if [ ${#name} -lt 1 ] || [ ${#name} -gt 32 ]; then
		echo "Error: Username must be 1-32 characters"
		return 1
	fi

	# Check POSIX format: ^[a-z_][a-z0-9_-]*$
	if ! [[ "$name" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
		echo "Error: Invalid username format. Must start with lowercase letter or underscore"
		echo "       Valid: admin, deploy_user, ci-bot"
		echo "       Invalid: 1user, Admin, user.name"
		return 1
	fi

	return 0
}

# Validate SSH key
validate_ssh_key() {
	local key="$1"

	# Check for valid key type prefix
	if ! echo "$key" | grep -qE "^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) "; then
		echo "Error: Invalid SSH key format. Must start with key type (ssh-rsa, ssh-ed25519, etc.)"
		return 1
	fi

	return 0
}

# Validate dotfiles URL
validate_dotfiles_url() {
	local url="$1"

	# Check for valid Git URL schemes
	if ! echo "$url" | grep -qE "^(https://|ssh://|git@)"; then
		echo "Error: Invalid dotfiles URL. Must use https://, ssh://, or git@... format"
		echo "       Valid: https://github.com/user/dotfiles.git"
		echo "       Valid: git@github.com:user/dotfiles.git"
		return 1
	fi

	return 0
}

# Show usage
show_help() {
	cat <<'HELP'
new-vm-setup.sh - Bootstrap fresh VMs with standard configuration

USAGE:
    ./new-vm-setup.sh [OPTIONS]

OPTIONS:
    --hostname <name>      Set system hostname (RFC-1123 format)
    --user <name>          Create user with sudo access
    --ssh-key '<key>'      SSH public key (full key string)
    --ssh-key-path <file>  Path to SSH public key file
    --packages '<list>'    Comma or space-separated package list
    --dotfiles <url>       Git URL for dotfiles repository
    --shell <path>         User shell (default: /bin/bash)
    --sudo-nopass          Allow passwordless sudo (SECURITY WARNING)
    --no-dotfiles          Skip dotfiles cloning
    --no-sudo              Print sudo commands without executing
    -y, --yes              Auto-confirm all prompts
    --dry-run              Show what would be done without executing
    --json                 JSON summary output
    --help                 Show this help message

EXAMPLES:
    # Basic setup with user and SSH key
    ./new-vm-setup.sh --hostname web-01 --user deploy \
        --ssh-key-path ~/.ssh/id_ed25519.pub

    # Full setup with packages and dotfiles
    ./new-vm-setup.sh --hostname dev-box --user admin \
        --ssh-key "ssh-ed25519 AAAA..." \
        --packages "git,curl,htop,vim" \
        --dotfiles https://github.com/user/dotfiles.git

    # Dry run to preview
    ./new-vm-setup.sh --hostname test-vm --user testuser \
        --ssh-key-path ~/.ssh/id_rsa.pub --dry-run

    # JSON output for automation
    ./new-vm-setup.sh --hostname prod-01 --user deploy \
        --ssh-key-path ~/.ssh/deploy.pub --json

FEATURES:
    - Idempotent operations (safe to run multiple times)
    - OS detection (Debian/Ubuntu/RHEL/CentOS/Fedora)
    - Automatic package manager selection (apt/yum/dnf)
    - Secure SSH key management (700/600 permissions)
    - Optional dotfiles cloning and linking

SAFETY:
    - No plaintext passwords (SSH key only)
    - Explicit sudo warnings with confirmation
    - Input validation (hostname, username, SSH keys, URLs)
    - Dry-run mode for preview
    - All operations logged to ./logs/new-vm-setup/

DEPENDENCIES:
    - Linux with /etc/os-release
    - Package manager: apt-get (Debian/Ubuntu) or yum/dnf (RHEL/CentOS/Fedora)
    - Optional: git (for --dotfiles)

VERSION: 1.3.0
HELP
}

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
	case $1 in
	--hostname)
		HOSTNAME="${2:-}"
		shift 2
		;;
	--user)
		USERNAME="${2:-}"
		shift 2
		;;
	--ssh-key)
		SSH_KEY="${2:-}"
		shift 2
		;;
	--ssh-key-path)
		SSH_KEY_PATH="${2:-}"
		shift 2
		;;
	--packages)
		PACKAGES="${2:-}"
		shift 2
		;;
	--dotfiles)
		DOTFILES_URL="${2:-}"
		shift 2
		;;
	--shell)
		SHELL_PATH="${2:-}"
		shift 2
		;;
	--sudo-nopass)
		SUDO_NOPASS=true
		shift
		;;
	--no-dotfiles)
		NO_DOTFILES=true
		shift
		;;
	--no-sudo)
		NO_SUDO=true
		shift
		;;
	-y | --yes)
		AUTO_YES=true
		shift
		;;
	--dry-run)
		DRY_RUN=true
		shift
		;;
	--json)
		OUTPUT_JSON=true
		shift
		;;
	--help)
		show_help
		exit 0
		;;
	*)
		if [ -n "$1" ]; then
			echo "Error: Unknown option '$1'"
		else
			echo "Error: Empty argument encountered"
		fi
		show_help
		exit 1
		;;
	esac
done

# Validate inputs
if [ -n "$HOSTNAME" ]; then
	if ! validate_hostname "$HOSTNAME"; then
		exit 1
	fi
fi

if [ -n "$USERNAME" ]; then
	if ! validate_username "$USERNAME"; then
		exit 1
	fi
fi

if [ -n "$SSH_KEY_PATH" ]; then
	if [ ! -f "$SSH_KEY_PATH" ]; then
		echo "Error: SSH key file not found: $SSH_KEY_PATH"
		exit 1
	fi
	SSH_KEY=$(cat "$SSH_KEY_PATH")
fi

if [ -n "$SSH_KEY" ]; then
	if ! validate_ssh_key "$SSH_KEY"; then
		exit 1
	fi
fi

if [ -n "$DOTFILES_URL" ]; then
	if ! validate_dotfiles_url "$DOTFILES_URL"; then
		exit 1
	fi
fi

if [ -n "$SHELL_PATH" ]; then
	# Only validate shell path if not in dry-run mode
	if [ "$DRY_RUN" = false ] && [ ! -x "$SHELL_PATH" ]; then
		echo "Error: Shell not executable: $SHELL_PATH"
		exit 1
	fi
fi

# Require at least one action
if [ -z "$HOSTNAME" ] && [ -z "$USERNAME" ] && [ -z "$PACKAGES" ]; then
	echo "Error: At least one action required (--hostname, --user, or --packages)"
	show_help
	exit 1
fi

# SSH key requires username
if [ -n "$SSH_KEY" ] && [ -z "$USERNAME" ]; then
	echo "Error: --ssh-key requires --user"
	exit 1
fi

# Dotfiles requires username
if [ -n "$DOTFILES_URL" ] && [ -z "$USERNAME" ]; then
	echo "Error: --dotfiles requires --user"
	exit 1
fi

# Check jq if JSON output requested
if ! require_jq_if_json "$OUTPUT_JSON"; then
	exit 1
fi

# Start logging
{
	echo "================================================"
	echo "VM Setup - $(get_iso8601_timestamp)"
	echo "================================================"
	echo "Hostname: ${HOSTNAME:-unchanged}"
	echo "User: ${USERNAME:-none}"
	echo "SSH key: ${SSH_KEY:+provided}"
	echo "Packages: ${PACKAGES:-none}"
	echo "Dotfiles: ${DOTFILES_URL:-none}"
	echo "Shell: $SHELL_PATH"
	echo "Dry run: $DRY_RUN"
	echo "No sudo: $NO_SUDO"
	echo "JSON output: $OUTPUT_JSON"
	echo "================================================"
} >>"$LOG_FILE"

# Detect OS
print_section "OS Detection"

if [ ! -f /etc/os-release ]; then
	print_error "Cannot detect OS: /etc/os-release not found"
	echo "This script requires a Linux distribution with /etc/os-release"
	exit 1
fi

# Parse /etc/os-release
source /etc/os-release
OS_DISTRO="${ID:-unknown}"
OS_LIKE="${ID_LIKE:-}"

print_info "Detected OS: $OS_DISTRO ${VERSION_ID:-} (${NAME:-})"

# Determine package manager
if command -v apt-get >/dev/null 2>&1; then
	PKG_MANAGER="apt"
	print_success "Package manager: apt-get"
elif command -v dnf >/dev/null 2>&1; then
	PKG_MANAGER="dnf"
	print_success "Package manager: dnf"
elif command -v yum >/dev/null 2>&1; then
	PKG_MANAGER="yum"
	print_success "Package manager: yum"
else
	print_error "No supported package manager found (apt-get, dnf, yum)"
	exit 1
fi

# Dry-run preview
if [ "$DRY_RUN" = true ]; then
	print_section "Dry Run - Preview"

	if [ -n "$HOSTNAME" ]; then
		echo "Would set hostname:"
		echo "  hostnamectl set-hostname $HOSTNAME"
		echo ""
	fi

	if [ -n "$USERNAME" ]; then
		echo "Would create user '$USERNAME':"
		echo "  useradd -m -s $SHELL_PATH $USERNAME"
		echo "  usermod -aG sudo $USERNAME  # (or wheel on RHEL)"
		echo ""

		if [ -n "$SSH_KEY" ]; then
			echo "Would add SSH key to ~$USERNAME/.ssh/authorized_keys"
			echo ""
		fi

		if [ "$SUDO_NOPASS" = true ]; then
			echo "Would configure passwordless sudo:"
			echo "  echo '$USERNAME ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$USERNAME"
			echo ""
		fi
	fi

	if [ -n "$PACKAGES" ]; then
		echo "Would install packages:"
		case "$PKG_MANAGER" in
		apt)
			echo "  apt-get update -y"
			echo "  apt-get install -y --no-install-recommends ${PACKAGES//,/ }"
			;;
		yum | dnf)
			echo "  $PKG_MANAGER install -y ${PACKAGES//,/ }"
			;;
		esac
		echo ""
	fi

	if [ -n "$DOTFILES_URL" ] && [ "$NO_DOTFILES" = false ]; then
		echo "Would clone dotfiles:"
		echo "  sudo -u $USERNAME git clone $DOTFILES_URL ~$USERNAME/dotfiles"
		echo ""
	fi

	print_success "Dry-run complete. Use without --dry-run to execute."
	exit 0
fi

# Check for sudo requirement
NEEDS_SUDO=false
if [ -n "$HOSTNAME" ] || [ -n "$USERNAME" ] || [ -n "$PACKAGES" ]; then
	NEEDS_SUDO=true
fi

if [ "$NEEDS_SUDO" = true ] && [ "$EUID" -ne 0 ]; then
	if [ "$NO_SUDO" = true ]; then
		print_warning "Running without sudo. Commands will be printed but not executed."
	else
		print_section "Sudo Requirement"
		print_warning "This script requires sudo for the following operations:"
		[ -n "$HOSTNAME" ] && echo "  • Setting hostname"
		[ -n "$USERNAME" ] && echo "  • Creating user and configuring sudo"
		[ -n "$PACKAGES" ] && echo "  • Installing packages"
		echo ""

		if [ "$AUTO_YES" = false ]; then
			read -p "Grant sudo privileges? [y/N] " -n 1 -r
			echo
			if [[ ! $REPLY =~ ^[Yy]$ ]]; then
				echo "Aborted by user"
				exit 1
			fi
		fi
	fi
fi

# Get current hostname
HOSTNAME_BEFORE=$(hostname)

# Set hostname
if [ -n "$HOSTNAME" ]; then
	print_section "Hostname Configuration"

	if [ "$HOSTNAME" = "$HOSTNAME_BEFORE" ]; then
		print_info "Hostname already set to: $HOSTNAME"
		HOSTNAME_AFTER="$HOSTNAME"
	else
		print_info "Changing hostname: $HOSTNAME_BEFORE → $HOSTNAME"

		if [ "$NO_SUDO" = true ]; then
			echo "Would run: sudo hostnamectl set-hostname $HOSTNAME"
		else
			if command -v hostnamectl >/dev/null 2>&1; then
				sudo hostnamectl set-hostname "$HOSTNAME" >>"$LOG_FILE" 2>&1
			else
				# Fallback for systems without hostnamectl
				echo "$HOSTNAME" | sudo tee /etc/hostname >/dev/null
				sudo hostname "$HOSTNAME"
			fi
			HOSTNAME_AFTER=$(hostname)
			print_success "Hostname set to: $HOSTNAME_AFTER"
		fi
	fi
fi

# Create user
if [ -n "$USERNAME" ]; then
	print_section "User Configuration"

	if id -u "$USERNAME" >/dev/null 2>&1; then
		print_info "User already exists: $USERNAME"
		USER_CREATED=false
	else
		print_info "Creating user: $USERNAME"

		if [ "$NO_SUDO" = true ]; then
			echo "Would run: sudo useradd -m -s $SHELL_PATH $USERNAME"
		else
			sudo useradd -m -s "$SHELL_PATH" "$USERNAME" >>"$LOG_FILE" 2>&1
			USER_CREATED=true
			print_success "User created: $USERNAME"
		fi
	fi

	# Add to sudo group
	SUDO_GROUP="sudo"
	if [[ "$OS_DISTRO" =~ ^(rhel|centos|fedora|rocky|alma)$ ]]; then
		SUDO_GROUP="wheel"
	fi

	print_info "Adding $USERNAME to $SUDO_GROUP group"
	if [ "$NO_SUDO" = true ]; then
		echo "Would run: sudo usermod -aG $SUDO_GROUP $USERNAME"
	else
		sudo usermod -aG "$SUDO_GROUP" "$USERNAME" >>"$LOG_FILE" 2>&1
		print_success "User added to $SUDO_GROUP group"
	fi

	# Configure passwordless sudo if requested
	if [ "$SUDO_NOPASS" = true ]; then
		print_warning "Configuring passwordless sudo (SECURITY: no password required)"
		SUDOERS_FILE="/etc/sudoers.d/$USERNAME"

		if [ "$NO_SUDO" = true ]; then
			echo "Would run: echo '$USERNAME ALL=(ALL) NOPASSWD:ALL' | sudo tee $SUDOERS_FILE"
		else
			echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" | sudo tee "$SUDOERS_FILE" >/dev/null
			sudo chmod 440 "$SUDOERS_FILE"
			print_success "Passwordless sudo configured"
		fi
	fi

	# Setup SSH key
	if [ -n "$SSH_KEY" ]; then
		print_section "SSH Key Setup"

		USER_HOME=$(eval echo "~$USERNAME")
		SSH_DIR="$USER_HOME/.ssh"
		AUTH_KEYS="$SSH_DIR/authorized_keys"

		print_info "Setting up SSH directory: $SSH_DIR"

		if [ "$NO_SUDO" = true ]; then
			echo "Would run:"
			echo "  sudo -u $USERNAME mkdir -p $SSH_DIR"
			echo "  sudo -u $USERNAME chmod 700 $SSH_DIR"
			echo "  echo '$SSH_KEY' | sudo -u $USERNAME tee -a $AUTH_KEYS"
			echo "  sudo -u $USERNAME chmod 600 $AUTH_KEYS"
		else
			# Create .ssh directory
			sudo -u "$USERNAME" mkdir -p "$SSH_DIR"
			sudo -u "$USERNAME" chmod 700 "$SSH_DIR"

			# Check if key already present
			if [ -f "$AUTH_KEYS" ] && grep -qF "$SSH_KEY" "$AUTH_KEYS" 2>/dev/null; then
				print_info "SSH key already present in authorized_keys"
				SSH_KEY_ADDED=false
			else
				# Add key
				echo "$SSH_KEY" | sudo -u "$USERNAME" tee -a "$AUTH_KEYS" >/dev/null
				sudo -u "$USERNAME" chmod 600 "$AUTH_KEYS"
				SSH_KEY_ADDED=true
				print_success "SSH key added to authorized_keys"
			fi
		fi
	fi
fi

# Install packages
if [ -n "$PACKAGES" ]; then
	print_section "Package Installation"

	# Convert to array
	IFS=',' read -ra PKG_ARRAY <<<"$PACKAGES"

	case "$PKG_MANAGER" in
	apt)
		print_info "Updating package lists..."
		if [ "$NO_SUDO" = true ]; then
			echo "Would run: sudo apt-get update -y"
		else
			sudo apt-get update -y >>"$LOG_FILE" 2>&1
			print_success "Package lists updated"
		fi

		for pkg in "${PKG_ARRAY[@]}"; do
			pkg=$(echo "$pkg" | xargs) # trim whitespace

			# Check if already installed
			if dpkg -s "$pkg" >/dev/null 2>&1; then
				print_info "Package already installed: $pkg"
			else
				print_info "Installing package: $pkg"
				if [ "$NO_SUDO" = true ]; then
					echo "Would run: sudo apt-get install -y --no-install-recommends $pkg"
				else
					if sudo apt-get install -y --no-install-recommends "$pkg" >>"$LOG_FILE" 2>&1; then
						PACKAGES_INSTALLED+=("$pkg")
						print_success "Installed: $pkg"
					else
						print_warning "Failed to install: $pkg"
					fi
				fi
			fi
		done
		;;

	yum | dnf)
		for pkg in "${PKG_ARRAY[@]}"; do
			pkg=$(echo "$pkg" | xargs) # trim whitespace

			# Check if already installed
			if rpm -q "$pkg" >/dev/null 2>&1; then
				print_info "Package already installed: $pkg"
			else
				print_info "Installing package: $pkg"
				if [ "$NO_SUDO" = true ]; then
					echo "Would run: sudo $PKG_MANAGER install -y $pkg"
				else
					if sudo "$PKG_MANAGER" install -y "$pkg" >>"$LOG_FILE" 2>&1; then
						PACKAGES_INSTALLED+=("$pkg")
						print_success "Installed: $pkg"
					else
						print_warning "Failed to install: $pkg"
					fi
				fi
			fi
		done
		;;
	esac
fi

# Clone dotfiles
if [ -n "$DOTFILES_URL" ] && [ "$NO_DOTFILES" = false ]; then
	print_section "Dotfiles Setup"

	# Check if git is available
	if ! command -v git >/dev/null 2>&1; then
		print_warning "git not found. Install git to clone dotfiles."
	else
		USER_HOME=$(eval echo "~$USERNAME")
		DOTFILES_DIR="$USER_HOME/dotfiles"

		if [ -d "$DOTFILES_DIR" ]; then
			print_info "Dotfiles directory already exists: $DOTFILES_DIR"
		else
			print_info "Cloning dotfiles from: $DOTFILES_URL"

			if [ "$NO_SUDO" = true ]; then
				echo "Would run: sudo -u $USERNAME git clone $DOTFILES_URL $DOTFILES_DIR"
			else
				if sudo -u "$USERNAME" git clone "$DOTFILES_URL" "$DOTFILES_DIR" >>"$LOG_FILE" 2>&1; then
					DOTFILES_CLONED=true
					print_success "Dotfiles cloned to: $DOTFILES_DIR"
					print_info "Run setup script manually from $DOTFILES_DIR if needed"
				else
					print_warning "Failed to clone dotfiles"
				fi
			fi
		fi
	fi
fi

# Summary
print_section "Summary"

echo "Hostname: ${HOSTNAME_BEFORE:-unchanged} ${HOSTNAME_AFTER:+→ $HOSTNAME_AFTER}"
[ -n "$USERNAME" ] && echo "User: $USERNAME (created: $USER_CREATED)"
[ -n "$SSH_KEY" ] && echo "SSH key: ${SSH_KEY_ADDED:+added}"
echo "Packages installed: ${#PACKAGES_INSTALLED[@]}"
[ -n "$DOTFILES_URL" ] && echo "Dotfiles: ${DOTFILES_CLONED:+cloned}"
echo "Warnings: ${#WARNINGS[@]}"

# JSON output
if [ "$OUTPUT_JSON" = true ]; then
	{
		echo "{"
		echo "  \"timestamp\": \"$(get_iso8601_timestamp)\","
		echo "  \"distro\": \"$OS_DISTRO\","
		echo "  \"package_manager\": \"$PKG_MANAGER\","
		echo "  \"hostname_before\": \"${HOSTNAME_BEFORE:-}\","
		echo "  \"hostname_after\": \"${HOSTNAME_AFTER:-$HOSTNAME_BEFORE}\","
		echo "  \"user\": \"${USERNAME:-}\","
		echo "  \"user_created\": $USER_CREATED,"
		echo "  \"ssh_key_added\": $SSH_KEY_ADDED,"
		echo "  \"packages_installed\": ["

		FIRST=true
		for pkg in "${PACKAGES_INSTALLED[@]}"; do
			if [ "$FIRST" = false ]; then
				echo "    ,"
			fi
			FIRST=false
			echo -n "    \"$pkg\""
		done
		echo ""
		echo "  ],"

		echo "  \"dotfiles_cloned\": ${DOTFILES_CLONED:-false},"
		echo "  \"dotfiles_url\": \"${DOTFILES_URL:-}\","
		echo "  \"warnings\": ["

		FIRST=true
		for warning in "${WARNINGS[@]}"; do
			if [ "$FIRST" = false ]; then
				echo "    ,"
			fi
			FIRST=false
			# Escape double quotes in warning message
			ESC_WARNING=$(echo "$warning" | sed 's/"/\\"/g')
			echo -n "    \"$ESC_WARNING\""
		done
		echo ""
		echo "  ],"

		echo "  \"log_file\": \"$LOG_FILE\""
		echo "}"
	} >"$JSON_FILE"
	chmod 600 "$JSON_FILE"
	print_success "JSON summary written to: $JSON_FILE"
fi

# Exit with appropriate code
if [ ${#WARNINGS[@]} -gt 0 ]; then
	exit 1
else
	exit 0
fi
