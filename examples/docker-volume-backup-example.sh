#!/bin/bash

# Example usage of docker-volume-backup.sh
# Demonstrates common volume backup scenarios

# Backup single volume
./docker-volume-backup.sh --volume postgres_data

# Backup all volumes (no container stop)
./docker-volume-backup.sh --all

# Backup all volumes with container stop for consistency
./docker-volume-backup.sh --all --stop

# Backup to custom directory
./docker-volume-backup.sh --volume app_data --out ~/backups/docker-volumes

# Backup with JSON output for automation
./docker-volume-backup.sh --all --json

# Dry run to preview what would be backed up
./docker-volume-backup.sh --all --dry-run

# Backup specific volume with container stop and JSON output
./docker-volume-backup.sh --volume redis_data --stop --json
