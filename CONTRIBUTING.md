# Contributing

Thanks for considering a contribution! This repo contains Bash scripts for cleanup, backups, and updates. Please follow these guidelines to keep quality high and changes safe.

## Getting Started
- Fork the repo and create a feature branch.
- Install tools: `shellcheck`, `shfmt` (optional), and `bash`.
- Enable the pre-commit hook:
  - `ln -sf ../../.githooks/pre-commit .git/hooks/pre-commit`

## Development
- Run local checks before opening a PR:
  - `shellcheck -S warning *.sh`
  - `bash -n *.sh`
  - Dry-run scripts to validate behavior:
    - `./disk-cleanup.sh --dry-run --no-gauge --no-fun`
    - `./smart-cleanup.sh --status`
    - `./update-all.sh --dry-run`
- Keep changes focused; avoid unrelated edits.
- Follow existing patterns for cross-platform compatibility (macOS/Linux).

## Style
- Bash with `#!/bin/bash` shebang.
- 4-space indent; quote variables; prefer arrays over unquoted scalars.
- Avoid `set -e` globally; we favor resilient flows with explicit checks.

## Pull Requests
- Use clear, imperative commit messages.
- Describe what changed and why; include validation steps and log snippets.
- Confirm you ran `shellcheck` and `bash -n`.

## Security
- Do not include secrets in code or logs.
- System pip updates are skipped by default per PEP 668; use `--pip-system` only when appropriate.

## Code of Conduct
By participating, you agree to follow our [Code of Conduct](CODE_OF_CONDUCT.md).

