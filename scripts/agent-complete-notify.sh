#!/bin/bash
set -uo pipefail

# Usage: agent-complete-notify.sh <task-id> [project]
# Sends a Telegram notification when a spawned agent finishes.
# Reads task status, commit count, and log tail to build the message.

TASK_ID="${1:?Usage: agent-complete-notify.sh <task-id> [project]}"
PROJECT="${2:-}"

TERRA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Find task file (active or done)
TASK_FILE=""
for dir in active done; do
  if [ -f "$TERRA_ROOT/tasks/$dir/$TASK_ID.json" ]; then
    TASK_FILE="$TERRA_ROOT/tasks/$dir/$TASK_ID.json"
    break
  fi
done

if [ -z "$TASK_FILE" ]; then
  echo "Warning: Task file not found for $TASK_ID, sending minimal notification"
fi

# Load Telegram credentials
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_USER_ID="${TELEGRAM_USER_ID:-}"
if [ -z "$TELEGRAM_BOT_TOKEN" ] && [ -f "$TERRA_ROOT/.env" ]; then
  TELEGRAM_BOT_TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' "$TERRA_ROOT/.env" 2>/dev/null | cut -d= -f2- || true)
  TELEGRAM_USER_ID=$(grep '^TELEGRAM_USER_ID=' "$TERRA_ROOT/.env" 2>/dev/null | cut -d= -f2- || true)
fi

if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_USER_ID" ]; then
  echo "No Telegram credentials found, skipping notification"
  exit 0
fi

# Extract task info
TITLE="$TASK_ID"
STATUS="unknown"
if [ -n "$TASK_FILE" ] && command -v jq &>/dev/null; then
  TITLE=$(jq -r '.title // .id' "$TASK_FILE")
  STATUS=$(jq -r '.status // "unknown"' "$TASK_FILE")
fi

# Count commits on agent branch
COMMIT_COUNT=0
if [ -n "$PROJECT" ]; then
  PROJECT_DIR="$TERRA_ROOT/projects/$PROJECT"
  BRANCH="agent/$TASK_ID"
  if [ -d "$PROJECT_DIR/.git" ] || [ -f "$PROJECT_DIR/.git" ]; then
    # Count commits on agent branch that aren't on main/master
    BASE_BRANCH=$(git -C "$PROJECT_DIR" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "main")
    COMMIT_COUNT=$(git -C "$PROJECT_DIR" log --oneline "$BASE_BRANCH..$BRANCH" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
  fi
fi

# Read last 5 lines of log
LOG_FILE="$TERRA_ROOT/logs/$TASK_ID.log"
LOG_TAIL=""
if [ -f "$LOG_FILE" ]; then
  LOG_TAIL=$(tail -5 "$LOG_FILE" 2>/dev/null | head -c 500 || true)
fi

# Determine icon
ICON="✅"
case "$STATUS" in
  done) ICON="✅" ;;
  failed) ICON="❌" ;;
  active) ICON="⚠️" ;;  # still active = likely crashed
  *) ICON="❓" ;;
esac

# Build message
MSG="$ICON *Agent Complete: $TASK_ID*
*Task:* $TITLE
*Status:* $STATUS
*Commits:* $COMMIT_COUNT"

if [ -n "$LOG_TAIL" ]; then
  # Escape markdown special chars in log tail
  ESCAPED_LOG=$(echo "$LOG_TAIL" | sed 's/[`*_]/\\&/g')
  MSG="$MSG

\`\`\`
$ESCAPED_LOG
\`\`\`"
fi

# Send notification
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d chat_id="$TELEGRAM_USER_ID" \
  --data-urlencode "text=$MSG" \
  -d parse_mode="Markdown" > /dev/null 2>&1 || true

echo "Telegram notification sent for $TASK_ID ($STATUS)"
