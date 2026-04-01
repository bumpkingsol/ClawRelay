#!/bin/bash
# OpenClaw Context Bridge - Helper Control CLI
# Narrow command surface for the native SwiftUI menu-bar app.
# All output is JSON so the Swift side can decode it easily.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/context-common.sh"

helper_auth_token() {
  cb_read_keychain_token "$(cb_keychain_service_helper)"
}

launchd_state() {
  local label="$1"
  if launchctl list "$label" >/dev/null 2>&1; then
    printf 'loaded\n'
  else
    printf 'missing\n'
  fi
}

product_state() {
  local daemon_state watcher_state
  daemon_state="$(launchd_state "com.openclaw.context-bridge")"
  watcher_state="$(launchd_state "com.openclaw.context-bridge-fswatch")"
  if [ "$daemon_state" = "missing" ] && [ "$watcher_state" = "missing" ]; then
    printf 'stopped\n'
  else
    printf 'running\n'
  fi
}

load_launch_agent() {
  local label="$1"
  local plist="$HOME/Library/LaunchAgents/${label}.plist"
  if [ ! -f "$plist" ]; then
    echo "{\"error\":\"plist not found: $plist\"}" >&2
    exit 1
  fi
  launchctl load "$plist"
}

unload_launch_agent() {
  local label="$1"
  local plist="$HOME/Library/LaunchAgents/${label}.plist"
  if [ ! -f "$plist" ]; then
    return 0
  fi
  launchctl unload "$plist" 2>/dev/null || true
}

stop_active_meeting_worker() {
  local cb
  cb="$(cb_dir)"
  local meeting_bin="$cb/bin/claw-meeting"
  local meeting_pid_file="$cb/meeting-worker.pid"

  if [ -x "$meeting_bin" ]; then
    "$meeting_bin" --stop 2>/dev/null || true
  fi

  if [ -f "$meeting_pid_file" ]; then
    local pid
    pid=$(cat "$meeting_pid_file" 2>/dev/null || echo "")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      sleep 1
      if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
      fi
    fi
  fi
}

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
meeting_pid_path = os.path.join(home, "meeting-worker.pid")
meeting_state_path = os.path.join(home, "meeting-state.json")

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

meeting_worker_pid = None
if os.path.exists(meeting_pid_path):
    try:
        pid = int(open(meeting_pid_path).read().strip())
        os.kill(pid, 0)
        meeting_worker_pid = pid
    except (ValueError, ProcessLookupError, PermissionError):
        pass

meeting_state = "idle"
meeting_id = None
meeting_elapsed_seconds = 0
if os.path.exists(meeting_state_path):
    try:
        ms = json.load(open(meeting_state_path))
        meeting_state = ms.get("state", "idle")
        meeting_id = ms.get("meeting_id", None)
        meeting_elapsed_seconds = ms.get("elapsed_seconds", 0)
    except (json.JSONDecodeError, IOError):
        pass

if meeting_worker_pid and meeting_state == "idle":
    meeting_state = "preparing"

snapshot = {
    "trackingState": "paused" if paused else (
        "sensitive" if os.path.exists(sensitive_path) else "active"),
    "productState": "running" if (
        launchd_state("com.openclaw.context-bridge") == "loaded"
        or launchd_state("com.openclaw.context-bridge-fswatch") == "loaded"
    ) else "stopped",
    "pauseUntil": pause_until,
    "sensitiveMode": os.path.exists(sensitive_path),
    "queueDepth": queue_depth,
    "daemonLaunchdState": launchd_state("com.openclaw.context-bridge"),
    "watcherLaunchdState": launchd_state("com.openclaw.context-bridge-fswatch"),
    "meetingState": meeting_state,
    "meetingId": meeting_id,
    "meetingElapsedSeconds": meeting_elapsed_seconds,
    "meetingWorkerPid": meeting_worker_pid,
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
# start-bridge / stop-bridge
# ---------------------------------------------------------------------------
do_start_bridge() {
  load_launch_agent "com.openclaw.context-bridge"
  load_launch_agent "com.openclaw.context-bridge-fswatch"
  status_json
}

do_stop_bridge() {
  stop_active_meeting_worker
  unload_launch_agent "com.openclaw.context-bridge-fswatch"
  unload_launch_agent "com.openclaw.context-bridge"
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
# purge-local  – wipe all local context data (queue, logs, pause, handoffs)
# ---------------------------------------------------------------------------
do_purge_local() {
  local cb
  cb="$(cb_dir)"
  local outbox
  outbox="$(cb_handoff_outbox_dir)"
  rm -f "$cb/local.db" "$cb/pause-until" "$cb/sensitive-mode" "$HOME/.context-bridge-cmds.log" "$cb/fswatch-changes.log"
  [ -n "$outbox" ] && [ "$outbox" != "/" ] && rm -rf "$outbox"
  mkdir -p "$cb" "$outbox"
  status_json
}

# ---------------------------------------------------------------------------
# privacy-rules get | set <path-to-json>
# ---------------------------------------------------------------------------
do_privacy_rules() {
  local subcmd="${1:-}"
  local rules_file
  rules_file="$(cb_privacy_rules_file)"
  case "$subcmd" in
    get)
      if [ -f "$rules_file" ]; then
        cat "$rules_file"
      else
        echo '{"rules":[]}'
      fi
      ;;
    set)
      local path="${2:-}"
      if [ -z "$path" ] || [ ! -f "$path" ]; then
        echo '{"error":"privacy-rules set requires a valid JSON file path"}' >&2
        exit 1
      fi
      cp "$path" "$rules_file"
      chmod 600 "$rules_file"
      status_json
      ;;
    *)
      echo '{"error":"privacy-rules requires get or set subcommand"}' >&2
      exit 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# queue-handoff <project> <task> [message]
# ---------------------------------------------------------------------------
do_queue_handoff() {
  local project="${1:-}"
  local task="${2:-}"
  local message="${3:-}"
  local priority="${4:-normal}"
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
    'priority': sys.argv[4],
    'ts':      sys.argv[5],
}
print(json.dumps(obj))
" "$project" "$task" "$message" "$priority" "$ts" > "$outbox/$filename"

  status_json
}

# ---------------------------------------------------------------------------
# list-handoffs  – fetch recent handoffs from the server
# ---------------------------------------------------------------------------
do_list_handoffs() {
  local server_url=""
  if [ -f "$(cb_dir)/server-url" ]; then
    server_url=$(cat "$(cb_dir)/server-url" 2>/dev/null || echo "")
  fi
  if [ -z "$server_url" ]; then
    echo "[]"
    exit 0
  fi

  # Replace /push with /handoffs in the URL
  # Assumes server-url contains the full push endpoint (e.g. https://host:7890/context/push)
  local handoffs_url
  handoffs_url=$(echo "$server_url" | sed 's|/context/push|/context/handoffs|')

  local auth_token=""
  auth_token=$(helper_auth_token)
  if [ -z "$auth_token" ]; then
    echo "[]"
    exit 0
  fi

  local curl_args=()
  local ca_cert="$(cb_dir)/server-ca.pem"
  if [[ "$handoffs_url" == https://* ]] && [ -f "$ca_cert" ]; then
    curl_args+=(--cacert "$ca_cert")
  fi

  local response
  if [ ${#curl_args[@]} -gt 0 ]; then
    response=$(curl -sf \
      -H "Authorization: Bearer $auth_token" \
      --connect-timeout 5 --max-time 10 \
      "${curl_args[@]}" \
      "$handoffs_url" 2>/dev/null || echo "[]")
  else
    response=$(curl -sf \
      -H "Authorization: Bearer $auth_token" \
      --connect-timeout 5 --max-time 10 \
      "$handoffs_url" 2>/dev/null || echo "[]")
  fi

  echo "$response"
}

# ---------------------------------------------------------------------------
# fetch-dashboard  – fetch combined dashboard data from the server
# ---------------------------------------------------------------------------
do_fetch_dashboard() {
  local history_days="${1:-7}"
  local server_url=""
  if [ -f "$(cb_dir)/server-url" ]; then
    server_url=$(cat "$(cb_dir)/server-url" 2>/dev/null || echo "")
  fi
  if [ -z "$server_url" ]; then
    echo "{}"
    exit 0
  fi

  local dashboard_url
  dashboard_url="$(echo "$server_url" | sed 's|/context/push|/context/dashboard|')?history_days=$history_days"

  local auth_token=""
  auth_token=$(helper_auth_token)
  if [ -z "$auth_token" ]; then
    echo "{}"
    exit 0
  fi

  local curl_args=()
  local ca_cert="$(cb_dir)/server-ca.pem"
  if [[ "$dashboard_url" == https://* ]] && [ -f "$ca_cert" ]; then
    curl_args+=(--cacert "$ca_cert")
  fi

  local response
  if [ ${#curl_args[@]} -gt 0 ]; then
    response=$(curl -sf \
      -H "Authorization: Bearer $auth_token" \
      --connect-timeout 5 --max-time 10 \
      "${curl_args[@]}" \
      "$dashboard_url" 2>/dev/null || echo "{}")
  else
    response=$(curl -sf \
      -H "Authorization: Bearer $auth_token" \
      --connect-timeout 5 --max-time 10 \
      "$dashboard_url" 2>/dev/null || echo "{}")
  fi

  echo "$response"
}

# ---------------------------------------------------------------------------
# mark-question-seen <id>  – PATCH jc-question seen=true on the server
# ---------------------------------------------------------------------------
do_mark_question_seen() {
  local qid="${1:-}"
  if [ -z "$qid" ]; then
    echo '{"error":"mark-question-seen requires <id>"}'
    exit 1
  fi

  local server_url=""
  if [ -f "$(cb_dir)/server-url" ]; then
    server_url=$(cat "$(cb_dir)/server-url" 2>/dev/null || echo "")
  fi
  if [ -z "$server_url" ]; then
    echo "{}"
    exit 0
  fi

  local question_url
  question_url="$(echo "$server_url" | sed "s|/context/push|/context/jc-question/$qid|")"

  local auth_token=""
  auth_token=$(helper_auth_token)
  if [ -z "$auth_token" ]; then
    echo "{}"
    exit 0
  fi

  local curl_args=()
  local ca_cert="$(cb_dir)/server-ca.pem"
  if [[ "$question_url" == https://* ]] && [ -f "$ca_cert" ]; then
    curl_args+=(--cacert "$ca_cert")
  fi

  if [ ${#curl_args[@]} -gt 0 ]; then
    curl -sf -X PATCH \
      -H "Authorization: Bearer $auth_token" \
      -H "Content-Type: application/json" \
      -d '{"seen": true}' \
      --connect-timeout 5 --max-time 10 \
      "${curl_args[@]}" \
      "$question_url" 2>/dev/null || echo "{}"
  else
    curl -sf -X PATCH \
      -H "Authorization: Bearer $auth_token" \
      -H "Content-Type: application/json" \
      -d '{"seen": true}' \
      --connect-timeout 5 --max-time 10 \
      "$question_url" 2>/dev/null || echo "{}"
  fi
}

# ---------------------------------------------------------------------------
# meeting-status  – JSON snapshot of current meeting state
# ---------------------------------------------------------------------------
do_meeting_status() {
  python3 - <<'PY'
import json, os

home = os.path.expanduser("~/.context-bridge")
pid_path = os.path.join(home, "meeting-worker.pid")
state_path = os.path.join(home, "meeting-state.json")

result = {
    "state": "idle",
    "meeting_id": None,
    "elapsed_seconds": 0,
    "worker_pid": None,
    "transcript_segments": 0,
    "screenshots_taken": 0,
    "briefing_loaded": False,
    "cards_surfaced": 0
}

if os.path.exists(pid_path):
    try:
        pid = int(open(pid_path).read().strip())
        os.kill(pid, 0)
        result["worker_pid"] = pid
    except (ValueError, ProcessLookupError, PermissionError):
        pass

if os.path.exists(state_path):
    try:
        state = json.load(open(state_path))
        result.update(state)
    except (json.JSONDecodeError, IOError):
        pass

if result["worker_pid"] and result["state"] == "idle":
    result["state"] = "preparing"

print(json.dumps({"meeting": result}))
PY
}

# ---------------------------------------------------------------------------
# meeting-start [meeting-id]  – trigger meeting start
# ---------------------------------------------------------------------------
do_meeting_start() {
  local meeting_id="${1:-}"
  local trigger_file
  trigger_file="$(cb_dir)/meeting-start-trigger"

  if [ -n "$meeting_id" ]; then
    echo "$meeting_id" > "$trigger_file"
  else
    echo "auto-$(date +%Y%m%d-%H%M%S)" > "$trigger_file"
  fi
  echo '{"status":"triggered"}'
}

# ---------------------------------------------------------------------------
# meeting-stop  – trigger meeting stop
# ---------------------------------------------------------------------------
do_meeting_stop() {
  local trigger_file
  trigger_file="$(cb_dir)/meeting-stop-trigger"
  touch "$trigger_file"
  echo '{"status":"triggered"}'
}

# ---------------------------------------------------------------------------
# projects  – fetch portfolio projects from the server
# ---------------------------------------------------------------------------
do_fetch_projects() {
  local server_url=""
  if [ -f "$(cb_dir)/server-url" ]; then
    server_url=$(cat "$(cb_dir)/server-url" 2>/dev/null || echo "")
  fi
  if [ -z "$server_url" ]; then
    echo '{}'
    exit 0
  fi

  local projects_url
  projects_url=$(echo "$server_url" | sed 's|/context/push|/context/projects|')

  local auth_token=""
  auth_token=$(helper_auth_token)
  if [ -z "$auth_token" ]; then
    echo '{}'
    exit 0
  fi

  local curl_args=()
  local ca_cert="$(cb_dir)/server-ca.pem"
  if [[ "$projects_url" == https://* ]] && [ -f "$ca_cert" ]; then
    curl_args+=(--cacert "$ca_cert")
  fi

  local response
  if [ ${#curl_args[@]} -gt 0 ]; then
    response=$(curl -sf \
      -H "Authorization: Bearer $auth_token" \
      --connect-timeout 5 --max-time 10 \
      "${curl_args[@]}" \
      "$projects_url" 2>/dev/null || echo '{}')
  else
    response=$(curl -sf \
      -H "Authorization: Bearer $auth_token" \
      --connect-timeout 5 --max-time 10 \
      "$projects_url" 2>/dev/null || echo '{}')
  fi

  echo "$response"
}

# ---------------------------------------------------------------------------
# meetings [days]  – fetch meeting history from the server
# ---------------------------------------------------------------------------
do_fetch_meetings() {
  local days="${1:-7}"
  local server_url=""
  if [ -f "$(cb_dir)/server-url" ]; then
    server_url=$(cat "$(cb_dir)/server-url" 2>/dev/null || echo "")
  fi
  if [ -z "$server_url" ]; then
    echo '{}'
    exit 0
  fi

  local meetings_url
  meetings_url="$(echo "$server_url" | sed "s|/context/push|/context/meetings|")?days=$days"

  local auth_token=""
  auth_token=$(helper_auth_token)
  if [ -z "$auth_token" ]; then
    echo '{}'
    exit 0
  fi

  local curl_args=()
  local ca_cert="$(cb_dir)/server-ca.pem"
  if [[ "$meetings_url" == https://* ]] && [ -f "$ca_cert" ]; then
    curl_args+=(--cacert "$ca_cert")
  fi

  local response
  if [ ${#curl_args[@]} -gt 0 ]; then
    response=$(curl -sf \
      -H "Authorization: Bearer $auth_token" \
      --connect-timeout 5 --max-time 10 \
      "${curl_args[@]}" \
      "$meetings_url" 2>/dev/null || echo '{}')
  else
    response=$(curl -sf \
      -H "Authorization: Bearer $auth_token" \
      --connect-timeout 5 --max-time 10 \
      "$meetings_url" 2>/dev/null || echo '{}')
  fi

  echo "$response"
}

# ---------------------------------------------------------------------------
# participants  – fetch participant profiles from the server
# ---------------------------------------------------------------------------
do_fetch_participants() {
  local server_url=""
  if [ -f "$(cb_dir)/server-url" ]; then
    server_url=$(cat "$(cb_dir)/server-url" 2>/dev/null || echo "")
  fi
  if [ -z "$server_url" ]; then
    echo '{}'
    exit 0
  fi

  local participants_url
  participants_url=$(echo "$server_url" | sed 's|/context/push|/context/participants|')

  local auth_token=""
  auth_token=$(helper_auth_token)
  if [ -z "$auth_token" ]; then
    echo '{}'
    exit 0
  fi

  local curl_args=()
  local ca_cert="$(cb_dir)/server-ca.pem"
  if [[ "$participants_url" == https://* ]] && [ -f "$ca_cert" ]; then
    curl_args+=(--cacert "$ca_cert")
  fi

  local response
  if [ ${#curl_args[@]} -gt 0 ]; then
    response=$(curl -sf \
      -H "Authorization: Bearer $auth_token" \
      --connect-timeout 5 --max-time 10 \
      "${curl_args[@]}" \
      "$participants_url" 2>/dev/null || echo '{}')
  else
    response=$(curl -sf \
      -H "Authorization: Bearer $auth_token" \
      --connect-timeout 5 --max-time 10 \
      "$participants_url" 2>/dev/null || echo '{}')
  fi

  echo "$response"
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
  start-bridge)    do_start_bridge ;;
  stop-bridge)     do_stop_bridge ;;
  restart-daemon)  restart_launchd "com.openclaw.context-bridge" ;;
  restart-watcher) restart_launchd "com.openclaw.context-bridge-fswatch" ;;
  purge-local)     do_purge_local ;;
  queue-handoff)   do_queue_handoff "$@" ;;
  list-handoffs)   do_list_handoffs ;;
  dashboard)            do_fetch_dashboard "$@" ;;
  projects)             do_fetch_projects ;;
  mark-question-seen)   do_mark_question_seen "$@" ;;
  privacy-rules)        do_privacy_rules "$@" ;;
  meeting-status)       do_meeting_status ;;
  meeting-start)        do_meeting_start "$@" ;;
  meeting-stop)         do_meeting_stop ;;
  meetings)             do_fetch_meetings "$@" ;;
  participants)         do_fetch_participants ;;
  *)
    echo '{"error":"unknown command","usage":"status|pause|resume|sensitive|start-bridge|stop-bridge|restart-daemon|restart-watcher|purge-local|queue-handoff|list-handoffs|dashboard|projects|meetings|participants|mark-question-seen|privacy-rules|meeting-status|meeting-start|meeting-stop"}' >&2
    exit 1
    ;;
esac
