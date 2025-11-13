#!/bin/bash

# Example deployment script using compose-redeploy.sh
# Demonstrates common deployment scenarios

# Basic redeploy of services
./compose-redeploy.sh

# Redeploy with volume backup (safer for production)
./compose-redeploy.sh --backup-volumes

# Custom compose file with extended health timeout
./compose-redeploy.sh --file production.yml --health-timeout 120

# Skip image pull (use existing images)
./compose-redeploy.sh --no-pull

# Dry run to preview changes
./compose-redeploy.sh --dry-run

# Full production deployment with JSON output
./compose-redeploy.sh --file app.yml --backup-volumes --health-timeout 180 --json
