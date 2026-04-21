#!/bin/bash
set -euo pipefail

# Usage: spawn-agent.sh [--no-worktree] <project> <task-id> <role>
# Spawns a Claude Code agent in a tmux session within a git worktree
# --no-worktree: skip worktree creation, run agent directly in the project directory

NO_WORKTREE=false
if [ "${1:-}" = "--no-worktree" ]; then
  NO_WORKTREE=true
  shift
fi

PROJECT="${1:?Usage: spawn-agent.sh [--no-worktree] <project> <task-id> <role>}"
TASK_ID="${2:?Missing task-id}"
ROLE="${3:?Missing role}"

TERRA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$TERRA_ROOT/projects/$PROJECT"
TASK_FILE="$TERRA_ROOT/tasks/active/$TASK_ID.json"
ROLE_FILE="$TERRA_ROOT/agents/roles/active/$ROLE.md"
LOG_FILE="$TERRA_ROOT/logs/$TASK_ID.log"
TMUX_SESSION="terra-$TASK_ID"
SESSION_UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')

if [ "$NO_WORKTREE" = true ]; then
  WORKTREE_DIR="$PROJECT_DIR"
else
  WORKTREE_DIR="$PROJECT_DIR/worktrees/$TASK_ID"
  BRANCH="agent/$TASK_ID"
fi

# Capacity governor: refuse to spawn if too many agents are running
MAX_AGENTS="${TERRA_MAX_AGENTS:-8}"
ACTIVE_COUNT=$(tmux ls 2>/dev/null | grep -c '^terra-task-' || true)
if [ "$ACTIVE_COUNT" -ge "$MAX_AGENTS" ]; then
  echo "Error: Capacity limit reached ($ACTIVE_COUNT/$MAX_AGENTS active agents)."
  echo "  Wait for agents to finish or increase the limit:"
  echo "  export TERRA_MAX_AGENTS=<number>"
  echo ""
  echo "  Active sessions:"
  tmux ls 2>/dev/null | grep '^terra-task-' || true
  exit 1
fi

# Validate inputs
if [ ! -d "$PROJECT_DIR" ]; then
  echo "Error: Project not found at $PROJECT_DIR"
  exit 1
fi

if [ ! -f "$TASK_FILE" ]; then
  echo "Error: Task file not found at $TASK_FILE"
  exit 1
fi

if [ ! -f "$ROLE_FILE" ]; then
  echo "Error: Role file not found at $ROLE_FILE"
  exit 1
fi

# Check for existing tmux session
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  echo "Error: tmux session '$TMUX_SESSION' already exists. Agent may be running."
  echo "  Attach: tmux attach -t $TMUX_SESSION"
  echo "  Kill:   tmux kill-session -t $TMUX_SESSION"
  exit 1
fi

# Set up working directory and role
if [ "$NO_WORKTREE" = true ]; then
  echo "Running in-place (no worktree) at $PROJECT_DIR"

  # Back up existing CLAUDE.md if present
  CLAUDE_MD="$PROJECT_DIR/.claude/CLAUDE.md"
  CLAUDE_MD_BAK="$PROJECT_DIR/.claude/CLAUDE.md.bak"
  mkdir -p "$PROJECT_DIR/.claude"
  if [ -f "$CLAUDE_MD" ]; then
    cp "$CLAUDE_MD" "$CLAUDE_MD_BAK"
  fi

  # Write role into CLAUDE.md (will be restored after agent finishes)
  ROLE_CONTENT=$(cat "$ROLE_FILE")
  echo "${ROLE_CONTENT//\{TASK_ID\}/$TASK_ID}" > "$CLAUDE_MD"

  # Copy task file into project root
  cp "$TASK_FILE" "$PROJECT_DIR/.task.json"

  # Update task status with "in-place" instead of a branch name
  if command -v jq &>/dev/null; then
    jq --arg tmux "$TMUX_SESSION" --arg sid "$SESSION_UUID" \
      '.status = "active" | .assigned_to = "in-place" | .tmux_session = $tmux | .session_id = $sid' \
      "$TASK_FILE" > "$TASK_FILE.tmp"
    mv "$TASK_FILE.tmp" "$TASK_FILE"
  fi
else
  # Create worktree
  echo "Creating worktree at $WORKTREE_DIR on branch $BRANCH..."
  git -C "$PROJECT_DIR" worktree add "$WORKTREE_DIR" -b "$BRANCH" 2>/dev/null || {
    echo "Warning: Branch $BRANCH may already exist, trying checkout..."
    git -C "$PROJECT_DIR" worktree add "$WORKTREE_DIR" "$BRANCH"
  }

  # Copy role CLAUDE.md into worktree
  mkdir -p "$WORKTREE_DIR/.claude"
  ROLE_CONTENT=$(cat "$ROLE_FILE")
  # Replace {TASK_ID} placeholder with actual task ID
  echo "${ROLE_CONTENT//\{TASK_ID\}/$TASK_ID}" > "$WORKTREE_DIR/.claude/CLAUDE.md"

  # Also make task file accessible from worktree
  cp "$TASK_FILE" "$WORKTREE_DIR/.task.json"

  # Update task status
  if command -v jq &>/dev/null; then
    jq --arg branch "$BRANCH" --arg tmux "$TMUX_SESSION" --arg sid "$SESSION_UUID" \
      '.status = "active" | .assigned_to = $branch | .tmux_session = $tmux | .session_id = $sid' \
      "$TASK_FILE" > "$TASK_FILE.tmp"
    mv "$TASK_FILE.tmp" "$TASK_FILE"
  fi
fi

# Session discovery: if a previous attempt failed, copy its log as .predecessor-log
if [ "$NO_WORKTREE" != true ] && command -v jq &>/dev/null; then
  CURRENT_TITLE=$(jq -r '.title // ""' "$TASK_FILE" 2>/dev/null)
  for PREV_TASK in "$TERRA_ROOT"/tasks/done/*.json; do
    [ -f "$PREV_TASK" ] || continue
    PREV_STATUS=$(jq -r '.status // ""' "$PREV_TASK" 2>/dev/null)
    [ "$PREV_STATUS" = "failed" ] || continue
    PREV_ID=$(jq -r '.id // ""' "$PREV_TASK" 2>/dev/null)
    PREV_TITLE=$(jq -r '.title // ""' "$PREV_TASK" 2>/dev/null)
    # Match by same task ID or same title
    if [ "$PREV_ID" = "$TASK_ID" ] || [ "$PREV_TITLE" = "$CURRENT_TITLE" ]; then
      PREV_LOG="$TERRA_ROOT/logs/$PREV_ID.log"
      if [ -f "$PREV_LOG" ]; then
        cp "$PREV_LOG" "$WORKTREE_DIR/.predecessor-log"
        echo "  Predecessor log copied from previous failed attempt ($PREV_ID)"
      fi
      break
    fi
  done
fi

# Extract model from role frontmatter (--- block with model: xxx)
MODEL=$(sed -n '/^---$/,/^---$/{ s/^model: *//p; }' "$ROLE_FILE" 2>/dev/null)
MODEL="${MODEL:-sonnet}"
MODEL_FLAG=""
if [ -n "$MODEL" ] && [ "$MODEL" != "sonnet" ]; then
  MODEL_FLAG="--model $MODEL"
fi

# Extract tools from role frontmatter for --allowedTools
# Format: "tools: Read, Edit, Write, Bash" → "Read Edit Write Bash"
TOOLS=$(sed -n '/^---$/,/^---$/{ s/^tools: *//p; }' "$ROLE_FILE" 2>/dev/null | tr ',' ' ' | tr -s ' ')
ALLOWED_TOOLS_FLAG=""
if [ -n "$TOOLS" ]; then
  ALLOWED_TOOLS_FLAG="--allowedTools $TOOLS"
fi

# Extract color from role frontmatter for tmux pane
COLOR=$(sed -n '/^---$/,/^---$/{ s/^color: *//p; }' "$ROLE_FILE" 2>/dev/null)
COLOR="${COLOR:-default}"

echo "Spawning agent in tmux session: $TMUX_SESSION"
echo "  Role:      $ROLE ($MODEL)"
echo "  Task:      $TASK_ID"
echo "  Session:   $SESSION_UUID"
if [ "$NO_WORKTREE" = true ]; then
  echo "  Directory: $WORKTREE_DIR (in-place, no worktree)"
else
  echo "  Worktree:  $WORKTREE_DIR"
fi
echo "  Tools:     ${TOOLS:-default}"
echo "  Log:       $LOG_FILE"
echo ""

# Launch in a tmux session
# The agent runs interactively so you can attach and observe
# --session-id ties the Claude Code session to our task for cost tracking via ccusage
# Optional stream-json tracer (none by default)
PIPE_CMD=""
OUTPUT_FMT=""

# Build cleanup command for no-worktree mode (restore original CLAUDE.md)
CLEANUP_CMD=""
if [ "$NO_WORKTREE" = true ]; then
  CLEANUP_CMD="rm -f '$PROJECT_DIR/.task.json'; "
  if [ -f "$CLAUDE_MD_BAK" ]; then
    CLEANUP_CMD+="mv '$CLAUDE_MD_BAK' '$CLAUDE_MD'; "
  else
    CLEANUP_CMD+="rm -f '$CLAUDE_MD'; "
  fi
fi

tmux new-session -d -s "$TMUX_SESSION" -c "$WORKTREE_DIR" \
  "claude -p 'You are a worker agent. Read .claude/CLAUDE.md for your role and .task.json for your assignment. Execute the task.' \
  --session-id '$SESSION_UUID' \
  $MODEL_FLAG \
  $ALLOWED_TOOLS_FLAG \
  $OUTPUT_FMT \
  2>&1 $PIPE_CMD | tee '$LOG_FILE'; \
  bash '$TERRA_ROOT/scripts/agent-complete-notify.sh' '$TASK_ID' '$PROJECT'; \
  bash '$TERRA_ROOT/scripts/merge-queue.sh' 2>&1 | tee -a '$LOG_FILE'; \
  $CLEANUP_CMD \
  echo ''; echo '=== Agent finished. Press any key to close ==='; read -n1"

# Store tmux session name for health checks
echo "$TMUX_SESSION" > "$TERRA_ROOT/logs/$TASK_ID.tmux"

echo "Agent running in tmux session: $TMUX_SESSION"
echo ""
echo "Commands:"
echo "  Attach:    tmux attach -t $TMUX_SESSION"
echo "  List all:  tmux ls | grep terra-"
echo "  Kill:      tmux kill-session -t $TMUX_SESSION"
echo "  Log:       tail -f $LOG_FILE"
