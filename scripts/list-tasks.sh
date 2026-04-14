#!/bin/bash
set -euo pipefail

# Usage: list-tasks.sh [queue|active|done|all]
# Lists tasks by status

TERRA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILTER="${1:-all}"

print_tasks() {
  local dir="$1"
  local label="$2"

  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    if command -v jq &>/dev/null; then
      id=$(jq -r '.id' "$f")
      title=$(jq -r '.title' "$f")
      role=$(jq -r '.role // "unassigned"' "$f")
      printf "  %-12s %-20s [%s] %s\n" "$id" "$role" "$label" "$title"
    else
      echo "  $(basename "$f" .json) [$label]"
    fi
  done
}

echo "=== Terra Task Board ==="
echo ""

if [ "$FILTER" = "all" ] || [ "$FILTER" = "queue" ]; then
  echo "QUEUE:"
  print_tasks "$TERRA_ROOT/tasks/queue" "pending"
  echo ""
fi

if [ "$FILTER" = "all" ] || [ "$FILTER" = "active" ]; then
  echo "ACTIVE:"
  print_tasks "$TERRA_ROOT/tasks/active" "active"
  echo ""
fi

if [ "$FILTER" = "all" ] || [ "$FILTER" = "done" ]; then
  echo "DONE:"
  print_tasks "$TERRA_ROOT/tasks/done" "done"
  echo ""
fi
