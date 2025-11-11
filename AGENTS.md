# Repository Guidelines

## Project Structure & Modules
- Root contains executable Bash scripts: `disk-cleanup.sh`, `rclone-sync.sh`, `smart-cleanup.sh`, `update-all.sh`.
- Documentation: `README.md`, UX notes (`UX_*.md`), and `CLAUDE.md`.
- Runtime logs: `logs/` (local), plus script-specific logs in `/tmp` and `~/rclone-sync.log`.

## Build, Test, and Dev Commands
- Run cleanup (interactive): `./disk-cleanup.sh`
- Dry run (no changes): `./disk-cleanup.sh --dry-run`
- Fast cleanup: `./disk-cleanup.sh -y --skip-git-gc`
- Start sync daemon: `./rclone-sync.sh --start`
- Check sync status: `./rclone-sync.sh --status`
- View sync logs: `./rclone-sync.sh --logs 100`
- Lint shell scripts (recommended): `shellcheck *.sh`
- Format shell (recommended): `shfmt -w -i 4 *.sh`

## Coding Style & Naming
- Language: Bash (`#!/bin/bash`). Prefer portability where feasible.
- Indentation: 4 spaces; wrap lines > 100 chars thoughtfully.
- Naming: kebab-case for files (`foo-bar.sh`); functions `snake_case`; constants `UPPER_SNAKE`.
- Flags: long options where available (e.g., `--dry-run`, `--status`).
- Patterns used here: colored status helpers (`print_info/success/warning/error`), sections via `print_section`.
- Safety: avoid global `set -e`; do use `set -u`. Check for tool presence with `command -v`.

## Testing Guidelines
- No formal test suite yet. Validate via built-in dry-run and logs.
- For `disk-cleanup.sh`: run `--dry-run`, review planned actions, then run with `-y` if satisfied.
- For `rclone-sync.sh`: test with `--dry-run` and inspect `~/rclone-sync.log`.
- Add minimal smoke tests when introducing risky changes (e.g., guard with temp dirs and `mktemp`).

## Commit & Pull Requests
- Use imperative, scoped messages. Recommended Conventional Commits style: `feat: add dry-run summary`, `fix(docker): handle daemon start failure`.
- PRs should include:
  - Summary, rationale, and impact.
  - Before/after sample output (or log snippets).
  - Repro/validation steps (commands to run).
  - Linked issue (if applicable).
  - Confirmation you ran `shellcheck` and `shfmt`.

## Security & Configuration
- Never commit secrets or personal paths beyond examples.
- Be cautious with destructive commands (`rm -rf`); keep confirmations and dry-run paths intact.
- External deps: `rclone`, Docker, Homebrew, Git. Document any new dependency in `README.md` with install steps.

