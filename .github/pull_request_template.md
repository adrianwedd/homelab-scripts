## Description

<!-- Provide a clear, concise description of what this PR changes and why -->

Fixes # (issue)

## Type of Change

<!-- Mark relevant items with an [x] -->

- [ ] Bug fix (non-breaking change which fixes an issue)
- [ ] New feature (non-breaking change which adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to not work as expected)
- [ ] Documentation update
- [ ] Code quality improvement (refactoring, performance, etc.)

## Changes Made

<!-- List the specific changes in this PR -->

-
-
-

## Testing

<!-- Describe how you tested these changes -->

- [ ] Ran `shellcheck -S warning -e SC2034,SC2155 *.sh`
- [ ] Ran `bash -n *.sh` (syntax validation)
- [ ] Tested with `--dry-run` flag
- [ ] Tested on macOS
- [ ] Tested on Linux
- [ ] Reviewed logs in `logs/` directory

### Test Commands

<!-- Paste commands you used to test this change -->

```bash
# Example:
./disk-cleanup.sh --dry-run -y --no-gauge
```

### Test Results

<!-- Paste relevant output or describe the results -->

```
# Paste output here
```

## Checklist

- [ ] My code follows the style guidelines (4-space indent, quoted variables)
- [ ] I have performed a self-review of my code
- [ ] I have commented my code where necessary
- [ ] I have updated documentation (README.md, CLAUDE.md, etc.)
- [ ] My changes generate no new ShellCheck warnings
- [ ] I have tested on both macOS and Linux (or noted limitations)
- [ ] I have updated CHANGELOG.md with my changes (if applicable)

## Security Considerations

<!-- Describe any security implications of this change -->

- [ ] No security implications
- [ ] Reviewed for unsafe operations (rm, eval, etc.)
- [ ] Handles user input safely
- [ ] Respects PEP 668 / sudo best practices

## Additional Context

<!-- Add any other context, screenshots, or relevant information -->
