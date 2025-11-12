#!/bin/bash

################################################################################
# Smart Cleanup - Intelligent System Maintenance
################################################################################
# Description: Shows concise analysis and recommendations
# Usage: ./smart-cleanup.sh [--auto-best|--auto-full|--status]
################################################################################

set -u

# Parse command line arguments
AUTO_MODE=""
STATUS_ONLY=0
PROFILE=""
CLEAN_VENVS=0
SCAN_VENVS=0
VENV_ROOTS=""
VENV_MIN_AGE_DAYS=""
VENV_MIN_GB=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto-best)
            AUTO_MODE="best"
            shift
            ;;
        --auto-full)
            AUTO_MODE="full"
            shift
            ;;
        --status)
            STATUS_ONLY=1
            shift
            ;;
        --profile)
            PROFILE="$2"
            shift 2
            ;;
        --clean-venvs)
            CLEAN_VENVS=1
            shift
            ;;
        --scan-venvs)
            SCAN_VENVS=1
            shift
            ;;
        --venv-roots)
            VENV_ROOTS="$2"
            shift 2
            ;;
        --venv-age)
            VENV_MIN_AGE_DAYS="$2"
            shift 2
            ;;
        --venv-min-gb)
            VENV_MIN_GB="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --auto-best        Automatically run quick cleanup (skip git gc)"
            echo "  --auto-full        Automatically run full cleanup (with git gc)"
            echo "  --status           Show what can be cleaned and exit"
            echo "  --profile <name>   Use cleanup profile: quick|thorough|emergency"
            echo "  --help, -h         Show this help message"
            echo ""
            echo "Venv cleanup options (passed to disk-cleanup.sh):"
            echo "  --scan-venvs       Scan and report virtualenv sizes"
            echo "  --clean-venvs      Remove stale virtualenvs by thresholds"
            echo "  --venv-roots \"PATHS\"  Space-separated roots to scan"
            echo "  --venv-age DAYS    Minimum age in days (default 30)"
            echo "  --venv-min-gb GB   Minimum size in GB (default 0.5)"
            echo ""
            echo "Profiles:"
            echo "  quick      Fast cleanup (~2-3 min): Docker, caches, skip git gc"
            echo "  thorough   Deep cleanup (~3-6 hrs): Everything including git gc"
            echo "  emergency  Ultra-fast (~30 sec): Docker only, no confirmations"
            echo ""
            echo "Examples:"
            echo "  $0 --status                      # Check what can be cleaned"
            echo "  $0 --auto-best                   # Quick cleanup (skip git gc)"
            echo "  $0 --auto-full                   # Full cleanup with git gc"
            echo "  $0 --scan-venvs                  # Scan Python virtualenvs"
            echo "  $0 --clean-venvs --venv-age 60   # Clean venvs older than 60 days"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run '$0 --help' for usage"
            exit 1
            ;;
    esac
done

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP_SCRIPT="$SCRIPT_DIR/disk-cleanup.sh"
LOGS_DIR="$SCRIPT_DIR/logs"
TEMP_LOG="$LOGS_DIR/smart_cleanup_$$.log"

# Create logs directory if it doesn't exist
mkdir -p "$LOGS_DIR"

# Cleanup temp file on exit
trap 'rm -f "$TEMP_LOG"' EXIT

if [ ! -f "$CLEANUP_SCRIPT" ]; then
    echo -e "${RED}✗${NC} Cleanup script not found: $CLEANUP_SCRIPT"
    exit 1
fi

# Helper function to convert size strings to MB for calculation
size_to_mb() {
    local size="$1"
    local value=$(echo "$size" | grep -oE '[0-9.]+')
    local unit=$(echo "$size" | grep -oE '[KMGT]B')

    case "$unit" in
        KB) awk "BEGIN {printf \"%.2f\", $value / 1024}" ;;
        MB) echo "$value" ;;
        GB) awk "BEGIN {printf \"%.2f\", $value * 1024}" ;;
        TB) awk "BEGIN {printf \"%.2f\", $value * 1024 * 1024}" ;;
        *) echo "0" ;;
    esac
}

# Helper function to format MB back to human readable
mb_to_human() {
    local mb=$1
    if awk "BEGIN {exit !($mb >= 1024)}"; then
        awk "BEGIN {printf \"%.2fGB\", $mb / 1024}"
    else
        awk "BEGIN {printf \"%.0fMB\", $mb}"
    fi
}

# Helper function to read a single character without waiting for Enter
read_single_char() {
    local prompt="$1"
    local valid_chars="$2"
    local timeout_secs=30

    # Print prompt to stderr so it doesn't interfere with return value
    echo -ne "$prompt" >&2

    # Save terminal settings
    local old_tty_settings=$(stty -g)

    # Set up timeout handler using a background sleep + trap
    local timed_out=0
    (
        sleep "$timeout_secs"
        # Send signal to parent if still running
        kill -ALRM $$ 2>/dev/null
    ) &
    local timeout_pid=$!

    # Trap ALRM signal for timeout
    trap 'timed_out=1' ALRM

    # Set terminal to raw mode (no echo, no line buffering)
    stty -icanon -echo min 1 time 0 2>/dev/null || true

    local char=""
    while [ "$timed_out" -eq 0 ]; do
        # Try to read with short timeout to check timed_out flag
        char=$(dd bs=1 count=1 2>/dev/null || echo "")

        # Handle EOF (Ctrl+D or non-interactive)
        if [ -z "$char" ] && [ ! -t 0 ]; then
            # Non-interactive or EOF: default to abort
            char="4"
            break
        fi

        # Check if character is valid
        if [ -n "$char" ] && [[ "$valid_chars" == *"$char"* ]]; then
            break
        fi
    done

    # Kill timeout background process if still running
    kill "$timeout_pid" 2>/dev/null
    wait "$timeout_pid" 2>/dev/null || true

    # Reset trap
    trap - ALRM

    # Restore terminal settings
    stty "$old_tty_settings" 2>/dev/null || true

    # If timed out, default to abort
    if [ "$timed_out" -eq 1 ]; then
        char="4"  # Abort option
        echo -e "${YELLOW}[timeout]${NC}" >&2
    else
        # Echo the character for visual feedback to stderr
        echo -e "${GREEN}$char${NC}" >&2
    fi
    echo "" >&2

    # Return ONLY the character to stdout (this is captured by the caller)
    echo -n "$char"
}

# Helper function to show progress bar with ETA
show_progress_bar() {
    local current=$1
    local total=$2
    local task_name=$3
    local start_time=${4:-$(date +%s)}

    local width=40
    local percentage=$((current * 100 / total))
    local completed=$((width * current / total))

    # Calculate ETA
    local elapsed=$(($(date +%s) - start_time))
    local eta=0
    if [ "$current" -gt 0 ]; then
        local avg_time=$((elapsed / current))
        eta=$(( (total - current) * avg_time ))
    fi

    # Format ETA
    local eta_str=""
    if [ "$eta" -gt 3600 ]; then
        eta_str="~$((eta / 3600))h $((eta % 3600 / 60))m"
    elif [ "$eta" -gt 60 ]; then
        eta_str="~$((eta / 60))m $((eta % 60))s"
    else
        eta_str="~${eta}s"
    fi

    # Draw progress bar
    printf "\r  ["
    printf "%${completed}s" | tr ' ' '█'
    printf "%$((width - completed))s" | tr ' ' '░'
    printf "] %3d%% " "$percentage"
    printf "(%d/%d) " "$current" "$total"
    [ "$current" -lt "$total" ] && printf "${DIM}ETA: %s${NC}" "$eta_str"
    [ "$current" -eq "$total" ] && printf "${GREEN}✓${NC}"
}

# Interactive menu for cleanup selection
show_interactive_menu() {
    local -n items=$1  # Array of items: "name|size|time|selected"

    # Check if terminal supports interactive mode
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        return 1  # Fall back to simple mode
    fi

    local selected=0
    local cursor=0

    while true; do
        # Clear screen and redraw
        clear
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  ${BOLD}${BLUE}🧹 SELECT CLEANUP OPERATIONS${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""

        local total_size_mb=0
        local total_time_sec=0
        local item_count=0

        # Display all items
        for i in "${!items[@]}"; do
            IFS='|' read -r name size time checked <<< "${items[$i]}"

            # Highlight current cursor position
            local prefix="  "
            if [ "$i" -eq "$cursor" ]; then
                prefix="${BOLD}${YELLOW}▶${NC} "
            fi

            # Checkbox state
            local checkbox="[ ]"
            if [ "$checked" = "1" ]; then
                checkbox="${GREEN}[✓]${NC}"
                # Calculate totals
                size_mb=$(size_to_mb "$size")
                total_size_mb=$(awk "BEGIN {printf \"%.2f\", $total_size_mb + $size_mb}")
                total_time_sec=$((total_time_sec + time))
                item_count=$((item_count + 1))
            fi

            # Risk indicator
            local risk_icon="${GREEN}●${NC}"
            if [[ "$time" -gt 600 ]]; then
                risk_icon="${YELLOW}●${NC}"
            fi
            if [[ "$time" -gt 3600 ]]; then
                risk_icon="${RED}●${NC}"
            fi

            # Format time
            local time_str="⚡ Fast"
            if [ "$time" -gt 3600 ]; then
                time_str="⏰ $(($time / 3600))h"
            elif [ "$time" -gt 60 ]; then
                time_str="⏱  $(($time / 60))m"
            else
                time_str="⚡ ${time}s"
            fi

            printf "${prefix}${checkbox} ${BOLD}%-20s${NC} ${DIM}→${NC} %-8s %-12s ${risk_icon}\n" \
                "$name" "$size" "$time_str"
        done

        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

        # Format total time
        local total_time_str="$((total_time_sec))s"
        if [ "$total_time_sec" -gt 3600 ]; then
            total_time_str="~$((total_time_sec / 3600))h $((total_time_sec % 3600 / 60))m"
        elif [ "$total_time_sec" -gt 60 ]; then
            total_time_str="~$((total_time_sec / 60))m"
        fi

        local total_size_str=$(mb_to_human "$total_size_mb")
        echo -e "  ${BOLD}Selected:${NC} $item_count items • ${GREEN}${total_size_str}${NC} • ${DIM}~${total_time_str}${NC}"
        echo ""
        echo -e "  ${DIM}[${NC}${BOLD}Space${NC}${DIM}] Toggle  [${NC}${BOLD}↑↓${NC}${DIM}] Navigate  [${NC}${BOLD}A${NC}${DIM}] All  [${NC}${BOLD}N${NC}${DIM}] None  [${NC}${BOLD}Enter${NC}${DIM}] Proceed  [${NC}${BOLD}Q${NC}${DIM}] Quit${NC}"
        echo ""

        # Read single key
        local old_tty=$(stty -g)
        stty -icanon -echo min 1 time 0
        local key=$(dd bs=1 count=1 2>/dev/null | od -An -tu1 | tr -d ' ')
        stty "$old_tty"

        case "$key" in
            27)  # Escape sequence (arrow keys)
                dd bs=2 count=1 2>/dev/null | read -r
                local arrow=$(dd bs=1 count=1 2>/dev/null | od -An -tu1 | tr -d ' ')
                case "$arrow" in
                    65) cursor=$((cursor > 0 ? cursor - 1 : ${#items[@]} - 1)) ;;  # Up
                    66) cursor=$(((cursor + 1) % ${#items[@]})) ;;  # Down
                esac
                ;;
            32)  # Space - toggle
                IFS='|' read -r name size time checked <<< "${items[$cursor]}"
                checked=$((1 - checked))
                items[$cursor]="$name|$size|$time|$checked"
                ;;
            65|97)  # A/a - select all
                for i in "${!items[@]}"; do
                    IFS='|' read -r name size time checked <<< "${items[$i]}"
                    items[$i]="$name|$size|$time|1"
                done
                ;;
            78|110)  # N/n - select none
                for i in "${!items[@]}"; do
                    IFS='|' read -r name size time checked <<< "${items[$i]}"
                    items[$i]="$name|$size|$time|0"
                done
                ;;
            10|13)  # Enter - proceed
                return 0
                ;;
            81|113)  # Q/q - quit
                return 2
                ;;
        esac
    done
}

# Analyze system and provide smart suggestions
analyze_and_suggest() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${BOLD}${BLUE}🧠 INTELLIGENT ANALYSIS${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    local suggestions=0

    # Check disk usage critically
    local percent_num=$(echo "$percent_initial" | tr -d '%')
    if [ "$percent_num" -ge 95 ]; then
        echo -e "  ${RED}🚨 CRITICAL${NC} Disk is ${RED}${percent_initial}${NC} full"
        echo -e "     ${DIM}→ Recommend emergency cleanup immediately${NC}"
        suggestions=$((suggestions + 1))
        echo ""
    elif [ "$percent_num" -ge 85 ]; then
        echo -e "  ${YELLOW}⚠  WARNING${NC} Disk is ${YELLOW}${percent_initial}${NC} full"
        echo -e "     ${DIM}→ Regular cleanup recommended${NC}"
        suggestions=$((suggestions + 1))
        echo ""
    fi

    # Check Docker size
    if [ "$docker_running" -eq 1 ] && [ -n "$docker_size" ]; then
        if awk "BEGIN {exit !($docker_mb > 15000)}"; then
            echo -e "  ${YELLOW}💡 DOCKER${NC} Unusually large (${BOLD}$docker_size${NC})"
            echo -e "     ${DIM}→ Hasn't been cleaned recently${NC}"
            suggestions=$((suggestions + 1))
            echo ""
        fi
    fi

    # Check for large caches
    if [ -n "$npm_size" ]; then
        if awk "BEGIN {exit !($npm_mb > 3000)}"; then
            echo -e "  ${CYAN}📦 NPM${NC} Cache is large (${BOLD}$npm_size${NC})"
            echo -e "     ${DIM}→ Safe to clear, rebuilds automatically${NC}"
            suggestions=$((suggestions + 1))
            echo ""
        fi
    fi

    if [ -n "$pip_size" ]; then
        if awk "BEGIN {exit !($pip_mb > 2000)}"; then
            echo -e "  ${CYAN}🐍 PIP${NC} Cache is large (${BOLD}$pip_size${NC})"
            echo -e "     ${DIM}→ Safe to clear, rebuilds automatically${NC}"
            suggestions=$((suggestions + 1))
            echo ""
        fi
    fi

    if [ "$suggestions" -eq 0 ]; then
        echo -e "  ${GREEN}✓${NC} System looks healthy"
        echo -e "  ${DIM}No urgent cleanup recommendations${NC}"
        echo ""
    fi

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Helper function to parse and beautify the dry-run report
show_beautiful_report() {
    local log_file="$1"

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${BOLD}${BLUE}📋 Detailed Analysis Report${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Parse VS Code section
    if grep -q "Cleaning VS Code" "$log_file"; then
        local vscode_count=$(grep -c "Would remove.*Code" "$log_file" 2>/dev/null || echo 0)
        vscode_count=$(echo "$vscode_count" | tr -d '\n\r' | grep -oE '[0-9]+' || echo 0)
        if [ "$vscode_count" -gt 0 ]; then
            echo -e "${BOLD}🗂  VS Code Caches${NC} ${DIM}($vscode_count items)${NC}"
            while IFS= read -r line; do
                local path=$(echo "$line" | sed 's/.*Would remove: //' | sed 's/ (.*//')
                local size=$(echo "$line" | grep -oE '\([0-9.]+[KMGT]B\)' | tr -d '()')
                local short_path=$(basename "$path")
                echo -e "  ${CYAN}•${NC} ${short_path} ${DIM}→ $size${NC}"
            done < <(grep "Would remove.*Code" "$log_file")
            echo ""
        fi
    fi

    # Parse Docker section
    if grep -q "Cleaning Docker" "$log_file"; then
        echo -e "${BOLD}🐳 Docker Resources${NC}"
        if grep -q "Docker daemon is not running" "$log_file"; then
            echo -e "  ${YELLOW}⚠${NC} ${DIM}Docker daemon not running${NC}"
        else
            # Parse Docker table - extract from actual docker output
            while IFS= read -r line; do
                # Skip header and empty lines
                if [[ "$line" =~ TYPE.*TOTAL ]] || [[ -z "$line" ]]; then
                    continue
                fi

                if [[ "$line" =~ ^Images ]]; then
                    # Extract: Images TOTAL ACTIVE SIZE RECLAIMABLE
                    # Column 5 is the reclaimable with percentage like "582MB (100%)"
                    local reclaim=$(echo "$line" | awk '{print $5, $6}' | sed 's/(/ (/')
                    if [ -n "$reclaim" ] && [ "$reclaim" != "0B" ]; then
                        echo -e "  ${CYAN}•${NC} Unused images ${DIM}→ $reclaim reclaimable${NC}"
                    fi
                elif [[ "$line" =~ ^Containers ]]; then
                    local size=$(echo "$line" | awk '{print $4}')
                    if [ -n "$size" ] && [ "$size" != "0B" ]; then
                        echo -e "  ${CYAN}•${NC} Stopped containers ${DIM}→ $size${NC}"
                    fi
                elif [[ "$line" =~ "Local Volumes" ]]; then
                    local reclaim=$(echo "$line" | awk '{print $5, $6}' | sed 's/(/ (/')
                    if [ -n "$reclaim" ] && [ "$reclaim" != "0B" ]; then
                        echo -e "  ${CYAN}•${NC} Unused volumes ${DIM}→ $reclaim reclaimable${NC}"
                    fi
                elif [[ "$line" =~ "Build Cache" ]]; then
                    local reclaim=$(echo "$line" | awk '{print $5, $6}' | sed 's/(/ (/')
                    if [ -n "$reclaim" ] && [ "$reclaim" != "0B" ]; then
                        echo -e "  ${CYAN}•${NC} Build cache ${DIM}→ $reclaim reclaimable${NC}"
                    fi
                fi
            done < <(grep -A 10 "TYPE.*TOTAL" "$log_file")
        fi
        echo ""
    fi

    # Parse NPM section
    if grep -q "Cleaning NPM" "$log_file"; then
        local npm_size=$(grep "NPM cache location" "$log_file" | grep -oE '[0-9.]+[KMGT]B' || echo "")
        if [ -n "$npm_size" ]; then
            echo -e "${BOLD}📦 NPM Package Cache${NC}"
            echo -e "  ${CYAN}•${NC} Cache size ${DIM}→ $npm_size${NC}"
            echo -e "  ${DIM}  Packages will re-download on next install${NC}"
            echo ""
        fi
    fi

    # Parse pip section
    if grep -q "Cleaning pip" "$log_file"; then
        local pip_size=$(grep "pip cache location" "$log_file" | grep -oE '[0-9.]+[KMGT]B' || echo "")
        if [ -n "$pip_size" ]; then
            echo -e "${BOLD}🐍 Python pip Cache${NC}"
            echo -e "  ${CYAN}•${NC} Cache size ${DIM}→ $pip_size${NC}"
            echo -e "  ${DIM}  Wheels will re-download on next install${NC}"
            echo ""
        fi
    fi

    # Parse Homebrew section
    if grep -q "Would run: brew cleanup" "$log_file"; then
        echo -e "${BOLD}🍺 Homebrew Cache${NC}"
        echo -e "  ${CYAN}•${NC} Old formula versions ${DIM}→ ~200MB estimated${NC}"
        echo ""
    fi

    # Parse pnpm section
    if grep -q "Would run: pnpm store prune" "$log_file"; then
        echo -e "${BOLD}📦 pnpm Store${NC}"
        echo -e "  ${CYAN}•${NC} Unreferenced packages ${DIM}→ ~100MB estimated${NC}"
        echo ""
    fi

    # Show disk usage info - use APFS container if available
    local total avail used percent
    if diskutil info / &>/dev/null; then
        total=$(diskutil info / | grep "Container Total Space" | awk '{print $4 $5}' | sed 's/(//')
        avail=$(diskutil info / | grep "Container Free Space" | awk '{print $4 $5}' | sed 's/(//')

        if [ -n "$total" ] && [ -n "$avail" ]; then
            # Calculate used and percent
            local total_bytes=$(echo "$total" | awk '{gsub(/GB/, "*1000000000"); gsub(/Gi/, "*1073741824"); print}' | awk '{print $1}' 2>/dev/null || echo "0")
            local avail_bytes=$(echo "$avail" | awk '{gsub(/GB/, "*1000000000"); gsub(/Gi/, "*1073741824"); print}' | awk '{print $1}' 2>/dev/null || echo "0")
            local used_bytes=$(awk "BEGIN {printf \"%.0f\", $total_bytes - $avail_bytes}" 2>/dev/null || echo "0")

            if [ "$total_bytes" != "0" ]; then
                local percent_num=$(awk "BEGIN {printf \"%.0f\", ($used_bytes * 100) / $total_bytes}")
                percent="${percent_num}%"

                # Format used
                local used_gb=$(awk "BEGIN {printf \"%.1f\", $used_bytes / 1000000000}")
                used="${used_gb}GB"
            else
                # Fallback
                local disk_info=$(df -h / | tail -1)
                used=$(echo "$disk_info" | awk '{print $3}')
                avail=$(echo "$disk_info" | awk '{print $4}')
                total=$(echo "$disk_info" | awk '{print $2}')
                percent=$(echo "$disk_info" | awk '{print $5}')
            fi
        else
            # Fallback
            local disk_info=$(df -h / | tail -1)
            used=$(echo "$disk_info" | awk '{print $3}')
            avail=$(echo "$disk_info" | awk '{print $4}')
            total=$(echo "$disk_info" | awk '{print $2}')
            percent=$(echo "$disk_info" | awk '{print $5}')
        fi
    else
        # Not macOS, use df
        local disk_info=$(df -h / | tail -1)
        used=$(echo "$disk_info" | awk '{print $3}')
        avail=$(echo "$disk_info" | awk '{print $4}')
        total=$(echo "$disk_info" | awk '{print $2}')
        percent=$(echo "$disk_info" | awk '{print $5}')
    fi

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${BOLD}💾 Current Disk Usage${NC}"
    echo -e "  ${DIM}Total: $total  •  Used: $used ($percent)  •  Available: $avail${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# Clear screen for clean presentation (unless status only)
if [ "$STATUS_ONLY" -eq 0 ]; then
    clear
fi

# Modern header with gradient-style design
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${BOLD}${BLUE}🧹 Smart Cleanup${NC}"
echo -e "  ${DIM}System Maintenance & Optimization${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Initial system probe - show disk info dynamically
echo -e "${DIM}[${NC}${CYAN}*${NC}${DIM}] Probing system...${NC}"
sleep 0.3

# Get disk info - try to get APFS container info for more accurate picture
if diskutil info / &>/dev/null; then
    container_total=$(diskutil info / | grep "Container Total Space" | awk '{print $4 $5}' | sed 's/(//')
    container_free=$(diskutil info / | grep "Container Free Space" | awk '{print $4 $5}' | sed 's/(//')

    if [ -n "$container_total" ] && [ -n "$container_free" ]; then
        # Use container stats (more accurate for APFS)
        total_initial="$container_total"
        avail_initial="$container_free"
        # Calculate used
        total_bytes=$(echo "$container_total" | awk '{gsub(/Gi/, "*1024*1024*1024"); gsub(/GB/, "*1000*1000*1000"); print}' | awk '{print $1}' 2>/dev/null || echo "0")
        avail_bytes=$(echo "$container_free" | awk '{gsub(/Gi/, "*1024*1024*1024"); gsub(/GB/, "*1000*1000*1000"); print}' | awk '{print $1}' 2>/dev/null || echo "0")
        used_bytes=$(awk "BEGIN {printf \"%.0f\", $total_bytes - $avail_bytes}" 2>/dev/null || echo "0")

        if [ "$total_bytes" != "0" ]; then
            percent_num=$(awk "BEGIN {printf \"%.0f\", ($used_bytes * 100) / $total_bytes}")
            percent_initial="${percent_num}%"

            # Format used in human readable
            used_gb=$(awk "BEGIN {printf \"%.1f\", $used_bytes / 1000000000}")
            used_initial="${used_gb}GB"
        else
            # Fallback to df if calculation fails
            disk_info_initial=$(df -h / | tail -1)
            used_initial=$(echo "$disk_info_initial" | awk '{print $3}')
            avail_initial=$(echo "$disk_info_initial" | awk '{print $4}')
            total_initial=$(echo "$disk_info_initial" | awk '{print $2}')
            percent_initial=$(echo "$disk_info_initial" | awk '{print $5}')
            percent_num=$(echo "$percent_initial" | tr -d '%')
        fi
    else
        # Fallback to df
        disk_info_initial=$(df -h / | tail -1)
        used_initial=$(echo "$disk_info_initial" | awk '{print $3}')
        avail_initial=$(echo "$disk_info_initial" | awk '{print $4}')
        total_initial=$(echo "$disk_info_initial" | awk '{print $2}')
        percent_initial=$(echo "$disk_info_initial" | awk '{print $5}')
        percent_num=$(echo "$percent_initial" | tr -d '%')
    fi
else
    # No diskutil (not macOS), use df
    disk_info_initial=$(df -h / | tail -1)
    used_initial=$(echo "$disk_info_initial" | awk '{print $3}')
    avail_initial=$(echo "$disk_info_initial" | awk '{print $4}')
    total_initial=$(echo "$disk_info_initial" | awk '{print $2}')
    percent_initial=$(echo "$disk_info_initial" | awk '{print $5}')
    percent_num=$(echo "$percent_initial" | tr -d '%')
fi

# Color code based on usage
if [ "$percent_num" -ge 90 ]; then
    usage_color="$RED"
    status_icon="⚠"
elif [ "$percent_num" -ge 75 ]; then
    usage_color="$YELLOW"
    status_icon="◐"
else
    usage_color="$GREEN"
    status_icon="✓"
fi

echo -e "${DIM}[${NC}${GREEN}✓${NC}${DIM}] Filesystem mounted at ${NC}/${NC}"
echo -e "${DIM}[${NC}${CYAN}~${NC}${DIM}] Capacity: ${NC}$total_initial ${DIM}total${NC}"
echo -e "${DIM}[${NC}${usage_color}${status_icon}${NC}${DIM}] Usage: ${NC}${usage_color}$used_initial${NC} ${DIM}of $total_initial (${usage_color}$percent_initial${NC}${DIM})${NC}"
echo -e "${DIM}[${NC}${BLUE}◇${NC}${DIM}] Available: ${NC}${BOLD}$avail_initial${NC} ${DIM}free${NC}"

# Show a dynamic progress indicator
echo ""
echo -ne "${DIM}[${NC}${CYAN}→${NC}${DIM}] Initializing cache scanner${NC}"
for i in {1..3}; do
    sleep 0.15
    echo -ne "."
done
echo -e " ${GREEN}ready${NC}"

echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Scanning for cleanup opportunities...${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo ""

# Run analysis silently in background
"$CLEANUP_SCRIPT" --dry-run --skip-git-gc > "$TEMP_LOG" 2>&1 &
ANALYSIS_PID=$!

# Track completed sections to avoid duplicates
seen_vscode=""
seen_docker=""
seen_git=""
seen_brew=""
seen_npm=""
seen_playwright=""
seen_pnpm=""
seen_pip=""
seen_aws=""

scan_counter=0
spinner_frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
spinner_idx=0

while kill -0 $ANALYSIS_PID 2>/dev/null; do
    # Check which section we're in by reading the log
    if [ -f "$TEMP_LOG" ]; then
        # Check each section only once
        if grep -q "Cleaning VS Code" "$TEMP_LOG" && [ -z "$seen_vscode" ]; then
            echo -e "${DIM}[${NC}${spinner_frames[$spinner_idx]}${DIM}] ${NC}VS Code${DIM} → ${NC}${CYAN}scanning cache dirs${NC}"
            seen_vscode=1
            scan_counter=$((scan_counter + 1))
        fi

        if grep -q "Cleaning Docker" "$TEMP_LOG" && [ -z "$seen_docker" ]; then
            echo -e "${DIM}[${NC}${spinner_frames[$spinner_idx]}${DIM}] ${NC}Docker${DIM} → ${NC}${CYAN}analyzing containers/images/volumes${NC}"
            seen_docker=1
            scan_counter=$((scan_counter + 1))
        fi

        if grep -q "Git Garbage Collection" "$TEMP_LOG" && [ -z "$seen_git" ]; then
            echo -e "${DIM}[${NC}${spinner_frames[$spinner_idx]}${DIM}] ${NC}Git${DIM} → ${NC}${CYAN}checking repositories${NC}"
            seen_git=1
            scan_counter=$((scan_counter + 1))
        fi

        if grep -q "Cleaning Homebrew" "$TEMP_LOG" && [ -z "$seen_brew" ]; then
            echo -e "${DIM}[${NC}${spinner_frames[$spinner_idx]}${DIM}] ${NC}Homebrew${DIM} → ${NC}${CYAN}checking formula cache${NC}"
            seen_brew=1
            scan_counter=$((scan_counter + 1))
        fi

        if grep -q "Cleaning NPM" "$TEMP_LOG" && [ -z "$seen_npm" ]; then
            echo -e "${DIM}[${NC}${spinner_frames[$spinner_idx]}${DIM}] ${NC}NPM${DIM} → ${NC}${CYAN}calculating package cache${NC}"
            seen_npm=1
            scan_counter=$((scan_counter + 1))
        fi

        if grep -q "Cleaning Playwright" "$TEMP_LOG" && [ -z "$seen_playwright" ]; then
            echo -e "${DIM}[${NC}${spinner_frames[$spinner_idx]}${DIM}] ${NC}Playwright${DIM} → ${NC}${CYAN}checking browser binaries${NC}"
            seen_playwright=1
            scan_counter=$((scan_counter + 1))
        fi

        if grep -q "Cleaning pnpm" "$TEMP_LOG" && [ -z "$seen_pnpm" ]; then
            echo -e "${DIM}[${NC}${spinner_frames[$spinner_idx]}${DIM}] ${NC}pnpm${DIM} → ${NC}${CYAN}analyzing store${NC}"
            seen_pnpm=1
            scan_counter=$((scan_counter + 1))
        fi

        if grep -q "Cleaning pip" "$TEMP_LOG" && [ -z "$seen_pip" ]; then
            echo -e "${DIM}[${NC}${spinner_frames[$spinner_idx]}${DIM}] ${NC}Python pip${DIM} → ${NC}${CYAN}scanning wheel cache${NC}"
            seen_pip=1
            scan_counter=$((scan_counter + 1))
        fi

        if grep -q "Cleaning AWS" "$TEMP_LOG" && [ -z "$seen_aws" ]; then
            echo -e "${DIM}[${NC}${spinner_frames[$spinner_idx]}${DIM}] ${NC}AWS CLI${DIM} → ${NC}${CYAN}checking cache${NC}"
            seen_aws=1
            scan_counter=$((scan_counter + 1))
        fi
    fi

    # Rotate spinner
    spinner_idx=$(( (spinner_idx + 1) % 10 ))
    sleep 0.2
done

echo ""
echo -e "${DIM}[${NC}${GREEN}✓${NC}${DIM}] Scan complete ${NC}${DIM}• ${NC}${BOLD}$scan_counter${NC} ${DIM}cache locations analyzed${NC}"
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo ""

# Parse results and extract actual sizes
vscode_size=""
vscode_mb=0
if grep -q "Would remove.*Code" "$TEMP_LOG"; then
    # VS Code reports multiple cache dirs - sum them up
    vscode_total_mb=0
    while IFS= read -r line; do
        size=$(echo "$line" | grep -oE '\([0-9.]+[KMGT]B\)' | tr -d '()')
        if [ -n "$size" ]; then
            mb=$(size_to_mb "$size")
            vscode_total_mb=$(awk "BEGIN {printf \"%.2f\", $vscode_total_mb + $mb}")
        fi
    done < <(grep "Would remove.*Code" "$TEMP_LOG")
    vscode_mb=$vscode_total_mb
    vscode_size=$(mb_to_human "$vscode_mb")
fi

docker_running=$(grep -q "Docker daemon is not running" "$TEMP_LOG" && echo 0 || echo 1)
docker_size=""
docker_mb=0
if [ "$docker_running" -eq 1 ]; then
    # Extract actual Docker sizes
    docker_total_mb=0
    for pattern in "Images" "Containers" "Local Volumes" "Build Cache"; do
        size=$(grep "$pattern" "$TEMP_LOG" | grep -oE '[0-9.]+[KMGT]B' | tail -1)
        if [ -n "$size" ]; then
            mb=$(size_to_mb "$size")
            docker_total_mb=$(awk "BEGIN {printf \"%.2f\", $docker_total_mb + $mb}")
        fi
    done
    docker_mb=$docker_total_mb
    docker_size=$(mb_to_human "$docker_mb")
fi

npm_size=$(grep "NPM cache location" "$TEMP_LOG" | grep -oE '[0-9.]+[KMGT]B' | tail -1)
npm_mb=0
if [ -n "$npm_size" ]; then
    npm_mb=$(size_to_mb "$npm_size")
fi

pip_size=$(grep "pip cache location" "$TEMP_LOG" | grep -oE '[0-9.]+[KMGT]B' | tail -1)
pip_mb=0
if [ -n "$pip_size" ]; then
    pip_mb=$(size_to_mb "$pip_size")
fi

# Homebrew estimate (use conservative 200MB average)
brew_mb=0
if grep -q "Would run: brew cleanup" "$TEMP_LOG"; then
    brew_mb=200
fi

# pnpm estimate (use conservative 100MB average)
pnpm_mb=0
if grep -q "Would run: pnpm store prune" "$TEMP_LOG"; then
    pnpm_mb=100
fi

# Calculate actual total
total_mb=$(awk "BEGIN {printf \"%.2f\", $vscode_mb + $docker_mb + $npm_mb + $pip_mb + $brew_mb + $pnpm_mb}")
total_estimate=$(mb_to_human "$total_mb")

# Calculate time estimate
time_estimate="~2-3 min"
time_seconds=120
if awk "BEGIN {exit !($docker_mb > 5000)}"; then
    time_seconds=$((time_seconds + 60))
fi
if awk "BEGIN {exit !($npm_mb > 2000)}"; then
    time_seconds=$((time_seconds + 30))
fi
time_minutes=$(awk "BEGIN {printf \"%.0f\", $time_seconds / 60}")
if [ "$time_minutes" -gt 3 ]; then
    time_estimate="~$time_minutes min"
fi

# Display results in compact format
echo -e "${BOLD}Discovered cleanup targets:${NC}"
echo ""

# Create item counter
item_count=0

# Helper function to get color based on size
get_size_color() {
    local mb=$1
    if awk "BEGIN {exit !($mb >= 5120)}"; then
        echo "$RED"  # >= 5GB
    elif awk "BEGIN {exit !($mb >= 1024)}"; then
        echo "$YELLOW"  # >= 1GB
    else
        echo "$GREEN"  # < 1GB
    fi
}

# VS Code
if [ -n "$vscode_size" ]; then
    item_count=$((item_count + 1))
    color=$(get_size_color "$vscode_mb")
    echo -e "  ${DIM}[${NC}${GREEN}${item_count}${NC}${DIM}]${NC} ${BOLD}VS Code${NC} ${DIM}→${NC} ${color}$vscode_size${NC} ${DIM}reclaimable${NC}"
    echo -e "      ${DIM}└─ cache dirs, extensions, workspace storage${NC}"
    echo ""
fi

# Docker
if [ "$docker_running" -eq 1 ] && [ -n "$docker_size" ]; then
    item_count=$((item_count + 1))
    color=$(get_size_color "$docker_mb")
    biggest=""
    if awk "BEGIN {exit !($docker_mb == $total_mb || $docker_mb / $total_mb > 0.5)}"; then
        biggest=" ${MAGENTA}← PRIMARY TARGET${NC}"
    fi
    echo -e "  ${DIM}[${NC}${GREEN}${item_count}${NC}${DIM}]${NC} ${BOLD}Docker${NC} ${DIM}→${NC} ${color}$docker_size${NC} ${DIM}reclaimable${NC}$biggest"
    echo -e "      ${DIM}└─ unused images, containers, volumes, build cache${NC}"
    echo ""
fi

# NPM
if [ -n "$npm_size" ]; then
    item_count=$((item_count + 1))
    color=$(get_size_color "$npm_mb")
    echo -e "  ${DIM}[${NC}${GREEN}${item_count}${NC}${DIM}]${NC} ${BOLD}NPM${NC} ${DIM}→${NC} ${color}$npm_size${NC} ${DIM}reclaimable${NC}"
    echo -e "      ${DIM}└─ package cache (safe, rebuilds on install)${NC}"
    echo ""
fi

# pip
if [ -n "$pip_size" ]; then
    item_count=$((item_count + 1))
    color=$(get_size_color "$pip_mb")
    echo -e "  ${DIM}[${NC}${GREEN}${item_count}${NC}${DIM}]${NC} ${BOLD}Python pip${NC} ${DIM}→${NC} ${color}$pip_size${NC} ${DIM}reclaimable${NC}"
    echo -e "      ${DIM}└─ wheel cache (safe, rebuilds on install)${NC}"
    echo ""
fi

# Homebrew
if grep -q "Would run: brew cleanup" "$TEMP_LOG"; then
    item_count=$((item_count + 1))
    echo -e "  ${DIM}[${NC}${GREEN}${item_count}${NC}${DIM}]${NC} ${BOLD}Homebrew${NC} ${DIM}→${NC} ${GREEN}~200MB${NC} ${DIM}reclaimable${NC}"
    echo -e "      ${DIM}└─ old formula versions${NC}"
    echo ""
fi

# pnpm
if grep -q "Would run: pnpm store prune" "$TEMP_LOG"; then
    item_count=$((item_count + 1))
    echo -e "  ${DIM}[${NC}${GREEN}${item_count}${NC}${DIM}]${NC} ${BOLD}pnpm${NC} ${DIM}→${NC} ${GREEN}~100MB${NC} ${DIM}reclaimable${NC}"
    echo -e "      ${DIM}└─ unreferenced packages${NC}"
    echo ""
fi

# Modern summary panel with accurate totals
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  RECOVERY POTENTIAL${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${DIM}Total reclaimable:${NC}  ${BOLD}${GREEN}$total_estimate${NC}"
echo -e "  ${DIM}Execution time:${NC}     ${time_estimate}"
echo -e "  ${DIM}Risk level:${NC}         ${GREEN}LOW${NC} ${DIM}(cache only, no data loss)${NC}"
echo ""

# Show what disk will look like after
avail_after_cleanup_mb=$(echo "$avail_initial" | sed 's/Gi//' | awk '{print $1 * 1024}')
total_mb_num=$(awk "BEGIN {printf \"%.2f\", $total_mb}")
avail_after_cleanup_mb=$(awk "BEGIN {printf \"%.2f\", $avail_after_cleanup_mb + $total_mb_num}")
avail_after_human=$(mb_to_human "$avail_after_cleanup_mb")

echo -e "  ${DIM}Disk after cleanup: ${NC}${BOLD}~$avail_after_human${NC} ${DIM}free${NC}"
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo ""

# Smart recommendations based on findings
if [ "$docker_running" -eq 1 ] && [ -n "$docker_size" ] && awk "BEGIN {exit !($docker_mb > 5120)}"; then
    echo -e "${DIM}[${NC}${YELLOW}!${NC}${DIM}] Primary target: Docker (${NC}${BOLD}$docker_size${NC}${DIM}) - largest reclaimable${NC}"
fi
if [ -n "$npm_size" ] && awk "BEGIN {exit !($npm_mb > 1024)}"; then
    echo -e "${DIM}[${NC}${CYAN}~${NC}${DIM}] NPM cache (${NC}${BOLD}$npm_size${NC}${DIM}) safe to clear, rebuilds automatically${NC}"
fi
if [ "$percent_num" -ge 85 ]; then
    echo -e "${DIM}[${NC}${RED}⚠${NC}${DIM}] Disk usage ${NC}${RED}$percent_initial${NC} ${DIM}→ cleanup recommended${NC}"
fi
echo ""

# Exit if status only mode
if [ "$STATUS_ONLY" -eq 1 ]; then
    exit 0
fi

# Show success celebration
show_success_celebration() {
    local freed_size=$1
    local time_taken=$2

    echo ""
    echo -e "${CYAN}   ✨ ✨ ✨ ✨ ✨ ✨ ✨ ✨ ✨ ✨${NC}"
    echo ""
    echo -e "        ${GREEN}${BOLD}🎉 CLEANUP COMPLETE! 🎉${NC}"
    echo ""
    echo -e "${CYAN}   ✨ ✨ ✨ ✨ ✨ ✨ ✨ ✨ ✨ ✨${NC}"
    echo ""
    echo -e "        ${BOLD}Space freed: ${GREEN}$freed_size${NC}"
    echo -e "        ${DIM}Completed in: $time_taken${NC}"
    echo ""

    # Fun facts based on freed space
    local freed_gb=$(echo "$freed_size" | grep -oE '[0-9.]+' | head -1)
    if [ -n "$freed_gb" ]; then
        local photos=$((${freed_gb%.*} * 250))
        local movies=$((${freed_gb%.*} * 5))
        echo -e "        ${DIM}💡 That's enough space for:${NC}"
        echo -e "           ${DIM}• ~$photos high-res photos${NC}"
        echo -e "           ${DIM}• ~$movies HD movies${NC}"
        echo ""
    fi
}

# Function to run cleanup with real-time progress
run_cleanup_with_progress() {
    local skip_git=$1
    local timestamp_str=$(date +%Y%m%d_%H%M%S)
    local start_epoch=$(date +%s)
    local cleanup_log="$LOGS_DIR/cleanup_${timestamp_str}.log"

    # Capture disk space before - use APFS container stats if available
    local total_disk used_before avail_before percent_before
    if diskutil info / &>/dev/null; then
        total_disk=$(diskutil info / | grep "Container Total Space" | awk '{print $4 $5}' | sed 's/(//')
        avail_before=$(diskutil info / | grep "Container Free Space" | awk '{print $4 $5}' | sed 's/(//')

        if [ -n "$total_disk" ] && [ -n "$avail_before" ]; then
            # Calculate used and percent
            local total_bytes=$(echo "$total_disk" | awk '{gsub(/GB/, "*1000000000"); gsub(/Gi/, "*1073741824"); print}' | awk '{print $1}' 2>/dev/null || echo "0")
            local avail_bytes=$(echo "$avail_before" | awk '{gsub(/GB/, "*1000000000"); gsub(/Gi/, "*1073741824"); print}' | awk '{print $1}' 2>/dev/null || echo "0")
            local used_bytes=$(awk "BEGIN {printf \"%.0f\", $total_bytes - $avail_bytes}" 2>/dev/null || echo "0")

            if [ "$total_bytes" != "0" ]; then
                local percent_num=$(awk "BEGIN {printf \"%.0f\", ($used_bytes * 100) / $total_bytes}")
                percent_before="${percent_num}%"

                # Format used
                local used_gb=$(awk "BEGIN {printf \"%.1f\", $used_bytes / 1000000000}")
                used_before="${used_gb}GB"
            else
                # Fallback
                disk_info_before=$(df -h / | tail -1)
                used_before=$(echo "$disk_info_before" | awk '{print $3}')
                avail_before=$(echo "$disk_info_before" | awk '{print $4}')
                total_disk=$(echo "$disk_info_before" | awk '{print $2}')
                percent_before=$(echo "$disk_info_before" | awk '{print $5}')
            fi
        else
            # Fallback
            disk_info_before=$(df -h / | tail -1)
            used_before=$(echo "$disk_info_before" | awk '{print $3}')
            avail_before=$(echo "$disk_info_before" | awk '{print $4}')
            total_disk=$(echo "$disk_info_before" | awk '{print $2}')
            percent_before=$(echo "$disk_info_before" | awk '{print $5}')
        fi
    else
        # Not macOS
        disk_info_before=$(df -h / | tail -1)
        used_before=$(echo "$disk_info_before" | awk '{print $3}')
        avail_before=$(echo "$disk_info_before" | awk '{print $4}')
        total_disk=$(echo "$disk_info_before" | awk '{print $2}')
        percent_before=$(echo "$disk_info_before" | awk '{print $5}')
    fi

    echo ""

    # Run cleanup in background and track progress
    # Build extra flags
    local extra_flags=()
    [ "$CLEAN_VENVS" -eq 1 ] && extra_flags+=("--clean-venvs")
    [ "$SCAN_VENVS" -eq 1 ] && extra_flags+=("--scan-venvs")
    [ -n "$VENV_ROOTS" ] && extra_flags+=("--venv-roots" "$VENV_ROOTS")
    [ -n "$VENV_MIN_AGE_DAYS" ] && extra_flags+=("--venv-age" "$VENV_MIN_AGE_DAYS")
    [ -n "$VENV_MIN_GB" ] && extra_flags+=("--venv-min-gb" "$VENV_MIN_GB")

    if [ "$skip_git" = "yes" ]; then
        "$CLEANUP_SCRIPT" -y --skip-git-gc "${extra_flags[@]}" > "$cleanup_log" 2>&1 &
    else
        "$CLEANUP_SCRIPT" -y "${extra_flags[@]}" > "$cleanup_log" 2>&1 &
    fi

    CLEANUP_PID=$!

    # Track what's been cleaned
    cleaned_vscode=""
    cleaned_docker=""
    cleaned_npm=""
    cleaned_pip=""
    cleaned_brew=""
    cleaned_pnpm=""
    cleaned_playwright=""
    cleaned_aws=""

    while kill -0 $CLEANUP_PID 2>/dev/null; do
        if [ -f "$cleanup_log" ]; then
            # Show progress for each section
            if grep -q "Cleaning VS Code" "$cleanup_log" && [ -z "$cleaned_vscode" ]; then
                echo -e "  ${CYAN}⏳${NC} Cleaning VS Code caches..."
                cleaned_vscode=1
            fi

            if grep -q "✓ Cleaned VS Code" "$cleanup_log" && [ "$cleaned_vscode" = "1" ]; then
                if [ -n "$vscode_size" ]; then
                    echo -e "  ${GREEN}✓${NC} VS Code cleaned → freed ${BOLD}$vscode_size${NC}"
                fi
                cleaned_vscode=2
            fi

            if grep -q "Cleaning Docker" "$cleanup_log" && [ -z "$cleaned_docker" ]; then
                echo -e "  ${CYAN}⏳${NC} Cleaning Docker resources... ${DIM}(may take 1-2 min)${NC}"
                cleaned_docker=1
            fi

            if grep -q "✓ Cleaned Docker" "$cleanup_log" && [ "$cleaned_docker" = "1" ]; then
                if [ -n "$docker_size" ]; then
                    echo -e "  ${GREEN}✓${NC} Docker cleaned → freed ${BOLD}$docker_size${NC}"
                fi
                cleaned_docker=2
            fi

            if grep -q "Cleaning NPM" "$cleanup_log" && [ -z "$cleaned_npm" ]; then
                echo -e "  ${CYAN}⏳${NC} Cleaning NPM cache..."
                cleaned_npm=1
            fi

            if grep -q "✓ Cleaned NPM" "$cleanup_log" && [ "$cleaned_npm" = "1" ]; then
                if [ -n "$npm_size" ]; then
                    echo -e "  ${GREEN}✓${NC} NPM cleaned → freed ${BOLD}$npm_size${NC}"
                fi
                cleaned_npm=2
            fi

            if grep -q "Cleaning pip" "$cleanup_log" && [ -z "$cleaned_pip" ]; then
                echo -e "  ${CYAN}⏳${NC} Cleaning Python pip cache..."
                cleaned_pip=1
            fi

            if grep -q "✓ Cleaned pip" "$cleanup_log" && [ "$cleaned_pip" = "1" ]; then
                if [ -n "$pip_size" ]; then
                    echo -e "  ${GREEN}✓${NC} pip cleaned → freed ${BOLD}$pip_size${NC}"
                fi
                cleaned_pip=2
            fi

            if grep -q "Cleaning Homebrew" "$cleanup_log" && [ -z "$cleaned_brew" ]; then
                echo -e "  ${CYAN}⏳${NC} Cleaning Homebrew cache..."
                cleaned_brew=1
            fi

            if grep -q "✓ Cleaned Homebrew" "$cleanup_log" && [ "$cleaned_brew" = "1" ]; then
                echo -e "  ${GREEN}✓${NC} Homebrew cleaned"
                cleaned_brew=2
            fi

            if grep -q "Cleaning pnpm" "$cleanup_log" && [ -z "$cleaned_pnpm" ]; then
                echo -e "  ${CYAN}⏳${NC} Cleaning pnpm store..."
                cleaned_pnpm=1
            fi

            if grep -q "✓ Cleaned pnpm" "$cleanup_log" && [ "$cleaned_pnpm" = "1" ]; then
                echo -e "  ${GREEN}✓${NC} pnpm cleaned"
                cleaned_pnpm=2
            fi
        fi

        sleep 0.3
    done

    # Capture disk space after - use APFS container stats if available
    local used_after avail_after percent_after
    if diskutil info / &>/dev/null; then
        avail_after=$(diskutil info / | grep "Container Free Space" | awk '{print $4 $5}' | sed 's/(//')

        if [ -n "$avail_after" ]; then
            # Calculate used and percent
            local total_bytes=$(echo "$total_disk" | awk '{gsub(/GB/, "*1000000000"); gsub(/Gi/, "*1073741824"); print}' | awk '{print $1}' 2>/dev/null || echo "0")
            local avail_bytes=$(echo "$avail_after" | awk '{gsub(/GB/, "*1000000000"); gsub(/Gi/, "*1073741824"); print}' | awk '{print $1}' 2>/dev/null || echo "0")
            local used_bytes=$(awk "BEGIN {printf \"%.0f\", $total_bytes - $avail_bytes}" 2>/dev/null || echo "0")

            if [ "$total_bytes" != "0" ]; then
                local percent_num=$(awk "BEGIN {printf \"%.0f\", ($used_bytes * 100) / $total_bytes}")
                percent_after="${percent_num}%"

                # Format used
                local used_gb=$(awk "BEGIN {printf \"%.1f\", $used_bytes / 1000000000}")
                used_after="${used_gb}GB"
            else
                # Fallback
                disk_info_after=$(df -h / | tail -1)
                used_after=$(echo "$disk_info_after" | awk '{print $3}')
                avail_after=$(echo "$disk_info_after" | awk '{print $4}')
                percent_after=$(echo "$disk_info_after" | awk '{print $5}')
            fi
        else
            # Fallback
            disk_info_after=$(df -h / | tail -1)
            used_after=$(echo "$disk_info_after" | awk '{print $3}')
            avail_after=$(echo "$disk_info_after" | awk '{print $4}')
            percent_after=$(echo "$disk_info_after" | awk '{print $5}')
        fi
    else
        # Not macOS
        disk_info_after=$(df -h / | tail -1)
        used_after=$(echo "$disk_info_after" | awk '{print $3}')
        avail_after=$(echo "$disk_info_after" | awk '{print $4}')
        percent_after=$(echo "$disk_info_after" | awk '{print $5}')
    fi

    # Calculate freed space
    local avail_before_mb=$(echo "$avail_before" | sed 's/[^0-9.]//g')
    local avail_after_mb=$(echo "$avail_after" | sed 's/[^0-9.]//g')
    local freed_size="Unknown"
    if [ -n "$avail_before_mb" ] && [ -n "$avail_after_mb" ]; then
        local freed_diff=$(awk "BEGIN {printf \"%.2f\", $avail_after_mb - $avail_before_mb}" 2>/dev/null || echo "0")
        if [ -n "$freed_diff" ] && [ "$freed_diff" != "0" ]; then
            if awk "BEGIN {exit !($freed_diff > 1)}"; then
                freed_size="${freed_diff}GB"
            else
                freed_size="${freed_diff}MB"
            fi
        fi
    fi

    # Calculate time taken
    local end_time=$(date +%s)
    local elapsed=$((end_time - start_epoch))
    local time_str="${elapsed}s"
    if [ "$elapsed" -gt 3600 ]; then
        time_str="$((elapsed / 3600))h $((elapsed % 3600 / 60))m"
    elif [ "$elapsed" -gt 60 ]; then
        time_str="$((elapsed / 60))m $((elapsed % 60))s"
    fi

    # Show celebration
    show_success_celebration "$freed_size" "$time_str"

    # Show detailed summary
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${BOLD}📊 DETAILED SUMMARY${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}💾 Disk Usage:${NC}"
    echo -e "     ${DIM}Before:${NC} $used_before used, $avail_before free ${DIM}($percent_before full)${NC}"
    echo -e "     ${BOLD}After:${NC}  $used_after used, $avail_after free ${DIM}($percent_after full)${NC}"
    echo ""
    echo -e "  ${BOLD}📁 Total Disk:${NC} $total_disk"
    echo -e "  ${BOLD}⏱  Duration:${NC}   $time_str"
    echo ""
    echo -e "  ${DIM}📝 Full log: $cleanup_log${NC}"
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# Show intelligent analysis
analyze_and_suggest

# Auto mode handling
if [ "$AUTO_MODE" = "best" ]; then
    echo -e "${GREEN}▶${NC} Auto mode: Starting quick cleanup..."
    run_cleanup_with_progress "yes"
    exit 0
elif [ "$AUTO_MODE" = "full" ]; then
    echo -e "${GREEN}▶${NC} Auto mode: Starting full cleanup (with git gc)..."
    echo -e "${YELLOW}⚠${NC}  ${DIM}This may take 1-4 hours for git garbage collection${NC}"
    run_cleanup_with_progress "no"
    exit 0
fi

# Profile-based execution
if [ -n "$PROFILE" ]; then
    case "$PROFILE" in
        quick)
            echo -e "${GREEN}▶${NC} Starting quick profile cleanup..."
            run_cleanup_with_progress "yes"
            exit 0
            ;;
        thorough)
            echo -e "${GREEN}▶${NC} Starting thorough profile cleanup..."
            echo -e "${YELLOW}⚠${NC}  ${DIM}This may take 1-4 hours for git garbage collection${NC}"
            run_cleanup_with_progress "no"
            exit 0
            ;;
        emergency)
            echo -e "${RED}🚨${NC} ${BOLD}EMERGENCY MODE${NC}"
            echo -e "${YELLOW}⚠${NC}  Ultra-fast cleanup (Docker only)"
            echo ""
            # Run emergency cleanup - just Docker
            "$CLEANUP_SCRIPT" -y --skip-git-gc 2>&1 | grep -E "(Docker|Total)" || true
            exit 0
            ;;
        *)
            echo -e "${RED}✗${NC} Unknown profile: $PROFILE"
            echo "  Valid profiles: quick, thorough, emergency"
            exit 1
            ;;
    esac
fi

# Try interactive menu first
declare -a menu_items
menu_items=()

# Build menu items based on analysis
if [ -n "$vscode_size" ]; then
    menu_items+=("VS Code|$vscode_size|30|1")
fi
if [ "$docker_running" -eq 1 ] && [ -n "$docker_size" ]; then
    menu_items+=("Docker|$docker_size|120|1")
fi
if [ -n "$npm_size" ]; then
    menu_items+=("NPM Cache|$npm_size|30|1")
fi
if [ -n "$pip_size" ]; then
    menu_items+=("pip Cache|$pip_size|20|1")
fi
if grep -q "Would run: brew cleanup" "$TEMP_LOG"; then
    menu_items+=("Homebrew|~200MB|20|1")
fi
if grep -q "Would run: pnpm store prune" "$TEMP_LOG"; then
    menu_items+=("pnpm|~100MB|15|1")
fi

# Show interactive menu if available
if [ "${#menu_items[@]}" -gt 0 ]; then
    if show_interactive_menu menu_items; then
        # User selected items, execute cleanup
        echo ""
        echo -e "${GREEN}▶${NC} Starting selected cleanup operations..."

        # For now, run full cleanup (TODO: selective cleanup based on menu)
        run_cleanup_with_progress "yes"
        exit 0
    elif [ $? -eq 2 ]; then
        # User quit
        echo ""
        echo -e "${BLUE}ℹ${NC} Cleanup cancelled"
        exit 0
    fi
fi

# Fallback to simple menu if interactive failed
echo ""
echo -e "  ${DIM}(Interactive menu unavailable, using simple mode)${NC}"
echo ""

# Ask with clear, simple options
echo -e "${BOLD}${YELLOW}▸ SELECT OPERATION${NC}"
echo ""
echo -e "  ${DIM}[${NC}${BOLD}1${NC}${DIM}]${NC} ${GREEN}Execute cleanup${NC} ${DIM}→ $total_estimate in $time_estimate${NC}"
echo -e "  ${DIM}[${NC}${BOLD}2${NC}${DIM}]${NC} ${BLUE}Full cleanup + git gc${NC} ${DIM}→ adds 1-4 hours${NC}"
echo -e "  ${DIM}[${NC}${BOLD}3${NC}${DIM}]${NC} ${YELLOW}Detailed analysis${NC} ${DIM}→ show breakdown${NC}"
echo -e "  ${DIM}[${NC}${BOLD}4${NC}${DIM}]${NC} ${RED}Abort${NC}"
echo ""
choice=$(read_single_char "${DIM}>${NC} " "1234")

case "$choice" in
    1)
        echo -e "${GREEN}▶${NC} Starting cleanup..."
        run_cleanup_with_progress "yes"
        ;;

    2)
        echo ""
        echo -e "${YELLOW}⚠${NC}  This will include git garbage collection"
        echo -e "   ${DIM}This may take 1-4 hours depending on repo sizes${NC}"
        echo ""
        confirm=$(read_single_char "Continue? [${GREEN}y${NC}/${RED}N${NC}]: " "yYnN")

        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            echo ""
            echo -e "${GREEN}▶${NC} Starting full cleanup (this will take a while)..."
            run_cleanup_with_progress "no"
        else
            echo ""
            echo -e "${BLUE}ℹ${NC} Cancelled"
        fi
        ;;

    3)
        show_beautiful_report "$TEMP_LOG"

        echo -e "${BOLD}${YELLOW}▸ SELECT OPERATION${NC}"
        echo ""
        echo -e "  ${DIM}[${NC}${BOLD}1${NC}${DIM}]${NC} ${GREEN}Execute cleanup${NC} ${DIM}→ $total_estimate in $time_estimate${NC}"
        echo -e "  ${DIM}[${NC}${BOLD}2${NC}${DIM}]${NC} ${BLUE}Full cleanup + git gc${NC} ${DIM}→ adds 1-4 hours${NC}"
        echo -e "  ${DIM}[${NC}${BOLD}3${NC}${DIM}]${NC} ${RED}Abort${NC}"
        echo ""
        detailed_choice=$(read_single_char "${DIM}>${NC} " "123")

        case "$detailed_choice" in
            1)
                echo ""
                echo -e "${GREEN}▶${NC} Starting cleanup..."
                run_cleanup_with_progress "yes"
                ;;
            2)
                echo ""
                echo -e "${GREEN}▶${NC} Starting full cleanup (this will take a while)..."
                run_cleanup_with_progress "no"
                ;;
            *)
                echo ""
                echo -e "${BLUE}ℹ${NC} No changes made"
                ;;
        esac
        ;;

    4|*)
        echo ""
        echo -e "${BLUE}ℹ${NC} Cleanup cancelled"
        ;;
esac
