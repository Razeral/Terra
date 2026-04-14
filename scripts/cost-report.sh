#!/bin/bash
set -euo pipefail

# Usage: cost-report.sh [--json] [--since YYYYMMDD]
# Aggregates cost data across all Terra tasks and ccusage sessions

TERRA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JSON_OUTPUT=false
SINCE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --json) JSON_OUTPUT=true; shift ;;
    --since) SINCE="$2"; shift 2 ;;
    *) echo "Usage: cost-report.sh [--json] [--since YYYYMMDD]"; exit 1 ;;
  esac
done

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required"
  exit 1
fi

# --- ccusage resolution: prefer global binary, fall back to npx ---
CCUSAGE_BIN=""
if command -v ccusage &>/dev/null; then
  CCUSAGE_BIN="ccusage"
elif command -v npx &>/dev/null; then
  npx ccusage@latest --version &>/dev/null && CCUSAGE_BIN="npx ccusage@latest" || true
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

ccusage_session_cached() {
  local session_id="$1"
  local cache_file="$CCUSAGE_CACHE_DIR/$session_id.json"
  local now
  now=$(date +%s)

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

  local result
  result=$(ccusage_cmd session --id "$session_id" --json 2>/dev/null || echo "")
  if [ -n "$result" ]; then
    echo "$result" > "$cache_file"
    echo "$result"
    return 0
  fi
  return 1
}

# --- Section 1: Task-level costs from completed tasks ---
echo "=== Terra Cost Report ==="
echo ""

TASK_TOTAL=0
TASK_COUNT=0
declare -A ROLE_COSTS 2>/dev/null || true
declare -A MODEL_COSTS 2>/dev/null || true
declare -A ROLE_COUNTS 2>/dev/null || true

# Collect from done + active tasks
TASK_DATA="[]"

for dir in "$TERRA_ROOT/tasks/done" "$TERRA_ROOT/tasks/active"; do
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue

    task_id=$(jq -r '.id' "$f")
    title=$(jq -r '.title // "(untitled)"' "$f")
    role=$(jq -r '.role // "unknown"' "$f")
    status=$(jq -r '.status // "unknown"' "$f")
    session_id=$(jq -r '.session_id // empty' "$f")
    cost=$(jq -r '.cost.total_cost_usd // 0' "$f")
    input_tokens=$(jq -r '.cost.input_tokens // 0' "$f")
    output_tokens=$(jq -r '.cost.output_tokens // 0' "$f")
    cache_read_tokens=$(jq -r '.cost.cache_read_tokens // 0' "$f")
    cache_creation_tokens=$(jq -r '.cost.cache_creation_tokens // 0' "$f")

    # If no stored cost but has session_id, try ccusage (cached)
    if [ "$cost" = "0" ] && [ -n "$session_id" ]; then
      live=$(ccusage_session_cached "$session_id" 2>/dev/null || echo "")
      if [ -n "$live" ]; then
        cost=$(echo "$live" | jq -r '.totalCost // 0' 2>/dev/null || echo "0")
        input_tokens=$(echo "$live" | jq -r '[.entries[]?.inputTokens // 0] | add // 0' 2>/dev/null || echo "0")
        output_tokens=$(echo "$live" | jq -r '[.entries[]?.outputTokens // 0] | add // 0' 2>/dev/null || echo "0")
        cache_read_tokens=$(echo "$live" | jq -r '[.entries[]?.cacheReadTokens // 0] | add // 0' 2>/dev/null || echo "0")
        cache_creation_tokens=$(echo "$live" | jq -r '[.entries[]?.cacheCreationTokens // 0] | add // 0' 2>/dev/null || echo "0")
      fi
    fi

    # Get model from role file
    model="sonnet"
    role_file="$TERRA_ROOT/agents/roles/active/$role.md"
    [ ! -f "$role_file" ] && role_file="$TERRA_ROOT/agents/roles/_templates/$role.md"
    if [ -f "$role_file" ]; then
      model=$(sed -n '/^---$/,/^---$/{ s/^model: *//p; }' "$role_file" 2>/dev/null)
      model="${model:-sonnet}"
    fi

    TASK_DATA=$(echo "$TASK_DATA" | jq --arg id "$task_id" --arg title "$title" \
      --arg role "$role" --arg model "$model" --arg status "$status" \
      --argjson cost "$cost" --argjson input "$input_tokens" --argjson output "$output_tokens" \
      --argjson cache_read "$cache_read_tokens" --argjson cache_create "$cache_creation_tokens" \
      '. + [{id: $id, title: $title, role: $role, model: $model, status: $status, cost: $cost, input_tokens: $input, output_tokens: $output, cache_read_tokens: $cache_read, cache_creation_tokens: $cache_create}]')
  done
done

if [ "$JSON_OUTPUT" = true ]; then
  # JSON output mode
  echo "$TASK_DATA" | jq '{
    tasks: .,
    summary: {
      total_cost: (map(.cost) | add // 0),
      task_count: length,
      by_role: (group_by(.role) | map({
        role: .[0].role,
        count: length,
        cost: (map(.cost) | add // 0)
      })),
      by_model: (group_by(.model) | map({
        model: .[0].model,
        count: length,
        cost: (map(.cost) | add // 0)
      }))
    }
  }'
  exit 0
fi

# --- Human-readable output ---

# Per-task breakdown
echo "TASK COSTS:"
printf "  %-12s %-10s %-8s %-10s %s\n" "TASK" "ROLE" "MODEL" "COST" "TITLE"
printf "  %-12s %-10s %-8s %-10s %s\n" "----" "----" "-----" "----" "-----"

echo "$TASK_DATA" | jq -r '.[] | "  \(.id)|\(.role)|\(.model)|\(.cost)|\(.title)"' | while IFS='|' read -r id role model cost title; do
  if [ "$cost" != "0" ]; then
    cost_fmt=$(printf "\$%.4f" "$cost")
  else
    cost_fmt="-"
  fi
  printf "  %-12s %-10s %-8s %-10s %s\n" "$id" "$role" "$model" "$cost_fmt" "$title"
done

TOTAL=$(echo "$TASK_DATA" | jq '[.[].cost] | add // 0')
TASK_COUNT=$(echo "$TASK_DATA" | jq 'length')

echo ""
echo "BY ROLE:"
echo "$TASK_DATA" | jq -r 'group_by(.role) | .[] | "\(.[0].role)|\(length)|\(map(.cost) | add // 0)"' | while IFS='|' read -r role count cost; do
  printf "  %s: %s tasks, \$%.4f\n" "$role" "$count" "$cost"
done

echo ""
echo "BY MODEL:"
echo "$TASK_DATA" | jq -r 'group_by(.model) | .[] | "\(.[0].model)|\(length)|\(map(.cost) | add // 0)"' | while IFS='|' read -r model count cost; do
  printf "  %s: %s tasks, \$%.4f\n" "$model" "$count" "$cost"
done

echo ""
echo "--- Session-level (ccusage) ---"

# Also show overall ccusage data for context
CCUSAGE_FLAGS=""
[ -n "$SINCE" ] && CCUSAGE_FLAGS="--since $SINCE"
ccusage_cmd monthly --breakdown $CCUSAGE_FLAGS 2>/dev/null || echo "  (ccusage not available)"

echo ""
echo "==========================="
printf "Terra tasks: %s | Total tracked cost: \$%.4f\n" "$TASK_COUNT" "$TOTAL"
