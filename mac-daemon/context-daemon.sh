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

# --- Source shared helpers and check pause state ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/context-common.sh"

if cb_is_paused; then
  exit 0
fi

# --- Auth check ---
if [ -z "$AUTH_TOKEN" ]; then
  AUTH_TOKEN=$(security find-generic-password -s "context-bridge" -a "token" -w 2>/dev/null || echo "")
  if [ -z "$AUTH_TOKEN" ]; then
    echo "ERROR: No auth token found. Set CONTEXT_BRIDGE_TOKEN or add to Keychain." >&2
    exit 1
  fi
fi

# Flush handoff outbox on every exit (including early exits for idle/paused/sensitive)
trap 'flush_handoff_outbox' EXIT

flush_handoff_outbox() {
  local outbox="$CB_DIR/handoff-outbox"
  [ -d "$outbox" ] || return 0
  local handoff_url="$(echo "$SERVER_URL" | sed 's|/context/push|/context/handoff|')"
  for hf in "$outbox"/*.json; do
    [ -f "$hf" ] || continue
    local hf_curl_args=()
    while IFS= read -r arg; do
      hf_curl_args+=("$arg")
    done < <(curl_tls_args)

    local hf_code
    if [ ${#hf_curl_args[@]} -gt 0 ]; then
      hf_code=$(curl -sf -o /dev/null -w "%{http_code}" \
        -X POST "$handoff_url" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -H "Content-Type: application/json" \
        -d @"$hf" \
        --connect-timeout 5 --max-time 10 \
        "${hf_curl_args[@]}" \
        2>/dev/null || echo "000")
    else
      hf_code=$(curl -sf -o /dev/null -w "%{http_code}" \
        -X POST "$handoff_url" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -H "Content-Type: application/json" \
        -d @"$hf" \
        --connect-timeout 5 --max-time 10 \
        2>/dev/null || echo "000")
    fi

    if [ "$hf_code" = "201" ]; then
      rm -f "$hf"
    fi
  done
}

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

    if [ ${#curl_args[@]} -gt 0 ]; then
      curl -sf -o /dev/null \
        -X POST "$SERVER_URL" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$queued_payload" \
        --connect-timeout 5 --max-time 10 \
        "${curl_args[@]}" \
        2>/dev/null
    else
      curl -sf -o /dev/null \
        -X POST "$SERVER_URL" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$queued_payload" \
        --connect-timeout 5 --max-time 10 \
        2>/dev/null
    fi && \
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

  if [ ${#curl_args[@]} -gt 0 ]; then
    http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
      -X POST "$SERVER_URL" \
      -H "Authorization: Bearer $AUTH_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      --connect-timeout 5 \
      --max-time 10 \
      "${curl_args[@]}" \
      2>/dev/null || echo "000")
  else
    http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
      -X POST "$SERVER_URL" \
      -H "Authorization: Bearer $AUTH_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      --connect-timeout 5 \
      --max-time 10 \
      2>/dev/null || echo "000")
  fi

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

PRIVACY_RULES_FILE="$CB_DIR/privacy-rules.json"

# Load privacy rules into shell-friendly formats (once at startup)
SENSITIVE_APPS_LIST=""
SENSITIVE_URL_PATTERNS=""
SENSITIVE_TITLE_KEYWORDS=""
if [ -f "$PRIVACY_RULES_FILE" ]; then
  SENSITIVE_APPS_LIST=$(python3 -c "
import json
with open('$PRIVACY_RULES_FILE') as f:
    rules = json.load(f)
for app in rules.get('sensitive_apps', []):
    print(app.lower())
" 2>/dev/null || echo "")
  SENSITIVE_URL_PATTERNS=$(python3 -c "
import json
with open('$PRIVACY_RULES_FILE') as f:
    rules = json.load(f)
for p in rules.get('sensitive_url_patterns', []):
    print(p.lower())
" 2>/dev/null || echo "")
  SENSITIVE_TITLE_KEYWORDS=$(python3 -c "
import json
with open('$PRIVACY_RULES_FILE') as f:
    rules = json.load(f)
for k in rules.get('sensitive_title_keywords', []):
    print(k.lower())
" 2>/dev/null || echo "")
fi

is_sensitive_app() {
  local app_lower
  app_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  if [ -n "$SENSITIVE_APPS_LIST" ]; then
    while IFS= read -r pattern; do
      [ -z "$pattern" ] && continue
      if [[ "$app_lower" == *"$pattern"* ]]; then
        return 0
      fi
    done <<< "$SENSITIVE_APPS_LIST"
    return 1
  fi
  # Fallback hardcoded list if no rules file
  case "$1" in
    "1Password"*|"Wise"|"Revolut"|"Vaultwarden") return 0 ;;
    *) return 1 ;;
  esac
}

is_sensitive_url() {
  local url_lower
  url_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  [ -z "$url_lower" ] && return 1
  if [ -n "$SENSITIVE_URL_PATTERNS" ]; then
    while IFS= read -r pattern; do
      [ -z "$pattern" ] && continue
      if [[ "$url_lower" == *"$pattern"* ]]; then
        return 0
      fi
    done <<< "$SENSITIVE_URL_PATTERNS"
  fi
  return 1
}

is_sensitive_title() {
  local title_lower
  title_lower=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  [ -z "$title_lower" ] && return 1
  if [ -n "$SENSITIVE_TITLE_KEYWORDS" ]; then
    while IFS= read -r keyword; do
      [ -z "$keyword" ] && continue
      if [[ "$title_lower" == *"$keyword"* ]]; then
        return 0
      fi
    done <<< "$SENSITIVE_TITLE_KEYWORDS"
  fi
  return 1
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

# --- If sensitive mode, send minimal active payload ---
if cb_is_sensitive_mode; then
  PAYLOAD=$(build_minimal_payload "active" "${idle_seconds:-0}")
  send_payload "$PAYLOAD" || true
  exit 0
fi

# ============================================================
# ACTIVE STATE - Full Capture
# ============================================================

# --- Active App + Window Title (switch log or snapshot) ---
SWITCH_LOG="$CB_DIR/app-switches.jsonl"
SWITCH_RESULT=""

if [ -f "$SWITCH_LOG" ] && [ -s "$SWITCH_LOG" ]; then
  SWITCH_RESULT=$(python3 -c "
import json, sys
from datetime import datetime, timezone

log_path = sys.argv[1]
lines = []
try:
    with open(log_path) as f:
        lines = [json.loads(l) for l in f if l.strip()]
except:
    pass

if not lines:
    print(json.dumps({'fallback': True}))
    sys.exit(0)

app_times = {}
all_titles = []
for i, entry in enumerate(lines):
    try:
        ts = datetime.fromisoformat(entry['ts'].replace('Z', '+00:00'))
    except:
        continue
    if i + 1 < len(lines):
        try:
            next_ts = datetime.fromisoformat(lines[i+1]['ts'].replace('Z', '+00:00'))
            duration = (next_ts - ts).total_seconds()
        except:
            duration = 0
    else:
        duration = (datetime.now(timezone.utc) - ts).total_seconds()
    duration = min(max(duration, 0), 300)
    app = entry.get('app', 'unknown')
    app_times[app] = app_times.get(app, 0) + duration
    title = entry.get('title', '')
    if title:
        all_titles.append(title)

if not app_times:
    print(json.dumps({'fallback': True}))
    sys.exit(0)

dominant = max(app_times, key=app_times.get)
dominant_title = ''
for entry in reversed(lines):
    if entry.get('app') == dominant:
        dominant_title = entry.get('title', '')
        break

unique_titles = list(set(all_titles))
print(json.dumps({
    'app': dominant,
    'title': dominant_title,
    'all_titles': unique_titles,
}))
" "$SWITCH_LOG" 2>/dev/null || echo '{"fallback": true}')

  # Truncate the log after reading
  > "$SWITCH_LOG"
fi

# Parse result or fall back to snapshot
FALLBACK=$(echo "$SWITCH_RESULT" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('fallback',''))" 2>/dev/null || echo "true")

if [ "$FALLBACK" = "True" ] || [ "$FALLBACK" = "true" ] || [ -z "$SWITCH_RESULT" ]; then
  # Snapshot fallback
  ACTIVE_APP=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || echo "unknown")
  WINDOW_TITLE=$(osascript -e 'tell application "System Events" to get name of front window of first application process whose frontmost is true' 2>/dev/null || echo "")
else
  ACTIVE_APP=$(echo "$SWITCH_RESULT" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('app','unknown'))" 2>/dev/null || echo "unknown")
  DOMINANT_TITLE=$(echo "$SWITCH_RESULT" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('title',''))" 2>/dev/null || echo "")
  ALL_TITLES=$(echo "$SWITCH_RESULT" | python3 -c "import json,sys; print(' '.join(json.loads(sys.stdin.read()).get('all_titles',[])))" 2>/dev/null || echo "")
  WINDOW_TITLE="$DOMINANT_TITLE"
  if [ -n "$ALL_TITLES" ]; then
    WINDOW_TITLE="$DOMINANT_TITLE [also: $ALL_TITLES]"
  fi
fi

# --- Sensitive app or title: blank out entirely ---
if is_sensitive_app "$ACTIVE_APP" || is_sensitive_title "$WINDOW_TITLE"; then
  PAYLOAD=$(build_minimal_payload "active" "${idle_seconds:-0}")
  send_payload "$PAYLOAD" || true
  exit 0
fi

# --- Chrome URLs (all open tabs, with sensitive URL filtering) ---
CHROME_URL=""
CHROME_ALL_TABS=""
if pgrep -x "Google Chrome" >/dev/null 2>&1; then
  CHROME_URL=$(osascript -e 'tell application "Google Chrome" to get URL of active tab of front window' 2>/dev/null || echo "")

  # If the active tab is a sensitive URL, blank out entirely
  if is_sensitive_url "$CHROME_URL"; then
    PAYLOAD=$(build_minimal_payload "active" "${idle_seconds:-0}")
    send_payload "$PAYLOAD" || true
    exit 0
  fi

  # Collect all tabs, then filter out sensitive ones
  CHROME_ALL_TABS_RAW=$(osascript -e '
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

  # Strip sensitive tabs from the list
  if [ -n "$CHROME_ALL_TABS_RAW" ]; then
    CHROME_ALL_TABS=$(echo "$CHROME_ALL_TABS_RAW" | tr ';;;' '\n' | while IFS= read -r tab_entry; do
      tab_url=$(echo "$tab_entry" | cut -d'|' -f1)
      if ! is_sensitive_url "$tab_url"; then
        echo "$tab_entry"
      fi
    done | paste -sd ';;;' - 2>/dev/null || echo "")
  fi
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

# --- WhatsApp messages (atomic rotation) ---
WA_BUFFER="$CB_DIR/whatsapp-buffer.jsonl"
WA_PROCESSING="$CB_DIR/whatsapp-buffer.jsonl.processing"
WA_MESSAGES_FILE=""

# Recover any leftover .processing file from a failed previous cycle
if [ -f "$WA_PROCESSING" ] && [ ! -f "$WA_BUFFER" ]; then
    WA_MESSAGES_FILE="$WA_PROCESSING"
elif [ -f "$WA_PROCESSING" ] && [ -f "$WA_BUFFER" ]; then
    cat "$WA_PROCESSING" "$WA_BUFFER" > "$WA_PROCESSING.merged"
    mv "$WA_PROCESSING.merged" "$WA_PROCESSING"
    rm -f "$WA_BUFFER"
    WA_MESSAGES_FILE="$WA_PROCESSING"
elif mv "$WA_BUFFER" "$WA_PROCESSING" 2>/dev/null; then
    WA_MESSAGES_FILE="$WA_PROCESSING"
fi

# Parse JSONL to JSON array via temp file (avoids ARG_MAX limits)
WA_JSON_TMP=""
if [ -n "$WA_MESSAGES_FILE" ] && [ -s "$WA_MESSAGES_FILE" ]; then
    WA_JSON_TMP="$CB_DIR/whatsapp-payload.json"
    python3 -c "
import sys, json
lines = []
for line in sys.stdin:
    line = line.strip()
    if line:
        try:
            lines.append(json.loads(line))
        except json.JSONDecodeError:
            pass
with open(sys.argv[1], 'w') as f:
    json.dump(lines, f)
" "$WA_JSON_TMP" < "$WA_MESSAGES_FILE"
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
NOTIF_DB="$HOME/Library/Group Containers/group.com.apple.usernoted/db2/db"
if [ -f "$NOTIF_DB" ] && [ -r "$NOTIF_DB" ]; then
  NOTIFICATIONS=$(python3 -c "
import sqlite3, json, sys
try:
    conn = sqlite3.connect('$NOTIF_DB')
    rows = conn.execute('''
        SELECT app_id, title, body
        FROM record
        WHERE delivered_date > strftime('%s','now') - 180
        ORDER BY delivered_date DESC
        LIMIT 5
    ''').fetchall()
    conn.close()
    print(json.dumps([{'app': r[0] or '', 'title': r[1] or '', 'body': r[2] or ''} for r in rows]))
except:
    print('[]')
" 2>/dev/null || echo "[]")
fi
# Fallback: alternative DB path for different macOS versions
if [ "$NOTIFICATIONS" = "[]" ] || [ -z "$NOTIFICATIONS" ]; then
  ALT_NOTIF_DB="$HOME/Library/Group Containers/group.com.apple.usernoted/db/db"
  if [ -f "$ALT_NOTIF_DB" ] && [ -r "$ALT_NOTIF_DB" ]; then
    NOTIFICATIONS=$(python3 -c "
import sqlite3, json
try:
    conn = sqlite3.connect('$ALT_NOTIF_DB')
    rows = conn.execute('''
        SELECT app_id, title, body
        FROM record
        WHERE delivered_date > strftime('%s','now') - 180
        ORDER BY delivered_date DESC
        LIMIT 5
    ''').fetchall()
    conn.close()
    print(json.dumps([{'app': r[0] or '', 'title': r[1] or '', 'body': r[2] or ''} for r in rows]))
except:
    print('[]')
" 2>/dev/null || echo "[]")
  fi
fi

# --- Meeting / Call Detection ---
IN_CALL="false"
CALL_APP=""
CALL_TYPE="unknown"

# Check camera (VDCAssistant = camera in use)
CAMERA_ACTIVE="false"
if pgrep -x "VDCAssistant" >/dev/null 2>&1; then
  CAMERA_ACTIVE="true"
fi

# Check mic via ioreg (audio input active)
MIC_ACTIVE="false"
if ioreg -c AppleHDAEngineInput 2>/dev/null | grep -q "IOAudioEngineState = 1" 2>/dev/null; then
  MIC_ACTIVE="true"
fi

# Identify call app first — mic/camera alone doesn't mean a call
# (many apps use mic/camera: voice memos, photo booth, Claude Code, etc.)
if [ "$CAMERA_ACTIVE" = "true" ] || [ "$MIC_ACTIVE" = "true" ]; then
  if pgrep -x "zoom.us" >/dev/null 2>&1; then
    CALL_APP="Zoom"
  elif pgrep -x "FaceTime" >/dev/null 2>&1; then
    CALL_APP="FaceTime"
  elif pgrep -x "Microsoft Teams" >/dev/null 2>&1 || pgrep -f "MSTeams" >/dev/null 2>&1; then
    CALL_APP="Teams"
  elif pgrep -x "Discord" >/dev/null 2>&1; then
    CALL_APP="Discord"
  elif pgrep -x "Slack" >/dev/null 2>&1; then
    CALL_APP="Slack"
  elif [ -n "$CHROME_ALL_TABS" ] && echo "$CHROME_ALL_TABS" | grep -qi "meet.google.com" 2>/dev/null; then
    CALL_APP="Google Meet"
  fi

  # Only mark as in-call if a known call app is running
  if [ -n "$CALL_APP" ]; then
    IN_CALL="true"
    if [ "$CAMERA_ACTIVE" = "true" ]; then
      CALL_TYPE="video"
    else
      CALL_TYPE="audio"
    fi
  fi
fi

# --- macOS Focus / DND Mode ---
FOCUS_MODE=""
FOCUS_MODE=$(osascript -e '
  try
    set focusState to do shell script "defaults read com.apple.controlcenter NSStatusItem\\ Visible\\ FocusModes 2>/dev/null || echo 0"
    if focusState is "1" then
      return "Focus"
    end if
  end try
  try
    set dndState to do shell script "plutil -extract dnd_prefs.userPref.enabled raw ~/Library/DoNotDisturb/DB/Assertions/DND.json 2>/dev/null || echo false"
    if dndState is "true" then
      return "Do Not Disturb"
    end if
  end try
  return ""
' 2>/dev/null || echo "")

# --- Calendar Awareness (opt-in) ---
CALENDAR_EVENTS="[]"
CALENDAR_ENABLED=$(python3 -c "
import json
try:
    with open('$PRIVACY_RULES_FILE') as f:
        print('true' if json.load(f).get('calendar_enabled') else 'false')
except:
    print('false')
" 2>/dev/null || echo "false")

if [ "$CALENDAR_ENABLED" = "true" ]; then
  # Use native Swift CLI (EventKit) — never launches Calendar.app
  export SENSITIVE_TITLE_KEYWORDS
  CALENDAR_EVENTS=$("$CB_DIR/bin/claw-calendar" 2>/dev/null || echo "[]")
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
export CB_IN_CALL="$IN_CALL"
export CB_CALL_APP="$CALL_APP"
export CB_CALL_TYPE="$CALL_TYPE"
export CB_FOCUS_MODE="$FOCUS_MODE"
export CB_CALENDAR_EVENTS="$CALENDAR_EVENTS"
export CB_IDLE_SECONDS="${idle_seconds:-0}"
export CB_WHATSAPP_MESSAGES_FILE="${WA_JSON_TMP:-""}"

PAYLOAD=$(python3 -c "
import json, os
wa_msgs = []
wa_file = os.environ.get('CB_WHATSAPP_MESSAGES_FILE', '')
if wa_file and os.path.exists(wa_file):
    with open(wa_file) as f:
        wa_msgs = json.load(f)
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
    'whatsapp_messages': wa_msgs,
    'notifications': os.environ.get('CB_NOTIFICATIONS', ''),
    'in_call': os.environ.get('CB_IN_CALL', 'false') == 'true',
    'call_app': os.environ.get('CB_CALL_APP', ''),
    'call_type': os.environ.get('CB_CALL_TYPE', 'unknown'),
    'focus_mode': os.environ.get('CB_FOCUS_MODE', '') or None,
    'calendar_events': os.environ.get('CB_CALENDAR_EVENTS', '[]'),
    'idle_state': 'active',
    'idle_seconds': int(os.environ.get('CB_IDLE_SECONDS', '0')),
}
print(json.dumps(data))
" 2>/dev/null)

if [ -z "$PAYLOAD" ]; then
  echo "ERROR: Failed to build payload" >&2
  exit 1
fi

if send_payload "$PAYLOAD"; then
  # Clean up WhatsApp buffer files after successful send
  rm -f "$WA_PROCESSING" "$WA_JSON_TMP"
fi

# --- Meeting Auto-Start / Stop / Sync ---
MEETING_BIN="$CB_DIR/bin/claw-meeting"
MEETING_PID_FILE="$CB_DIR/meeting-worker.pid"
MEETING_STATE_FILE="$CB_DIR/meeting-state.json"
MEETING_START_TRIGGER="$CB_DIR/meeting-start-trigger"
MEETING_STOP_TRIGGER="$CB_DIR/meeting-stop-trigger"
MEETING_SESSION_DIR="$CB_DIR/meeting-session"
MEETING_SYNC_SCRIPT="$CB_DIR/bin/meeting-sync.sh"

is_meeting_running() {
  if [ -f "$MEETING_PID_FILE" ]; then
    local pid
    pid=$(cat "$MEETING_PID_FILE" 2>/dev/null || echo "")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    # Stale PID file
    rm -f "$MEETING_PID_FILE"
  fi
  return 1
}

start_meeting() {
  local meeting_id="${1:-$(date +%Y-%m-%d-%H%M%S)}"
  if [ -x "$MEETING_BIN" ]; then
    "$MEETING_BIN" --run "$meeting_id" >> /tmp/claw-meeting.log 2>&1 &
    # Write state for helperctl
    python3 -c "
import json, os, time
state = {
    'state': 'recording',
    'meeting_id': '$meeting_id',
    'call_app': '$CALL_APP',
    'started_at': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'elapsed_seconds': 0,
}
with open('$MEETING_STATE_FILE', 'w') as f:
    json.dump(state, f)
" 2>/dev/null || true
  fi
}

stop_meeting() {
  if [ -x "$MEETING_BIN" ]; then
    "$MEETING_BIN" --stop 2>/dev/null || true
  fi
  # If still running after graceful stop, SIGTERM
  if is_meeting_running; then
    local pid
    pid=$(cat "$MEETING_PID_FILE" 2>/dev/null || echo "")
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  fi
}

sync_completed_meetings() {
  if [ -x "$MEETING_SYNC_SCRIPT" ] && [ -d "$MEETING_SESSION_DIR" ]; then
    for session_dir in "$MEETING_SESSION_DIR"/*/; do
      [ -d "$session_dir" ] || continue
      [ -f "$session_dir/.synced" ] && continue
      # Only sync if no PID file (meeting finished) or session has session-state.json with completed state
      if ! is_meeting_running || [ -f "$session_dir/session-state.json" ]; then
        "$MEETING_SYNC_SCRIPT" "$session_dir" >> /tmp/claw-meeting-sync.log 2>&1 &
      fi
    done
  fi
}

# Handle explicit triggers only — recording requires user consent
if [ -f "$MEETING_START_TRIGGER" ]; then
  TRIGGER_ID=$(cat "$MEETING_START_TRIGGER" 2>/dev/null || echo "")
  rm -f "$MEETING_START_TRIGGER"
  if ! is_meeting_running; then
    start_meeting "${TRIGGER_ID:-$(date +%Y-%m-%d-%H%M%S)}"
  fi
elif [ -f "$MEETING_STOP_TRIGGER" ]; then
  rm -f "$MEETING_STOP_TRIGGER"
  if is_meeting_running; then
    stop_meeting
  fi
fi

# Update state file for helperctl while meeting is active
if is_meeting_running && [ -f "$MEETING_STATE_FILE" ]; then
  python3 -c "
import json, time, os
try:
    with open('$MEETING_STATE_FILE') as f:
        state = json.load(f)
    started = state.get('started_at', '')
    if started:
        from datetime import datetime, timezone
        start_dt = datetime.fromisoformat(started.replace('Z', '+00:00'))
        state['elapsed_seconds'] = int((datetime.now(timezone.utc) - start_dt).total_seconds())
    state['state'] = 'recording'
    with open('$MEETING_STATE_FILE', 'w') as f:
        json.dump(state, f)
except: pass
" 2>/dev/null || true
fi

# Clean up state when meeting is done
if ! is_meeting_running && [ -f "$MEETING_STATE_FILE" ]; then
  python3 -c "
import json
try:
    with open('$MEETING_STATE_FILE') as f:
        state = json.load(f)
    if state.get('state') not in ('idle', 'completed'):
        state['state'] = 'completed'
        state['ended_at'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
        with open('$MEETING_STATE_FILE', 'w') as f:
            json.dump(state, f)
except: pass
" 2>/dev/null || true
fi

# Sync any completed meetings to server
sync_completed_meetings

# --- Flush handoff outbox ---
flush_handoff_outbox
