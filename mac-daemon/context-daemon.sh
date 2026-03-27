#!/bin/bash
# OpenClaw Context Bridge - Mac Daemon
# Captures active window, URLs, file paths, git state, idle status
# Runs every 2-3 minutes via launchd

set -euo pipefail

# --- Config ---
SERVER_URL="${CONTEXT_BRIDGE_URL:-https://localhost:7890/context/push}"
AUTH_TOKEN="${CONTEXT_BRIDGE_TOKEN:-}"
CMD_LOG="$HOME/.context-bridge-cmds.log"
LOCAL_DB="$HOME/.context-bridge/local.db"
IDLE_THRESHOLD=300  # 5 minutes in seconds

# --- Ensure local queue DB exists ---
mkdir -p "$HOME/.context-bridge"
if [ ! -f "$LOCAL_DB" ]; then
  sqlite3 "$LOCAL_DB" "CREATE TABLE IF NOT EXISTS queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    payload TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now'))
  );"
fi

# --- Auth check ---
if [ -z "$AUTH_TOKEN" ]; then
  # Try macOS Keychain
  AUTH_TOKEN=$(security find-generic-password -s "context-bridge" -a "token" -w 2>/dev/null || echo "")
  if [ -z "$AUTH_TOKEN" ]; then
    echo "ERROR: No auth token found. Set CONTEXT_BRIDGE_TOKEN or add to Keychain." >&2
    exit 1
  fi
fi

# --- Idle Detection ---
get_idle_seconds() {
  ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'
}

is_screen_locked() {
  python3 -c "
import Quartz
d = Quartz.CGSessionCopyCurrentDictionary()
if d and d.get('CGSSessionScreenIsLocked', 0):
    print('locked')
else:
    print('unlocked')
" 2>/dev/null || echo "unknown"
}

idle_seconds=$(get_idle_seconds)
lock_state=$(is_screen_locked)

if [ "$lock_state" = "locked" ]; then
  IDLE_STATE="locked"
elif [ "${idle_seconds:-0}" -gt 1800 ]; then
  IDLE_STATE="away"
elif [ "${idle_seconds:-0}" -gt "$IDLE_THRESHOLD" ]; then
  IDLE_STATE="idle"
else
  IDLE_STATE="active"
fi

# --- If idle/away/locked, send minimal payload ---
if [ "$IDLE_STATE" != "active" ]; then
  PAYLOAD=$(cat <<ENDJSON
{
  "ts": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "idle_state": "$IDLE_STATE",
  "idle_seconds": ${idle_seconds:-0}
}
ENDJSON
)
  # Try to send, queue if offline
  HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X POST "$SERVER_URL" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>/dev/null || echo "000")
  
  if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "201" ]; then
    sqlite3 "$LOCAL_DB" "INSERT INTO queue (payload) VALUES ('$(echo "$PAYLOAD" | sed "s/'/''/" )');"
  fi
  exit 0
fi

# --- Active App + Window Title ---
ACTIVE_APP=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || echo "unknown")
WINDOW_TITLE=$(osascript -e 'tell application "System Events" to get name of front window of first application process whose frontmost is true' 2>/dev/null || echo "")

# --- Chrome URL (if Chrome is active) ---
CHROME_URL=""
if [[ "$ACTIVE_APP" == "Google Chrome" ]]; then
  CHROME_URL=$(osascript -e 'tell application "Google Chrome" to get URL of active tab of front window' 2>/dev/null || echo "")
fi

# --- File path from editor window title ---
FILE_PATH=""
GIT_REPO=""
GIT_BRANCH=""

if [[ "$ACTIVE_APP" == "Cursor" || "$ACTIVE_APP" == "Code" || "$ACTIVE_APP" == "Visual Studio Code" ]]; then
  # Electron editors show: filename - folder - AppName
  # Extract the folder part to infer project
  FILE_PATH=$(echo "$WINDOW_TITLE" | sed -n 's/.*— \(.*\) — .*/\1/p' 2>/dev/null || echo "")
  if [ -z "$FILE_PATH" ]; then
    # Try dash separator variant
    FILE_PATH=$(echo "$WINDOW_TITLE" | sed -n 's/.* - \(.*\) - .*/\1/p' 2>/dev/null || echo "")
  fi
  
  # Try to get git info from the project directory
  if [ -n "$FILE_PATH" ] && [ -d "$HOME/$FILE_PATH" ]; then
    GIT_BRANCH=$(cd "$HOME/$FILE_PATH" && git branch --show-current 2>/dev/null || echo "")
    GIT_REPO=$(cd "$HOME/$FILE_PATH" && basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo "")
  fi
fi

# --- Terminal: check for active git repo in pwd ---
if [[ "$ACTIVE_APP" == "Terminal" || "$ACTIVE_APP" == "iTerm2" || "$ACTIVE_APP" == "Warp" ]]; then
  # Try to get the frontmost terminal's working directory
  if [[ "$ACTIVE_APP" == "Terminal" ]]; then
    # macOS Terminal stores CWD in custom property
    TERM_PWD=$(osascript -e 'tell application "Terminal" to get custom title of front window' 2>/dev/null || echo "")
  fi
fi

# --- Terminal commands (from preexec hook log) ---
TERMINAL_CMDS=""
if [ -f "$CMD_LOG" ]; then
  # Read last 10 commands, filter sensitive content
  TERMINAL_CMDS=$(tail -20 "$CMD_LOG" 2>/dev/null | \
    sed -E 's/(export\s+\w*(KEY|TOKEN|SECRET|PASSWORD|PASS)\w*=).*/\1[REDACTED]/gi' | \
    sed -E 's/(Bearer\s+)\S+/\1[REDACTED]/g' | \
    sed -E 's/(password|secret|token)\s*=\s*\S+/\1=[REDACTED]/gi' | \
    sed -E 's/sk-[a-zA-Z0-9]+/[REDACTED_KEY]/g' | \
    sed -E 's/sb_[a-zA-Z0-9_]+/[REDACTED_KEY]/g' | \
    tail -10 | \
    python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null || echo '""')
  
  # Flush the log after reading
  > "$CMD_LOG"
fi

# --- Notifications (recent, last 3 minutes) ---
NOTIFICATIONS=""
# macOS notification center access requires a helper - simplified approach:
# Read from notification database if accessible
NOTIF_DB="$HOME/Library/Group Containers/group.com.apple.usernoted/db2/db"
if [ -f "$NOTIF_DB" ]; then
  NOTIFICATIONS=$(sqlite3 "$NOTIF_DB" "
    SELECT app_id, title, body 
    FROM record 
    WHERE delivered_date > strftime('%s','now') - 180
    ORDER BY delivered_date DESC
    LIMIT 5
  " 2>/dev/null | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null || echo '""')
fi

# --- Build payload ---
PAYLOAD=$(python3 -c "
import json, sys
payload = {
    'ts': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'app': '$(echo "$ACTIVE_APP" | sed "s/'/\\\\'/g")',
    'window_title': $(echo "$WINDOW_TITLE" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null || echo '""'),
    'url': '$(echo "$CHROME_URL" | sed "s/'/\\\\'/g")',
    'file_path': '$(echo "$FILE_PATH" | sed "s/'/\\\\'/g")',
    'git_repo': '$GIT_REPO',
    'git_branch': '$GIT_BRANCH',
    'terminal_cmds': $TERMINAL_CMDS,
    'notifications': $NOTIFICATIONS,
    'idle_state': '$IDLE_STATE',
    'idle_seconds': ${idle_seconds:-0}
}
print(json.dumps(payload))
" 2>/dev/null)

if [ -z "$PAYLOAD" ]; then
  echo "ERROR: Failed to build payload" >&2
  exit 1
fi

# --- Send to server (or queue if offline) ---
HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "$SERVER_URL" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  --connect-timeout 5 \
  --max-time 10 \
  2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
  # Success - also flush any queued items
  QUEUED=$(sqlite3 "$LOCAL_DB" "SELECT COUNT(*) FROM queue;" 2>/dev/null || echo "0")
  if [ "$QUEUED" -gt 0 ]; then
    sqlite3 "$LOCAL_DB" "SELECT payload FROM queue ORDER BY id ASC LIMIT 50;" 2>/dev/null | while read -r queued_payload; do
      curl -sf -o /dev/null \
        -X POST "$SERVER_URL" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$queued_payload" \
        --connect-timeout 5 \
        --max-time 10 \
        2>/dev/null && \
        sqlite3 "$LOCAL_DB" "DELETE FROM queue WHERE payload = '$(echo "$queued_payload" | sed "s/'/''/g")';" 2>/dev/null
    done
  fi
else
  # Offline or error - queue locally
  sqlite3 "$LOCAL_DB" "INSERT INTO queue (payload) VALUES ($(echo "$PAYLOAD" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null));" 2>/dev/null
  
  # Enforce max queue size
  sqlite3 "$LOCAL_DB" "DELETE FROM queue WHERE id NOT IN (SELECT id FROM queue ORDER BY id DESC LIMIT 10000);" 2>/dev/null
fi
