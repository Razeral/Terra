#!/bin/bash
set -euo pipefail

# Usage: merge-work.sh <project> <task-id>
# Merges a completed agent's worktree branch back to main

PROJECT="${1:?Usage: merge-work.sh <project> <task-id>}"
TASK_ID="${2:?Missing task-id}"

TERRA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$TERRA_ROOT/projects/$PROJECT"
WORKTREE_DIR="$PROJECT_DIR/worktrees/$TASK_ID"
BRANCH="agent/$TASK_ID"

if [ ! -d "$PROJECT_DIR" ]; then
  echo "Error: Project not found at $PROJECT_DIR"
  exit 1
fi

# Show what will be merged
echo "=== Merge Preview ==="
echo "Project: $PROJECT"
echo "Branch:  $BRANCH"
echo ""

# Detect main branch: try remote HEAD, then common names, then fall back to current branch
MAIN_BRANCH=$(git -C "$PROJECT_DIR" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)
if [ -z "$MAIN_BRANCH" ]; then
  if git -C "$PROJECT_DIR" show-ref --verify --quiet refs/heads/main 2>/dev/null; then
    MAIN_BRANCH="main"
  elif git -C "$PROJECT_DIR" show-ref --verify --quiet refs/heads/master 2>/dev/null; then
    MAIN_BRANCH="master"
  else
    # Fall back to whatever non-agent branch exists (e.g. v2, develop)
    MAIN_BRANCH=$(git -C "$PROJECT_DIR" branch --no-color | grep -v 'agent/' | sed 's/^[* ]*//' | head -1)
    MAIN_BRANCH="${MAIN_BRANCH:-main}"
  fi
fi

echo "Changes to merge into $MAIN_BRANCH:"
git -C "$PROJECT_DIR" log "$MAIN_BRANCH..$BRANCH" --oneline 2>/dev/null || {
  echo "Could not compare branches. Showing branch log:"
  git -C "$PROJECT_DIR" log "$BRANCH" --oneline -5
}
echo ""

read -p "Proceed with merge? [y/N] " confirm
if [[ "$confirm" != [yY] ]]; then
  echo "Aborted."
  exit 0
fi

# Merge
git -C "$PROJECT_DIR" checkout "$MAIN_BRANCH"
if ! git -C "$PROJECT_DIR" merge "$BRANCH" --no-ff -m "feat: merge $TASK_ID work from agent"; then
  # Auto-resolve .task.json conflicts by taking the branch (agent's) version
  if git -C "$PROJECT_DIR" diff --name-only --diff-filter=U 2>/dev/null | grep -qx '.task.json'; then
    echo "Auto-resolving .task.json conflict with --theirs"
    git -C "$PROJECT_DIR" checkout --theirs .task.json
    git -C "$PROJECT_DIR" add .task.json
  fi
  # If there are still unresolved conflicts, bail out
  if [ -n "$(git -C "$PROJECT_DIR" diff --name-only --diff-filter=U 2>/dev/null)" ]; then
    echo "Unresolved conflicts remain:"
    git -C "$PROJECT_DIR" diff --name-only --diff-filter=U
    echo "Aborting merge."
    git -C "$PROJECT_DIR" merge --abort 2>/dev/null || true
    exit 1
  fi
  # Complete the merge with the auto-resolutions
  git -C "$PROJECT_DIR" commit --no-edit
fi

# Cleanup worktree
if [ -d "$WORKTREE_DIR" ]; then
  git -C "$PROJECT_DIR" worktree remove "$WORKTREE_DIR" --force
  echo "Worktree removed."
fi

# Cleanup pid file
rm -f "$TERRA_ROOT/logs/$TASK_ID.pid"

# Harvest cost data from ccusage before moving task
TASK_FILE="$TERRA_ROOT/tasks/active/$TASK_ID.json"
if [ -f "$TASK_FILE" ] && command -v jq &>/dev/null; then
  SESSION_ID=$(jq -r '.session_id // empty' "$TASK_FILE")
  if [ -n "$SESSION_ID" ]; then
    echo "Harvesting cost data for session $SESSION_ID..."
    if command -v ccusage &>/dev/null; then
      COST_JSON=$(ccusage session --id "$SESSION_ID" --json 2>/dev/null || echo "")
    elif command -v npx &>/dev/null; then
      COST_JSON=$(npx ccusage@latest session --id "$SESSION_ID" --json 2>/dev/null || echo "")
    else
      COST_JSON=""
    fi
    if [ -n "$COST_JSON" ]; then
      COST_DATA=$(echo "$COST_JSON" | jq '{
        total_cost_usd: (.totalCost // .total_cost_usd // 0),
        input_tokens: ([.entries[]?.inputTokens // 0] | add // 0),
        output_tokens: ([.entries[]?.outputTokens // 0] | add // 0),
        cache_read_tokens: ([.entries[]?.cacheReadTokens // 0] | add // 0),
        cache_creation_tokens: ([.entries[]?.cacheCreationTokens // 0] | add // 0)
      }' 2>/dev/null || echo "")
      if [ -n "$COST_DATA" ]; then
        COST_DATA=$(echo "$COST_DATA" | jq 'with_entries(select(.key == "total_cost_usd" or .value != 0))' 2>/dev/null || echo "$COST_DATA")
        jq --argjson cost "$COST_DATA" '.cost = $cost' "$TASK_FILE" > "$TASK_FILE.tmp"
        mv "$TASK_FILE.tmp" "$TASK_FILE"
        COST_DISPLAY=$(echo "$COST_DATA" | jq -r '.total_cost_usd')
        printf "  Cost: \$%.4f\n" "$COST_DISPLAY"
      fi
    else
      echo "  Warning: Could not retrieve cost data from ccusage"
    fi
  fi

  # Mark task as done with timestamp
  jq '.status = "done" | .completed_at = (now | todate)' "$TASK_FILE" > "$TASK_FILE.tmp"
  mv "$TASK_FILE.tmp" "$TASK_FILE"

  mv "$TASK_FILE" "$TERRA_ROOT/tasks/done/"
else
  # Fallback: move without cost data
  [ -f "$TERRA_ROOT/tasks/active/$TASK_ID.json" ] && \
    mv "$TERRA_ROOT/tasks/active/$TASK_ID.json" "$TERRA_ROOT/tasks/done/"
fi

echo "Merge complete."
