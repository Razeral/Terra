#!/bin/bash
set -euo pipefail
trap 'echo "TRAP: exit code $? at line $LINENO cmd=${BASH_COMMAND}" >> "${LOG:-/tmp/sub-mayor-trap.log}" 2>/dev/null; echo "TRAP: exit code $? at line $LINENO cmd=${BASH_COMMAND}" >&2' ERR

# Generic Sub-Mayor: monitors a set of tasks, spawns agents, retries failures.
# Usage: sub-mayor.sh <pipeline-name> <project> <task-id>...
#
# Features:
# - Always starts with a planner task (first task-id should be a planner)
# - Polls every 60s for task status changes
# - Spawns agents when dependencies are satisfied
# - Detects dead agents (tmux gone) and checks worktree for actual completion
# - Retries failed tasks up to MAX_RETRIES times (copies predecessor log)
# - Capacity governor: limits concurrent agents to MAX_CONCURRENT
# - Dynamic task discovery: picks up new tasks created by planner agents
# - Exits when all tasks reach terminal state

PIPELINE="${1:?Usage: sub-mayor.sh <pipeline-name> <project> <task-id>...}"
PROJECT="${2:?Missing project}"
shift 2
MANAGED_TASKS=("$@")

TERRA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$TERRA_ROOT/logs/sub-mayor-${PIPELINE}.log"
POLL_INTERVAL=60
MAX_RETRIES=2
MAX_CONCURRENT=4

# Retry tracking via temp files (bash 3 compat, no associative arrays)
RETRY_DIR="${TMPDIR:-/tmp}/terra-sub-mayor-${PIPELINE}-retries"
mkdir -p "$RETRY_DIR"

get_retries() { cat "$RETRY_DIR/$1" 2>/dev/null || echo 0; }
set_retries() { echo "$2" > "$RETRY_DIR/$1"; }

log() {
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$ts] $*" | tee -a "$LOG"
}

# Find task file across all directories
find_task_file() {
  local tid="$1"
  for dir in "$TERRA_ROOT/tasks/active" "$TERRA_ROOT/tasks/done" "$TERRA_ROOT/tasks/queue"; do
    if [ -f "$dir/$tid.json" ]; then
      echo "$dir/$tid.json"
      return
    fi
  done
}

task_status() {
  local f
  f=$(find_task_file "$1")
  [ -n "$f" ] && jq -r '.status // "unknown"' "$f" || echo "missing"
}

is_done() { [ "$(task_status "$1")" = "done" ]; }
is_failed() { [ "$(task_status "$1")" = "failed" ]; }
is_pending() { [ "$(task_status "$1")" = "pending" ]; }
is_active() { [ "$(task_status "$1")" = "active" ]; }
is_merge_conflict() { [ "$(task_status "$1")" = "merge_conflict" ]; }

is_terminal() {
  local s
  s=$(task_status "$1")
  [ "$s" = "done" ] || [ "$s" = "failed" ] || [ "$s" = "merge_conflict" ]
}

deps_satisfied() {
  local f
  f=$(find_task_file "$1")
  [ -z "$f" ] && return 1
  local deps
  deps=$(jq -r '.depends_on[]? // empty' "$f" 2>/dev/null)
  [ -z "$deps" ] && return 0
  while IFS= read -r dep; do
    is_done "$dep" || return 1
  done <<< "$deps"
  return 0
}

# Count currently active (spawned) agents across this pipeline
count_active() {
  local count=0
  for tid in "${MANAGED_TASKS[@]}"; do
    if is_active "$tid"; then count=$((count + 1)); fi
  done
  echo "$count"
}

# Check if a "dead" agent actually completed in the worktree
check_worktree_completion() {
  local tid="$1"
  local worktree="$TERRA_ROOT/projects/$PROJECT/worktrees/$tid"
  if [ -f "$worktree/.task.json" ]; then
    local wt_status
    wt_status=$(jq -r '.status // "unknown"' "$worktree/.task.json" 2>/dev/null)
    if [ "$wt_status" = "done" ]; then
      return 0
    fi
  fi
  return 1
}

# Sync done status from worktree and trigger merge
sync_and_merge() {
  local tid="$1"
  log "SYNC: $tid completed in worktree — merging"
  # Run merge in subshell so failures don't kill the sub-mayor
  if (echo y | bash "$TERRA_ROOT/scripts/merge-work.sh" "$PROJECT" "$tid" 2>&1 | tee -a "$LOG"); then
    log "MERGED: $tid"
  else
    log "MERGE-FAIL: $tid — attempting conflict resolution"
    # Try to resolve .task.json conflicts (most common) and complete the merge
    local project_dir="$TERRA_ROOT/projects/$PROJECT"
    if git -C "$project_dir" diff --name-only --diff-filter=U 2>/dev/null | grep -q '.task.json'; then
      git -C "$project_dir" checkout --theirs .task.json 2>/dev/null
      git -C "$project_dir" add .task.json 2>/dev/null
    fi
    # Check if there are remaining conflicts
    if git -C "$project_dir" diff --name-only --diff-filter=U 2>/dev/null | grep -qv '.task.json'; then
      local conflicted
      conflicted=$(git -C "$project_dir" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')
      log "MERGE-CONFLICT: $tid has non-trivial conflicts in: $conflicted"
      log "MERGE-CONFLICT: $tid — marking as merge_conflict, needs manual resolution"
      git -C "$project_dir" merge --abort 2>/dev/null || true
      # Mark task as merge_conflict (terminal state, not retried)
      local task_file="$TERRA_ROOT/tasks/active/$tid.json"
      if [ -f "$task_file" ]; then
        jq --arg files "$conflicted" \
          '.status = "merge_conflict" | .notes = ("Non-trivial merge conflicts in: " + $files + ". Resolve manually with: git merge agent/" + .id)' \
          "$task_file" > "$task_file.tmp" && mv "$task_file.tmp" "$task_file"
      fi
      return 0
    fi
    # Complete the merge
    if git -C "$project_dir" commit --no-edit 2>&1 | tee -a "$LOG"; then
      # Clean up worktree
      local worktree="$project_dir/worktrees/$tid"
      [ -d "$worktree" ] && git -C "$project_dir" worktree remove "$worktree" --force 2>/dev/null || true
      # Move task to done
      if [ -f "$TERRA_ROOT/tasks/active/$tid.json" ]; then
        jq '.status = "done"' "$TERRA_ROOT/tasks/active/$tid.json" > "$TERRA_ROOT/tasks/done/$tid.json"
        rm -f "$TERRA_ROOT/tasks/active/$tid.json"
      fi
      log "MERGED: $tid (after conflict resolution)"
    else
      log "MERGE-FAIL: $tid — commit failed, marking as merge_conflict"
      git -C "$project_dir" merge --abort 2>/dev/null || true
      local task_file="$TERRA_ROOT/tasks/active/$tid.json"
      if [ -f "$task_file" ]; then
        jq '.status = "merge_conflict" | .notes = "Merge commit failed, needs manual resolution"' \
          "$task_file" > "$task_file.tmp" && mv "$task_file.tmp" "$task_file"
      fi
      return 0
    fi
  fi
  return 0
}

# Copy predecessor log into worktree for retry context
save_predecessor_log() {
  local tid="$1"
  local old_worktree="$TERRA_ROOT/projects/$PROJECT/worktrees/$tid"
  local old_log="$TERRA_ROOT/logs/$tid.log"
  local predecessor_log="${TMPDIR:-/tmp}/terra-sub-mayor-${PIPELINE}-predecessor-${tid}.log"

  # Save from worktree .task.json notes + agent log
  {
    if [ -f "$old_worktree/.task.json" ]; then
      echo "=== Previous .task.json ==="
      cat "$old_worktree/.task.json"
      echo ""
    fi
    if [ -f "$old_log" ] && [ -s "$old_log" ]; then
      echo "=== Previous agent log (last 200 lines) ==="
      tail -200 "$old_log"
    fi
  } > "$predecessor_log" 2>/dev/null || true

  echo "$predecessor_log"
}

# Clean up failed task and reset for retry
retry_task() {
  local tid="$1"
  local retries
  retries=$(get_retries "$tid")
  retries=$((retries + 1))
  set_retries "$tid" "$retries"

  if [ "$retries" -gt "$MAX_RETRIES" ]; then
    log "MAX-RETRIES: $tid exceeded $MAX_RETRIES retries — giving up"
    return 1
  fi

  log "RETRY: $tid (attempt $retries/$MAX_RETRIES)"

  # Save predecessor context before cleanup
  local pred_log
  pred_log=$(save_predecessor_log "$tid")

  # Clean up old worktree and branch
  local worktree="$TERRA_ROOT/projects/$PROJECT/worktrees/$tid"
  local branch="agent/$tid"
  if [ -d "$worktree" ]; then
    git -C "$TERRA_ROOT/projects/$PROJECT" worktree remove "$worktree" --force 2>/dev/null || true
  fi
  git -C "$TERRA_ROOT/projects/$PROJECT" branch -D "$branch" 2>/dev/null || true

  # Reset task: move back to queue, set pending
  local task_file
  task_file=$(find_task_file "$tid")
  if [ -n "$task_file" ]; then
    jq '.status = "pending" | .assigned_to = null | del(.tmux_session, .session_id, .notes)' "$task_file" > "$task_file.tmp"
    mv "$task_file.tmp" "$TERRA_ROOT/tasks/queue/$tid.json"
    # Remove from active/done if it was there
    rm -f "$TERRA_ROOT/tasks/active/$tid.json" "$TERRA_ROOT/tasks/done/$tid.json"
  fi

  # Stash predecessor log path for spawn_task to pick up
  echo "$pred_log" > "$RETRY_DIR/${tid}.predlog"

  # Clean up old tmux/log artifacts
  rm -f "$TERRA_ROOT/logs/$tid.tmux"

  log "RESET: $tid back to queue for retry (predecessor log saved)"
}

spawn_task() {
  local tid="$1"
  local task_file="$TERRA_ROOT/tasks/queue/$tid.json"

  if [ ! -f "$task_file" ]; then
    log "WARN: $tid not found in queue, skipping spawn"
    return 1
  fi

  # Capacity governor: check concurrent agent count
  local active_count
  active_count=$(count_active)
  if [ "$active_count" -ge "$MAX_CONCURRENT" ]; then
    log "THROTTLE: $tid waiting — $active_count/$MAX_CONCURRENT agents active"
    return 1
  fi

  local role
  role=$(jq -r '.role // "coder"' "$task_file")
  local role_file="$TERRA_ROOT/agents/roles/active/$role.md"
  if [ ! -f "$role_file" ]; then
    log "WARN: role file $role_file not found, using coder"
    role="coder"
  fi

  mv "$task_file" "$TERRA_ROOT/tasks/active/$tid.json"
  log "SPAWN: $tid (role=$role, retry=$(get_retries "$tid"), active=$((active_count + 1))/$MAX_CONCURRENT)"

  bash "$TERRA_ROOT/scripts/spawn-agent.sh" "$PROJECT" "$tid" "$role" 2>&1 | tee -a "$LOG"

  # If this is a retry, copy predecessor log into the worktree
  local pred_path="$RETRY_DIR/${tid}.predlog"
  if [ -f "$pred_path" ]; then
    local pred_log
    pred_log=$(cat "$pred_path")
    local worktree="$TERRA_ROOT/projects/$PROJECT/worktrees/$tid"
    if [ -f "$pred_log" ] && [ -d "$worktree" ]; then
      cp "$pred_log" "$worktree/.predecessor-log"
      log "PREDECESSOR: copied log to $worktree/.predecessor-log"
    fi
    rm -f "$pred_path"
  fi
}

# Discover new tasks created by planner agents (e.g., task-aal0X in queue)
discover_new_tasks() {
  local prefix="task-${PIPELINE}"
  local discovered=0
  for f in "$TERRA_ROOT/tasks/queue/${prefix}"*.json "$TERRA_ROOT/tasks/active/${prefix}"*.json; do
    [ -f "$f" ] || continue
    local tid
    tid=$(basename "$f" .json)
    # Check if already managed
    local found=false
    for existing in "${MANAGED_TASKS[@]}"; do
      if [ "$existing" = "$tid" ]; then
        found=true
        break
      fi
    done
    if ! $found; then
      MANAGED_TASKS+=("$tid")
      discovered=$((discovered + 1))
      log "DISCOVERED: $tid added to pipeline (total: ${#MANAGED_TASKS[@]})"
    fi
  done
  if [ "$discovered" -gt 0 ]; then
    log "DISCOVERY: found $discovered new tasks"
  fi
}

# --- Main loop ---

log "=========================================="
log "Sub-Mayor [$PIPELINE] started"
log "Project: $PROJECT"
log "Managing ${#MANAGED_TASKS[@]} tasks: ${MANAGED_TASKS[*]}"
log "Poll interval: ${POLL_INTERVAL}s, Max retries: $MAX_RETRIES, Max concurrent: $MAX_CONCURRENT"
log "=========================================="

while true; do
  ALL_TERMINAL=true
  SPAWNED_ANY=false

  # Discover tasks created by planner/coder agents mid-flight
  discover_new_tasks

  for tid in "${MANAGED_TASKS[@]}"; do
    # --- Handle active tasks: check for dead agents ---
    if is_active "$tid"; then
      ALL_TERMINAL=false
      tmux_file="$TERRA_ROOT/logs/$tid.tmux"
      if [ -f "$tmux_file" ]; then
        tmux_session=$(cat "$tmux_file")
        if ! tmux has-session -t "$tmux_session" 2>/dev/null; then
          # Agent tmux is dead — did it complete in the worktree?
          if check_worktree_completion "$tid"; then
            log "COMPLETED: $tid (agent finished, tmux exited normally)"
            sync_and_merge "$tid" || log "SYNC-ERROR: $tid sync_and_merge returned non-zero (continuing)"
          else
            log "DEAD: $tid tmux gone, not completed — will retry"
            task_file="$TERRA_ROOT/tasks/active/$tid.json"
            jq '.status = "failed" | .notes = "tmux session died before completion"' "$task_file" > "$task_file.tmp"
            mv "$task_file.tmp" "$task_file"
            # Retry immediately
            retry_task "$tid" || true
          fi
        fi
      fi
      continue
    fi

    # --- Handle failed tasks: retry if under limit ---
    if is_failed "$tid"; then
      retries="$(get_retries "$tid")"
      if [ "$retries" -lt "$MAX_RETRIES" ]; then
        ALL_TERMINAL=false
        retry_task "$tid" || true
      fi
      # If at max retries, treat as terminal
      continue
    fi

    # --- Handle missing tasks ---
    if [ "$(task_status "$tid")" = "missing" ]; then
      log "MISSING: $tid — task file not found in any directory, skipping"
      continue
    fi

    # --- Handle done tasks ---
    if is_done "$tid"; then
      continue
    fi

    # --- Handle merge_conflict tasks: terminal, no retry ---
    if is_merge_conflict "$tid"; then
      continue
    fi

    # --- Handle pending tasks: spawn if deps met ---
    if is_pending "$tid"; then
      ALL_TERMINAL=false
      if deps_satisfied "$tid"; then
        spawn_task "$tid" && SPAWNED_ANY=true
        sleep 3
      fi
    fi
  done

  # Check if all truly done or max-retried
  if $ALL_TERMINAL; then
    log "=========================================="
    log "ALL TASKS TERMINAL — Pipeline complete!"
    log ""
    DONE_COUNT=0
    FAIL_COUNT=0
    CONFLICT_COUNT=0
    for tid in "${MANAGED_TASKS[@]}"; do
      if is_done "$tid"; then
        DONE_COUNT=$((DONE_COUNT + 1))
        log "  DONE: $tid"
      elif is_merge_conflict "$tid"; then
        CONFLICT_COUNT=$((CONFLICT_COUNT + 1))
        log "  MERGE_CONFLICT: $tid (needs manual merge of agent/$tid)"
      else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        log "  FAIL: $tid (retries: $(get_retries "$tid"))"
      fi
    done
    log ""
    log "Result: $DONE_COUNT done, $CONFLICT_COUNT merge_conflict, $FAIL_COUNT failed out of ${#MANAGED_TASKS[@]}"
    log "=========================================="
    exit 0
  fi

  # Status snapshot
  log "--- Status check ---"
  for tid in "${MANAGED_TASKS[@]}"; do
    s=$(task_status "$tid")
    r="$(get_retries "$tid")"
    extra=""
    if [ "$r" -gt 0 ]; then extra=" (retries: $r)"; fi
    log "  $tid: $s$extra"
  done

  sleep "$POLL_INTERVAL"
done
