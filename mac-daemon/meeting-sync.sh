#!/bin/bash
# Push completed meeting session data to the server.
# Called by the daemon after a meeting ends.
#
# Usage: meeting-sync.sh <session-dir>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/context-common.sh"

SESSION_DIR="${1:-}"
if [ -z "$SESSION_DIR" ] || [ ! -d "$SESSION_DIR" ]; then
  echo "Usage: meeting-sync.sh <session-dir>" >&2
  exit 1
fi

SYNC_STATE_FILE="$SESSION_DIR/.sync-state.json"
SYNC_MARKER_FILE="$SESSION_DIR/.synced"

read_sync_state() {
  local key="$1"
  python3 - "$SYNC_STATE_FILE" "$key" <<'PY'
import json
import os
import sys

path, key = sys.argv[1], sys.argv[2]
if not os.path.exists(path):
    print("")
    raise SystemExit(0)
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    print("")
    raise SystemExit(0)
value = data.get(key, "")
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(value)
PY
}

write_sync_state() {
  local session_uploaded="$1"
  local frames_uploaded="$2"
  local fully_synced="$3"
  python3 - "$SYNC_STATE_FILE" "$session_uploaded" "$frames_uploaded" "$fully_synced" <<'PY'
import json
import sys
from datetime import datetime, timezone

path = sys.argv[1]
data = {
    "session_uploaded": sys.argv[2] == "true",
    "frames_uploaded": sys.argv[3] == "true",
    "fully_synced": sys.argv[4] == "true",
    "updated_at": datetime.now(timezone.utc).isoformat(),
}
with open(path, "w") as f:
    json.dump(data, f, indent=2, sort_keys=True)
PY
}

mark_fully_synced() {
  write_sync_state "true" "true" "true"
  touch "$SYNC_MARKER_FILE"
}

if [ -f "$SYNC_MARKER_FILE" ] && [ "$(read_sync_state fully_synced)" = "true" ]; then
  exit 0
fi

CB_DIR="$HOME/.context-bridge"
SERVER_URL_FILE="$CB_DIR/server-url"
SERVER_URL=""
if [ -f "$SERVER_URL_FILE" ]; then
  SERVER_URL=$(cat "$SERVER_URL_FILE" 2>/dev/null || echo "")
fi
if [ -z "$SERVER_URL" ]; then
  echo "ERROR: No server URL configured" >&2
  exit 1
fi
BASE_URL=$(echo "$SERVER_URL" | sed 's|/context/push||')

AUTH_TOKEN=$(cb_read_keychain_token "$(cb_keychain_service_daemon)")
if [ -z "$AUTH_TOKEN" ]; then
  AUTH_TOKEN="${CONTEXT_BRIDGE_DAEMON_WRITE_TOKEN:-}"
fi
if [ -z "$AUTH_TOKEN" ]; then
  echo "ERROR: No auth token" >&2
  exit 1
fi

curl_tls_args() {
  if [ -f "$CB_DIR/server-ca.pem" ] && [[ "$BASE_URL" == https://* ]]; then
    echo "--cacert"
    echo "$CB_DIR/server-ca.pem"
  fi
}

TLS_ARGS=()
while IFS= read -r arg; do
  TLS_ARGS+=("$arg")
done < <(curl_tls_args)

MEETING_ID=$(basename "$SESSION_DIR")
STATE_FILE="$SESSION_DIR/session-state.json"

STATE_JSON=$(python3 - "$STATE_FILE" <<'PY'
import json
import os
import sys
path = sys.argv[1]
if not os.path.exists(path):
    print("{}")
    raise SystemExit(0)
with open(path) as f:
    print(json.dumps(json.load(f)))
PY
)

state_value() {
  local key="$1"
  python3 - "$STATE_JSON" "$key" <<'PY'
import json
import sys
data = json.loads(sys.argv[1])
value = data.get(sys.argv[2], "")
if isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, list):
    print(json.dumps(value))
elif value is None:
    print("")
else:
    print(value)
PY
}

STARTED_AT="$(state_value started_at)"
ENDED_AT="$(state_value ended_at)"
DURATION_SECONDS="$(state_value elapsed_seconds)"
CALL_APP="$(state_value call_app)"
PARTICIPANTS_JSON="$(state_value participants)"
ALLOW_EXTERNAL_PROCESSING="$(state_value allow_external_processing)"
SENSITIVE_DURING_SESSION="$(state_value sensitive_during_session)"
FRAMES_EXPECTED="$(state_value screenshots_taken)"

STARTED_AT="${STARTED_AT:-}"
ENDED_AT="${ENDED_AT:-}"
DURATION_SECONDS="${DURATION_SECONDS:-0}"
CALL_APP="${CALL_APP:-}"
PARTICIPANTS_JSON="${PARTICIPANTS_JSON:-[]}"
ALLOW_EXTERNAL_PROCESSING="${ALLOW_EXTERNAL_PROCESSING:-false}"
SENSITIVE_DURING_SESSION="${SENSITIVE_DURING_SESSION:-false}"
FRAMES_EXPECTED="${FRAMES_EXPECTED:-0}"

if [ -z "$STARTED_AT" ]; then
  STARTED_AT=$(python3 -c "
import os, datetime
st = os.stat('$SESSION_DIR')
print(datetime.datetime.fromtimestamp(st.st_birthtime, datetime.timezone.utc).isoformat())
" 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
fi
if [ -z "$ENDED_AT" ]; then
  ENDED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fi

TRANSCRIPT_JSON="null"
VISUAL_EVENTS_JSON="null"
BUFFER_FILE="$SESSION_DIR/buffer.jsonl"
FINAL_TRANSCRIPT="$SESSION_DIR/transcript.json"

if [ "$SENSITIVE_DURING_SESSION" != "true" ] && [ -f "$BUFFER_FILE" ]; then
  TRANSCRIPT_JSON=$(python3 -c "
import json
segments = []
for line in open('$BUFFER_FILE'):
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    if obj.get('type') == 'transcript':
        obj.pop('type', None)
        segments.append(obj)
print(json.dumps(segments) if segments else 'null')
" 2>/dev/null || echo "null")

  VISUAL_EVENTS_JSON=$(python3 -c "
import json
events = []
for line in open('$BUFFER_FILE'):
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    if obj.get('type') == 'visual':
        obj.pop('type', None)
        events.append(obj)
print(json.dumps(events) if events else 'null')
" 2>/dev/null || echo "null")
fi

if [ "$SENSITIVE_DURING_SESSION" != "true" ] && [ -f "$FINAL_TRANSCRIPT" ]; then
  TRANSCRIPT_JSON=$(cat "$FINAL_TRANSCRIPT")
fi

SESSION_UPLOADED="$(read_sync_state session_uploaded)"
FRAMES_UPLOADED="$(read_sync_state frames_uploaded)"
FULLY_SYNCED="$(read_sync_state fully_synced)"

SESSION_UPLOADED="${SESSION_UPLOADED:-false}"
FRAMES_UPLOADED="${FRAMES_UPLOADED:-false}"
FULLY_SYNCED="${FULLY_SYNCED:-false}"

if [ "$FULLY_SYNCED" = "true" ]; then
  touch "$SYNC_MARKER_FILE"
  exit 0
fi

if [ "$SESSION_UPLOADED" != "true" ]; then
  SESSION_PAYLOAD=$(python3 - "$MEETING_ID" "$STARTED_AT" "$ENDED_AT" "$DURATION_SECONDS" "$CALL_APP" "$ALLOW_EXTERNAL_PROCESSING" "$PARTICIPANTS_JSON" "$TRANSCRIPT_JSON" "$VISUAL_EVENTS_JSON" "$SENSITIVE_DURING_SESSION" "$FRAMES_EXPECTED" <<'PY'
import json
import sys

def parse_json(value, fallback):
    try:
        return json.loads(value)
    except Exception:
        return fallback

payload = {
    "meeting_id": sys.argv[1],
    "started_at": sys.argv[2],
    "ended_at": sys.argv[3],
    "duration_seconds": int(sys.argv[4] or 0),
    "app": sys.argv[5],
    "allow_external_processing": sys.argv[6] == "true",
    "participants": parse_json(sys.argv[7], []),
    "transcript_json": None if sys.argv[10] == "true" else parse_json(sys.argv[8], None),
    "visual_events_json": None if sys.argv[10] == "true" else parse_json(sys.argv[9], None),
    "sensitive_during_session": sys.argv[10] == "true",
    "frames_expected": int(sys.argv[11] or 0),
}
print(json.dumps(payload))
PY
)

  HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X POST "$BASE_URL/context/meeting/session" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$SESSION_PAYLOAD" \
    --connect-timeout 10 \
    --max-time 30 \
    "${TLS_ARGS[@]}" \
    2>/dev/null || echo "000")

  if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "201" ]; then
    echo "ERROR: Session push failed (HTTP $HTTP_CODE)" >&2
    exit 1
  fi

  SESSION_UPLOADED="true"
  if [ "$SENSITIVE_DURING_SESSION" = "true" ] || [ "$FRAMES_EXPECTED" -eq 0 ]; then
    FRAMES_UPLOADED="true"
  fi
  write_sync_state "$SESSION_UPLOADED" "$FRAMES_UPLOADED" "false"
fi

if [ "$FRAMES_UPLOADED" != "true" ] && [ "$SENSITIVE_DURING_SESSION" != "true" ] && [ "$FRAMES_EXPECTED" -gt 0 ]; then
  FRAMES_DIR="$SESSION_DIR/frames"
  if [ ! -d "$FRAMES_DIR" ]; then
    echo "ERROR: Frames expected but frames directory is missing" >&2
    exit 1
  fi

  mapfile -t FRAME_FILES < <(find "$FRAMES_DIR" -name "*.png" -type f 2>/dev/null | sort | head -50)
  if [ "${#FRAME_FILES[@]}" -eq 0 ]; then
    echo "ERROR: Frames expected but no frame files were found" >&2
    exit 1
  fi

  BATCH=()
  for frame in "${FRAME_FILES[@]}"; do
    BATCH+=("-F" "frames=@$frame")
    if [ ${#BATCH[@]} -ge 20 ]; then
      curl -sf -o /dev/null \
        -X POST "$BASE_URL/context/meeting/frames" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -F "meeting_id=$MEETING_ID" \
        "${BATCH[@]}" \
        "${TLS_ARGS[@]}" \
        --connect-timeout 10 \
        --max-time 60 \
        2>/dev/null || {
          echo "ERROR: frame batch upload failed" >&2
          write_sync_state "$SESSION_UPLOADED" "false" "false"
          exit 1
        }
      BATCH=()
    fi
  done

  if [ ${#BATCH[@]} -gt 0 ]; then
    curl -sf -o /dev/null \
      -X POST "$BASE_URL/context/meeting/frames" \
      -H "Authorization: Bearer $AUTH_TOKEN" \
      -F "meeting_id=$MEETING_ID" \
      "${BATCH[@]}" \
      "${TLS_ARGS[@]}" \
      --connect-timeout 10 \
      --max-time 60 \
      2>/dev/null || {
        echo "ERROR: frame batch upload failed" >&2
        write_sync_state "$SESSION_UPLOADED" "false" "false"
        exit 1
      }
  fi

  FRAMES_UPLOADED="true"
  write_sync_state "$SESSION_UPLOADED" "$FRAMES_UPLOADED" "false"
fi

mark_fully_synced
echo "Meeting $MEETING_ID synced successfully"
