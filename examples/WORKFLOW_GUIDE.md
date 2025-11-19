# Custom Workflow System - Getting Started Guide

## Overview

The homelab orchestration system supports user-defined workflows through JSON configuration files. This allows you to create custom automation sequences that combine multiple scripts with scheduling, error handling, and notifications.

## Quick Start

### 1. List Available Workflows

```bash
./homelab.sh workflow list
```

This shows both built-in workflows (morning, weekly, emergency, pre-deploy) and your custom workflows.

### 2. Create Your First Workflow

Create a file in `~/.config/homelab/workflows/my-workflow.json`:

```json
{
  "name": "my-workflow",
  "description": "My first custom workflow",
  "schedule": {
    "type": "cron",
    "expression": "0 9 * * *",
    "comment": "Daily at 9:00 AM"
  },
  "steps": [
    {
      "name": "Check Disk Space",
      "script": "disk-cleanup.sh",
      "args": ["--scan-venvs"],
      "skip_on_error": true,
      "timeout": 120
    },
    {
      "name": "Network Scan",
      "script": "nmap-scan.sh",
      "args": ["--delta"],
      "skip_on_error": true,
      "timeout": 180
    }
  ],
  "notifications": {
    "triggers": ["warning", "failure"],
    "channels": ["slack"]
  }
}
```

### 3. Validate Your Workflow

```bash
./homelab.sh workflow validate my-workflow
```

This checks:
- JSON syntax is valid
- Required fields are present (name, steps)
- Each step has a name and script
- Args are arrays (not strings)
- Scripts exist in PATH or common locations

### 4. Run Your Workflow

```bash
# Manual run (with notifications if --notify is used)
./homelab.sh workflow run my-workflow

# Scheduled run (automatically sends notifications based on triggers)
./homelab.sh workflow run my-workflow --scheduled

# Dry run (preview without execution)
./homelab.sh workflow run my-workflow --dry-run
```

### 5. View Workflow Details

```bash
./homelab.sh workflow show my-workflow
```

## Workflow Definition Format

### Required Fields

```json
{
  "name": "workflow-name",           // Must match filename (without .json)
  "description": "Human description", // Shown in workflow list
  "steps": [ ... ]                    // Array of steps to execute
}
```

### Optional Fields

```json
{
  "schedule": {
    "type": "cron",                   // Schedule type (cron only for now)
    "expression": "0 3 * * *",        // Cron expression
    "comment": "Daily at 3:00 AM"     // Human-readable schedule
  },
  "notifications": {
    "triggers": ["warning", "failure"], // When to send notifications
    "channels": ["slack", "macos"]      // Which channels to use
  },
  "conditions": {                     // Pre-flight checks (workflow-level)
    "disk": { ... },                  // Disk space requirement
    "time_window": { ... },           // Time window restriction
    "last_run": { ... },              // Cooldown period
    "command": { ... },               // Custom shell condition
    "file_exists": { ... }            // File presence check
  }
}
```

### Conditional Execution

Workflows support both workflow-level pre-flight conditions and step-level guards to control when execution should proceed.

#### Workflow-Level Conditions

Pre-flight conditions are evaluated before the workflow starts. If any condition fails, the entire workflow is skipped or failed based on the `action` field.

```json
{
  "conditions": {
    "disk": {
      "min_free_gb": 10,              // Minimum free disk space in GB
      "path": "/",                    // Path to check (default: /)
      "action": "skip"                // "skip" or "fail"
    },
    "time_window": {
      "start": "02:00",               // Start time (HH:MM, 24-hour)
      "end": "06:00",                 // End time (HH:MM, 24-hour)
      "action": "skip"                // Only run between 2 AM and 6 AM
    },
    "last_run": {
      "min_hours_since": 12,          // Minimum hours since last run
      "action": "skip"                // Cooldown period (requires state tracking)
    },
    "command": {
      "script": "ping -c 1 server",   // Shell command to run
      "timeout": 5,                   // Timeout in seconds (optional)
      "action": "skip"                // Skip if command fails (exit != 0)
    },
    "file_exists": {
      "path": "/tmp/lock",            // File path to check
      "negate": true,                 // true = skip if exists, false = skip if missing
      "action": "fail"                // Fail workflow if lock file exists
    }
  }
}
```

**Condition Actions:**
- `"skip"`: Skip the workflow gracefully (exit 0, warning notification)
- `"fail"`: Fail the workflow immediately (exit 1, failure notification)

**Time Window Behavior:**
- Supports overnight windows (e.g., `22:00` to `06:00`)
- Uses 24-hour format (HH:MM)
- Condition passes when current time is WITHIN the window
- Use with `action: "skip"` for off-hours-only workflows

**Example: Off-hours backup**
```json
{
  "name": "night-backup",
  "conditions": {
    "time_window": {
      "start": "22:00",
      "end": "06:00",
      "action": "skip"              // Skip if NOT between 10 PM and 6 AM
    },
    "disk": {
      "min_free_gb": 50,
      "action": "skip"              // Skip if less than 50 GB free
    }
  },
  "steps": [ ... ]
}
```

#### Step-Level Guards (when)

Each step can have `when` conditions that are evaluated before the step runs. If conditions fail, only that step is skipped or failed.

```json
{
  "steps": [
    {
      "name": "Weekend Full Backup",
      "script": "backup.sh",
      "args": ["--full"],
      "when": {
        "weekday": {
          "days": [0, 6],           // 0=Sunday, 6=Saturday
          "action": "skip"          // Only run on weekends
        }
      }
    },
    {
      "name": "Large File Transfer",
      "script": "transfer.sh",
      "when": {
        "disk": {
          "min_free_gb": 100,       // Need 100 GB free
          "path": "/backup",
          "action": "skip"
        },
        "time_window": {
          "start": "02:00",
          "end": "06:00",
          "action": "skip"          // Only during maintenance window
        }
      }
    }
  ]
}
```

**Step-Level Condition Types:**
- `disk`: Same as workflow-level
- `time_window`: Same as workflow-level
- `command`: Same as workflow-level
- `file_exists`: Same as workflow-level
- `weekday`: Step-only (not available at workflow level)

**Weekday Values:**
- `0` = Sunday
- `1` = Monday
- `2` = Tuesday
- `3` = Wednesday
- `4` = Thursday
- `5` = Friday
- `6` = Saturday

**Condition Evaluation:**
- All conditions in a block must pass for execution to proceed
- Conditions are ANDed together (not OR)
- If any condition fails, the action is taken
- Errors during evaluation are treated as "pass" (fail-open design)

### Step Definition

```json
{
  "name": "Step Name",                // Human-readable step name
  "script": "script-name.sh",         // Script to run (in PATH or absolute path)
  "args": ["--flag", "value"],        // Arguments as array (not string!)
  "skip_on_error": false,             // Continue workflow if step fails?
  "timeout": 60                       // Timeout in seconds (future feature)
}
```

## Example Workflows

### System Health Check

```json
{
  "name": "system-health",
  "description": "Daily system health check workflow",
  "schedule": {
    "type": "cron",
    "expression": "0 8 * * *",
    "comment": "Daily at 8:00 AM"
  },
  "steps": [
    {
      "name": "Check Disk Space",
      "script": "disk-cleanup.sh",
      "args": ["--scan-venvs"],
      "skip_on_error": true,
      "timeout": 120
    },
    {
      "name": "Network Scan",
      "script": "nmap-scan.sh",
      "args": ["--delta"],
      "skip_on_error": true,
      "timeout": 180
    },
    {
      "name": "SSH Key Audit",
      "script": "ssh-key-audit.sh",
      "args": ["--all-users", "--risk"],
      "skip_on_error": true,
      "timeout": 300
    }
  ],
  "notifications": {
    "triggers": ["warning", "failure"],
    "channels": ["slack", "macos"]
  }
}
```

### Backup Verification

```json
{
  "name": "backup-check",
  "description": "Verify backup integrity",
  "schedule": {
    "type": "cron",
    "expression": "0 3 * * *",
    "comment": "Daily at 3:00 AM"
  },
  "steps": [
    {
      "name": "Rclone Status Check",
      "script": "rclone-sync.sh",
      "args": ["--status"],
      "skip_on_error": false,
      "timeout": 60
    },
    {
      "name": "Backup Integrity Verification",
      "script": "rclone-sync.sh",
      "args": ["--check", "--verify"],
      "skip_on_error": false,
      "timeout": 600
    }
  ],
  "notifications": {
    "triggers": ["warning", "failure"],
    "channels": ["slack", "email"]
  }
}
```

### Development Sync

```json
{
  "name": "dev-sync",
  "description": "Sync development repositories and run health checks",
  "schedule": {
    "type": "cron",
    "expression": "0 */4 * * *",
    "comment": "Every 4 hours"
  },
  "steps": [
    {
      "name": "Git Pull All Repos",
      "script": "git-sync.sh",
      "args": ["--repos", "~/dev"],
      "skip_on_error": true,
      "timeout": 300
    },
    {
      "name": "Disk Space Check",
      "script": "disk-cleanup.sh",
      "args": ["--scan-venvs"],
      "skip_on_error": true,
      "timeout": 120
    },
    {
      "name": "Network Health Check",
      "script": "nmap-scan.sh",
      "args": ["--delta"],
      "skip_on_error": true,
      "timeout": 180
    }
  ],
  "notifications": {
    "triggers": ["failure"],
    "channels": ["slack"]
  }
}
```

### Conditional Backup (Advanced)

This example demonstrates all condition types working together:

```json
{
  "name": "conditional-backup",
  "description": "Conditional backup workflow demonstrating all condition types",
  "schedule": {
    "type": "cron",
    "expression": "0 2 * * *",
    "comment": "Daily at 2:00 AM"
  },
  "conditions": {
    "disk": {
      "min_free_gb": 5,
      "path": "/",
      "action": "skip"
    },
    "time_window": {
      "start": "02:00",
      "end": "06:00",
      "action": "skip"
    }
  },
  "steps": [
    {
      "name": "Check network connectivity",
      "script": "ping",
      "args": ["-c", "1", "8.8.8.8"],
      "skip_on_error": false,
      "when": {
        "command": {
          "script": "ping -c 1 8.8.8.8",
          "timeout": 5,
          "action": "fail"
        }
      }
    },
    {
      "name": "Verify backup destination accessible",
      "script": "test",
      "args": ["-d", "/backup/destination"],
      "skip_on_error": false,
      "when": {
        "file_exists": {
          "path": "/backup/destination",
          "negate": false,
          "action": "fail"
        }
      }
    },
    {
      "name": "Run incremental backup",
      "script": "rsync",
      "args": ["-av", "--delete", "~/repos/", "/backup/destination/"],
      "skip_on_error": false,
      "when": {
        "disk": {
          "min_free_gb": 10,
          "path": "/backup",
          "action": "skip"
        }
      }
    },
    {
      "name": "Weekend full backup",
      "script": "tar",
      "args": ["-czf", "/backup/full-backup.tar.gz", "~/repos"],
      "skip_on_error": true,
      "when": {
        "weekday": {
          "days": [0, 6],
          "action": "skip"
        }
      }
    },
    {
      "name": "Off-hours maintenance",
      "script": "echo",
      "args": ["Running maintenance during off-hours"],
      "skip_on_error": true,
      "when": {
        "time_window": {
          "start": "22:00",
          "end": "06:00",
          "action": "skip"
        }
      }
    }
  ],
  "notifications": {
    "triggers": ["warning", "failure"],
    "channels": ["macos"]
  }
}
```

**Key Features:**
- Workflow-level conditions ensure minimum disk space and time window
- Network connectivity check with `command` condition
- File existence check for backup destination
- Step-level disk space guard for large transfers
- Weekday-based full backup (weekends only)
- Time window for off-hours maintenance tasks

## Common Patterns

### Error Handling Strategies

**Fail Fast (Critical Workflows)**
```json
"skip_on_error": false  // Stop workflow if step fails
```

**Continue on Error (Monitoring Workflows)**
```json
"skip_on_error": true   // Continue even if step fails
```

### Notification Strategies

**Alert on Problems Only**
```json
"triggers": ["warning", "failure"]
```

**Alert on Everything**
```json
"triggers": ["start", "success", "warning", "failure"]
```

**Silent (Manual Review)**
```json
// Omit notifications section entirely
```

### Script Path Strategies

**Use Script Name (in PATH)**
```json
"script": "disk-cleanup.sh"  // Must be in PATH or homelab directory
```

**Use Absolute Path**
```json
"script": "/usr/local/bin/my-script.sh"  // Explicit path
```

**Use Relative Path**
```json
"script": "./scripts/my-script.sh"  // Relative to homelab directory
```

## Notification Configuration

Configure notifications in `~/.config/homelab/homelab.conf`:

### Slack

```bash
HOMELAB_NOTIFY_ENABLED=true
HOMELAB_NOTIFY_CHANNELS="slack"
HOMELAB_NOTIFY_SLACK_WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
```

### macOS Native

```bash
HOMELAB_NOTIFY_ENABLED=true
HOMELAB_NOTIFY_CHANNELS="macos"
```

### Multiple Channels

```bash
HOMELAB_NOTIFY_ENABLED=true
HOMELAB_NOTIFY_CHANNELS="slack,macos,email"
HOMELAB_NOTIFY_SLACK_WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
HOMELAB_NOTIFY_EMAIL_TO="you@example.com"
```

## Scheduling Workflows

Custom workflows can be scheduled using the built-in scheduler:

```bash
# Install schedules for all workflows (built-in + custom)
./homelab.sh schedule install

# Show all scheduled workflows
./homelab.sh schedule show
```

This will create:
- **macOS**: launchd plists in `~/Library/LaunchAgents/`
- **Linux**: systemd timers in `~/.config/systemd/user/`

## Validation Rules

The workflow validator checks:

1. **JSON Syntax**: Valid JSON format
2. **Required Fields**: `name` and `steps` must be present
3. **Step Structure**:
   - Each step must have `name` and `script`
   - `args` must be an array (e.g., `["--flag", "value"]`, not `"--flag value"`)
4. **Script Existence**: Scripts should be in PATH or specified as absolute paths
5. **Type Safety**: All values must match expected types

Common validation errors:

```bash
# ✗ Args as string (should be array)
"args": "--flag value"  # WRONG
"args": ["--flag", "value"]  # CORRECT

# ✗ Missing required fields
{
  "description": "No name field"  # WRONG - missing "name"
}

# ✗ Empty steps array
"steps": []  # WRONG - must have at least one step
```

## Overriding Built-in Workflows

You can override built-in workflows by creating a file in `~/.config/homelab/.workflow-overrides/`:

```bash
# Example: Override the "morning" workflow
~/.config/homelab/.workflow-overrides/morning.json
```

The override file uses the same format as custom workflows.

## Troubleshooting

### Workflow Not Found

```bash
$ ./homelab.sh workflow run my-workflow
✗ Workflow not found: my-workflow
```

**Solution**: Check that the file exists at `~/.config/homelab/workflows/my-workflow.json`

### Validation Errors

```bash
$ ./homelab.sh workflow validate my-workflow
✗ Step 1: 'args' must be an array, got string
```

**Solution**: Change `"args": "--flag value"` to `"args": ["--flag", "value"]`

### Script Not Found Warning

```bash
⚠ Step 1 (Check Disk): Script 'my-script.sh' not found in PATH or common locations
⚠ Script will be resolved at execution time
```

**Solution**: This is a warning, not an error. The script will be searched at runtime. To fix:
- Add the script to your PATH
- Use an absolute path: `"/path/to/my-script.sh"`
- Ensure the script is executable: `chmod +x my-script.sh`

### No Parser Available

```bash
✗ Custom workflow execution requires jq or python3
Install with: brew install jq (macOS) or apt install jq (Linux)
```

**Solution**: Install jq (recommended) or ensure python3 is available:
```bash
brew install jq  # macOS
apt install jq   # Linux
```

## Next Steps

1. **Create your first workflow** following the examples above
2. **Validate it** with `./homelab.sh workflow validate <name>`
3. **Test it manually** with `./homelab.sh workflow run <name> --dry-run`
4. **Run it for real** with `./homelab.sh workflow run <name>`
5. **Schedule it** with `./homelab.sh schedule install`

For more examples, see:
- `examples/workflow-system-health.json` - System health monitoring
- `~/.config/homelab/workflows/test-backup.json` - Backup verification
- `~/.config/homelab/workflows/dev-sync.json` - Development sync

## Additional Resources

- Main README: `/Users/adrian/repos/scripts/README.md`
- Homelab README: `/Users/adrian/repos/scripts/homelab/README.md`
- CHANGELOG: `/Users/adrian/repos/scripts/CHANGELOG.md`
