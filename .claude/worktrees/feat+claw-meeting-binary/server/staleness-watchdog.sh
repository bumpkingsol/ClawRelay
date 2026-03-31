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

# Use Python with db_utils to support encrypted DBs
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGE_SECONDS=$(cd "$SCRIPT_DIR" && python3 -c "
from datetime import datetime, timezone
from db_utils import get_db
try:
    db = get_db()
    row = db.execute('SELECT MAX(created_at) FROM activity_stream').fetchone()
    db.close()
    latest = row[0] if row else None
    if not latest:
        print('no_data')
    else:
        ts = datetime.fromisoformat(latest).replace(tzinfo=timezone.utc)
        print(int((datetime.now(timezone.utc) - ts).total_seconds()))
except Exception as e:
    print('9999')
" 2>/dev/null || echo "9999")

if [ "$AGE_SECONDS" = "no_data" ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) stale=true reason=no_data" > "$STALE_FLAG"
  exit 0
fi

if [ "$AGE_SECONDS" -gt $((THRESHOLD_MINUTES * 60)) ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) stale=true age_seconds=$AGE_SECONDS last=$LATEST" > "$STALE_FLAG"
else
  rm -f "$STALE_FLAG"
fi
