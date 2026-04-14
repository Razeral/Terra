#!/bin/bash
set -euo pipefail

# Usage: merge-queue.sh
# Scans tasks/active/ for done tasks and auto-merges clean ones into main.
# Skips tasks with merge conflicts (Mayor handles manually).
# Can be run periodically or triggered after agent completion.

TERRA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERGED=0
SKIPPED=0
CONFLICTS=0

for TASK_FILE in "$TERRA_ROOT"/tasks/active/*.json; do
  [ -f "$TASK_FILE" ] || continue

  # Only process tasks with status "done"
  STATUS=$(jq -r '.status // ""' "$TASK_FILE" 2>/dev/null)
  [ "$STATUS" = "done" ] || continue

  TASK_ID=$(jq -r '.id // ""' "$TASK_FILE" 2>/dev/null)
  ASSIGNED=$(jq -r '.assigned_to // ""' "$TASK_FILE" 2>/dev/null)

  # Skip in-place tasks (no branch to merge)
  if [ "$ASSIGNED" = "in-place" ]; then
    echo "[$TASK_ID] Skipping in-place task (no branch)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  BRANCH="$ASSIGNED"
  # If assigned_to doesn't look like a branch, derive it
  if [[ "$BRANCH" != agent/* ]]; then
    BRANCH="agent/$TASK_ID"
  fi

  # Find the project directory from the worktree path
  # Convention: worktree is at projects/<project>/worktrees/<task-id>
  WORKTREE_DIR=""
  for PROJECT_DIR in "$TERRA_ROOT"/projects/*/; do
    [ -d "$PROJECT_DIR" ] || continue
    WT="$PROJECT_DIR/worktrees/$TASK_ID"
    if [ -d "$WT" ]; then
      WORKTREE_DIR="$WT"
      break
    fi
  done

  if [ -z "$PROJECT_DIR" ] || [ ! -d "$PROJECT_DIR" ]; then
    echo "[$TASK_ID] Warning: Could not find project directory, skipping"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Detect main branch
  MAIN_BRANCH=$(git -C "$PROJECT_DIR" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)
  if [ -z "$MAIN_BRANCH" ]; then
    if git -C "$PROJECT_DIR" show-ref --verify --quiet refs/heads/main 2>/dev/null; then
      MAIN_BRANCH="main"
    elif git -C "$PROJECT_DIR" show-ref --verify --quiet refs/heads/master 2>/dev/null; then
      MAIN_BRANCH="master"
    else
      MAIN_BRANCH=$(git -C "$PROJECT_DIR" branch --no-color | grep -v 'agent/' | sed 's/^[* ]*//' | head -1)
      MAIN_BRANCH="${MAIN_BRANCH:-main}"
    fi
  fi

  # Verify branch exists
  if ! git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$BRANCH" 2>/dev/null; then
    echo "[$TASK_ID] Warning: Branch $BRANCH not found, skipping"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Test if merge is clean (--no-commit --no-ff, then abort)
  echo "[$TASK_ID] Testing merge of $BRANCH into $MAIN_BRANCH..."
  git -C "$PROJECT_DIR" checkout "$MAIN_BRANCH" --quiet 2>/dev/null

  if git -C "$PROJECT_DIR" merge --no-commit --no-ff "$BRANCH" --quiet 2>/dev/null; then
    # Clean merge possible — abort the test merge, then do the real one
    git -C "$PROJECT_DIR" merge --abort 2>/dev/null || true

    echo "[$TASK_ID] Clean merge — merging..."
    git -C "$PROJECT_DIR" merge "$BRANCH" --no-ff -m "feat: merge $TASK_ID work from agent"

    # Harvest cost data
    SESSION_ID=$(jq -r '.session_id // empty' "$TASK_FILE" 2>/dev/null)
    if [ -n "$SESSION_ID" ]; then
      if command -v ccusage &>/dev/null; then
        COST_JSON=$(ccusage session --id "$SESSION_ID" --json 2>/dev/null || echo "")
      else
        COST_JSON=$(npx ccusage@latest session --id "$SESSION_ID" --json 2>/dev/null || echo "")
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
          printf "  [$TASK_ID] Cost: \$%.4f\n" "$COST_DISPLAY"
        fi
      fi
    fi

    # Mark task as done with timestamp and move to done/
    jq '.status = "done" | .completed_at = (now | todate)' "$TASK_FILE" > "$TASK_FILE.tmp"
    mv "$TASK_FILE.tmp" "$TASK_FILE"
    mv "$TASK_FILE" "$TERRA_ROOT/tasks/done/"

    # Clean up worktree
    if [ -n "$WORKTREE_DIR" ] && [ -d "$WORKTREE_DIR" ]; then
      git -C "$PROJECT_DIR" worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
      echo "  [$TASK_ID] Worktree removed"
    fi

    # Clean up branch
    git -C "$PROJECT_DIR" branch -d "$BRANCH" 2>/dev/null || true

    # Clean up log artifacts
    rm -f "$TERRA_ROOT/logs/$TASK_ID.tmux"
    rm -f "$TERRA_ROOT/logs/$TASK_ID.pid"

    echo "  [$TASK_ID] Merged and cleaned up"
    MERGED=$((MERGED + 1))
  else
    # Merge has conflicts — abort and skip
    git -C "$PROJECT_DIR" merge --abort 2>/dev/null || true
    echo "[$TASK_ID] Merge conflicts detected — skipping (requires manual merge)"
    CONFLICTS=$((CONFLICTS + 1))
  fi
done

echo ""
echo "=== Merge Queue Summary ==="
echo "  Merged:    $MERGED"
echo "  Conflicts: $CONFLICTS"
echo "  Skipped:   $SKIPPED"
