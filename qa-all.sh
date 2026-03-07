#!/usr/bin/env bash
set -u

# qa-all.sh - Unified QA harness for shell scripts
# Usage: ./qa-all.sh [--ci]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs/qa"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${LOG_DIR}/run_${TIMESTAMP}"
SUMMARY_TXT="${RUN_DIR}/summary.txt"
SUMMARY_JSON="${RUN_DIR}/summary.json"
CI_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
    --ci)
        CI_MODE=true
        shift
        ;;
    --help | -h)
        cat <<'HELP'
qa-all.sh - Unified QA harness

USAGE:
    ./qa-all.sh [--ci]

OPTIONS:
    --ci    CI-friendly mode (same checks, deterministic output layout)
    -h      Show this help
HELP
        exit 0
        ;;
    *)
        echo "Unknown option: $1"
        exit 1
        ;;
    esac
done

mkdir -p "$RUN_DIR"
chmod 700 "$LOG_DIR" "$RUN_DIR" 2>/dev/null || true
umask 077

TOTAL=0
PASSED=0
FAILED=0
declare -a RESULTS

log() {
    printf "%s\n" "$*" | tee -a "$SUMMARY_TXT"
}

run_expect_success() {
    local name="$1"
    shift
    local logfile="${RUN_DIR}/${name}.log"
    TOTAL=$((TOTAL + 1))
    if "$@" >"$logfile" 2>&1; then
        PASSED=$((PASSED + 1))
        RESULTS+=("${name}|success|0|pass|${logfile}")
        log "PASS  ${name}"
    else
        local ec=$?
        FAILED=$((FAILED + 1))
        RESULTS+=("${name}|success|${ec}|fail|${logfile}")
        log "FAIL  ${name} (exit=${ec})"
    fi
}

run_expect_failure() {
    local name="$1"
    shift
    local logfile="${RUN_DIR}/${name}.log"
    TOTAL=$((TOTAL + 1))
    if "$@" >"$logfile" 2>&1; then
        FAILED=$((FAILED + 1))
        RESULTS+=("${name}|failure|0|fail|${logfile}")
        log "FAIL  ${name} (expected failure, got exit=0)"
    else
        local ec=$?
        PASSED=$((PASSED + 1))
        RESULTS+=("${name}|failure|${ec}|pass|${logfile}")
        log "PASS  ${name} (expected failure)"
    fi
}

run_batch_help_smoke() {
    local logfile="${RUN_DIR}/help_smoke.log"
    TOTAL=$((TOTAL + 1))
    local failures=0
    : >"$logfile"
    for script in *.sh; do
        [ -x "$script" ] || continue
        if ./"$script" --help >>"$logfile" 2>&1; then
            :
        else
            failures=$((failures + 1))
            echo "help failed: $script" >>"$logfile"
        fi
    done
    if [ "$failures" -eq 0 ]; then
        PASSED=$((PASSED + 1))
        RESULTS+=("help_smoke|success|0|pass|${logfile}")
        log "PASS  help_smoke"
    else
        FAILED=$((FAILED + 1))
        RESULTS+=("help_smoke|success|1|fail|${logfile}")
        log "FAIL  help_smoke (${failures} failures)"
    fi
}

cd "$SCRIPT_DIR" || exit 1
log "QA run: ${TIMESTAMP}"
log "CI mode: ${CI_MODE}"
log "Artifacts: ${RUN_DIR}"
log ""

run_expect_success "shellcheck" shellcheck -S warning -e SC2034,SC2155 *.sh homelab/*.sh homelab/lib/*.sh lib/*.sh examples/*.sh
run_expect_success "shfmt_check" shfmt -ln bash -l -i 4 *.sh homelab/*.sh homelab/lib/*.sh lib/*.sh examples/*.sh
run_expect_success "bash_syntax" bash -n *.sh homelab/*.sh homelab/lib/*.sh lib/*.sh examples/*.sh
run_batch_help_smoke

run_expect_success "disk_cleanup_dry_run" ./disk-cleanup.sh --dry-run -y --no-gauge --no-fun --skip-docker
run_expect_success "update_all_dry_run" ./update-all.sh --dry-run
run_expect_success "smart_cleanup_status" ./smart-cleanup.sh --status
run_expect_success "nmap_dry_run" ./nmap-scan.sh --cidr "192.168.1.0/24" --dry-run
run_expect_success "service_health_dry_run" ./service-health-check.sh --dry-run --config examples/services.conf
run_expect_success "cert_renewal_dry_run" ./cert-renewal-check.sh --domains examples/domains.txt --dry-run
run_expect_success "db_backup_dry_run" env DB_DSN="postgres://user:pass@localhost/db" ./db-backup.sh --db pg --dry-run
run_expect_success "compose_redeploy_dry_run" ./compose-redeploy.sh --file examples/test-app-compose.yml --dry-run
run_expect_success "docker_volume_backup_dry_run" ./docker-volume-backup.sh --all --dry-run
run_expect_success "dyndns_dry_run" env TEST_CF_TOKEN="token-123" ./dyndns-update.sh --provider cloudflare --zone example.com --record home --token env:TEST_CF_TOKEN --dry-run
run_expect_success "smart_disk_check_dry_run" ./smart-disk-check.sh --dry-run
run_expect_success "ssh_key_audit_dry_run" ./ssh-key-audit.sh --dry-run
run_expect_success "new_vm_setup_dry_run" ./new-vm-setup.sh --hostname qa-vm --user qauser --ssh-key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForDryRunOnly qa@local" --dry-run
run_expect_success "ci_health_audit_dry_run" env REPOS_DIR=/home/pi/repos ./ci-health-audit.sh --dry-run
run_expect_success "rclone_sync_dry_run" ./rclone-sync.sh --dry-run
run_expect_success "deploy_scripts_dry_run" ./deploy-scripts.sh --hosts "fakeuser@192.0.2.1" --dry-run

run_expect_success "json_contract_cert_renewal" bash -c '
    ./cert-renewal-check.sh --domains examples/domains.txt --json --dry-run >/dev/null 2>&1
    jf=$(ls -t logs/cert/cert_check_*.json | head -n 1)
    jq -e ".script and .version and .timestamp and .status and (.duration_ms >= 0) and (.errors|type==\"array\") and (.result|type==\"object\")" "$jf" >/dev/null
'
run_expect_success "json_contract_db_backup" bash -c '
    DB_DSN="postgres://user:pass@localhost/db" ./db-backup.sh --db pg --json --dry-run >/dev/null 2>&1
    jf=$(ls -t logs/db-backup/backup_*.json | head -n 1)
    jq -e ".script and .version and .timestamp and .status and (.duration_ms >= 0) and (.errors|type==\"array\") and (.result|type==\"object\")" "$jf" >/dev/null
'
run_expect_success "json_contract_smart_disk" bash -c '
    ./smart-disk-check.sh --json --dry-run >/dev/null 2>&1
    jf=$(ls -t logs/smart-check/smart_check_summary_*.json | head -n 1)
    jq -e ".script and .version and .timestamp and .status and (.duration_ms >= 0) and (.errors|type==\"array\") and (.result|type==\"object\")" "$jf" >/dev/null
'
run_expect_success "json_contract_new_vm_setup" bash -c '
    ./new-vm-setup.sh --hostname qa-vm-json --user qauser --ssh-key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForDryRunOnly qa@local" --json --dry-run >/dev/null 2>&1
    jf=$(ls -t logs/new-vm-setup/vm_setup_summary_*.json | head -n 1)
    jq -e ".script and .version and .timestamp and .status and (.duration_ms >= 0) and (.errors|type==\"array\") and (.result|type==\"object\")" "$jf" >/dev/null
'
run_expect_success "json_contract_service_health" bash -c '
    ./service-health-check.sh --json --dry-run --config examples/services.conf >"'"$RUN_DIR"'/service_health_json.out" 2>/dev/null
    jq -e ".script and .version and .timestamp and .status and (.duration_ms >= 0) and (.errors|type==\"array\") and (.result|type==\"object\")" "'"$RUN_DIR"'/service_health_json.out" >/dev/null
'

run_expect_success "config_precedence_update_all" bash -c '
    td=$(mktemp -d)
    printf "DRY_RUN=0\n" >"$td/system.conf"
    printf "DRY_RUN=1\n" >"$td/user.conf"
    out=$(HOMELAB_SYSTEM_CONFIG="$td/system.conf" HOMELAB_USER_CONFIG="$td/user.conf" ./update-all.sh --show-config)
    echo "$out" | grep -q "^DRY_RUN=1$"
    out=$(HOMELAB_SYSTEM_CONFIG="$td/system.conf" HOMELAB_USER_CONFIG="$td/user.conf" UPDATE_ALL_DRY_RUN=0 ./update-all.sh --show-config)
    echo "$out" | grep -q "^DRY_RUN=0$"
    out=$(HOMELAB_SYSTEM_CONFIG="$td/system.conf" HOMELAB_USER_CONFIG="$td/user.conf" UPDATE_ALL_DRY_RUN=0 ./update-all.sh --dry-run --show-config)
    echo "$out" | grep -q "^DRY_RUN=1$"
    rm -rf "$td"
'
run_expect_success "config_precedence_disk_cleanup" bash -c '
    td=$(mktemp -d)
    printf "SKIP_DOCKER=false\n" >"$td/system.conf"
    printf "SKIP_DOCKER=true\n" >"$td/user.conf"
    out=$(HOMELAB_SYSTEM_CONFIG="$td/system.conf" HOMELAB_USER_CONFIG="$td/user.conf" ./disk-cleanup.sh --show-config)
    echo "$out" | grep -q "^SKIP_DOCKER=true$"
    out=$(HOMELAB_SYSTEM_CONFIG="$td/system.conf" HOMELAB_USER_CONFIG="$td/user.conf" DISK_CLEANUP_SKIP_DOCKER=false ./disk-cleanup.sh --show-config)
    echo "$out" | grep -q "^SKIP_DOCKER=false$"
    out=$(HOMELAB_SYSTEM_CONFIG="$td/system.conf" HOMELAB_USER_CONFIG="$td/user.conf" DISK_CLEANUP_SKIP_DOCKER=false ./disk-cleanup.sh --skip-docker --show-config)
    echo "$out" | grep -q "^SKIP_DOCKER=true$"
    rm -rf "$td"
'

run_expect_failure "gc_threshold_bounds" ./disk-cleanup.sh --gc-threshold 9999999
run_expect_failure "venv_age_bounds" ./disk-cleanup.sh --venv-age 99999
run_expect_failure "venv_roots_system_block" ./disk-cleanup.sh --venv-roots /etc
run_expect_failure "venv_roots_traversal_block" ./disk-cleanup.sh --venv-roots "$HOME/../etc"

{
    echo "{"
    echo "  \"timestamp\": \"${TIMESTAMP}\","
    echo "  \"ci_mode\": ${CI_MODE},"
    echo "  \"run_dir\": \"${RUN_DIR}\","
    echo "  \"totals\": {\"total\": ${TOTAL}, \"passed\": ${PASSED}, \"failed\": ${FAILED}},"
    echo "  \"checks\": ["
    first=true
    for row in "${RESULTS[@]}"; do
        IFS='|' read -r name expected exit_code status logfile <<<"$row"
        [ "$first" = false ] && echo ","
        first=false
        echo -n "    {\"name\":\"${name}\",\"expected\":\"${expected}\",\"exit_code\":${exit_code},\"status\":\"${status}\",\"log_file\":\"${logfile}\"}"
    done
    echo ""
    echo "  ]"
    echo "}"
} >"$SUMMARY_JSON"

log ""
log "Summary: total=${TOTAL} passed=${PASSED} failed=${FAILED}"
log "JSON: ${SUMMARY_JSON}"

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
