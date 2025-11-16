#!/usr/bin/env bash

# Example usage of ssh-key-audit.sh

echo "=== ssh-key-audit examples ==="

echo "1) Audit specific users"
./ssh-key-audit.sh --users "alice,bob" --json

echo "2) Audit all users under /home"
./ssh-key-audit.sh --all-users

echo "3) Include system paths"
./ssh-key-audit.sh --all-users --system

echo "4) Forbid RSA keys and fail on weak type"
./ssh-key-audit.sh --users "deploy" --forbid-types "ssh-rsa" --fail-on weak-type

echo "5) Flag keys older than a year"
./ssh-key-audit.sh --users "admin" --max-age 365

echo "6) Custom home root (fixtures)"
./ssh-key-audit.sh --all-users --home-root ./tests/fixtures/ssh

echo "7) Custom system paths"
./ssh-key-audit.sh --system --system-paths "/etc/ssh/authorized_keys:/etc/ssh/authorized_keys.d:/opt/custom/akeys"

echo "8) Full JSON report"
./ssh-key-audit.sh --all-users --system --json

