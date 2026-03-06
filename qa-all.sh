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
