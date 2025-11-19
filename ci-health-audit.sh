#!/bin/bash

# CI Health Audit Script
# Comprehensive analysis of all GitHub Actions workflows across repositories
# Usage: ./ci-health-audit.sh [--fix-broken] [--add-guards] [--fix-heredocs]

set -euo pipefail

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
REPOS_DIR="${REPOS_DIR:-/Users/adrian/repos}"
FIX_BROKEN=false
ADD_GUARDS=false
FIX_HEREDOCS=false

# Parse arguments
for arg in "$@"; do
  case $arg in
    --fix-broken) FIX_BROKEN=true ;;
    --add-guards) ADD_GUARDS=true ;;
    --fix-heredocs) FIX_HEREDOCS=true ;;
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --fix-broken    Fix workflows with YAML syntax errors"
      echo "  --add-guards    Add branch guards to scheduled workflows"
      echo "  --fix-heredocs  Add sed fixes for Python/JS heredocs"
      echo "  --help          Show this help message"
      exit 0
      ;;
  esac
done

echo -e "${BLUE}=== COMPREHENSIVE CI AUDIT - ALL REPOSITORIES ===${NC}"
echo ""

total_repos=0
repos_with_workflows=0
total_workflows=0
broken_workflows=0
unguarded_schedules=0
heredocs_need_fix=0

declare -a broken_list
declare -a schedule_list
declare -a heredoc_list

# Scan all repositories
for repo_path in "$REPOS_DIR"/* "$REPOS_DIR"/orchestrix-worktrees/*; do
  [ -d "$repo_path" ] || continue
  [ -d "$repo_path/.git" ] || [ -f "$repo_path/.git" ] || continue
  
  repo=$(basename "$repo_path")
  total_repos=$((total_repos + 1))
  
  [ -d "$repo_path/.github/workflows" ] || continue
  repos_with_workflows=$((repos_with_workflows + 1))
  
  cd "$repo_path"
  
  repo_workflows=0
  repo_broken=0
  repo_schedules=0
  repo_heredocs=0
  
  for workflow in .github/workflows/*.yml .github/workflows/*.yaml; do
    [ -f "$workflow" ] || continue
    [ "${workflow%.disabled}" != "$workflow" ] && continue
    
    repo_workflows=$((repo_workflows + 1))
    total_workflows=$((total_workflows + 1))
    
    # Check 1: YAML validity
    if ! python3 -c "import yaml; yaml.safe_load(open('$workflow'))" 2>/dev/null; then
      repo_broken=$((repo_broken + 1))
      broken_workflows=$((broken_workflows + 1))
      broken_list+=("$repo:$(basename $workflow)")
    fi
    
    # Check 2: Unguarded scheduled workflows
    if grep -q "schedule:" "$workflow" 2>/dev/null; then
      if ! grep -q "github.ref.*main\|github.ref.*develop\|github.event_name != 'schedule'" "$workflow" 2>/dev/null; then
        repo_schedules=$((repo_schedules + 1))
        unguarded_schedules=$((unguarded_schedules + 1))
        schedule_list+=("$repo:$(basename $workflow)")
      fi
    fi
    
    # Check 3: Python/JS heredocs without sed fix
    if grep -q "cat.*\\.py.*<<.*EOF\|cat.*\\.js.*<<.*EOF" "$workflow" 2>/dev/null; then
      if ! grep -q "sed.*'s/\\^" "$workflow" 2>/dev/null; then
        repo_heredocs=$((repo_heredocs + 1))
        heredocs_need_fix=$((heredocs_need_fix + 1))
        heredoc_list+=("$repo:$(basename $workflow)")
      fi
    fi
  done
  
  # Print repo status
  if [ $repo_workflows -gt 0 ]; then
    status="${GREEN}✅${NC}"
    [ $repo_broken -gt 0 ] && status="${RED}❌${NC}"
    [ $repo_schedules -gt 0 ] && [ $repo_broken -eq 0 ] && status="${YELLOW}⚠️${NC}"
    
    printf "%-40s %b  %2d workflows" "$repo" "$status" "$repo_workflows"
    [ $repo_broken -gt 0 ] && printf "  ${RED}(%d broken)${NC}" "$repo_broken"
    [ $repo_schedules -gt 0 ] && printf "  ${YELLOW}(%d unguarded)${NC}" "$repo_schedules"
    [ $repo_heredocs -gt 0 ] && printf "  ${YELLOW}(%d heredoc)${NC}" "$repo_heredocs"
    printf "\n"
  fi
done

echo ""
echo -e "${BLUE}=== SUMMARY ===${NC}"
echo "Total Repositories Scanned: $total_repos"
echo "Repositories with CI: $repos_with_workflows"
echo "Total Workflows: $total_workflows"
echo ""
echo -e "${RED}Broken Workflows (YAML errors):${NC} $broken_workflows"
echo -e "${YELLOW}Unguarded Schedules (cost waste):${NC} $unguarded_schedules"
echo -e "${YELLOW}Heredocs Needing Fix (runtime errors):${NC} $heredocs_need_fix"
echo ""

health_pct=$((100 * (total_workflows - broken_workflows) / total_workflows))
if [ $health_pct -ge 95 ]; then
  health_color=$GREEN
elif [ $health_pct -ge 85 ]; then
  health_color=$YELLOW
else
  health_color=$RED
fi

echo -e "${BLUE}=== OVERALL CI HEALTH: ${health_color}${health_pct}%${NC} ${BLUE}===${NC}"
echo ""

# Estimated cost savings
if [ $unguarded_schedules -gt 0 ]; then
  # Assume 7 branches average, 10 min runs, $0.008/min
  monthly_waste=$((unguarded_schedules * 7 * 30 * 10 * 8 / 1000))
  echo -e "${YELLOW}💰 Estimated monthly waste from unguarded schedules: \$${monthly_waste}${NC}"
  echo ""
fi

# Detailed breakdowns
if [ $broken_workflows -gt 0 ]; then
  echo -e "${RED}=== BROKEN WORKFLOWS (need immediate fix) ===${NC}"
  printf "%s\n" "${broken_list[@]}" | sort | head -20
  [ ${#broken_list[@]} -gt 20 ] && echo "... and $((${#broken_list[@]} - 20)) more"
  echo ""
fi

if [ $unguarded_schedules -gt 0 ]; then
  echo -e "${YELLOW}=== UNGUARDED SCHEDULES (add branch filters) ===${NC}"
  printf "%s\n" "${schedule_list[@]}" | sort | head -20
  [ ${#schedule_list[@]} -gt 20 ] && echo "... and $((${#schedule_list[@]} - 20)) more"
  echo ""
fi

if [ $heredocs_need_fix -gt 0 ]; then
  echo -e "${YELLOW}=== HEREDOCS NEEDING SED FIX ===${NC}"
  printf "%s\n" "${heredoc_list[@]}" | sort | head -20
  [ ${#heredoc_list[@]} -gt 20 ] && echo "... and $((${#heredoc_list[@]} - 20)) more"
  echo ""
fi

echo -e "${BLUE}=== RECOMMENDATIONS ===${NC}"
echo "1. Fix $broken_workflows broken workflows (YAML syntax errors)"
echo "2. Add branch guards to $unguarded_schedules scheduled workflows"
echo "3. Fix $heredocs_need_fix Python/JS heredocs with sed commands"
echo ""
echo "Run with --fix-broken, --add-guards, or --fix-heredocs to auto-fix"
