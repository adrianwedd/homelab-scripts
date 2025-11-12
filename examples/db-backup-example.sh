#!/bin/bash

# Example backup script using db-backup.sh
# Demonstrates common backup scenarios

# Set DSN via environment variable (recommended for security)
export DB_DSN="postgres://username:password@localhost:5432/mydatabase"

# Basic PostgreSQL backup
./db-backup.sh --db pg --out ./backups

# MySQL backup with custom retention (14 daily, 8 weekly, 24 monthly)
export DB_DSN="mysql://root:password@localhost:3306/appdb"
./db-backup.sh --db mysql --out /var/backups/mysql --retention 14:8:24

# Backup with cloud sync to rclone remote
export DB_DSN="postgres://user:pass@db.local:5432/production"
./db-backup.sh --db pg --out ./backups --rclone gdrive:database-backups

# Backup with test restore validation (PostgreSQL only)
./db-backup.sh --db pg --out ./backups --test-restore

# Backup with JSON summary for monitoring integration
./db-backup.sh --db pg --out ./backups --json

# Dry run to preview backup without executing
./db-backup.sh --db pg --dry-run
