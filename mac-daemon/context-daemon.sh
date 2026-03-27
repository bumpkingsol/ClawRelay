#!/bin/bash
# OpenClaw Context Bridge - Mac Daemon
# Captures active window, URLs, file paths, git state, idle status,
# clipboard change events, file changes, Codex sessions, WhatsApp context
# Runs every 2 minutes via launchd

set -euo pipefail
umask 077

# --- Config ---
CB_DIR="$HOME/.context-bridge"
SERVER_URL_FILE="$CB_DIR/server-url"
SERVER_URL="${CONTEXT_BRIDGE_URL:-}"
if [ -z "$SERVER_URL" ] && [ -f "$SERVER_URL_FILE" ]; then
  SERVER_URL=$(cat "$SERVER_URL_FILE" 2>/dev/null || echo "")
fi
SERVER_URL="${SERVER_URL:-https://localhost:7890/context/push}"
AUTH_TOKEN="${CONTEXT_BRIDGE_TOKEN:-}"
CMD_LOG="$HOME/.context-bridge-cmds.log"
LOCAL_DB="$CB_DIR/local.db"
CLIPBOARD_HASH_FILE="$CB_DIR/last-clipboard-hash"
FSWATCH_LOG="$CB_DIR/fswatch-changes.log"
SERVER_CA_CERT_FILE="$CB_DIR/server-ca.pem"
IDLE_THRESHOLD=300  # 5 minutes in seconds

# --- Ensure dirs + local queue DB ---
mkdir -p "$CB_DIR"
chmod 700 "$CB_DIR" 2>/dev/null || true
touch "$CMD_LOG" "$FSWATCH_LOG" "$CLIPBOARD_HASH_FILE" 2>/dev/null || true
chmod 600 "$CMD_LOG" "$FSWATCH_LOG" "$CLIPBOARD_HASH_FILE" 2>/dev/null || true
if [ ! -f "$LOCAL_DB" ]; then
  sqlite3 "$LOCAL_DB" "CREATE TABLE IF NOT EXISTS queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    payload TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now'))
  );"
fi
chmod 600 "$LOCAL_DB" 2>/dev/null || true

# --- Auth check ---
if [ -z "$AUTH_TOKEN" ]; then
  AUTH_TOKEN=$(security find-generic-password -s "context-bridge" -a "token" -w 2>/dev/null || echo "")
  if [ -z "$AUTH_TOKEN" ]; then
    echo "ERROR: No auth token found. Set CONTEXT_BRIDGE_TOKEN or add to Keychain." >&2
    exit 1
  fi
fi

curl_tls_args() {
  if [[ "$SERVER_URL" == https://* ]] && [ -f "$SERVER_CA_CERT_FILE" ]; then
    printf '%s\n' "--cacert" "$SERVER_CA_CERT_FILE"
  fi
}

queue_payload() {
  local payload="$1"
  sqlite3 "$LOCAL_DB" "INSERT INTO queue (payload) VALUES ($(printf '%s' "$payload" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))"))" 2>/dev/null
  sqlite3 "$LOCAL_DB" "DELETE FROM queue WHERE id NOT IN (SELECT id FROM queue ORDER BY id DESC LIMIT 10000);" 2>/dev/null
}

flush_queue() {
  local queued
  queued=$(sqlite3 "$LOCAL_DB" "SELECT COUNT(*) FROM queue;" 2>/dev/null || echo "0")
  if [ "$queued" -le 0 ]; then
    return
  fi

  sqlite3 "$LOCAL_DB" "SELECT payload FROM queue ORDER BY id ASC LIMIT 50;" 2>/dev/null | while read -r queued_payload; do
    local curl_args=()
    while IFS= read -r arg; do
      curl_args+=("$arg")
    done < <(curl_tls_args)

    curl -sf -o /dev/null \
      -X POST "$SERVER_URL" \
      -H "Authorization: Bearer $AUTH_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$queued_payload" \
      --connect-timeout 5 --max-time 10 \
      "${curl_args[@]}" \
      2>/dev/null && \
      sqlite3 "$LOCAL_DB" "DELETE FROM queue WHERE payload = '$(echo "$queued_payload" | sed "s/'/''/g")';" 2>/dev/null
  done || true
}

send_payload() {
  local payload="$1"
  local http_code
  local curl_args=()

  while IFS= read -r arg; do
    curl_args+=("$arg")
  done < <(curl_tls_args)

  http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X POST "$SERVER_URL" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    --connect-timeout 5 \
    --max-time 10 \
    "${curl_args[@]}" \
    2>/dev/null || echo "000")

  if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
    flush_queue
    return 0
  fi

  queue_payload "$payload"
  return 1
}

build_minimal_payload() {
  local state="$1"
  local seconds="$2"

  python3 -c "
import json
print(json.dumps({
    'ts': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'idle_state': '$state',
    'idle_seconds': $seconds
}))
" 2>/dev/null
}

is_sensitive_app() {
  case "$1" in
    "1Password"*|"Wise"|"Revolut"|"Vaultwarden")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# --- Idle Detection ---
get_idle_seconds() {
  ioreg -c IOHIDSystem 2>/dev/null | awk '
    /HIDIdleTime/ && !seen {
      print int($NF/1000000000)
      seen=1
    }
    END {
      if (!seen) {
        print 0
      }
    }
  '
}

is_screen_locked() {
  # Use CGSession dictionary via ioreg — no Python/Quartz dependency
  if /usr/bin/python3 -c "
import Quartz
d = Quartz.CGSessionCopyCurrentDictionary()
print('locked' if d and d.get('CGSSessionScreenIsLocked', 0) else 'unlocked')
" 2>/dev/null; then
    return
  fi
  # Fallback: check if screen saver or login window is active
  if pgrep -x "ScreenSaverEngine" >/dev/null 2>&1 || \
     pgrep -x "loginwindow" >/dev/null 2>&1 && \
     ! osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' >/dev/null 2>&1; then
    echo "locked"
  else
    echo "unlocked"
  fi
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
  PAYLOAD=$(build_minimal_payload "$IDLE_STATE" "${idle_seconds:-0}")
  send_payload "$PAYLOAD" || true
  exit 0
fi

# ============================================================
# ACTIVE STATE - Full Capture
# ============================================================

# --- Active App + Window Title ---
ACTIVE_APP=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || echo "unknown")
WINDOW_TITLE=$(osascript -e 'tell application "System Events" to get name of front window of first application process whose frontmost is true' 2>/dev/null || echo "")

if is_sensitive_app "$ACTIVE_APP"; then
  PAYLOAD=$(build_minimal_payload "active" "${idle_seconds:-0}")
  send_payload "$PAYLOAD" || true
  exit 0
fi

# --- Chrome URLs (all open tabs) ---
CHROME_URL=""
CHROME_ALL_TABS=""
if pgrep -x "Google Chrome" >/dev/null 2>&1; then
  CHROME_URL=$(osascript -e 'tell application "Google Chrome" to get URL of active tab of front window' 2>/dev/null || echo "")
  CHROME_ALL_TABS=$(osascript -e '
    set tabList to {}
    tell application "Google Chrome"
      repeat with w in windows
        repeat with t in tabs of w
          set end of tabList to (URL of t) & "|" & (title of t)
        end repeat
      end repeat
    end tell
    set AppleScript'\''s text item delimiters to ";;;"
    return tabList as text
  ' 2>/dev/null || echo "")
fi

# --- File path from editor window title ---
FILE_PATH=""
GIT_REPO=""
GIT_BRANCH=""

if [[ "$ACTIVE_APP" == "Cursor" || "$ACTIVE_APP" == "Code" || "$ACTIVE_APP" == "Visual Studio Code" ]]; then
  # Electron editors: try multiple separator patterns
  FILE_PATH=$(echo "$WINDOW_TITLE" | sed -n 's/.*— \(.*\) — .*/\1/p' 2>/dev/null || echo "")
  if [ -z "$FILE_PATH" ]; then
    FILE_PATH=$(echo "$WINDOW_TITLE" | sed -n 's/.* - \(.*\) - .*/\1/p' 2>/dev/null || echo "")
  fi
  if [ -z "$FILE_PATH" ]; then
    FILE_PATH=$(echo "$WINDOW_TITLE" | sed -n 's/.* | \(.*\) | .*/\1/p' 2>/dev/null || echo "")
  fi
  
  # Git info from project directory
  if [ -n "$FILE_PATH" ] && [ -d "$HOME/$FILE_PATH" ]; then
    GIT_BRANCH=$(cd "$HOME/$FILE_PATH" && git branch --show-current 2>/dev/null || echo "")
    GIT_REPO=$(cd "$HOME/$FILE_PATH" && basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo "")
  fi
fi

# --- Terminal context ---
TERM_PWD=""
if [[ "$ACTIVE_APP" == "Terminal" || "$ACTIVE_APP" == "iTerm2" || "$ACTIVE_APP" == "Warp" ]]; then
  if [[ "$ACTIVE_APP" == "Terminal" ]]; then
    TERM_PWD=$(osascript -e 'tell application "Terminal" to get custom title of front window' 2>/dev/null || echo "")
  fi
  # Also try to infer git info from terminal window title (often shows branch)
  if echo "$WINDOW_TITLE" | grep -q "git:" 2>/dev/null; then
    GIT_BRANCH=$(echo "$WINDOW_TITLE" | grep -oE 'git:[^ ]+' | cut -d: -f2 || echo "")
  fi
fi

# --- Terminal commands (from preexec hook log) ---
TERMINAL_CMDS=""
if [ -f "$CMD_LOG" ] && [ -s "$CMD_LOG" ]; then
  TERMINAL_CMDS=$(tail -10 "$CMD_LOG" 2>/dev/null | \
    sed -E 's/(export[[:space:]]+[A-Za-z_]*(KEY|TOKEN|SECRET|PASSWORD|PASS)[A-Za-z_]*=).*/\1[REDACTED]/gi' | \
    sed -E 's/(Bearer[[:space:]]+)[^ ]+/\1[REDACTED]/g' | \
    sed -E 's/(password|secret|token)[[:space:]]*=[[:space:]]*[^ ]+/\1=[REDACTED]/gi' | \
    sed -E 's/sk-[a-zA-Z0-9]+/[REDACTED_KEY]/g' | \
    sed -E 's/sb_[a-zA-Z0-9_]+/[REDACTED_KEY]/g' | \
    sed -E 's/am_[a-zA-Z0-9_]+/[REDACTED_KEY]/g' | \
    python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null || echo '""')
  > "$CMD_LOG"
fi

# --- Clipboard change detection (content never leaves the Mac) ---
CLIPBOARD_CHANGED="false"
CURRENT_CLIP=$(pbpaste 2>/dev/null | head -c 2000 || echo "")  # cap at 2KB
if [ -n "$CURRENT_CLIP" ]; then
  CURRENT_HASH=$(echo "$CURRENT_CLIP" | md5 -q 2>/dev/null || echo "$CURRENT_CLIP" | md5sum 2>/dev/null | cut -d' ' -f1)
  LAST_HASH=""
  if [ -f "$CLIPBOARD_HASH_FILE" ]; then
    LAST_HASH=$(cat "$CLIPBOARD_HASH_FILE" 2>/dev/null || echo "")
  fi
  if [ "$CURRENT_HASH" != "$LAST_HASH" ]; then
    CLIPBOARD_CHANGED="true"
    printf '%s' "$CURRENT_HASH" > "$CLIPBOARD_HASH_FILE"
    chmod 600 "$CLIPBOARD_HASH_FILE" 2>/dev/null || true
  fi
fi

# --- File change events (from fswatch log) ---
FILE_CHANGES=""
if [ -f "$FSWATCH_LOG" ] && [ -s "$FSWATCH_LOG" ]; then
  FILE_CHANGES=$(tail -30 "$FSWATCH_LOG" 2>/dev/null | \
    sort -u | \
    awk 'NR <= 20 { print }' | \
    python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null || echo '""')
  > "$FSWATCH_LOG"
fi

# --- Codex / Claude Code session detection ---
CODEX_SESSION=""
# Check for active Codex sessions (Codex stores sessions in ~/.codex/sessions/)
CODEX_DIR="$HOME/.codex/sessions"
if [ -d "$CODEX_DIR" ]; then
  # Find sessions modified in last 5 minutes
  RECENT_SESSIONS=$(find "$CODEX_DIR" -name "*.json" -mmin -5 2>/dev/null | awk 'NR <= 3 { print }')
  if [ -n "$RECENT_SESSIONS" ]; then
    CODEX_SESSION=$(echo "$RECENT_SESSIONS" | while read -r sess; do
      # Extract session metadata (task/prompt) without full conversation
      python3 -c "
import json, sys
try:
    with open('$sess') as f:
        data = json.load(f)
    # Get just the initial task/prompt, not full conversation
    task = data.get('task', data.get('prompt', data.get('messages', [{}])[0].get('content', '')))[:200]
    print(json.dumps({'file': '$sess', 'task': task}))
except: pass
" 2>/dev/null
    done | python3 -c "import sys,json; lines=[l.strip() for l in sys.stdin if l.strip()]; print(json.dumps(lines))" 2>/dev/null || echo '[]')
  fi
fi
# Also check if Claude Code / Codex is running as a process
CODEX_RUNNING="false"
if pgrep -f "codex" >/dev/null 2>&1 || pgrep -f "claude" >/dev/null 2>&1; then
  CODEX_RUNNING="true"
fi

# --- WhatsApp Desktop context ---
WHATSAPP_CONTEXT=""
if pgrep -x "WhatsApp" >/dev/null 2>&1; then
  # Get WhatsApp window title (shows active chat name)
  WA_TITLE=$(osascript -e 'tell application "System Events" to get name of front window of application process "WhatsApp"' 2>/dev/null || echo "")
  if [ -n "$WA_TITLE" ]; then
    WHATSAPP_CONTEXT="$WA_TITLE"
  fi
fi

# --- Notifications (with Full Disk Access support) ---
NOTIFICATIONS=""
# Primary: notification center DB (requires Full Disk Access)
NOTIF_DB="$HOME/Library/Group Containers/group.com.apple.usernoted/db2/db"
if [ -f "$NOTIF_DB" ] && [ -r "$NOTIF_DB" ]; then
  NOTIFICATIONS=$(sqlite3 "$NOTIF_DB" "
    SELECT app_id, title, body 
    FROM record 
    WHERE delivered_date > strftime('%s','now') - 180
    ORDER BY delivered_date DESC
    LIMIT 5
  " 2>/dev/null | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null || echo '""')
fi
# Fallback: try alternative notification DB paths for different macOS versions
if [ "$NOTIFICATIONS" = '""' ] || [ -z "$NOTIFICATIONS" ]; then
  ALT_NOTIF_DB="$HOME/Library/Group Containers/group.com.apple.usernoted/db/db"
  if [ -f "$ALT_NOTIF_DB" ] && [ -r "$ALT_NOTIF_DB" ]; then
    NOTIFICATIONS=$(sqlite3 "$ALT_NOTIF_DB" "
      SELECT app_id, title, body 
      FROM record 
      WHERE delivered_date > strftime('%s','now') - 180
      ORDER BY delivered_date DESC
      LIMIT 5
    " 2>/dev/null | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null || echo '""')
  fi
fi

# Export for Python payload builder
export CB_APP="$ACTIVE_APP"
export CB_WINDOW_TITLE="$WINDOW_TITLE"
export CB_CHROME_URL="$CHROME_URL"
export CB_ALL_TABS="$CHROME_ALL_TABS"
export CB_FILE_PATH="$FILE_PATH"
export CB_GIT_REPO="$GIT_REPO"
export CB_GIT_BRANCH="$GIT_BRANCH"
export CB_TERMINAL_CMDS="${TERMINAL_CMDS:-""}"
export CB_CLIPBOARD_CHANGED="$CLIPBOARD_CHANGED"
export CB_FILE_CHANGES="${FILE_CHANGES:-""}"
export CB_CODEX_SESSION="${CODEX_SESSION:-""}"
export CB_CODEX_RUNNING="$CODEX_RUNNING"
export CB_WHATSAPP="$WHATSAPP_CONTEXT"
export CB_NOTIFICATIONS="${NOTIFICATIONS:-""}"
export CB_IDLE_SECONDS="${idle_seconds:-0}"

PAYLOAD=$(python3 -c "
import json, os
data = {
    'ts': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'app': os.environ.get('CB_APP', ''),
    'window_title': os.environ.get('CB_WINDOW_TITLE', ''),
    'url': os.environ.get('CB_CHROME_URL', ''),
    'all_tabs': os.environ.get('CB_ALL_TABS', ''),
    'file_path': os.environ.get('CB_FILE_PATH', ''),
    'git_repo': os.environ.get('CB_GIT_REPO', ''),
    'git_branch': os.environ.get('CB_GIT_BRANCH', ''),
    'terminal_cmds': os.environ.get('CB_TERMINAL_CMDS', ''),
    'clipboard_changed': os.environ.get('CB_CLIPBOARD_CHANGED', 'false') == 'true',
    'file_changes': os.environ.get('CB_FILE_CHANGES', ''),
    'codex_session': os.environ.get('CB_CODEX_SESSION', ''),
    'codex_running': os.environ.get('CB_CODEX_RUNNING', 'false') == 'true',
    'whatsapp_context': os.environ.get('CB_WHATSAPP', ''),
    'notifications': os.environ.get('CB_NOTIFICATIONS', ''),
    'idle_state': 'active',
    'idle_seconds': int(os.environ.get('CB_IDLE_SECONDS', '0')),
}
print(json.dumps(data))
" 2>/dev/null)

if [ -z "$PAYLOAD" ]; then
  echo "ERROR: Failed to build payload" >&2
  exit 1
fi

send_payload "$PAYLOAD" || true
