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

# Rebase agent branch onto latest main BEFORE merging.
# Why: if Agent A's branch was created from main at time T, and Agent B merged
# fixes into main between T and now, A's branch is "behind". A plain merge can
# silently reapply A's older content on top of B's fix if A rewrote the file
# wholesale (no conflict detected). Rebasing replays A's commits on top of
# latest main, so any lost-fix case surfaces as an explicit rebase conflict
# rather than a silently-reverted bugfix.
#
# Rebase happens inside the agent's worktree (the branch is checked out there).
if [ -d "$WORKTREE_DIR" ]; then
  echo "Rebasing $BRANCH onto $MAIN_BRANCH (prevents silent fix-loss)..."
  if ! git -C "$WORKTREE_DIR" rebase "$MAIN_BRANCH" 2>&1; then
    # Auto-resolve .task.json conflicts during rebase (agent state always wins)
    if git -C "$WORKTREE_DIR" diff --name-only --diff-filter=U 2>/dev/null | grep -qx '.task.json'; then
      echo "Rebase: auto-resolving .task.json with --theirs"
      git -C "$WORKTREE_DIR" checkout --theirs .task.json
      git -C "$WORKTREE_DIR" add .task.json
      git -C "$WORKTREE_DIR" rebase --continue 2>&1 || {
        git -C "$WORKTREE_DIR" rebase --abort 2>/dev/null || true
        echo "Rebase aborted — falling through to direct merge (will surface conflicts for review)"
      }
    else
      git -C "$WORKTREE_DIR" rebase --abort 2>/dev/null || true
      echo "Rebase aborted due to conflicts — falling through to direct merge"
      echo "Conflicted files visible via: git -C $WORKTREE_DIR status"
    fi
  else
    echo "Rebase clean — merge will be fast-forward"
  fi
fi

# Merge
PRE_MERGE_SHA=$(git -C "$PROJECT_DIR" rev-parse "$MAIN_BRANCH")
git -C "$PROJECT_DIR" checkout "$MAIN_BRANCH"
if ! git -C "$PROJECT_DIR" merge "$BRANCH" --no-ff -m "feat: merge $TASK_ID work from agent"; then
  # Auto-resolve .task.json conflicts by taking the branch (agent's) version —
  # agents always have the freshest task state. Same pattern as sub-mayor.sh.
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
    # Prefer global ccusage binary, fall back to npx
    if command -v ccusage &>/dev/null; then
      COST_JSON=$(ccusage session --id "$SESSION_ID" --json 2>/dev/null || echo "")
    else
      COST_JSON=$(npx ccusage@latest session --id "$SESSION_ID" --json 2>/dev/null || echo "")
    fi
    if [ -n "$COST_JSON" ]; then
      # Extract cost metrics — try multiple field name conventions
      # Token fields may be nested under .entries[] or flat at top level
      COST_DATA=$(echo "$COST_JSON" | jq '{
        total_cost_usd: (.totalCost // .total_cost_usd // 0),
        input_tokens: ([.entries[]?.inputTokens // 0] | add // 0),
        output_tokens: ([.entries[]?.outputTokens // 0] | add // 0),
        cache_read_tokens: ([.entries[]?.cacheReadTokens // 0] | add // 0),
        cache_creation_tokens: ([.entries[]?.cacheCreationTokens // 0] | add // 0)
      }' 2>/dev/null || echo "")
      # Remove zero-only token fields to avoid misleading data
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

# Auto-trigger BS dashboard rebuild if this merge touched build-solver/manifest.json
if [ "$PROJECT" = "build-solver" ]; then
  if git -C "$PROJECT_DIR" diff --name-only "$PRE_MERGE_SHA..HEAD" | grep -qx 'manifest.json'; then
    echo ""
    echo "=== manifest.json changed — rebuilding BS dashboard ==="
    if [ -x "$TERRA_ROOT/scripts/deploy-bs-dashboard.sh" ]; then
      if bash "$TERRA_ROOT/scripts/deploy-bs-dashboard.sh"; then
        echo "Dashboard redeploy complete."
      else
        echo "WARNING: deploy-bs-dashboard.sh failed. Merge succeeded but dashboard is stale — run it manually."
      fi
    else
      echo "WARNING: $TERRA_ROOT/scripts/deploy-bs-dashboard.sh not found or not executable."
    fi
  fi
fi

echo "Merge complete."
