#!/usr/bin/env bash
# common.sh - Shared functions for homelab scripts
# Version: 1.2.1
# Source this file: source "${SCRIPT_DIR}/lib/common.sh"

# Get ISO8601 timestamp (BSD/GNU compatible)
# Usage: timestamp=$(get_iso8601_timestamp)
get_iso8601_timestamp() {
	# Try GNU date first (Linux, macOS with coreutils)
	if date -Iseconds >/dev/null 2>&1; then
		date -Iseconds
	# Fall back to BSD date (macOS default)
	elif date -u +"%Y-%m-%dT%H:%M:%SZ" >/dev/null 2>&1; then
		date -u +"%Y-%m-%dT%H:%M:%SZ"
	# Last resort: basic ISO format without timezone
	else
		date -u +"%Y-%m-%dT%H:%M:%S"
	fi
}

# Check if jq is required and available
# Usage: require_jq_if_json "$OUTPUT_JSON"
# Returns: 0 if jq available or not needed, 1 if required but missing
require_jq_if_json() {
	local json_enabled="${1:-false}"

	if [ "$json_enabled" = true ]; then
		if ! command -v jq >/dev/null 2>&1; then
			echo "Error: jq not found. Install jq for --json output (brew install jq / apt install jq)" >&2
			return 1
		fi
	fi
	return 0
}

# Print colored status messages
# Usage: print_status "success" "Message" or print_status "error" "Message"
print_status() {
	local status="$1"
	local message="$2"
	local RED='\033[0;31m'
	local GREEN='\033[0;32m'
	local YELLOW='\033[1;33m'
	local BLUE='\033[0;34m'
	local NC='\033[0m'

	case "$status" in
		success)
			echo -e "${GREEN}✓${NC} $message"
			;;
		error)
			echo -e "${RED}✗ Error:${NC} $message" >&2
			;;
		warning)
			echo -e "${YELLOW}⚠${NC} $message"
			;;
		info)
			echo -e "${BLUE}ℹ${NC} $message"
			;;
		*)
			echo "$message"
			;;
	esac
}

# Validate output directory path (security)
# Usage: validate_output_dir "/path/to/dir"
# Returns: 0 if valid, exits with error if invalid
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
			echo "Error: Path contains traversal sequences and cannot be validated" >&2
			echo "       Rejecting for safety: $dir" >&2
			return 1
		fi
		canonical="$dir"
	fi

	# Block system directories
	local blocked_prefixes=("/usr" "/etc" "/var" "/bin" "/sbin" "/boot" "/sys" "/proc" "/dev")
	for prefix in "${blocked_prefixes[@]}"; do
		if [[ "$canonical" == "$prefix"* ]]; then
			echo "Error: Output directory cannot be in system directory: $prefix" >&2
			echo "       Use a directory under \$HOME instead" >&2
			echo "       Example: $HOME/backups" >&2
			return 1
		fi
	done

	# Require path to be under $HOME or relative
	if [[ "$canonical" != "$HOME"* ]] && [[ "$canonical" != "."* ]] && [[ "$canonical" != "./"* ]]; then
		echo "Error: Output directory must be under \$HOME for safety" >&2
		echo "       Provided: $canonical" >&2
		echo "       Required: Under $HOME" >&2
		echo "       Example: $HOME/backups" >&2
		return 1
	fi

	return 0
}

# Check Docker helper image availability
# Usage: ensure_docker_image "alpine:latest"
# Returns: 0 if available or pulled successfully, 1 on failure
ensure_docker_image() {
	local image="${1:-alpine:latest}"
	local log_file="${2:-/dev/null}"

	if ! docker image inspect "$image" >/dev/null 2>&1; then
		echo "ℹ Pulling $image for backup operations..." >&2
		if ! docker pull "$image" >>"$log_file" 2>&1; then
			echo "✗ Error: Failed to pull $image (required for backups)" >&2
			return 1
		fi
		echo "✓ $image pulled" >&2
	fi
	return 0
}
