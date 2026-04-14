#!/bin/bash
# Hook script: updates mayor-state.json timestamp, heartbeat, and live task snapshot
# Called by PostToolUse hook in .claude/settings.local.json
# The full state content (goals, discussion, next_steps) is updated by the Mayor LLM
# at natural breakpoints; this script auto-captures live operational data so any
# responder (terminal Mayor, Telegram responder) has fresh context.

TERRA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_FILE="$TERRA_ROOT/logs/mayor-state.json"
HEARTBEAT_FILE="$TERRA_ROOT/logs/mayor-heartbeat"
INBOX_FILE="$TERRA_ROOT/logs/mayor-inbox.jsonl"
OUTBOX_FILE="$TERRA_ROOT/logs/mayor-outbox.jsonl"
INBOX_PENDING_FILE="$TERRA_ROOT/logs/inbox-pending"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Update heartbeat
echo "$NOW" > "$HEARTBEAT_FILE"

# Update timestamp + live snapshot in state file
if [ -f "$STATE_FILE" ] && command -v jq &>/dev/null; then
  # Snapshot active tasks
  ACTIVE_TASKS="[]"
  if [ -d "$TERRA_ROOT/tasks/active" ]; then
    ACTIVE_TASKS=$(find "$TERRA_ROOT/tasks/active" -name '*.json' -exec cat {} + 2>/dev/null \
      | jq -s '[.[] | {id, title, status, role, assigned_to}]' 2>/dev/null || echo "[]")
  fi

  # Snapshot running tmux sessions
  RUNNING_AGENTS="[]"
  if command -v tmux &>/dev/null; then
    RUNNING_AGENTS=$(tmux list-sessions -F '#{session_name}' 2>/dev/null \
      | grep '^terra-task-' \
      | sed 's/terra-task-//' \
      | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")
  fi

  TMP="$STATE_FILE.tmp"
  jq --arg ts "$NOW" \
     --argjson active "$ACTIVE_TASKS" \
     --argjson agents "$RUNNING_AGENTS" \
     '.updated_at = $ts | .live = {active_tasks: $active, running_agents: $agents}' \
     "$STATE_FILE" > "$TMP" 2>/dev/null && mv "$TMP" "$STATE_FILE"
fi

# Track pending inbox count
if [ -f "$INBOX_FILE" ]; then
  INBOX_COUNT=$(wc -l < "$INBOX_FILE" | tr -d ' ')
  OUTBOX_COUNT=0
  if [ -f "$OUTBOX_FILE" ]; then
    OUTBOX_COUNT=$(wc -l < "$OUTBOX_FILE" | tr -d ' ')
  fi
  PENDING=$(( INBOX_COUNT - OUTBOX_COUNT ))
  [ "$PENDING" -lt 0 ] && PENDING=0
  echo "$PENDING" > "$INBOX_PENDING_FILE"
fi
