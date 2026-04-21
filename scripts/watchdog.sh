#!/bin/bash
set -euo pipefail

# Usage: watchdog.sh
# Health check for Terra Mayor and Tentacles bot.
# Designed to be run by launchd every 5 minutes.
# Restarts dead/hung processes and sends Telegram alerts.
#
# Inspired by Gas Town's tiered approach:
# - Crash loop protection (max 3 consecutive restarts, then stop + escalate)
# - Graduated heartbeat thresholds (fresh / stale / very stale)
# - Work-aware recovery (flags active tasks for review on Mayor death)

TERRA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAYOR_SESSION="terra-mayor"
HEARTBEAT_FILE="$TERRA_ROOT/logs/mayor-heartbeat"
WATCHDOG_LOG="$TERRA_ROOT/logs/watchdog.log"
CRASH_COUNT_FILE="$TERRA_ROOT/logs/watchdog-crash-count"
LAST_RESTART_FILE="$TERRA_ROOT/logs/watchdog-last-restart"

# Graduated heartbeat thresholds (seconds)
HEARTBEAT_FRESH=300       # <5 min = healthy
HEARTBEAT_STALE=1200      # 5-20 min = warning
HEARTBEAT_VERY_STALE=1200 # >20 min = restart

# Crash loop protection
MAX_CONSECUTIVE_RESTARTS=3
CRASH_COOLDOWN_SEC=900  # 15 min — reset crash counter after this much uptime

# Load Telegram credentials for alerts (if available)
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_USER_ID="${TELEGRAM_USER_ID:-}"

# Try loading from .env (optional)
if [ -z "$TELEGRAM_BOT_TOKEN" ] && [ -f "$TERRA_ROOT/.env" ]; then
  TELEGRAM_BOT_TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' "$TERRA_ROOT/.env" 2>/dev/null | cut -d= -f2- || true)
  TELEGRAM_USER_ID=$(grep '^TELEGRAM_USER_ID=' "$TERRA_ROOT/.env" 2>/dev/null | cut -d= -f2- || true)
fi

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$WATCHDOG_LOG"
}

alert() {
  local message="$1"
  local severity="${2:-INFO}"
  log "ALERT [$severity]: $message"

  if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_USER_ID" ]; then
    local icon="ℹ️"
    case "$severity" in
      CRITICAL) icon="🔴" ;;
      HIGH)     icon="🟠" ;;
      MEDIUM)   icon="🟡" ;;
    esac
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d chat_id="$TELEGRAM_USER_ID" \
      -d text="$icon Terra Watchdog [$severity]: $message" \
      -d parse_mode="Markdown" > /dev/null 2>&1 || true
  fi
}

get_crash_count() {
  if [ -f "$CRASH_COUNT_FILE" ]; then
    cat "$CRASH_COUNT_FILE"
  else
    echo "0"
  fi
}

increment_crash_count() {
  local count
  count=$(get_crash_count)
  echo $(( count + 1 )) > "$CRASH_COUNT_FILE"
}

reset_crash_count() {
  echo "0" > "$CRASH_COUNT_FILE"
}

# Reset crash counter if last restart was long enough ago (stable uptime)
maybe_reset_crash_count() {
  if [ -f "$LAST_RESTART_FILE" ]; then
    local last_restart
    last_restart=$(cat "$LAST_RESTART_FILE")
    local last_epoch
    last_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_restart" +%s 2>/dev/null || echo "0")
    local now_epoch
    now_epoch=$(date +%s)
    local since_restart=$(( now_epoch - last_epoch ))
    if [ "$since_restart" -gt "$CRASH_COOLDOWN_SEC" ]; then
      reset_crash_count
    fi
  fi
}

# Flag active tasks for review when Mayor dies unexpectedly
flag_active_tasks() {
  local flagged=0
  for f in "$TERRA_ROOT"/tasks/active/*.json; do
    [ -f "$f" ] || continue
    if command -v jq &>/dev/null; then
      local task_id
      task_id=$(jq -r '.id' "$f")
      local title
      title=$(jq -r '.title' "$f")
      log "  Active task needs review: $task_id — $title"
      flagged=$(( flagged + 1 ))
    fi
  done
  if [ "$flagged" -gt 0 ]; then
    alert "$flagged active task(s) may need review after Mayor restart" "MEDIUM"
  fi
}

restart_mayor() {
  local reason="$1"

  # Crash loop protection
  maybe_reset_crash_count
  local crashes
  crashes=$(get_crash_count)

  if [ "$crashes" -ge "$MAX_CONSECUTIVE_RESTARTS" ]; then
    alert "Mayor crash loop detected ($crashes consecutive restarts). NOT restarting. Manual intervention required. Reason: $reason" "CRITICAL"
    log "Crash loop — giving up. Fix manually and run: echo 0 > $CRASH_COUNT_FILE"
    exit 1
  fi

  # Flag any in-flight work
  flag_active_tasks

  # Restart
  increment_crash_count
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "$LAST_RESTART_FILE"
  log "Restarting Mayor (crash #$(get_crash_count)/$MAX_CONSECUTIVE_RESTARTS). Reason: $reason"
  bash "$TERRA_ROOT/scripts/start-mayor.sh" --restart >> "$WATCHDOG_LOG" 2>&1
  alert "Mayor restarted ($(get_crash_count)/$MAX_CONSECUTIVE_RESTARTS). Reason: $reason" "HIGH"
}

# --- Check 1: Mayor tmux session ---
if ! tmux has-session -t "$MAYOR_SESSION" 2>/dev/null; then
  log "Mayor tmux session not found"
  restart_mayor "tmux session missing"
  exit 0
fi

# --- Check 2: claude process alive inside Mayor session ---
MAYOR_PID=$(tmux list-panes -t "$MAYOR_SESSION" -F "#{pane_pid}" 2>/dev/null | head -1)
if [ -n "$MAYOR_PID" ]; then
  CLAUDE_PID=$(pgrep -P "$MAYOR_PID" -f "claude" 2>/dev/null | head -1 || true)
  if [ -z "$CLAUDE_PID" ]; then
    log "No claude process found in Mayor session (pane PID: $MAYOR_PID)"
    restart_mayor "claude process dead inside tmux"
    exit 0
  fi
fi

# --- Check 3: Graduated heartbeat freshness ---
if [ -f "$HEARTBEAT_FILE" ]; then
  LAST_BEAT=$(cat "$HEARTBEAT_FILE")
  LAST_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_BEAT" +%s 2>/dev/null || echo "0")
  NOW_EPOCH=$(date +%s)
  AGE=$(( NOW_EPOCH - LAST_EPOCH ))

  if [ "$AGE" -gt "$HEARTBEAT_VERY_STALE" ]; then
    log "Heartbeat VERY STALE (${AGE}s old)"
    restart_mayor "heartbeat very stale (${AGE}s)"
    exit 0
  elif [ "$AGE" -gt "$HEARTBEAT_FRESH" ]; then
    log "Heartbeat STALE (${AGE}s old) — warning, not restarting yet"
    alert "Mayor heartbeat stale (${AGE}s). Will restart if it exceeds $(( HEARTBEAT_VERY_STALE / 60 ))m." "MEDIUM"
    exit 0
  fi
fi

# All healthy — reset crash counter (stable uptime)
maybe_reset_crash_count

log "OK — Mayor alive, heartbeat fresh"

# --- Check 4: Remind about unreviewed plans (every 3 hours) ---
REMIND_INTERVAL=10800  # 3 hours
REMIND_LAST_FILE="$TERRA_ROOT/logs/watchdog-last-remind"
REMIND_NOW=$(date +%s)
REMIND_DUE=true

if [ -f "$REMIND_LAST_FILE" ]; then
  REMIND_LAST=$(cat "$REMIND_LAST_FILE")
  if [ $(( REMIND_NOW - REMIND_LAST )) -lt "$REMIND_INTERVAL" ]; then
    REMIND_DUE=false
  fi
fi

if [ "$REMIND_DUE" = "true" ]; then
  REMIND_MSG=""

  # Check for debated plans not yet reviewed (debated_plan.md in done tasks' dirs)
  for f in "$TERRA_ROOT"/tasks/done/*.json; do
    [ -f "$f" ] || continue
    if command -v jq &>/dev/null; then
      role=$(jq -r '.role // ""' "$f")
      if [ "$role" = "debater" ]; then
        task_id=$(jq -r '.id' "$f")
        title=$(jq -r '.title' "$f")
        completed=$(jq -r '.completed_at // ""' "$f")
        # Check if there's a corresponding coder task — if not, plan wasn't actioned
        prefix=$(echo "$task_id" | sed 's/[0-9]*$//')
        coder_exists=$(ls "$TERRA_ROOT"/tasks/done/${prefix}*.json "$TERRA_ROOT"/tasks/active/${prefix}*.json "$TERRA_ROOT"/tasks/queue/${prefix}*.json 2>/dev/null | grep -v "$task_id" | head -1 || true)
        if [ -z "$coder_exists" ]; then
          REMIND_MSG="${REMIND_MSG}\n- Debated plan *${title}* (${task_id}) completed ${completed} — no downstream tasks found"
        fi
      fi
    fi
  done

  # Check for stale queued tasks (>4 hours old)
  for f in "$TERRA_ROOT"/tasks/queue/*.json; do
    [ -f "$f" ] || continue
    if command -v jq &>/dev/null; then
      created=$(jq -r '.created_at // ""' "$f")
      task_id=$(jq -r '.id' "$f")
      title=$(jq -r '.title' "$f")
      if [ -n "$created" ]; then
        created_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created" +%s 2>/dev/null || echo "0")
        age=$(( REMIND_NOW - created_epoch ))
        if [ "$age" -gt 14400 ]; then
          hours=$(( age / 3600 ))
          REMIND_MSG="${REMIND_MSG}\n- Queued task *${title}* (${task_id}) waiting ${hours}h"
        fi
      fi
    fi
  done

  if [ -n "$REMIND_MSG" ]; then
    alert "📋 Plan review reminder:${REMIND_MSG}" "INFO"
    log "Sent plan review reminder"
  fi

  echo "$REMIND_NOW" > "$REMIND_LAST_FILE"
fi
