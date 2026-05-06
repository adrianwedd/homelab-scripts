#!/usr/bin/env bash
# Example usage of new-vm-setup.sh
# This script demonstrates common VM bootstrap scenarios

# IMPORTANT: This is an example only. Adjust paths, usernames, and URLs for your environment.

# ============================================================================
# Basic Usage Examples
# ============================================================================

# Example 1: Dry-run to preview what would happen
./new-vm-setup.sh \
	--hostname "web-server-01" \
	--user "deploy" \
	--ssh-key-path "$HOME/.ssh/id_ed25519.pub" \
	--packages "curl,git,vim,htop" \
	--dry-run

# Example 2: Full setup with all options (interactive confirmation)
./new-vm-setup.sh \
	--hostname "app-server-01" \
	--user "admin" \
	--ssh-key-path "$HOME/.ssh/id_ed25519.pub" \
	--packages "curl,git,vim,htop,docker.io,nginx" \
	--dotfiles "https://github.com/yourusername/dotfiles.git" \
	--shell "/bin/zsh"

# Example 3: Non-interactive setup with JSON output
./new-vm-setup.sh \
	--hostname "db-server-01" \
	--user "dbadmin" \
	--ssh-key-path "$HOME/.ssh/id_rsa.pub" \
	--packages "postgresql-client,postgresql" \
	--yes \
	--json

# Example 4: Minimal setup (hostname and user only)
./new-vm-setup.sh \
	--hostname "minimal-vm" \
	--user "sysadmin" \
	--ssh-key-path "$HOME/.ssh/id_ed25519.pub" \
	--yes

# Example 5: Setup with passwordless sudo (use with caution!)
./new-vm-setup.sh \
	--hostname "ci-runner-01" \
	--user "ci" \
	--ssh-key-path "$HOME/.ssh/ci_deploy_key.pub" \
	--packages "docker.io,git" \
	--sudo-nopass \
	--yes

# Example 6: Using inline SSH key instead of file
SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAbc123... user@host"
./new-vm-setup.sh \
	--hostname "test-vm" \
	--user "testuser" \
	--ssh-key "$SSH_KEY" \
	--packages "curl,vim" \
	--yes

# Example 7: No dotfiles setup
./new-vm-setup.sh \
	--hostname "prod-server" \
	--user "ops" \
	--ssh-key-path "$HOME/.ssh/id_ed25519.pub" \
	--packages "nginx,certbot,ufw" \
	--no-dotfiles \
	--yes

# ============================================================================
# Advanced Usage
# ============================================================================

# Example 8: Preview only (no sudo required)
./new-vm-setup.sh \
	--hostname "preview-vm" \
	--user "previewuser" \
	--ssh-key-path "$HOME/.ssh/id_ed25519.pub" \
	--packages "git,curl" \
	--no-sudo \
	--dry-run

# Example 9: Different shells
./new-vm-setup.sh \
	--hostname "zsh-vm" \
	--user "developer" \
	--ssh-key-path "$HOME/.ssh/id_ed25519.pub" \
	--shell "/bin/zsh" \
	--packages "zsh,git,curl" \
	--yes

# Example 10: Multiple packages with specific versions (distro-specific)
./new-vm-setup.sh \
	--hostname "k8s-node-01" \
	--user "kubernetes" \
	--ssh-key-path "$HOME/.ssh/k8s_deploy.pub" \
	--packages "docker.io,kubectl,kubeadm,kubelet" \
	--yes

# ============================================================================
# Common Scenarios
# ============================================================================

# Web server setup
./new-vm-setup.sh \
	--hostname "nginx-server" \
	--user "webadmin" \
	--ssh-key-path "$HOME/.ssh/id_ed25519.pub" \
	--packages "nginx,certbot,python3-certbot-nginx,ufw,fail2ban" \
	--dotfiles "https://github.com/yourusername/server-dotfiles.git" \
	--yes \
	--json

# Database server setup
./new-vm-setup.sh \
	--hostname "postgres-db" \
	--user "dbadmin" \
	--ssh-key-path "$HOME/.ssh/id_ed25519.pub" \
	--packages "postgresql,postgresql-contrib,ufw" \
	--yes

# CI/CD runner setup
./new-vm-setup.sh \
	--hostname "gitlab-runner" \
	--user "gitlab-runner" \
	--ssh-key-path "$HOME/.ssh/ci_key.pub" \
	--packages "docker.io,git,curl" \
	--sudo-nopass \
	--yes

# Development VM setup
./new-vm-setup.sh \
	--hostname "dev-box" \
	--user "developer" \
	--ssh-key-path "$HOME/.ssh/id_ed25519.pub" \
	--packages "build-essential,git,vim,tmux,htop,curl,wget,python3,python3-pip,nodejs,npm" \
	--dotfiles "https://github.com/yourusername/dotfiles.git" \
	--shell "/bin/zsh" \
	--yes

# ============================================================================
# Validation Examples (these will fail gracefully)
# ============================================================================

# Invalid hostname (uppercase)
./new-vm-setup.sh \
	--hostname "Invalid-Hostname" \
	--user "test" \
	--ssh-key-path "$HOME/.ssh/id_ed25519.pub" \
	--dry-run

# Invalid hostname (too long)
./new-vm-setup.sh \
	--hostname "this-hostname-is-way-too-long-and-exceeds-sixty-three-characters-limit" \
	--user "test" \
	--ssh-key-path "$HOME/.ssh/id_ed25519.pub" \
	--dry-run

# Invalid username (root)
./new-vm-setup.sh \
	--hostname "test-vm" \
	--user "root" \
	--ssh-key-path "$HOME/.ssh/id_ed25519.pub" \
	--dry-run

# Invalid username (starts with number)
./new-vm-setup.sh \
	--hostname "test-vm" \
	--user "1admin" \
	--ssh-key-path "$HOME/.ssh/id_ed25519.pub" \
	--dry-run

# ============================================================================
# Notes
# ============================================================================

# SSH Key Paths:
# - Use absolute paths or $HOME for portability
# - Ensure the .pub file exists and contains a valid public key
# - Supported key types: ssh-rsa, ssh-ed25519, ecdsa-sha2-nistp256/384/521

# Package Names:
# - Package names are distribution-specific
# - apt: docker.io, nginx, postgresql
# - dnf/yum: docker, nginx, postgresql-server
# - Always test with --dry-run first

# Dotfiles:
# - Must be a valid Git repository
# - Supports https://, ssh://, and git@ URLs
# - Cloned to user's home directory as ~/dotfiles
# - Run any install scripts manually after setup

# Security:
# - Never use --sudo-nopass in production without understanding the risks
# - Always use SSH keys (no password authentication)
# - Review dry-run output before running with --yes

# Logs:
# - Located in ./logs/new-vm-setup/
# - Timestamped for each run
# - JSON summaries available with --json flag
# - Permissions: 700 (directory), 600 (files)
