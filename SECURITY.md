# Security Policy

## Reporting Security Vulnerabilities

Please report security vulnerabilities through one of the following methods:

- **GitHub Security Advisories** (preferred): [Report a vulnerability](https://github.com/adrianwedd/homelab-scripts/security/advisories/new)
- **Email**: security@adrianwedd.com (if GitHub is unavailable)

**Important**:
- Do not open public issues for potential security problems
- We aim to acknowledge reports within 3 business days
- Provide steps to reproduce, affected versions, and suggested mitigations if known

## Scope and Notes
- Scripts run with user privileges and may invoke `sudo` (Linux) for Docker control.
- Python updates: We respect PEP 668 by default (externally-managed environments). Use `--pip-system` to override at your own risk.
- Docker cleanup removes unused containers, images, volumes, and build caches; verify before running on critical hosts.

Responsible Disclosure
- Provide steps to reproduce, affected versions, and suggested mitigations if known.
- We will coordinate a fix and credit reporters if desired.

