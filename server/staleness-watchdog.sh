#!/bin/bash
# OpenClaw Context Bridge - Staleness Watchdog
# Runs via cron every 5 minutes.
# Writes /tmp/context-bridge-stale if no data arrived in the last 10 minutes.

set -euo pipefail

DB_PATH="${CONTEXT_BRIDGE_DB:-/home/admin/clawd/data/context-bridge.db}"
STALE_FLAG="/tmp/context-bridge-stale"
THRESHOLD_MINUTES=10

if [ ! -f "$DB_PATH" ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) stale=true reason=db_missing" > "$STALE_FLAG"
  exit 0
fi

LATEST=$(sqlite3 "$DB_PATH" "SELECT MAX(created_at) FROM activity_stream;" 2>/dev/null || echo "")

if [ -z "$LATEST" ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) stale=true reason=no_data" > "$STALE_FLAG"
  exit 0
fi

AGE_SECONDS=$(python3 -c "
from datetime import datetime, timezone
latest = datetime.fromisoformat('$LATEST').replace(tzinfo=timezone.utc)
age = (datetime.now(timezone.utc) - latest).total_seconds()
print(int(age))
" 2>/dev/null || echo "9999")

if [ "$AGE_SECONDS" -gt $((THRESHOLD_MINUTES * 60)) ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) stale=true age_seconds=$AGE_SECONDS last=$LATEST" > "$STALE_FLAG"
else
  rm -f "$STALE_FLAG"
fi
