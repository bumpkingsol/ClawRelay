#!/bin/bash
# OpenClaw Context Bridge - Helper Control CLI
# Narrow command surface for the native SwiftUI menu-bar app.
# All output is JSON so the Swift side can decode it easily.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/context-common.sh"

# ---------------------------------------------------------------------------
# status  – JSON snapshot of the bridge's current state
# ---------------------------------------------------------------------------
status_json() {
  python3 - <<'PY'
import json, os, sqlite3, subprocess, time

home = os.path.expanduser("~/.context-bridge")
pause_path = os.path.join(home, "pause-until")
sensitive_path = os.path.join(home, "sensitive-mode")
db_path = os.path.join(home, "local.db")

queue_depth = 0
if os.path.exists(db_path):
    try:
        db = sqlite3.connect(db_path)
        queue_depth = db.execute("select count(*) from queue").fetchone()[0]
        db.close()
    except sqlite3.Error:
        pass

def launchd_state(label: str) -> str:
    proc = subprocess.run(["launchctl", "list", label],
                          capture_output=True, text=True)
    return "loaded" if proc.returncode == 0 else "missing"

paused = False
pause_until = None
if os.path.exists(pause_path):
    raw = open(pause_path).read().strip()
    pause_until = raw if raw else None
    if pause_until == "indefinite":
        paused = True
    elif pause_until:
        try:
            paused = int(pause_until) > int(time.time())
        except ValueError:
            paused = False
            pause_until = None

snapshot = {
    "trackingState": "paused" if paused else (
        "sensitive" if os.path.exists(sensitive_path) else "active"),
    "pauseUntil": pause_until,
    "sensitiveMode": os.path.exists(sensitive_path),
    "queueDepth": queue_depth,
    "daemonLaunchdState": launchd_state("com.openclaw.context-bridge"),
    "watcherLaunchdState": launchd_state("com.openclaw.context-bridge-fswatch"),
}
print(json.dumps(snapshot))
PY
}

# ---------------------------------------------------------------------------
# pause <seconds> | until-tomorrow | indefinite
# ---------------------------------------------------------------------------
do_pause() {
  local arg="${1:-}"
  local pause_file
  pause_file="$(cb_pause_file)"

  case "$arg" in
    indefinite)
      echo "indefinite" > "$pause_file"
      ;;
    until-tomorrow)
      # midnight local time tomorrow
      local tomorrow
      tomorrow="$(date -v+1d -j -f '%Y-%m-%d' "$(date +%Y-%m-%d)" '+%s' 2>/dev/null \
                  || date -d 'tomorrow 00:00:00' '+%s')"
      echo "$tomorrow" > "$pause_file"
      ;;
    ''|*[!0-9]*)
      echo '{"error":"pause requires <seconds>, until-tomorrow, or indefinite"}' >&2
      exit 1
      ;;
    *)
      local until
      until=$(( $(cb_now_epoch) + arg ))
      echo "$until" > "$pause_file"
      ;;
  esac
  status_json
}

# ---------------------------------------------------------------------------
# resume
# ---------------------------------------------------------------------------
do_resume() {
  rm -f "$(cb_pause_file)"
  status_json
}

# ---------------------------------------------------------------------------
# sensitive on|off
# ---------------------------------------------------------------------------
do_sensitive() {
  local mode="${1:-}"
  case "$mode" in
    on)  touch "$(cb_sensitive_file)" ;;
    off) rm -f "$(cb_sensitive_file)" ;;
    *)
      echo '{"error":"sensitive requires on or off"}' >&2
      exit 1
      ;;
  esac
  status_json
}

# ---------------------------------------------------------------------------
# restart-daemon / restart-watcher
# ---------------------------------------------------------------------------
restart_launchd() {
  local label="$1"
  local plist="$HOME/Library/LaunchAgents/${label}.plist"
  if [ ! -f "$plist" ]; then
    echo "{\"error\":\"plist not found: $plist\"}" >&2
    exit 1
  fi
  launchctl unload "$plist" 2>/dev/null || true
  launchctl load "$plist"
  status_json
}

# ---------------------------------------------------------------------------
# purge-local  – wipe the local SQLite queue
# ---------------------------------------------------------------------------
do_purge_local() {
  local db_path
  db_path="$(cb_dir)/local.db"
  if [ -f "$db_path" ]; then
    sqlite3 "$db_path" "DELETE FROM queue;" 2>/dev/null || true
  fi
  status_json
}

# ---------------------------------------------------------------------------
# queue-handoff <project> <task> [message]
# ---------------------------------------------------------------------------
do_queue_handoff() {
  local project="${1:-}"
  local task="${2:-}"
  local message="${3:-}"
  if [ -z "$project" ] || [ -z "$task" ]; then
    echo '{"error":"queue-handoff requires <project> <task> [message]"}' >&2
    exit 1
  fi

  local outbox
  outbox="$(cb_handoff_outbox_dir)"
  mkdir -p "$outbox"

  local ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"

  # Sanitize project and task to prevent directory traversal
  local project_safe="${project//[^a-zA-Z0-9_-]/_}"
  local task_safe="${task//[^a-zA-Z0-9_-]/_}"
  local filename="${ts}_${project_safe}_${task_safe}.json"

  python3 -c "
import json, sys
obj = {
    'project': sys.argv[1],
    'task':    sys.argv[2],
    'message': sys.argv[3],
    'ts':      sys.argv[4],
}
print(json.dumps(obj))
" "$project" "$task" "$message" "$ts" > "$outbox/$filename"

  status_json
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
cmd="${1:-}"
shift || true

case "$cmd" in
  status)          status_json ;;
  pause)           do_pause "$@" ;;
  resume)          do_resume ;;
  sensitive)       do_sensitive "$@" ;;
  restart-daemon)  restart_launchd "com.openclaw.context-bridge" ;;
  restart-watcher) restart_launchd "com.openclaw.context-bridge-fswatch" ;;
  purge-local)     do_purge_local ;;
  queue-handoff)   do_queue_handoff "$@" ;;
  *)
    echo '{"error":"unknown command","usage":"status|pause|resume|sensitive|restart-daemon|restart-watcher|purge-local|queue-handoff"}' >&2
    exit 1
    ;;
esac
