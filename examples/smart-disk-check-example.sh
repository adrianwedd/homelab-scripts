#!/usr/bin/env bash
# smart-disk-check-example.sh - Example usage patterns for S.M.A.R.T. disk monitoring

echo "=== S.M.A.R.T. Disk Check Examples ==="
echo ""

# Example 1: Auto-discover and check all drives
echo "1. Auto-discover and check all drives:"
echo "   ./smart-disk-check.sh"
echo ""

# Example 2: Check specific drives
echo "2. Check specific drives:"
echo "   ./smart-disk-check.sh --devices /dev/sda,/dev/sdb"
echo ""

# Example 3: Custom temperature thresholds
echo "3. Custom temperature thresholds (warn: 45°C, crit: 55°C):"
echo "   ./smart-disk-check.sh --warn-temp 45 --crit-temp 55"
echo ""

# Example 4: Schedule short test
echo "4. Schedule short S.M.A.R.T. test on all drives:"
echo "   ./smart-disk-check.sh --test short"
echo ""

# Example 5: Schedule long test on specific drives
echo "5. Schedule long test on specific drives:"
echo "   ./smart-disk-check.sh --devices /dev/sda,/dev/sdb --test long"
echo ""

# Example 6: JSON output for monitoring integration
echo "6. JSON output for monitoring systems:"
echo "   ./smart-disk-check.sh --json > health.json"
echo ""

# Example 7: Dry run to preview
echo "7. Dry run to preview what would be checked:"
echo "   ./smart-disk-check.sh --dry-run"
echo ""

# Example 8: Cron job for daily monitoring
echo "8. Daily cron job (6 AM, sends email on warnings/failures):"
echo "   0 6 * * * /path/to/smart-disk-check.sh --json || mail -s 'Disk Health Alert' admin@example.com"
echo ""

# Example 9: Monitoring integration with JSON parsing
echo "9. Extract critical devices with jq:"
echo "   ./smart-disk-check.sh --json | jq -r '.devices[] | select(.status == \"CRITICAL\") | .device'"
echo ""

# Example 10: Temperature monitoring only
echo "10. Focus on temperature with low thresholds:"
echo "    ./smart-disk-check.sh --warn-temp 40 --crit-temp 50"
echo ""

echo "=== Common S.M.A.R.T. Attributes Monitored ==="
echo ""
echo "ID  Name                    Description"
echo "--- ----------------------- ------------------------------------------"
echo "  5 Reallocated_Sector_Ct   Bad sectors remapped (pre-fail)"
echo "187 Reported_Uncorrect      Uncorrectable errors (pre-fail)"
echo "188 Command_Timeout         Commands that timed out (pre-fail)"
echo "197 Current_Pending_Sector  Sectors waiting to be remapped (pre-fail)"
echo "198 Offline_Uncorrectable   Uncorrectable errors found offline (pre-fail)"
echo ""

echo "=== Exit Codes ==="
echo ""
echo "0 - All devices healthy"
echo "1 - One or more devices have warnings"
echo "2 - One or more devices critical"
echo ""

echo "=== Dependencies ==="
echo ""
echo "Install smartmontools:"
echo "  macOS: brew install smartmontools"
echo "  Linux: sudo apt install smartmontools (Debian/Ubuntu)"
echo "         sudo yum install smartmontools (RHEL/CentOS)"
echo ""
