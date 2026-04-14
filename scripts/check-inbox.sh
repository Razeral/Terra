#!/bin/bash
# PostToolUse hook: checks for unprocessed Telegram messages in mayor-inbox.jsonl
# Outputs a reminder for each unprocessed message so the Mayor notices it.
# Designed to be fast — uses grep/awk, no heavy runtimes.
# Compatible with bash 3 (macOS default).

TERRA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INBOX="$TERRA_ROOT/logs/mayor-inbox.jsonl"
OUTBOX="$TERRA_ROOT/logs/mayor-outbox.jsonl"
REMINDED="$TERRA_ROOT/logs/inbox-reminded"

# Exit silently if no inbox
[ -f "$INBOX" ] || exit 0
[ -s "$INBOX" ] || exit 0

NOW=$(date +%s)

# Collect processed request_ids from outbox
PROCESSED=""
if [ -f "$OUTBOX" ] && [ -s "$OUTBOX" ]; then
  PROCESSED=$(grep -o '"request_id":"[^"]*"' "$OUTBOX" | cut -d'"' -f4)
fi

# Collect unprocessed messages (append-order, newest last)
UNPROCESSED=()
while IFS= read -r line; do
  [ -z "$line" ] && continue
  msg_id=$(echo "$line" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ -z "$msg_id" ] && continue

  # Skip if already processed
  if [ -n "$PROCESSED" ] && echo "$PROCESSED" | grep -qF "$msg_id"; then
    continue
  fi

  UNPROCESSED+=("$line")
done < "$INBOX"

# No unprocessed messages — nothing to do
[ ${#UNPROCESSED[@]} -eq 0 ] && exit 0

# Take only the 3 most recent (last 3 entries)
TOTAL=${#UNPROCESSED[@]}
START=0
if [ "$TOTAL" -gt 3 ]; then
  START=$((TOTAL - 3))
fi

REMINDED_DIRTY=false

# Helper: get last-reminded epoch for a message ID from the reminded file
get_reminded_time() {
  local mid="$1"
  if [ -f "$REMINDED" ]; then
    grep "^${mid}	" "$REMINDED" | tail -1 | cut -f2
  fi
}

for ((i = TOTAL - 1; i >= START; i--)); do
  line="${UNPROCESSED[$i]}"
  msg_id=$(echo "$line" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
  preview=$(echo "$line" | grep -o '"text":"[^"]*"' | head -1 | cut -d'"' -f4 | cut -c1-200)

  # Extract timestamp and compute age
  msg_ts=$(echo "$line" | grep -o '"timestamp":"[^"]*"' | head -1 | cut -d'"' -f4)
  msg_epoch=0
  if [ -n "$msg_ts" ]; then
    msg_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$msg_ts" +%s 2>/dev/null || echo 0)
  fi
  age_secs=$((NOW - msg_epoch))

  if [ "$age_secs" -gt 60 ] && [ "$msg_epoch" -gt 0 ]; then
    # Escalated prompt — check if we already reminded recently
    last_reminded=$(get_reminded_time "$msg_id")
    last_reminded=${last_reminded:-0}
    since_reminded=$((NOW - last_reminded))

    if [ "$since_reminded" -ge 120 ]; then
      # Compute human-readable age
      if [ "$age_secs" -ge 3600 ]; then
        age_display="$((age_secs / 3600))h ago"
      elif [ "$age_secs" -ge 60 ]; then
        age_display="$((age_secs / 60))m ago"
      else
        age_display="${age_secs}s ago"
      fi

      echo "⚠️ UNREAD Telegram message (${age_display}): [Telegram:${msg_id}] ${preview}"
      echo "Process this by reading logs/mayor-inbox.jsonl and responding via scripts/write-outbox.sh"

      # Update reminded file: remove old entry, append new
      if [ -f "$REMINDED" ]; then
        grep -v "^${msg_id}	" "$REMINDED" > "${REMINDED}.tmp" 2>/dev/null || true
        mv "${REMINDED}.tmp" "$REMINDED"
      fi
      printf '%s\t%s\n' "$msg_id" "$NOW" >> "$REMINDED"
      REMINDED_DIRTY=true
    fi
  else
    # Fresh message — always show
    echo "[Telegram:${msg_id}] ${preview}"
  fi
done

# Clean up reminded file: remove entries for processed messages
if [ "$REMINDED_DIRTY" = true ] && [ -f "$REMINDED" ] && [ -n "$PROCESSED" ]; then
  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    grep -v "^${pid}	" "$REMINDED" > "${REMINDED}.tmp" 2>/dev/null || true
    mv "${REMINDED}.tmp" "$REMINDED"
  done <<< "$PROCESSED"
fi
