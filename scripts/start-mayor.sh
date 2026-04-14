#!/bin/bash
set -euo pipefail

# Usage: start-mayor.sh [--restart]
# Starts the Mayor (orchestrator) Claude Code session in a named tmux session.
# The Mayor is always reachable via: tmux attach -t terra-mayor

TERRA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMUX_SESSION="terra-mayor"
HEARTBEAT_FILE="$TERRA_ROOT/logs/mayor-heartbeat"

RESTART=false
[ "${1:-}" = "--restart" ] && RESTART=true

# Check if already running
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  if [ "$RESTART" = true ]; then
    echo "Killing existing Mayor session..."
    tmux kill-session -t "$TMUX_SESSION"
  else
    echo "Mayor already running — attaching..."
    exec tmux attach -t "$TMUX_SESSION"
  fi
fi

# Ensure log directory exists
mkdir -p "$TERRA_ROOT/logs"

# Write initial heartbeat
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$HEARTBEAT_FILE"

# Launch Mayor in tmux
# Set TERRA_MODEL to override the default model (e.g. sonnet, opus, haiku)
tmux new-session -d -s "$TMUX_SESSION" -c "$TERRA_ROOT" \
  "claude --model ${TERRA_MODEL:-opus}"

if [ -t 0 ]; then
  echo "Mayor started — attaching..."
  exec tmux attach -t "$TMUX_SESSION"
else
  echo "Mayor started (no TTY — skipping attach)"
fi
