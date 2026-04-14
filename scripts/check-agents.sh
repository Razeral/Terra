#!/bin/bash
set -euo pipefail

# Usage: check-agents.sh
# Shows all Terra agents with rich status inspection

TERRA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# --- ccusage resolution: prefer global binary, fall back to npx ---
CCUSAGE_BIN=""
if command -v ccusage &>/dev/null; then
  CCUSAGE_BIN="ccusage"
elif command -v npx &>/dev/null; then
  timeout 10 npx ccusage@latest --version &>/dev/null 2>&1 && CCUSAGE_BIN="npx ccusage@latest" || true
fi

ccusage_cmd() {
  if [ -n "$CCUSAGE_BIN" ]; then
    $CCUSAGE_BIN "$@"
  else
    return 1
  fi
}

# --- ccusage session cache (60s TTL) ---
CCUSAGE_CACHE_DIR="${TMPDIR:-/tmp}/terra-ccusage-cache"
CCUSAGE_CACHE_TTL=60
mkdir -p "$CCUSAGE_CACHE_DIR"

# Returns cached ccusage session JSON or fetches and caches it
ccusage_session_cached() {
  local session_id="$1"
  local cache_file="$CCUSAGE_CACHE_DIR/$session_id.json"
  local now
  now=$(date +%s)

  # Check cache freshness
  if [ -f "$cache_file" ]; then
    local mtime
    if stat -f %m "$cache_file" &>/dev/null; then
      mtime=$(stat -f %m "$cache_file")
    else
      mtime=$(stat -c %Y "$cache_file" 2>/dev/null || echo "0")
    fi
    if [ $((now - mtime)) -lt $CCUSAGE_CACHE_TTL ]; then
      cat "$cache_file"
      return 0
    fi
  fi

  # Fetch and cache
  local result
  result=$(ccusage_cmd session --id "$session_id" --json 2>/dev/null || echo "")
  if [ -n "$result" ]; then
    echo "$result" > "$cache_file"
    echo "$result"
    return 0
  fi
  return 1
}

# Helper: human-readable time ago from epoch seconds
time_ago() {
  local mtime="$1"
  local now
  now=$(date +%s)
  local diff=$((now - mtime))
  if [ $diff -lt 60 ]; then
    echo "${diff}s ago"
  elif [ $diff -lt 3600 ]; then
    echo "$((diff / 60))m ago"
  elif [ $diff -lt 86400 ]; then
    echo "$((diff / 3600))h ago"
  else
    echo "$((diff / 86400))d ago"
  fi
}

echo "=== Terra Agent Dashboard ==="
echo ""

# Collect counts
RUNNING=0
STOPPED=0
DONE_COUNT=$(find "$TERRA_ROOT/tasks/done" -name '*.json' -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
QUEUE_COUNT=$(find "$TERRA_ROOT/tasks/queue" -name '*.json' -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')

# Check active tasks (primary source of truth)
shopt -s nullglob
ACTIVE_TASKS=("$TERRA_ROOT"/tasks/active/*.json)
shopt -u nullglob
if [ ${#ACTIVE_TASKS[@]} -eq 0 ]; then
  echo "No active tasks."
  echo ""
  echo "Tasks: $QUEUE_COUNT queued, 0 active, $DONE_COUNT done"
  exit 0
fi

TOTAL_COST=0

for task_file in "${ACTIVE_TASKS[@]}"; do
  [ -f "$task_file" ] || continue
  task_id=$(basename "$task_file" .json)

  # Parse task metadata
  title=$(jq -r '.title // "(unknown)"' "$task_file" | cut -c1-50)
  role=$(jq -r '.role // "(unknown)"' "$task_file")
  task_status=$(jq -r '.status // "unknown"' "$task_file")
  assigned_to=$(jq -r '.assigned_to // empty' "$task_file")
  session_id=$(jq -r '.session_id // empty' "$task_file")

  # Check tmux session
  tmux_file="$TERRA_ROOT/logs/$task_id.tmux"
  tmux_session=""
  tmux_alive=false
  if [ -f "$tmux_file" ]; then
    tmux_session=$(cat "$tmux_file")
    if tmux has-session -t "$tmux_session" 2>/dev/null; then
      tmux_alive=true
    fi
  fi

  # Determine display status
  if [ "$tmux_alive" = true ]; then
    status_icon="🟢"
    status_label="RUNNING"
    RUNNING=$((RUNNING + 1))
  else
    status_icon="🔴"
    status_label="DEAD"
    STOPPED=$((STOPPED + 1))
  fi

  # Count commits on agent branch (only commits ahead of main)
  commits="-"
  if [ -n "$assigned_to" ] && [ "$assigned_to" != "in-place" ] && [ "$assigned_to" != "null" ]; then
    for project_dir in "$TERRA_ROOT"/projects/*/; do
      [ -d "$project_dir/.git" ] || [ -f "$project_dir/.git" ] || continue
      if git -C "$project_dir" rev-parse --verify "$assigned_to" &>/dev/null; then
        commits=$(git -C "$project_dir" log --oneline "main..$assigned_to" 2>/dev/null | wc -l | tr -d ' ')
        break
      fi
    done
  fi

  # Log file info
  log_file="$TERRA_ROOT/logs/$task_id.log"
  last_log="-"
  log_age="-"
  if [ -f "$log_file" ]; then
    # Get last non-empty line, strip ANSI codes
    last_log=$(tail -20 "$log_file" 2>/dev/null | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-60 || echo "-")
    [ -z "$last_log" ] && last_log="(empty)"
    # Get file mtime
    if stat -f %m "$log_file" &>/dev/null; then
      mtime=$(stat -f %m "$log_file")
    else
      mtime=$(stat -c %Y "$log_file" 2>/dev/null || echo "0")
    fi
    [ "$mtime" != "0" ] && log_age=$(time_ago "$mtime")
  fi

  # Get model from role file
  model="sonnet"
  role_file="$TERRA_ROOT/agents/roles/active/$role.md"
  [ ! -f "$role_file" ] && role_file="$TERRA_ROOT/agents/roles/_templates/$role.md"
  if [ -f "$role_file" ]; then
    m=$(sed -n '/^---$/,/^---$/{ s/^model: *//p; }' "$role_file" 2>/dev/null)
    [ -n "$m" ] && model="$m"
  fi

  # Cost lookup
  cost="-"
  stored_cost=$(jq -r '.cost.total_cost_usd // empty' "$task_file")
  if [ -n "$stored_cost" ] && [ "$stored_cost" != "0" ]; then
    cost=$(printf "\$%.4f" "$stored_cost")
    TOTAL_COST=$(echo "$TOTAL_COST + $stored_cost" | bc 2>/dev/null || echo "$TOTAL_COST")
  elif [ -n "$session_id" ]; then
    live_json=$(ccusage_session_cached "$session_id" 2>/dev/null || echo "")
    if [ -n "$live_json" ]; then
      live_cost=$(echo "$live_json" | jq -r '.totalCost // .total_cost_usd // empty' 2>/dev/null || echo "")
      if [ -n "$live_cost" ]; then
        cost=$(printf "\$%.4f" "$live_cost")
        TOTAL_COST=$(echo "$TOTAL_COST + $live_cost" | bc 2>/dev/null || echo "$TOTAL_COST")
      fi
    fi
  fi

  # Print agent block
  echo "$status_icon $task_id [$status_label] $role ($model) $cost"
  echo "   $title"
  echo "   Commits: $commits | Log: $log_age"
  if [ "$last_log" != "-" ] && [ "$last_log" != "(empty)" ]; then
    echo "   > $last_log"
  fi
  echo ""
done

# Summary line
echo "---"
echo "Summary: $RUNNING running, $STOPPED dead, $DONE_COUNT completed, $QUEUE_COUNT queued"
printf "Total estimated cost: \$%.4f\n" "$TOTAL_COST"
echo ""
echo "Commands:"
echo "  Attach:  tmux attach -t terra-<task-id>"
echo "  Kill:    tmux kill-session -t terra-<task-id>"
echo "  Merge:   scripts/merge-work.sh <project> <task-id>"
