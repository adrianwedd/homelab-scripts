# Security Policy

- Please report vulnerabilities privately to: security@your-domain.example
- Do not open public issues for potential security problems.
- We aim to acknowledge reports within 3 business days.

Scope and Notes
- Scripts run with user privileges and may invoke `sudo` (Linux) for Docker control.
- Python updates: We respect PEP 668 by default (externally-managed environments). Use `--pip-system` to override at your own risk.
- Docker cleanup removes unused containers, images, volumes, and build caches; verify before running on critical hosts.

Responsible Disclosure
- Provide steps to reproduce, affected versions, and suggested mitigations if known.
- We will coordinate a fix and credit reporters if desired.

