#!/bin/bash

################################################################################
# Update All - Comprehensive System Update Script
################################################################################
# Description: Updates all package managers and system components
# Usage: ./update-all.sh [--dry-run] [-y|--yes]
################################################################################

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Defaults
DRY_RUN=0
AUTO_YES=0
ALLOW_PIP_SYSTEM=${ALLOW_PIP_SYSTEM:-0}
SHOW_CONFIG=0

# Config precedence: defaults < system < user < env < CLI
load_script_config_chain "update-all"
apply_env_overrides "UPDATE_ALL_" DRY_RUN AUTO_YES ALLOW_PIP_SYSTEM

# Normalize string booleans from config/env to integers
case "$DRY_RUN" in true | TRUE | yes | YES) DRY_RUN=1 ;; false | FALSE | no | NO) DRY_RUN=0 ;; esac
case "$AUTO_YES" in true | TRUE | yes | YES) AUTO_YES=1 ;; false | FALSE | no | NO) AUTO_YES=0 ;; esac
case "$ALLOW_PIP_SYSTEM" in true | TRUE | yes | YES) ALLOW_PIP_SYSTEM=1 ;; false | FALSE | no | NO) ALLOW_PIP_SYSTEM=0 ;; esac

while [[ $# -gt 0 ]]; do
	case "$1" in
	--dry-run)
		DRY_RUN=1
		shift
		;;
	-y | --yes)
		AUTO_YES=1
		shift
		;;
	--pip-system)
		ALLOW_PIP_SYSTEM=1
		shift
		;;
	--show-config)
		SHOW_CONFIG=1
		shift
		;;
	--help | -h)
		echo "Usage: $0 [options]"
		echo ""
		echo "Options:"
		echo "  --dry-run      Show what would be updated without making changes"
		echo "  -y, --yes      Skip confirmation prompts"
		echo "  --pip-system   Allow system-wide pip updates (uses --break-system-packages)"
		echo "  --show-config  Print effective config and exit"
		echo "  --help, -h     Show this help message"
		exit 0
		;;
	*)
		echo "Unknown option: $1"
		echo "Run '$0 --help' for usage"
		exit 1
		;;
	esac
done

if [ "$SHOW_CONFIG" -eq 1 ]; then
	echo "DRY_RUN=$DRY_RUN"
	echo "AUTO_YES=$AUTO_YES"
	echo "ALLOW_PIP_SYSTEM=$ALLOW_PIP_SYSTEM"
	exit 0
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Disable colors when not attached to a TTY to avoid TERM issues
if [ ! -t 1 ]; then
	RED=''
	GREEN=''
	YELLOW=''
	BLUE=''
	CYAN=''
	MAGENTA=''
	BOLD=''
	DIM=''
	NC=''
fi

LOGS_DIR="$SCRIPT_DIR/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOGS_DIR/update_${TIMESTAMP}.log"
LOCK_FILE="$LOGS_DIR/.locks/update-all.lock"

# Ensure new log files default to 600.
umask 077

# Create logs directory
mkdir -p "$LOGS_DIR"
chmod 700 "$LOGS_DIR" 2>/dev/null || true

if ! acquire_lock "$LOCK_FILE" 86400; then
	echo "Another update-all run is already active (lock: $LOCK_FILE)."
	exit 3
fi
cleanup_on_exit() {
	release_lock "$LOCK_FILE"
}
trap cleanup_on_exit EXIT INT TERM

# Clear screen (interactive only)
[ -t 1 ] && clear

# Header
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${BOLD}${BLUE}🔄 Update All${NC} ${DIM}v1.0${NC}"
echo -e "  ${DIM}System-wide package updates${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ "$DRY_RUN" -eq 1 ]; then
	echo -e "${YELLOW}⚠  DRY RUN MODE${NC} ${DIM}→ no changes will be made${NC}"
	echo ""
fi

# Detection phase
echo -e "${DIM}[${NC}${CYAN}*${NC}${DIM}] Detecting package managers...${NC}"
echo ""

managers=()
managers_found=0

# Check Homebrew
if command -v brew &>/dev/null; then
	managers+=("brew")
	managers_found=$((managers_found + 1))
	echo -e "${DIM}[${NC}${GREEN}✓${NC}${DIM}] Homebrew → ${NC}$(brew --version | head -1)"
fi

# Check NPM
if command -v npm &>/dev/null; then
	managers+=("npm")
	managers_found=$((managers_found + 1))
	echo -e "${DIM}[${NC}${GREEN}✓${NC}${DIM}] NPM → ${NC}v$(npm --version)"
fi

# Check pnpm
if command -v pnpm &>/dev/null; then
	managers+=("pnpm")
	managers_found=$((managers_found + 1))
	echo -e "${DIM}[${NC}${GREEN}✓${NC}${DIM}] pnpm → ${NC}$(pnpm --version)"
fi

# Check pip
if command -v pip3 &>/dev/null; then
	managers+=("pip")
	managers_found=$((managers_found + 1))
	echo -e "${DIM}[${NC}${GREEN}✓${NC}${DIM}] pip → ${NC}$(pip3 --version | awk '{print $2}')"
fi

# Check gem
if command -v gem &>/dev/null; then
	managers+=("gem")
	managers_found=$((managers_found + 1))
	echo -e "${DIM}[${NC}${GREEN}✓${NC}${DIM}] RubyGems → ${NC}$(gem --version)"
fi

# Check macOS Software Update
if command -v softwareupdate &>/dev/null; then
	managers+=("macos")
	managers_found=$((managers_found + 1))
	echo -e "${DIM}[${NC}${GREEN}✓${NC}${DIM}] macOS Software Update${NC}"
fi

echo ""
echo -e "${DIM}[${NC}${BOLD}${managers_found}${NC}${DIM}] package managers detected${NC}"
if [ ${#managers[@]} -gt 0 ]; then
	echo -e "${DIM}Managers:${NC} ${managers[*]}"
fi
echo ""

if [ "$managers_found" -eq 0 ]; then
	echo -e "${RED}✗${NC} No package managers found"
	exit 1
fi

# Ask for confirmation unless --yes
if [ "$AUTO_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
	echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
	echo -e "${BOLD}${YELLOW}▸ READY TO UPDATE${NC}"
	echo ""
	echo -ne "${DIM}Continue with updates? [${NC}${GREEN}y${NC}${DIM}/${NC}${RED}N${NC}${DIM}]${NC} "
	read -r confirm
	echo ""

	if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
		echo -e "${BLUE}ℹ${NC} Cancelled"
		exit 0
	fi
fi

echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Starting updates...${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo ""

# Start logging
echo "Update All - Started at $(date)" >"$LOG_FILE"
echo "Managers detected: ${managers[*]}" >>"$LOG_FILE"
echo "" >>"$LOG_FILE"

update_counter=0
PIP_SKIPPED=0
failed_updates=()

# Update Homebrew
if [[ " ${managers[*]} " =~ " brew " ]]; then
	echo -e "${DIM}[${NC}${CYAN}→${NC}${DIM}] Updating Homebrew...${NC}"

	if [ "$DRY_RUN" -eq 1 ]; then
		echo -e "  ${DIM}Would run: brew update && brew upgrade && brew cleanup${NC}"
	else
		{
			echo "=== Homebrew Update ===" >>"$LOG_FILE"
			brew update 2>&1 | tee -a "$LOG_FILE" | grep -E "(Already up-to-date|Updated|Updating)"
			echo ""

			outdated=$(brew outdated | wc -l | tr -d ' ')
			if [ "$outdated" -gt 0 ]; then
				echo -e "  ${DIM}Found ${NC}${BOLD}$outdated${NC}${DIM} outdated package(s)${NC}"
				brew upgrade 2>&1 | tee -a "$LOG_FILE" | grep -E "(Upgrading|Installed|upgraded)"
				echo ""
			else
				echo -e "  ${GREEN}✓${NC} All packages up to date"
			fi

			brew cleanup >>"$LOG_FILE" 2>&1
		} && {
			echo -e "${DIM}[${NC}${GREEN}✓${NC}${DIM}] Homebrew updated${NC}"
			update_counter=$((update_counter + 1))
		} || {
			echo -e "${DIM}[${NC}${RED}✗${NC}${DIM}] Homebrew update failed${NC}"
			failed_updates+=("Homebrew")
		}
	fi
	echo ""
fi

# Update NPM global packages
if [[ " ${managers[*]} " =~ " npm " ]]; then
	echo -e "${DIM}[${NC}${CYAN}→${NC}${DIM}] Updating NPM global packages...${NC}"

	if [ "$DRY_RUN" -eq 1 ]; then
		outdated_count=$(npm outdated -g --depth=0 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
		echo -e "  ${DIM}Would run: npm update -g${NC} ${DIM}(outdated: ${outdated_count:-0})${NC}"
	else
		{
			echo "=== NPM Global Update ===" >>"$LOG_FILE"
			outdated=$(npm outdated -g --depth=0 2>/dev/null | wc -l | tr -d ' ')

			if [ "$outdated" -gt 1 ]; then # Header counts as 1
				echo -e "  ${DIM}Found outdated global packages${NC}"
				npm update -g 2>&1 | tee -a "$LOG_FILE" | grep -v "^$"
			else
				echo -e "  ${GREEN}✓${NC} All global packages up to date"
			fi
		} && {
			echo -e "${DIM}[${NC}${GREEN}✓${NC}${DIM}] NPM updated${NC}"
			update_counter=$((update_counter + 1))
		} || {
			echo -e "${DIM}[${NC}${RED}✗${NC}${DIM}] NPM update failed${NC}"
			failed_updates+=("NPM")
		}
	fi
	echo ""
fi

# Update pnpm
if [[ " ${managers[*]} " =~ " pnpm " ]]; then
	echo -e "${DIM}[${NC}${CYAN}→${NC}${DIM}] Updating pnpm...${NC}"

	if [ "$DRY_RUN" -eq 1 ]; then
		echo -e "  ${DIM}Would run: pnpm add -g pnpm${NC}"
	else
		{
			echo "=== pnpm Update ===" >>"$LOG_FILE"
			pnpm add -g pnpm 2>&1 | tee -a "$LOG_FILE" | grep -E "(Progress|Success|Already)"
		} && {
			echo -e "${DIM}[${NC}${GREEN}✓${NC}${DIM}] pnpm updated${NC}"
			update_counter=$((update_counter + 1))
		} || {
			echo -e "${DIM}[${NC}${RED}✗${NC}${DIM}] pnpm update failed${NC}"
			failed_updates+=("pnpm")
		}
	fi
	echo ""
fi

# Update pip
if [[ " ${managers[*]} " =~ " pip " ]]; then
	echo -e "${DIM}[${NC}${CYAN}→${NC}${DIM}] Updating pip packages...${NC}"

	# Detect externally managed environment (PEP 668)
	EXTERNALLY_MANAGED=0
	if ls /usr/lib/python*/EXTERNALLY-MANAGED >/dev/null 2>&1 || ls /usr/lib/python3*/EXTERNALLY-MANAGED >/dev/null 2>&1; then
		EXTERNALLY_MANAGED=1
	fi

	if [ "$DRY_RUN" -eq 1 ]; then
		if [ "$EXTERNALLY_MANAGED" -eq 1 ] && [ "$ALLOW_PIP_SYSTEM" -ne 1 ]; then
			echo -e "  ${YELLOW}⚠${NC} Externally managed Python detected (PEP 668). Skipping system pip updates."
			echo -e "  ${DIM}Tip:${NC} It is strongly recommended to use a virtual environment (e.g., venv, conda) to manage Python packages."
			echo -e "  ${DIM}If you are sure you want to modify the system Python, re-run with ${BOLD}--pip-system${NC} to override (uses --break-system-packages)."
			PIP_SKIPPED=1
		else
			echo -e "  ${DIM}Would run: pip3 list --outdated | pip3 install -U <packages>${NC}"
		fi
	else
		if [ "$EXTERNALLY_MANAGED" -eq 1 ] && [ "$ALLOW_PIP_SYSTEM" -ne 1 ]; then
			echo -e "  ${YELLOW}⚠${NC} Externally managed Python detected (PEP 668). Skipping system pip updates."
			echo -e "  ${DIM}Tip:${NC} It is strongly recommended to use a virtual environment (e.g., venv, conda) to manage Python packages."
			echo -e "  ${DIM}If you are sure you want to modify the system Python, re-run with ${BOLD}--pip-system${NC} to override (uses --break-system-packages)."
			PIP_SKIPPED=1
		else
			{
				echo "=== pip Update ===" >>"$LOG_FILE"

				# Build flags array for PEP 668 override
				pip_flags=()
				if [ "$ALLOW_PIP_SYSTEM" -eq 1 ]; then
					pip_flags+=(--break-system-packages)
				fi

				# Update pip itself first
				pip3 install --upgrade "${pip_flags[@]}" pip >>"$LOG_FILE" 2>&1

				# Get list of outdated packages
				outdated=$(pip3 list --outdated 2>/dev/null | tail -n +3 | awk '{print $1}')

				if [ -n "$outdated" ]; then
					count=$(echo "$outdated" | wc -l | tr -d ' ')
					echo -e "  ${DIM}Found ${NC}${BOLD}$count${NC}${DIM} outdated package(s)${NC}"
					echo "$outdated" | while IFS= read -r pkg; do
						echo -e "  ${CYAN}•${NC} Upgrading $pkg..."
						pip3 install --upgrade "${pip_flags[@]}" "$pkg" >>"$LOG_FILE" 2>&1
					done
				else
					echo -e "  ${GREEN}✓${NC} All packages up to date"
				fi
			} && {
				echo -e "${DIM}[${NC}${GREEN}✓${NC}${DIM}] pip updated${NC}"
				update_counter=$((update_counter + 1))
			} || {
				echo -e "${DIM}[${NC}${RED}✗${NC}${DIM}] pip update failed${NC}"
				failed_updates+=("pip")
			}
		fi
	fi
	echo ""
fi

# Update RubyGems
if [[ " ${managers[*]} " =~ " gem " ]]; then
	echo -e "${DIM}[${NC}${CYAN}→${NC}${DIM}] Updating RubyGems...${NC}"

	if [ "$DRY_RUN" -eq 1 ]; then
		echo -e "  ${DIM}Would run: gem update --system && gem update${NC}"
	else
		{
			echo "=== RubyGems Update ===" >>"$LOG_FILE"

			# Update RubyGems itself
			gem update --system >>"$LOG_FILE" 2>&1

			# Update all gems
			outdated=$(gem outdated 2>/dev/null | wc -l | tr -d ' ')
			if [ "$outdated" -gt 0 ]; then
				echo -e "  ${DIM}Found ${NC}${BOLD}$outdated${NC}${DIM} outdated gem(s)${NC}"
				gem update 2>&1 | tee -a "$LOG_FILE" | grep "Updating"
			else
				echo -e "  ${GREEN}✓${NC} All gems up to date"
			fi
		} && {
			echo -e "${DIM}[${NC}${GREEN}✓${NC}${DIM}] RubyGems updated${NC}"
			update_counter=$((update_counter + 1))
		} || {
			echo -e "${DIM}[${NC}${RED}✗${NC}${DIM}] RubyGems update failed${NC}"
			failed_updates+=("RubyGems")
		}
	fi
	echo ""
fi

# Update macOS
if [[ " ${managers[*]} " =~ " macos " ]]; then
	echo -e "${DIM}[${NC}${CYAN}→${NC}${DIM}] Checking macOS updates...${NC}"

	if [ "$DRY_RUN" -eq 1 ]; then
		echo -e "  ${DIM}Would run: softwareupdate -l${NC}"
	else
		{
			echo "=== macOS Update ===" >>"$LOG_FILE"

			# List available updates
			updates=$(softwareupdate -l 2>&1)

			if echo "$updates" | grep -q "No new software available"; then
				echo -e "  ${GREEN}✓${NC} macOS is up to date"
			else
				count=$(echo "$updates" | grep -c "recommended" || echo 0)
				if [ "$count" -gt 0 ]; then
					echo -e "  ${YELLOW}⚠${NC} ${BOLD}$count${NC} update(s) available"
					echo -e "  ${DIM}Run 'softwareupdate -ia' to install${NC}"
					echo "$updates" >>"$LOG_FILE"
				fi
			fi
		} && {
			echo -e "${DIM}[${NC}${GREEN}✓${NC}${DIM}] macOS checked${NC}"
			update_counter=$((update_counter + 1))
		} || {
			echo -e "${DIM}[${NC}${RED}✗${NC}${DIM}] macOS check failed${NC}"
			failed_updates+=("macOS")
		}
	fi
	echo ""
fi

# Summary
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  UPDATE SUMMARY${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo ""

if [ "$DRY_RUN" -eq 1 ]; then
	echo -e "  ${YELLOW}⚠${NC} ${BOLD}Dry run completed${NC} ${DIM}(no changes made)${NC}"
	echo -e "  ${DIM}Would have updated ${BOLD}${managers_found}${NC}${DIM} package managers${NC}"
	if [ "$PIP_SKIPPED" -eq 1 ]; then
		echo -e "  ${DIM}Skipped pip:${NC} externally managed (PEP 668). Use --pip-system to override, or apt/venv."
	fi
else
	echo -e "  ${GREEN}✓${NC} ${BOLD}${update_counter}${NC} of ${BOLD}${managers_found}${NC} package managers updated"

	if [ "${#failed_updates[@]}" -gt 0 ]; then
		echo -e "  ${RED}✗${NC} ${BOLD}${#failed_updates[@]}${NC} failed: ${failed_updates[*]}"
	fi

	echo ""
	echo -e "  ${DIM}📝 Full log: $LOG_FILE${NC}"
fi

echo ""
echo "Update completed at $(date)" >>"$LOG_FILE"

exit 0
