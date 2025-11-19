#!/usr/bin/env bash
# homelab/lib/notifications.sh - Notification delivery system
# Part of homelab v1.0.0

# Rate limiting state
LAST_NOTIFICATION_TIME=0
NOTIFICATION_CIRCUIT_BREAKERS=()  # Track failed channels

# Helper: Capitalize first letter (bash 3.2 compatible)
capitalize() {
  local str="$1"
  echo "$(echo "${str:0:1}" | tr '[:lower:]' '[:upper:]')${str:1}"
}

# Helper: JSON escape string for safe embedding
json_escape() {
  local str="$1"
  # Escape backslashes first, then quotes, then control characters
  str="${str//\\/\\\\}"
  str="${str//\"/\\\"}"
  str="${str//$'\n'/\\n}"
  str="${str//$'\r'/\\r}"
  str="${str//$'\t'/\\t}"
  echo "$str"
}

# Check if notifications are enabled globally
is_notifications_enabled() {
  [ "${HOMELAB_NOTIFY_ENABLED:-false}" = true ]
}

# Check if we should notify for this trigger type
should_notify() {
  local trigger="$1"  # success, warning, failure, start
  local is_scheduled="${2:-false}"  # true if run from cron/launchd

  # Check if notifications are enabled
  if ! is_notifications_enabled; then
    return 1
  fi

  # For manual runs, require explicit --notify flag
  if [ "$is_scheduled" = false ] && [ "${HOMELAB_NOTIFY_MANUAL:-false}" != true ]; then
    return 1
  fi

  # Check if this trigger is enabled
  local triggers="${HOMELAB_NOTIFY_TRIGGERS:-warning,failure}"
  if [[ ",$triggers," =~ ,$trigger, ]]; then
    return 0
  fi

  return 1
}

# Rate limiting check
# Takes optional dry_run and trigger parameters
# dry_run: if true, doesn't update timestamp
# trigger: if "start", doesn't update timestamp (allows completion notification)
#
# Known edge case: Start notifications don't CONSUME the rate limit (line 76-78)
# but they ARE still SUBJECT TO the rate limit check (line 67-72).
# Impact:
#   - Intra-workflow: start → completion works (start doesn't block completion)
#   - Cross-workflow: completion → start may be blocked if < min_interval apart
is_rate_limited() {
  local dry_run="${1:-false}"
  local trigger="${2:-}"
  local min_interval="${HOMELAB_NOTIFY_MIN_INTERVAL_SECONDS:-60}"
  local now=$(date +%s)
  local elapsed=$((now - LAST_NOTIFICATION_TIME))

  # Check if we're within the rate limit window
  # Note: This blocks ALL notifications including 'start' if too soon after previous notification
  if [ $LAST_NOTIFICATION_TIME -gt 0 ] && [ $elapsed -lt $min_interval ]; then
    if [ "${HOMELAB_VERBOSE:-false}" = true ]; then
      print_warning "Rate limited: ${elapsed}s since last notification (min: ${min_interval}s)"
    fi
    return 0  # Rate limited
  fi

  # Only update timestamp for real notifications that aren't start events
  # Start notifications don't consume the rate limit so completion can still fire
  if [ "$dry_run" != true ] && [ "$trigger" != "start" ]; then
    LAST_NOTIFICATION_TIME=$now
  fi
  return 1  # Not rate limited
}

# Check if a notification channel is available/configured
# Returns 0 if channel is ready to use, 1 if not available
is_channel_available() {
  local channel="$1"

  case "$channel" in
    slack)
      # Slack requires webhook URL
      [ -n "${HOMELAB_NOTIFY_SLACK_WEBHOOK_URL:-}" ]
      ;;
    webhook)
      # Generic webhook requires URL
      [ -n "${HOMELAB_NOTIFY_WEBHOOK_URL:-}" ]
      ;;
    macos)
      # macOS requires Darwin platform and osascript
      [ "$(uname)" = "Darwin" ] && command -v osascript >/dev/null 2>&1
      ;;
    linux)
      # Linux requires notify-send
      command -v notify-send >/dev/null 2>&1
      ;;
    email)
      # Email requires recipient and mail command
      [ -n "${HOMELAB_NOTIFY_EMAIL_TO:-}" ] && command -v mail >/dev/null 2>&1
      ;;
    *)
      # Unknown channel
      return 1
      ;;
  esac
}

# Check if channel is in circuit breaker state
is_circuit_broken() {
  local channel="$1"
  local circuit_key="circuit_breaker_${channel}"

  # Check if channel is in breaker list
  [[ " ${NOTIFICATION_CIRCUIT_BREAKERS[*]:-} " =~ \ ${channel}\  ]]
}

# Add channel to circuit breaker
break_circuit() {
  local channel="$1"
  if ! is_circuit_broken "$channel"; then
    NOTIFICATION_CIRCUIT_BREAKERS+=("$channel")
    log_to_file "NOTIFICATION: Circuit breaker opened for channel: $channel"
  fi
}

# Format notification message (plain text)
format_notification_plain() {
  local workflow="$1"
  local status="$2"      # success, warning, failure
  local duration="$3"
  local completed="$4"
  local total="$5"
  local failed="$6"      # comma-separated list
  local skipped="$7"     # comma-separated list
  local log_file="$8"

  local status_icon
  case "$status" in
    success) status_icon="✓" ;;
    warning) status_icon="⚠" ;;
    failure) status_icon="✗" ;;
    *) status_icon="ℹ" ;;
  esac

  local hostname=$(hostname -s 2>/dev/null || hostname)
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

  # Optionally redact paths
  if [ "${HOMELAB_NOTIFY_REDACT_PATHS:-false}" = true ]; then
    log_file=$(echo "$log_file" | sed "s|$HOME|~|g")
  fi

  # Build message
  local message="${status_icon} $(capitalize "$workflow") workflow ${status} on ${hostname}"
  message="${message}\n"
  message="${message}\nDuration: ${duration}"
  message="${message}\nSteps: ${completed}/${total} completed"

  if [ -n "$skipped" ] && [ "$skipped" != "0" ]; then
    local skipped_count=$(echo "$skipped" | tr ',' '\n' | wc -l | tr -d ' ')
    message="${message}\nSkipped: ${skipped_count}"
  else
    message="${message}\nSkipped: 0"
  fi

  if [ -n "$failed" ] && [ "$failed" != "0" ]; then
    local failed_count=$(echo "$failed" | tr ',' '\n' | wc -l | tr -d ' ')
    message="${message}\nFailed: ${failed_count}"
    # List failed steps (avoid subshell - use IFS and read)
    message="${message}\n\nFailed steps:"
    IFS=',' read -ra failed_array <<< "$failed"
    for step in "${failed_array[@]}"; do
      [ -n "$step" ] && message="${message}\n  - ${step}"
    done
  else
    message="${message}\nFailed: 0"
  fi

  message="${message}\n\nLog: ${log_file}"
  message="${message}\nTime: ${timestamp}"

  echo -e "$message"
}

# Format notification for Slack (rich format)
format_notification_slack() {
  local workflow="$1"
  local status="$2"
  local duration="$3"
  local completed="$4"
  local total="$5"
  local failed="$6"
  local skipped="$7"
  local log_file="$8"

  local color
  case "$status" in
    success) color="good" ;;
    warning) color="warning" ;;
    failure) color="danger" ;;
    *) color="#439FE0" ;;
  esac

  local hostname=$(hostname -s 2>/dev/null || hostname)
  local title="$(capitalize "$workflow") workflow ${status}"

  # Optionally redact paths
  if [ "${HOMELAB_NOTIFY_REDACT_PATHS:-false}" = true ]; then
    log_file=$(echo "$log_file" | sed "s|$HOME|~|g")
  fi

  # Build fields array
  local fields='['
  fields="${fields}{\"title\":\"Duration\",\"value\":\"${duration}\",\"short\":true},"
  fields="${fields}{\"title\":\"Steps\",\"value\":\"${completed}/${total}\",\"short\":true},"

  if [ -n "$skipped" ] && [ "$skipped" != "0" ]; then
    local skipped_count=$(echo "$skipped" | tr ',' '\n' | wc -l | tr -d ' ')
    fields="${fields}{\"title\":\"Skipped\",\"value\":\"${skipped_count}\",\"short\":true},"
  fi

  if [ -n "$failed" ] && [ "$failed" != "0" ]; then
    local failed_list=$(echo "$failed" | tr ',' '\n' | sed 's/^/• /' | tr '\n' '\\n')
    fields="${fields}{\"title\":\"Failed Steps\",\"value\":\"${failed_list}\",\"short\":false},"
  fi

  fields="${fields}{\"title\":\"Host\",\"value\":\"${hostname}\",\"short\":true}"
  fields="${fields}]"

  # Build Slack payload (log_file already redacted if HOMELAB_NOTIFY_REDACT_PATHS=true)
  local payload=$(cat <<EOF
{
  "username": "${HOMELAB_NOTIFY_SLACK_USERNAME:-homelab-bot}",
  "icon_emoji": ":robot_face:",
  "attachments": [
    {
      "color": "${color}",
      "title": "${title}",
      "fields": ${fields},
      "footer": "homelab",
      "footer_icon": "https://api.slack.com/img/blocks/bkb_template_images/placeholder.png",
      "ts": $(date +%s)
    }
  ]
}
EOF
)

  echo "$payload"
}

# Send notification via Slack webhook
send_notification_slack() {
  local workflow="$1"
  local status="$2"
  local duration="$3"
  local completed="$4"
  local total="$5"
  local failed="$6"
  local skipped="$7"
  local log_file="$8"
  local dry_run="${9:-false}"

  local webhook_url="${HOMELAB_NOTIFY_SLACK_WEBHOOK_URL:-}"

  if [ -z "$webhook_url" ]; then
    log_to_file "NOTIFICATION: Slack webhook URL not configured"
    return 1
  fi

  # Check circuit breaker
  if is_circuit_broken "slack"; then
    log_to_file "NOTIFICATION: Slack channel in circuit breaker state"
    return 1
  fi

  # Format message
  local payload
  if [ "${HOMELAB_NOTIFY_RICH_FORMAT:-true}" = true ]; then
    payload=$(format_notification_slack "$workflow" "$status" "$duration" "$completed" "$total" "$failed" "$skipped" "$log_file")
  else
    local plain_text=$(format_notification_plain "$workflow" "$status" "$duration" "$completed" "$total" "$failed" "$skipped" "$log_file")
    local escaped_text=$(json_escape "$plain_text")
    payload="{\"text\":\"${escaped_text}\"}"
  fi

  if [ "$dry_run" = true ]; then
    echo "━━━ Slack Notification (DRY RUN) ━━━"
    echo "Webhook URL: ${webhook_url}"
    echo "Payload:"
    echo "$payload" | jq '.' 2>/dev/null || echo "$payload"
    echo ""
    return 0
  fi

  # Send notification
  local response
  local http_code
  response=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -d "$payload" "$webhook_url" 2>&1)
  http_code=$(echo "$response" | tail -1)

  if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
    log_to_file "NOTIFICATION: Sent via Slack (HTTP ${http_code})"
    return 0
  else
    log_to_file "NOTIFICATION: Slack delivery failed (HTTP ${http_code})"
    break_circuit "slack"
    return 1
  fi
}

# Send notification via generic webhook
send_notification_webhook() {
  local workflow="$1"
  local status="$2"
  local duration="$3"
  local completed="$4"
  local total="$5"
  local failed="$6"
  local skipped="$7"
  local log_file="$8"
  local dry_run="${9:-false}"

  local webhook_url="${HOMELAB_NOTIFY_WEBHOOK_URL:-}"

  if [ -z "$webhook_url" ]; then
    log_to_file "NOTIFICATION: Generic webhook URL not configured"
    return 1
  fi

  # Check circuit breaker
  if is_circuit_broken "webhook"; then
    log_to_file "NOTIFICATION: Webhook channel in circuit breaker state"
    return 1
  fi

  # Build generic JSON payload
  local hostname=$(hostname -s 2>/dev/null || hostname)
  local timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  local failed_json="[]"
  if [ -n "$failed" ] && [ "$failed" != "0" ]; then
    failed_json="[$(echo "$failed" | sed 's/,/","/g' | sed 's/^/"/;s/$/"/')]"
  fi

  local skipped_json="[]"
  if [ -n "$skipped" ] && [ "$skipped" != "0" ]; then
    skipped_json="[$(echo "$skipped" | sed 's/,/","/g' | sed 's/^/"/;s/$/"/')]"
  fi

  local payload=$(cat <<EOF
{
  "workflow": "${workflow}",
  "status": "${status}",
  "hostname": "${hostname}",
  "timestamp": "${timestamp}",
  "duration": "${duration}",
  "steps": {
    "completed": ${completed},
    "total": ${total},
    "failed": ${failed_json},
    "skipped": ${skipped_json}
  },
  "log_file": "${log_file}"
}
EOF
)

  if [ "$dry_run" = true ]; then
    echo "━━━ Generic Webhook Notification (DRY RUN) ━━━"
    echo "Webhook URL: ${webhook_url}"
    echo "Payload:"
    echo "$payload" | jq '.' 2>/dev/null || echo "$payload"
    echo ""
    return 0
  fi

  # Send notification with optional custom headers
  local curl_args=(-s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d "$payload")

  if [ -n "${HOMELAB_NOTIFY_WEBHOOK_HEADERS:-}" ]; then
    # Split headers by newline and add each as -H arg
    while IFS= read -r header; do
      [ -n "$header" ] && curl_args+=(-H "$header")
    done <<< "$HOMELAB_NOTIFY_WEBHOOK_HEADERS"
  fi

  curl_args+=("$webhook_url")

  local response
  local http_code
  response=$(curl "${curl_args[@]}" 2>&1)
  http_code=$(echo "$response" | tail -1)

  if [ "$http_code" = "200" ] || [ "$http_code" = "201" ] || [ "$http_code" = "202" ]; then
    log_to_file "NOTIFICATION: Sent via webhook (HTTP ${http_code})"
    return 0
  else
    log_to_file "NOTIFICATION: Webhook delivery failed (HTTP ${http_code})"
    break_circuit "webhook"
    return 1
  fi
}

# Send notification via macOS native
send_notification_macos() {
  local workflow="$1"
  local status="$2"
  local duration="$3"
  local completed="$4"
  local total="$5"
  local failed="$6"
  local skipped="$7"
  local log_file="$8"
  local dry_run="${9:-false}"

  # Check if macOS and GUI session available
  if [ "$(uname)" != "Darwin" ]; then
    log_to_file "NOTIFICATION: macOS notifications not available (not macOS)"
    return 1
  fi

  if ! command -v osascript >/dev/null 2>&1; then
    log_to_file "NOTIFICATION: osascript not found"
    return 1
  fi

  # Check circuit breaker
  if is_circuit_broken "macos"; then
    log_to_file "NOTIFICATION: macOS channel in circuit breaker state"
    return 1
  fi

  # Format plain message
  local message=$(format_notification_plain "$workflow" "$status" "$duration" "$completed" "$total" "$failed" "$skipped" "$log_file")
  # Simplify for notification (first line only + summary)
  local title="$(capitalize "$workflow") workflow ${status}"
  local subtitle="Duration: ${duration}, Steps: ${completed}/${total}"

  if [ "$dry_run" = true ]; then
    echo "━━━ macOS Notification (DRY RUN) ━━━"
    echo "Title: $title"
    echo "Subtitle: $subtitle"
    echo "Sound: ${HOMELAB_NOTIFY_MACOS_SOUND:-true}"
    echo ""
    return 0
  fi

  # Send notification
  local sound_arg=""
  if [ "${HOMELAB_NOTIFY_MACOS_SOUND:-true}" = true ]; then
    sound_arg='sound name "Glass"'
  fi

  if osascript -e "display notification \"${subtitle}\" with title \"homelab\" subtitle \"${title}\" ${sound_arg}" 2>/dev/null; then
    log_to_file "NOTIFICATION: Sent via macOS native"
    return 0
  else
    log_to_file "NOTIFICATION: macOS delivery failed"
    break_circuit "macos"
    return 1
  fi
}

# Send notification via Linux notify-send
send_notification_linux() {
  local workflow="$1"
  local status="$2"
  local duration="$3"
  local completed="$4"
  local total="$5"
  local failed="$6"
  local skipped="$7"
  local log_file="$8"
  local dry_run="${9:-false}"

  # Check if Linux and notify-send available
  if [ "$(uname)" = "Darwin" ]; then
    log_to_file "NOTIFICATION: Linux notifications not available (not Linux)"
    return 1
  fi

  if ! command -v notify-send >/dev/null 2>&1; then
    log_to_file "NOTIFICATION: notify-send not found"
    return 1
  fi

  # Check circuit breaker
  if is_circuit_broken "linux"; then
    log_to_file "NOTIFICATION: Linux channel in circuit breaker state"
    return 1
  fi

  # Format message
  local title="$(capitalize "$workflow") workflow ${status}"
  local body="Duration: ${duration}\nSteps: ${completed}/${total}"

  # Set urgency based on status
  local urgency="normal"
  case "$status" in
    failure) urgency="critical" ;;
    warning) urgency="normal" ;;
    success) urgency="low" ;;
  esac

  if [ "$dry_run" = true ]; then
    echo "━━━ Linux Notification (DRY RUN) ━━━"
    echo "Title: $title"
    echo "Body: $body"
    echo "Urgency: $urgency"
    echo ""
    return 0
  fi

  # Send notification
  if notify-send --urgency="$urgency" --app-name="homelab" "$title" "$body" 2>/dev/null; then
    log_to_file "NOTIFICATION: Sent via Linux notify-send"
    return 0
  else
    log_to_file "NOTIFICATION: Linux delivery failed"
    break_circuit "linux"
    return 1
  fi
}

# Send notification via email (simplified - using mail command)
send_notification_email() {
  local workflow="$1"
  local status="$2"
  local duration="$3"
  local completed="$4"
  local total="$5"
  local failed="$6"
  local skipped="$7"
  local log_file="$8"
  local dry_run="${9:-false}"

  local email_to="${HOMELAB_NOTIFY_EMAIL_TO:-}"

  if [ -z "$email_to" ]; then
    log_to_file "NOTIFICATION: Email recipient not configured"
    return 1
  fi

  if ! command -v mail >/dev/null 2>&1; then
    log_to_file "NOTIFICATION: mail command not found"
    return 1
  fi

  # Check circuit breaker
  if is_circuit_broken "email"; then
    log_to_file "NOTIFICATION: Email channel in circuit breaker state"
    return 1
  fi

  # Format message
  local subject="[homelab] $(capitalize "$workflow") workflow ${status}"
  local body=$(format_notification_plain "$workflow" "$status" "$duration" "$completed" "$total" "$failed" "$skipped" "$log_file")

  if [ "$dry_run" = true ]; then
    echo "━━━ Email Notification (DRY RUN) ━━━"
    echo "To: $email_to"
    echo "From: ${HOMELAB_NOTIFY_EMAIL_FROM:-homelab@localhost}"
    echo "Subject: $subject"
    echo ""
    echo "Body:"
    echo "$body"
    echo ""
    return 0
  fi

  # Send email
  if echo -e "$body" | mail -s "$subject" "$email_to" 2>/dev/null; then
    log_to_file "NOTIFICATION: Sent via email to $email_to"
    return 0
  else
    log_to_file "NOTIFICATION: Email delivery failed"
    break_circuit "email"
    return 1
  fi
}

# Main notification dispatcher
send_notification() {
  local workflow="$1"
  local status="$2"      # success, warning, failure
  local duration="$3"    # Human-readable duration
  local completed="$4"   # Number of completed steps
  local total="$5"       # Total steps
  local failed="$6"      # Comma-separated list of failed step names
  local skipped="$7"     # Comma-separated list of skipped step names
  local log_file="$8"    # Path to workflow log
  local is_scheduled="${9:-false}"   # true if from cron/launchd
  local dry_run="${10:-false}"       # true for dry-run mode

  # Check if we should send notifications
  if ! should_notify "$status" "$is_scheduled"; then
    if [ "${HOMELAB_VERBOSE:-false}" = true ]; then
      print_info "Notifications disabled for trigger: $status (scheduled: $is_scheduled)"
    fi
    return 0
  fi

  # Check rate limiting (pass dry_run and status so tests/start don't consume the limit)
  if is_rate_limited "$dry_run" "$status"; then
    return 0
  fi

  # Get enabled channels
  local channels="${HOMELAB_NOTIFY_CHANNELS:-slack,macos}"
  local success_count=0
  local total_attempts=0

  # Try each enabled channel in priority order
  # Only attempt if channel is available/configured
  if [[ ",$channels," =~ ",slack," ]] && is_channel_available "slack"; then
    total_attempts=$((total_attempts + 1))
    if send_notification_slack "$workflow" "$status" "$duration" "$completed" "$total" "$failed" "$skipped" "$log_file" "$dry_run"; then
      success_count=$((success_count + 1))
    fi
  fi

  if [[ ",$channels," =~ ",webhook," ]] && is_channel_available "webhook"; then
    total_attempts=$((total_attempts + 1))
    if send_notification_webhook "$workflow" "$status" "$duration" "$completed" "$total" "$failed" "$skipped" "$log_file" "$dry_run"; then
      success_count=$((success_count + 1))
    fi
  fi

  if [[ ",$channels," =~ ",macos," ]] && is_channel_available "macos"; then
    total_attempts=$((total_attempts + 1))
    if send_notification_macos "$workflow" "$status" "$duration" "$completed" "$total" "$failed" "$skipped" "$log_file" "$dry_run"; then
      success_count=$((success_count + 1))
    fi
  fi

  if [[ ",$channels," =~ ",linux," ]] && is_channel_available "linux"; then
    total_attempts=$((total_attempts + 1))
    if send_notification_linux "$workflow" "$status" "$duration" "$completed" "$total" "$failed" "$skipped" "$log_file" "$dry_run"; then
      success_count=$((success_count + 1))
    fi
  fi

  if [[ ",$channels," =~ ",email," ]] && is_channel_available "email"; then
    total_attempts=$((total_attempts + 1))
    if send_notification_email "$workflow" "$status" "$duration" "$completed" "$total" "$failed" "$skipped" "$log_file" "$dry_run"; then
      success_count=$((success_count + 1))
    fi
  fi

  # Log results
  if [ $total_attempts -eq 0 ]; then
    log_to_file "NOTIFICATION: No channels configured"
    return 1
  elif [ $success_count -eq 0 ]; then
    log_to_file "NOTIFICATION: All channels failed (${total_attempts} attempted)"
    return 1
  else
    log_to_file "NOTIFICATION: Sent via ${success_count}/${total_attempts} channels"
    return 0
  fi
}

# Test notification system
test_notifications() {
  local dry_run="${1:-false}"

  print_section "Notification System Test"

  # Check if notifications are enabled
  if ! is_notifications_enabled; then
    print_error "Notifications are disabled (HOMELAB_NOTIFY_ENABLED=false)"
    echo ""
    echo "Enable notifications in your config:"
    echo "  HOMELAB_NOTIFY_ENABLED=true"
    return 1
  fi

  print_info "Notifications enabled: ${HOMELAB_NOTIFY_ENABLED}"
  print_info "Channels: ${HOMELAB_NOTIFY_CHANNELS:-slack,macos}"
  print_info "Triggers: ${HOMELAB_NOTIFY_TRIGGERS:-warning,failure}"
  echo ""

  # Test message
  local workflow="test"
  local status="success"
  local duration="2m 15s"
  local completed="4"
  local total="4"
  local failed="0"
  local skipped="0"
  local log_file="/tmp/homelab_test.log"
  local is_scheduled="true"

  print_info "Sending test notification..."
  echo ""

  # Override trigger check for testing
  HOMELAB_NOTIFY_TRIGGERS="success,${HOMELAB_NOTIFY_TRIGGERS:-warning,failure}"

  if send_notification "$workflow" "$status" "$duration" "$completed" "$total" "$failed" "$skipped" "$log_file" "$is_scheduled" "$dry_run"; then
    print_success "Test notification sent successfully"
    return 0
  else
    print_error "Test notification failed"
    return 1
  fi
}
