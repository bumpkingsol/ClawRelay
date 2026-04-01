#!/bin/bash
# Push completed meeting session data to the server.
# Called by the daemon after a meeting ends.
#
# Usage: meeting-sync.sh <session-dir>
# Example: meeting-sync.sh ~/.context-bridge/meeting-session/2026-03-31-140000

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/context-common.sh"

SESSION_DIR="${1:-}"
if [ -z "$SESSION_DIR" ] || [ ! -d "$SESSION_DIR" ]; then
  echo "Usage: meeting-sync.sh <session-dir>" >&2
  exit 1
fi

# Already synced?
if [ -f "$SESSION_DIR/.synced" ]; then
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

# Derive base URL from push URL
BASE_URL=$(echo "$SERVER_URL" | sed 's|/context/push||')

# Auth token from Keychain
AUTH_TOKEN=$(cb_read_keychain_token "$(cb_keychain_service_daemon)")
if [ -z "$AUTH_TOKEN" ]; then
  AUTH_TOKEN="${CONTEXT_BRIDGE_DAEMON_WRITE_TOKEN:-}"
fi
if [ -z "$AUTH_TOKEN" ]; then
  echo "ERROR: No auth token" >&2
  exit 1
fi

# TLS args
curl_tls_args() {
  if [ -f "$CB_DIR/server-ca.pem" ] && [[ "$BASE_URL" == https://* ]]; then
    echo "--cacert"
    echo "$CB_DIR/server-ca.pem"
  fi
}

MEETING_ID=$(basename "$SESSION_DIR")

# Read session metadata from state file
STATE_FILE="$SESSION_DIR/session-state.json"
STARTED_AT=""
ENDED_AT=""
DURATION_SECONDS=0
CALL_APP=""
ALLOW_EXTERNAL_PROCESSING="false"

if [ -f "$STATE_FILE" ]; then
  STARTED_AT=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('started_at',''))" 2>/dev/null || echo "")
  ENDED_AT=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('ended_at',''))" 2>/dev/null || echo "")
  DURATION_SECONDS=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('elapsed_seconds',0))" 2>/dev/null || echo "0")
  CALL_APP=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('call_app',''))" 2>/dev/null || echo "")
  ALLOW_EXTERNAL_PROCESSING=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print('true' if d.get('allow_external_processing') else 'false')" 2>/dev/null || echo "false")
fi

# Fallback: derive timestamps from directory creation/modification
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

# Read transcript and visual events from buffer.jsonl
TRANSCRIPT_JSON="null"
VISUAL_EVENTS_JSON="null"
BUFFER_FILE="$SESSION_DIR/buffer.jsonl"

if [ -f "$BUFFER_FILE" ]; then
  TRANSCRIPT_JSON=$(python3 -c "
import json, sys
segments = []
for line in open('$BUFFER_FILE'):
    line = line.strip()
    if not line: continue
    try:
        obj = json.loads(line)
        if obj.get('type') == 'transcript':
            del obj['type']
            segments.append(obj)
    except: pass
print(json.dumps(segments) if segments else 'null')
" 2>/dev/null || echo "null")

  VISUAL_EVENTS_JSON=$(python3 -c "
import json, sys
events = []
for line in open('$BUFFER_FILE'):
    line = line.strip()
    if not line: continue
    try:
        obj = json.loads(line)
        if obj.get('type') == 'visual':
            del obj['type']
            events.append(obj)
    except: pass
print(json.dumps(events) if events else 'null')
" 2>/dev/null || echo "null")
fi

# Also check for final transcript.json (from batch transcription)
FINAL_TRANSCRIPT="$SESSION_DIR/transcript.json"
if [ -f "$FINAL_TRANSCRIPT" ]; then
  TRANSCRIPT_JSON=$(cat "$FINAL_TRANSCRIPT")
fi

# Build session payload
SESSION_PAYLOAD=$(python3 -c "
import json
data = {
    'meeting_id': '$MEETING_ID',
    'started_at': '$STARTED_AT',
    'ended_at': '$ENDED_AT',
    'duration_seconds': $DURATION_SECONDS,
    'app': '$CALL_APP',
    'allow_external_processing': $ALLOW_EXTERNAL_PROCESSING,
    'participants': '',
    'transcript_json': $TRANSCRIPT_JSON,
    'visual_events_json': $VISUAL_EVENTS_JSON,
}
print(json.dumps(data))
" 2>/dev/null)

if [ -z "$SESSION_PAYLOAD" ]; then
  echo "ERROR: Failed to build session payload" >&2
  exit 1
fi

# Push session to server
TLS_ARGS=()
while IFS= read -r arg; do
  TLS_ARGS+=("$arg")
done < <(curl_tls_args)

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

echo "Session $MEETING_ID pushed (HTTP $HTTP_CODE)"

# Push frames (up to 10 at a time)
FRAMES_DIR="$SESSION_DIR/frames"
if [ -d "$FRAMES_DIR" ]; then
  FRAME_FILES=($(find "$FRAMES_DIR" -name "*.png" -type f 2>/dev/null | sort | head -50))

  # Upload in batches of 10
  BATCH=()
  for frame in "${FRAME_FILES[@]}"; do
    BATCH+=("-F" "frames=@$frame")
    if [ ${#BATCH[@]} -ge 20 ]; then  # 20 args = 10 files (each is -F + path)
      curl -sf -o /dev/null \
        -X POST "$BASE_URL/context/meeting/frames" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -F "meeting_id=$MEETING_ID" \
        "${BATCH[@]}" \
        "${TLS_ARGS[@]}" \
        --connect-timeout 10 \
        --max-time 60 \
        2>/dev/null || echo "Warning: frame batch upload failed" >&2
      BATCH=()
    fi
  done

  # Upload remaining batch
  if [ ${#BATCH[@]} -gt 0 ]; then
    curl -sf -o /dev/null \
      -X POST "$BASE_URL/context/meeting/frames" \
      -H "Authorization: Bearer $AUTH_TOKEN" \
      -F "meeting_id=$MEETING_ID" \
      "${BATCH[@]}" \
      "${TLS_ARGS[@]}" \
      --connect-timeout 10 \
      --max-time 60 \
      2>/dev/null || echo "Warning: frame batch upload failed" >&2
  fi

  echo "Uploaded ${#FRAME_FILES[@]} frames for $MEETING_ID"
fi

# Mark as synced
touch "$SESSION_DIR/.synced"
echo "Meeting $MEETING_ID synced successfully"
