#!/bin/bash
set -uo pipefail
shopt -s nullglob

# Usage: run-janitor.sh [--fix]
# Scans for stale tasks, dead agents, and orphaned worktrees.
# Writes findings to logs/janitor-report.json.
# With --fix, auto-resolves safe issues (dead agents → failed, orphaned worktrees → removed).

TERRA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPORT="$TERRA_ROOT/logs/janitor-report.json"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
FIX=false

[ "${1:-}" = "--fix" ] && FIX=true

# Collect findings as JSON array
FINDINGS="[]"

# Detect the base branch of a git repo (main, master, or origin/HEAD target).
# Echoes the base ref name; empty on failure.
detect_base_branch() {
  local dir="$1"
  local ref
  ref=$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return
  fi
  for candidate in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$candidate"; then
      echo "$candidate"
      return
    fi
  done
  echo ""
}

add_finding() {
  local type="$1" severity="$2" target="$3" detail="$4" action="$5"
  FINDINGS=$(echo "$FINDINGS" | jq \
    --arg type "$type" \
    --arg severity "$severity" \
    --arg target "$target" \
    --arg detail "$detail" \
    --arg action "$action" \
    '. + [{"type": $type, "severity": $severity, "target": $target, "detail": $detail, "suggested_action": $action}]')
}

# --- 1. Dead agents: active tasks whose tmux session is gone ---

for task_file in "$TERRA_ROOT"/tasks/active/*.json; do
  [ -f "$task_file" ] || continue
  task_id=$(jq -r '.id' "$task_file")
  tmux_session=$(jq -r '.tmux_session // empty' "$task_file")
  branch=$(jq -r '.assigned_to // empty' "$task_file")

  if [ -n "$tmux_session" ]; then
    if ! tmux has-session -t "$tmux_session" 2>/dev/null; then
      # Check if the worktree branch has commits beyond the base
      has_work=false
      if [ -n "$branch" ]; then
        # Find the worktree path from any project
        for project_dir in "$TERRA_ROOT"/projects/*/; do
          wt_path="${project_dir}worktrees/${task_id}"
          if [ -d "$wt_path" ]; then
            base=$(detect_base_branch "$wt_path")
            if [ -n "$base" ]; then
              commit_count=$(git -C "$wt_path" rev-list --count "HEAD" "^$base" 2>/dev/null || echo "0")
            else
              commit_count=0
            fi
            [ "$commit_count" -gt 0 ] && has_work=true
            break
          fi
        done
      fi

      if [ "$has_work" = true ]; then
        add_finding "dead-agent" "medium" "$task_id" \
          "tmux session '$tmux_session' is dead but worktree has commits" \
          "review-and-merge"
      else
        add_finding "dead-agent" "low" "$task_id" \
          "tmux session '$tmux_session' is dead, no commits found" \
          "mark-failed"
        if [ "$FIX" = true ]; then
          jq --arg ts "$NOW" '.status = "failed" | .completed_at = $ts' "$task_file" > "$task_file.tmp" \
            && mv "$task_file.tmp" "$task_file" \
            && mv "$task_file" "$TERRA_ROOT/tasks/done/"
        fi
      fi
    fi
  fi
done

# --- 1b. No-worktree stuck-done: --no-worktree agents that committed and exited
#         but left task status=active (saw this with task-efp-mv — agent commits
#         on master, tmux dies, but .task.json in tasks/active/ never updates). ---

for task_file in "$TERRA_ROOT"/tasks/active/*.json; do
  [ -f "$task_file" ] || continue
  task_id=$(jq -r '.id' "$task_file")
  tmux_session=$(jq -r '.tmux_session // empty' "$task_file")
  assigned_to=$(jq -r '.assigned_to // empty' "$task_file")

  # --no-worktree pattern: assigned_to == "in-place" in spawn-agent.sh
  [ "$assigned_to" != "in-place" ] && continue
  # Must be a dead session
  [ -z "$tmux_session" ] && continue
  tmux has-session -t "$tmux_session" 2>/dev/null && continue

  # Look for a commit on the current branch of the Terra repo whose message
  # references this task id. If found, the agent did its work — promote.
  if git -C "$TERRA_ROOT" log --oneline -20 | grep -qE "(^|[^a-z])${task_id}([^a-z]|$)"; then
    add_finding "stuck-done-inplace" "low" "$task_id" \
      "In-place agent's tmux is dead and a commit referencing $task_id is on master — task stayed active" \
      "auto-mark-done"
    if [ "$FIX" = true ]; then
      jq --arg ts "$NOW" '.status = "done" | .completed_at = $ts | .notes = ((.notes // "") + " [reconciled by janitor: in-place commit landed but status was stale]")' "$task_file" > "$task_file.tmp" \
        && mv "$task_file.tmp" "$task_file" \
        && mv "$task_file" "$TERRA_ROOT/tasks/done/"
    fi
  fi
done

# --- 2. Stale queue: pending tasks that have been sitting too long ---

for task_file in "$TERRA_ROOT"/tasks/queue/*.json; do
  [ -f "$task_file" ] || continue
  task_id=$(jq -r '.id' "$task_file")
  title=$(jq -r '.title' "$task_file")
  created_at=$(jq -r '.created_at // empty' "$task_file")

  if [ -n "$created_at" ]; then
    # Calculate age in seconds
    created_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${created_at%Z}" +%s 2>/dev/null || echo "0")
    now_epoch=$(date +%s)
    age_hours=$(( (now_epoch - created_epoch) / 3600 ))

    if [ "$age_hours" -gt 24 ]; then
      add_finding "stale-queue" "low" "$task_id" \
        "Queued for ${age_hours}h: $title" \
        "review-relevance"
    fi
  fi
done

# --- 3. Orphaned worktrees: worktree dirs with no matching active task ---

for project_dir in "$TERRA_ROOT"/projects/*/; do
  [ -d "${project_dir}worktrees" ] || continue
  for wt_dir in "${project_dir}worktrees"/*/; do
    [ -d "$wt_dir" ] || continue
    wt_name=$(basename "$wt_dir")

    # Check if there's a matching active task
    has_task=false
    for task_file in "$TERRA_ROOT"/tasks/active/*.json; do
      [ -f "$task_file" ] || continue
      tid=$(jq -r '.id' "$task_file")
      if [ "$tid" = "$wt_name" ]; then
        has_task=true
        break
      fi
    done

    if [ "$has_task" = false ]; then
      # Check if it has unmerged commits
      project_name=$(basename "$project_dir")
      base=$(detect_base_branch "$wt_dir")
      if [ -n "$base" ]; then
        commit_count=$(git -C "$wt_dir" rev-list --count "HEAD" "^$base" 2>/dev/null || echo "0")
      else
        commit_count=0
      fi

      if [ "$commit_count" -gt 0 ]; then
        add_finding "orphaned-worktree" "medium" "$project_name/$wt_name" \
          "Worktree has $commit_count unmerged commits but no active task" \
          "review-and-merge-or-delete"
      else
        add_finding "orphaned-worktree" "low" "$project_name/$wt_name" \
          "Empty orphaned worktree (no commits beyond main)" \
          "delete-worktree"
        if [ "$FIX" = true ]; then
          git -C "$project_dir" worktree remove "$wt_dir" --force 2>/dev/null || true
        fi
      fi
    fi
  done
done

# --- 4. Orphaned tmux logs: .tmux files in logs/ with no matching active task ---

for tmux_file in "$TERRA_ROOT"/logs/*.tmux; do
  [ -f "$tmux_file" ] || continue
  task_id=$(basename "$tmux_file" .tmux)

  if [ ! -f "$TERRA_ROOT/tasks/active/$task_id.json" ]; then
    add_finding "orphaned-log" "low" "$task_id" \
      "tmux log file exists but task is not active" \
      "cleanup-log"
    if [ "$FIX" = true ]; then
      rm -f "$tmux_file"
    fi
  fi
done

# --- 5. Backlog staleness: check if referenced files still exist ---

BACKLOG="$TERRA_ROOT/tasks/backlog.json"
if [ -f "$BACKLOG" ]; then
  count=$(jq 'length' "$BACKLOG")
  for i in $(seq 0 $((count - 1))); do
    item_id=$(jq -r ".[$i].id" "$BACKLOG")
    area=$(jq -r ".[$i].area" "$BACKLOG")
    title=$(jq -r ".[$i].title" "$BACKLOG")
    discovered=$(jq -r ".[$i].discovered" "$BACKLOG")

    # Flag items older than 7 days for review
    if [ -n "$discovered" ]; then
      disc_epoch=$(date -j -f "%Y-%m-%d" "$discovered" +%s 2>/dev/null || echo "0")
      now_epoch=$(date +%s)
      age_days=$(( (now_epoch - disc_epoch) / 86400 ))
      if [ "$age_days" -gt 7 ]; then
        add_finding "stale-backlog" "low" "$item_id" \
          "Backlog item ${age_days}d old: $title" \
          "review-relevance"
      fi
    fi
  done
fi

# --- Write report ---

FINDING_COUNT=$(echo "$FINDINGS" | jq 'length')
MEDIUM_COUNT=$(echo "$FINDINGS" | jq '[.[] | select(.severity == "medium")] | length')

jq -n \
  --arg ts "$NOW" \
  --argjson findings "$FINDINGS" \
  --argjson count "$FINDING_COUNT" \
  --argjson medium "$MEDIUM_COUNT" \
  --arg mode "$([ "$FIX" = true ] && echo "auto-fix" || echo "report-only")" \
  '{
    run_at: $ts,
    mode: $mode,
    summary: {
      total_findings: $count,
      medium_severity: $medium
    },
    findings: $findings
  }' > "$REPORT"

# --- Console output ---

if [ "$FINDING_COUNT" -eq 0 ]; then
  echo "Janitor: all clean ✓"
else
  echo "Janitor: $FINDING_COUNT finding(s) ($MEDIUM_COUNT medium)"
  echo "$FINDINGS" | jq -r '.[] | "  [\(.severity)] \(.type): \(.target) — \(.detail)"'
  echo ""
  echo "Report: $REPORT"
  [ "$FIX" = false ] && echo "Run with --fix to auto-resolve safe issues."
fi
