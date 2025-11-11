# Git Hooks

This directory contains git hooks for maintaining code quality in the scripts repository.

## Pre-commit Hook

The pre-commit hook automatically runs quality checks on staged `.sh` files before each commit.

### What it checks:

1. **shellcheck** - Static analysis for shell scripts
   - Detects common errors and warnings
   - Blocks commits if critical issues found

2. **shfmt** - Shell script formatting
   - Checks for consistent formatting
   - Warns but doesn't block (run `shfmt -w *.sh` to auto-fix)

3. **Custom checks:**
   - Detects `bc` usage (should use `awk` instead)
   - Warns about unsafe variable expansions

### Installation

To enable the pre-commit hook:

```bash
# From the repository root
ln -sf ../../.githooks/pre-commit .git/hooks/pre-commit
```

Or copy it manually:

```bash
cp .githooks/pre-commit .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```

### Dependencies

Install the linting tools:

```bash
# macOS
brew install shellcheck shfmt

# Linux (Debian/Ubuntu)
apt-get install shellcheck
go install mvdan.cc/sh/v3/cmd/shfmt@latest

# Linux (other)
# See https://github.com/koalaman/shellcheck#installing
# See https://github.com/mvdan/sh#shfmt
```

### Usage

Once installed, the hook runs automatically on `git commit`. If issues are found:

```bash
# Fix the issues, then commit again
git commit -m "your message"

# Or skip the hook (not recommended)
git commit --no-verify -m "your message"
```

### Testing the hook

Test it manually without committing:

```bash
.git/hooks/pre-commit
```

## Future hooks

Additional hooks can be added to `.githooks/` and installed the same way.
