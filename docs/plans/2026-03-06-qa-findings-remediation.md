# QA Findings Remediation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix all 20 findings from the multi-agent QA audit (7 critical, 8 high, 5 medium/low actionable).

**Architecture:** Each task is a self-contained fix to one or two files, verified by `./qa-all.sh --ci` plus targeted manual checks. Tasks are ordered by severity and dependency — security fixes first, then compatibility, then consistency.

**Tech Stack:** Bash, shellcheck, shfmt, qa-all.sh

---

## Task 1: Fix shfmt regression in ssh-key-audit.sh associative array keys (C6)

**Files:**
- Modify: `ssh-key-audit.sh:440,446,451,489,495,501`

The formatting commit `c377620` added spaces around hyphens inside `${RISK_DESCRIPTIONS[...]}` subscripts, turning valid keys like `ssh-dir-perms` into arithmetic expressions `ssh - dir - perms`. This breaks all risk description lookups on Bash 4+.

**Step 1: Fix the broken associative array key lookups**

Replace every spaced-out key with the correct hyphenated key. There are 6 occurrences:

```bash
# Line 440: change
${RISK_DESCRIPTIONS[ssh - dir - perms]}
# to
${RISK_DESCRIPTIONS[ssh-dir-perms]}

# Line 446: change
${RISK_DESCRIPTIONS[auth - keys - perms]}
# to
${RISK_DESCRIPTIONS[auth-keys-perms]}

# Line 451: change
${RISK_DESCRIPTIONS[auth - keys - missing]}
# to
${RISK_DESCRIPTIONS[auth-keys-missing]}

# Line 489: change
${RISK_DESCRIPTIONS[unsafe - options]}
# to
${RISK_DESCRIPTIONS[unsafe-options]}

# Lines 495, 501 use ${RISK_DESCRIPTIONS[duplicate]} and ${RISK_DESCRIPTIONS[stale]}
# — verify these are still correct (no spaces added). If spaced, fix them too.
```

**Step 2: Verify with shellcheck and shfmt**

Run: `shellcheck -S warning -e SC2034,SC2155 ssh-key-audit.sh && shfmt -d -i 4 ssh-key-audit.sh`
Expected: No errors. If shfmt wants to re-add spaces, add a `# shfmt:ignore` directive or adjust the subscript quoting: `${RISK_DESCRIPTIONS["ssh-dir-perms"]}`.

**Step 3: Verify risk scoring path works**

Run: `bash -n ssh-key-audit.sh`
Expected: Clean syntax.

**Step 4: Commit**

```bash
git add ssh-key-audit.sh
git commit -m "fix(ssh-audit): restore associative array keys broken by shfmt normalization"
```

---

## Task 2: Replace eval with array-based execution in nmap-scan.sh (C2)

**Files:**
- Modify: `nmap-scan.sh:334-378,504-507`

**Step 1: Rewrite build_nmap_cmd to return an array instead of a string**

Replace the `build_nmap_cmd()` function (lines 334-378) and its call site (lines 504-507):

```bash
# Replace build_nmap_cmd to populate a global array instead of echoing a string.
# Change function signature:
build_nmap_cmd() {
    local cidr="$1"
    NMAP_CMD=(nmap)

    if [ "$SCAN_MODE" = "fast" ]; then
        NMAP_CMD+=(-sn -PS22,80,443)
        if ! is_root; then
            NMAP_CMD+=(-sT)
        fi
    elif [ "$SCAN_MODE" = "full" ]; then
        NMAP_CMD+=(--top-ports 1000)
        if is_root; then
            NMAP_CMD+=(-sS)
        else
            NMAP_CMD+=(-sT)
        fi
    fi

    NMAP_CMD+=(--max-rate "$RATE_LIMIT")
    NMAP_CMD+=(-oX -)
    NMAP_CMD+=("$cidr")

    if [ -n "$EXCLUDE_LIST" ]; then
        NMAP_CMD+=(--exclude "$EXCLUDE_LIST")
    fi
}
```

At the call site (lines 498-513), replace:

```bash
# Old:
#   nmap_cmd=$(build_nmap_cmd "$cidr")
#   print_info "Command: $nmap_cmd"
#   if ! eval "$nmap_cmd" >>"$temp_xml" 2>>"$LOG_FILE"; then

# New:
    build_nmap_cmd "$cidr"
    print_info "Command: ${NMAP_CMD[*]}"

    if ! "${NMAP_CMD[@]}" >>"$temp_xml" 2>>"$LOG_FILE"; then
```

Also update the dry-run display (around line 384) to use `build_nmap_cmd "$cidr"; echo "${NMAP_CMD[*]}"` instead of `$(build_nmap_cmd "$cidr")`.

**Step 2: Remove unused variable needs_root (L4)**

Delete line 337: `local needs_root=false` — it is never read.

**Step 3: Verify**

Run: `shellcheck -S warning -e SC2034,SC2155 nmap-scan.sh && bash -n nmap-scan.sh`
Expected: Clean.

Run: `./nmap-scan.sh --dry-run --cidr "192.168.1.0/24"`
Expected: Shows command without `eval`.

**Step 4: Commit**

```bash
git add nmap-scan.sh
git commit -m "security(nmap): replace eval with array-based command execution"
```

---

## Task 3: Fix nmap delta analysis self-comparison bug (C7)

**Files:**
- Modify: `nmap-scan.sh:519-534`

The symlink is updated at line 520 BEFORE the delta reads it at line 528, so `readlink` resolves to the current scan and comparison is always skipped.

**Step 1: Move symlink update after delta analysis**

```bash
# Before (current order):
#   ln -sf "$(basename "$JSON_FILE")" "$LATEST_LINK"   # line 520
#   ... delta tracking reads $LATEST_LINK ...           # line 527-534

# After (fixed order):
#   ... delta tracking reads $LATEST_LINK ...
#   ln -sf "$(basename "$JSON_FILE")" "$LATEST_LINK"   # moved to after delta block

# Specifically: cut line 520 and paste it after the closing `fi` of the delta block
# (after the line that currently closes the `if [ "$DO_DELTA" = true ]` block).
```

**Step 2: Verify dry-run still works**

Run: `./nmap-scan.sh --dry-run --cidr "192.168.1.0/24"`
Expected: Clean.

**Step 3: Commit**

```bash
git add nmap-scan.sh
git commit -m "fix(nmap): move symlink update after delta analysis to fix self-comparison"
```

---

## Task 4: Replace eval echo with safe home directory resolution in new-vm-setup.sh (C3)

**Files:**
- Modify: `new-vm-setup.sh:610,714`

**Step 1: Replace both eval echo lines**

```bash
# Line 610 and 714: replace
USER_HOME=$(eval echo "~$USERNAME")

# with
USER_HOME=$(getent passwd "$USERNAME" 2>/dev/null | cut -d: -f6)
if [ -z "$USER_HOME" ]; then
    USER_HOME="/home/$USERNAME"
    print_warning "Could not resolve home for $USERNAME, assuming $USER_HOME"
fi
```

**Step 2: Verify**

Run: `shellcheck -S warning -e SC2034,SC2155 new-vm-setup.sh && bash -n new-vm-setup.sh`
Expected: Clean.

Run: `./new-vm-setup.sh --dry-run --hostname test --username testuser`
Expected: Shows resolved home directory.

**Step 3: Commit**

```bash
git add new-vm-setup.sh
git commit -m "security(vm-setup): replace eval echo with getent for safe home resolution"
```

---

## Task 5: Apply json_escape to webhook payloads in notifications.sh (C4)

**Files:**
- Modify: `homelab/lib/notifications.sh:196-210,216-228,335-351`

**Step 1: Escape all interpolated string fields in Slack payload builder**

In the Slack payload (lines 196-210, 216-228), wrap every interpolated variable in `$(json_escape "...")`:

```bash
# Lines 196-209: wrap duration, hostname, and any text fields
fields="${fields}{\"title\":\"Duration\",\"value\":\"$(json_escape "$duration")\",\"short\":true},"
# ... same pattern for all fields containing user-controlled text

# Lines 216-228: wrap title and HOMELAB_NOTIFY_SLACK_USERNAME
"username": "$(json_escape "${HOMELAB_NOTIFY_SLACK_USERNAME:-homelab-bot}")",
"title": "$(json_escape "$title")",
```

**Step 2: Escape all fields in generic webhook payload**

In lines 335-351:

```bash
"workflow": "$(json_escape "$workflow")",
"status": "$(json_escape "$status")",
"hostname": "$(json_escape "$hostname")",
"timestamp": "$(json_escape "$timestamp")",
"duration": "$(json_escape "$duration")",
"log_file": "$(json_escape "$log_file")"
```

**Step 3: Verify**

Run: `shellcheck -S warning -e SC2034,SC2155 homelab/lib/notifications.sh && bash -n homelab/lib/notifications.sh`
Expected: Clean.

**Step 4: Commit**

```bash
git add homelab/lib/notifications.sh
git commit -m "security(notifications): apply json_escape to all webhook payload fields"
```

---

## Task 6: Add Bash 3.2 version guard to db-backup.sh (C1)

**Files:**
- Modify: `db-backup.sh` — add guard before `apply_retention()` call (~line 656)

**Step 1: Add version check before retention call**

Find the call to `apply_retention` and guard it:

```bash
# Before the apply_retention call, add:
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    print_warning "Retention policy requires Bash 4+ (current: $BASH_VERSION). Skipping retention."
else
    apply_retention
fi
```

**Step 2: Verify**

Run: `bash -n db-backup.sh && shellcheck -S warning -e SC2034,SC2155 db-backup.sh`
Expected: Clean.

Run: `./db-backup.sh --dry-run --type postgres --host localhost --name testdb --user testuser`
Expected: Dry run completes.

**Step 3: Commit**

```bash
git add db-backup.sh
git commit -m "fix(db-backup): add Bash 3.2 guard for associative arrays in retention logic"
```

---

## Task 7: Clean up orphaned history.sh and HANDOFF_NOTES.md (C5)

**Files:**
- Delete: `homelab/lib/history.sh`
- Delete: `HANDOFF_NOTES.md`
- Delete: `package-lock.json`

**Step 1: Confirm no references exist**

Run: `grep -r 'history\.sh\|history_file\|append_history' homelab/ lib/ *.sh`
Expected: No hits (confirming it's truly orphaned).

**Step 2: Delete the files**

```bash
rm homelab/lib/history.sh HANDOFF_NOTES.md package-lock.json
```

**Step 3: Commit**

```bash
git add -A homelab/lib/history.sh HANDOFF_NOTES.md package-lock.json
git commit -m "chore: remove orphaned history module, stale handoff notes, and empty package-lock"
```

---

## Task 8: Fix path validation prefix matching in lib/common.sh (H1)

**Files:**
- Modify: `lib/common.sh:104`

**Step 1: Fix the HOME prefix check**

```bash
# Line 104: change
if [[ "$canonical" != "$HOME"* ]] && [[ "$canonical" != "."* ]] && [[ "$canonical" != "./"* ]]; then

# to
if [[ "$canonical" != "$HOME" && "$canonical" != "$HOME/"* ]] && [[ "$canonical" != "."* ]] && [[ "$canonical" != "./"* ]]; then
```

**Step 2: Verify with qa-all**

Run: `./qa-all.sh --ci`
Expected: All checks pass (bounds/traversal tests still pass).

**Step 3: Commit**

```bash
git add lib/common.sh
git commit -m "security(common): fix HOME prefix validation to require trailing slash"
```

---

## Task 9: Replace eval with printf -v in homelab config.sh (H3)

**Files:**
- Modify: `homelab/lib/config.sh:22`

**Step 1: Replace eval with printf -v**

```bash
# Line 22: change
eval "$var_name=\"$script_path\""

# to
printf -v "$var_name" '%s' "$script_path"
```

**Step 2: Verify homelab still detects scripts**

Run: `./homelab/homelab.sh config validate 2>&1 | head -20`
Expected: Scripts detected correctly.

Run: `bash -n homelab/lib/config.sh`
Expected: Clean.

**Step 3: Commit**

```bash
git add homelab/lib/config.sh
git commit -m "security(homelab): replace eval with printf -v for safe variable assignment"
```

---

## Task 10: Fix config type coercion in update-all.sh (H8)

**Files:**
- Modify: `update-all.sh:23` (add normalization after apply_env_overrides)

The config chain stores string `"true"` but the script uses `[ "$DRY_RUN" -eq 1 ]` integer comparison.

**Step 1: Add boolean normalization after config load**

After line 23 (`apply_env_overrides ...`), add:

```bash
# Normalize string booleans from config/env to integers
case "$DRY_RUN" in true|TRUE|yes|YES) DRY_RUN=1 ;; false|FALSE|no|NO) DRY_RUN=0 ;; esac
case "$AUTO_YES" in true|TRUE|yes|YES) AUTO_YES=1 ;; false|FALSE|no|NO) AUTO_YES=0 ;; esac
case "$ALLOW_PIP_SYSTEM" in true|TRUE|yes|YES) ALLOW_PIP_SYSTEM=1 ;; false|FALSE|no|NO) ALLOW_PIP_SYSTEM=0 ;; esac
```

**Step 2: Verify**

Run: `UPDATE_ALL_DRY_RUN=true ./update-all.sh --show-config`
Expected: `DRY_RUN=1` (not `DRY_RUN=true`), no `integer expression expected` error.

Run: `./qa-all.sh --ci`
Expected: All pass.

**Step 3: Commit**

```bash
git add update-all.sh
git commit -m "fix(update-all): normalize string booleans from config/env to integers"
```

---

## Task 11: Add Bash 4.3 guard for local -n in smart-cleanup.sh (H7)

**Files:**
- Modify: `smart-cleanup.sh:294-295`

**Step 1: Add version guard before nameref usage**

```bash
# Line 294-295: change
show_interactive_menu() {
    local -n items=$1

# to
show_interactive_menu() {
    if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]; }; then
        # local -n (nameref) requires Bash 4.3+
        return 1  # Fall back to simple mode (caller handles return 1)
    fi
    local -n items=$1
```

**Step 2: Verify**

Run: `bash -n smart-cleanup.sh && shellcheck -S warning -e SC2034,SC2155 smart-cleanup.sh`
Expected: Clean.

**Step 3: Commit**

```bash
git add smart-cleanup.sh
git commit -m "fix(smart-cleanup): add Bash 4.3 guard for local -n nameref"
```

---

## Task 12: Fix umask ordering in 3 scripts (H5)

**Files:**
- Modify: `compose-redeploy.sh:164-166`
- Modify: `docker-volume-backup.sh:179-181`
- Modify: `smart-cleanup.sh:140-142`

In each file, move `umask 077` BEFORE `mkdir -p`.

**Step 1: Fix compose-redeploy.sh**

```bash
# Lines 163-166: change order to
umask 077
mkdir -p "$LOG_DIR" && chmod 700 "$LOG_DIR" || true
mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR" || true
```

**Step 2: Fix docker-volume-backup.sh**

```bash
# Lines 178-181: change order to
umask 077
mkdir -p "$LOG_DIR" && chmod 700 "$LOG_DIR" || true
mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR" || true
```

**Step 3: Fix smart-cleanup.sh**

```bash
# Lines 140-142: add umask before mkdir
umask 077
mkdir -p "$LOGS_DIR"
chmod 700 "$LOGS_DIR" 2>/dev/null || true
```

**Step 4: Verify**

Run: `./qa-all.sh --ci`
Expected: All pass.

**Step 5: Commit**

```bash
git add compose-redeploy.sh docker-volume-backup.sh smart-cleanup.sh
git commit -m "security: move umask 077 before log directory creation in 3 scripts"
```

---

## Task 13: Quote REMOTE_PATH in deploy-scripts.sh (H6)

**Files:**
- Modify: `deploy-scripts.sh:117`

**Step 1: Quote the variable in rsync-path**

```bash
# Line 117: change
--rsync-path="mkdir -p $REMOTE_PATH && rsync" \

# to
--rsync-path="mkdir -p '$REMOTE_PATH' && rsync" \
```

**Step 2: Verify**

Run: `shellcheck -S warning -e SC2034,SC2155 deploy-scripts.sh && bash -n deploy-scripts.sh`
Expected: Clean.

**Step 3: Commit**

```bash
git add deploy-scripts.sh
git commit -m "security(deploy): quote REMOTE_PATH in rsync-path to handle spaces"
```

---

## Task 14: Fix rm -rf error masking in disk-cleanup.sh (Codex M4)

**Files:**
- Modify: `disk-cleanup.sh:534`

**Step 1: Fix the || true that masks rm failures**

```bash
# Line 534: change
if rm -rf "$dir" 2>/dev/null || true; then

# to
if rm -rf "$dir" 2>/dev/null; then
```

**Step 2: Verify**

Run: `bash -n disk-cleanup.sh && shellcheck -S warning -e SC2034,SC2155 disk-cleanup.sh`
Expected: Clean.

**Step 3: Commit**

```bash
git add disk-cleanup.sh
git commit -m "fix(cleanup): remove || true that masked rm -rf failures"
```

---

## Task 15: Run full QA validation

**Files:** None modified.

**Step 1: Run qa-all**

Run: `./qa-all.sh --ci`
Expected: All checks pass.

**Step 2: Run targeted smoke tests**

```bash
./disk-cleanup.sh --dry-run -y --no-gauge --no-fun --json
./update-all.sh --dry-run
./nmap-scan.sh --dry-run --cidr "192.168.1.0/24"
./smart-cleanup.sh --status
./ssh-key-audit.sh --dry-run
./new-vm-setup.sh --dry-run --hostname test --username testuser
./db-backup.sh --dry-run --type postgres --host localhost --name testdb --user testuser
./compose-redeploy.sh --dry-run
./docker-volume-backup.sh --dry-run
./deploy-scripts.sh --dry-run --host localhost
UPDATE_ALL_DRY_RUN=true ./update-all.sh --show-config
```

Expected: All complete without errors.

**Step 3: Final commit (if any shfmt adjustments needed)**

```bash
git add -A
git commit -m "style: shfmt adjustments after QA remediation"
```

---

## Summary

| Task | Finding | Severity | Files |
|------|---------|----------|-------|
| 1 | shfmt broke assoc-array keys | C6 | ssh-key-audit.sh |
| 2 | eval command injection | C2 | nmap-scan.sh |
| 3 | Delta self-comparison | C7 | nmap-scan.sh |
| 4 | eval echo injection | C3 | new-vm-setup.sh |
| 5 | JSON injection in webhooks | C4 | homelab/lib/notifications.sh |
| 6 | Bash 3.2 crash in retention | C1 | db-backup.sh |
| 7 | Orphaned files cleanup | C5 | history.sh, HANDOFF_NOTES.md |
| 8 | Weak HOME prefix check | H1 | lib/common.sh |
| 9 | eval in config.sh | H3 | homelab/lib/config.sh |
| 10 | Config type coercion | H8 | update-all.sh |
| 11 | local -n on Bash 3.2 | H7 | smart-cleanup.sh |
| 12 | Umask ordering | H5 | 3 scripts |
| 13 | Unquoted REMOTE_PATH | H6 | deploy-scripts.sh |
| 14 | rm error masking | M4 | disk-cleanup.sh |
| 15 | Full QA validation | — | all |
