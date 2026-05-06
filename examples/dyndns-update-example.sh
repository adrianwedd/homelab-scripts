#!/bin/bash

# Example usage of dyndns-update.sh
# Demonstrates common dynamic DNS update scenarios

# Basic Cloudflare update with environment variable token
export CF_TOKEN="your-cloudflare-api-token-here"
./dyndns-update.sh --provider cloudflare --zone example.com \
	--record home --token env:CF_TOKEN

# Update @ record (apex/root domain)
./dyndns-update.sh --provider cloudflare --zone example.com \
	--record @ --token env:CF_TOKEN

# Custom TTL (10 minutes = 600 seconds)
./dyndns-update.sh --provider cloudflare --zone example.com \
	--record home --token env:CF_TOKEN --ttl 600

# Force update even if IP unchanged (bypasses cache and rate limiting)
./dyndns-update.sh --provider cloudflare --zone example.com \
	--record home --token env:CF_TOKEN --force

# Dry run to preview without making changes
./dyndns-update.sh --provider cloudflare --zone example.com \
	--record home --token env:CF_TOKEN --dry-run

# JSON output for automation/monitoring
./dyndns-update.sh --provider cloudflare --zone example.com \
	--record home --token env:CF_TOKEN --json

# Cron job example (runs every 15 minutes)
# */15 * * * * /path/to/dyndns-update.sh --provider cloudflare --zone example.com --record home --token env:CF_TOKEN --json >> /var/log/dyndns.log 2>&1

# Multiple records example
./dyndns-update.sh --provider cloudflare --zone example.com --record home --token env:CF_TOKEN
./dyndns-update.sh --provider cloudflare --zone example.com --record office --token env:CF_TOKEN
./dyndns-update.sh --provider cloudflare --zone example.com --record vpn --token env:CF_TOKEN
