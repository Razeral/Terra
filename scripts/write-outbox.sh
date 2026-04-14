#!/bin/bash
# Usage: write-outbox.sh <request-id> <response-text> [status]
# Appends a response to the Mayor outbox for external integrations to pick up.
set -euo pipefail
TERRA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTBOX="$TERRA_ROOT/logs/mayor-outbox.jsonl"
REQUEST_ID="$1"
TEXT="$2"
STATUS="${3:-ok}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
printf '%s\n' "{\"id\":\"$ID\",\"request_id\":\"$REQUEST_ID\",\"timestamp\":\"$TIMESTAMP\",\"text\":$(printf '%s' "$TEXT" | jq -Rs .),\"status\":\"$STATUS\"}" >> "$OUTBOX"
