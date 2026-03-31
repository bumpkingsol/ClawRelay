# Meetings Tab & Live Sidebar — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Meetings tab to the Control Center, a live meeting sidebar panel anchored to Zoom/Meet, and a consent gate before auto-detected recordings — completing the meeting intelligence UI.

**Architecture:** Three server endpoints serve meeting history and participant data. The helperctl shell script gains two new commands (`meetings`, `participants`) to fetch this data. The Swift app adds a `.awaitingConsent` lifecycle state, a new NSPanel sidebar for live meetings, and a 7th Control Center tab with adaptive live/idle views.

**Tech Stack:** Python 3 / Flask / SQLite (server), Bash (daemon), Swift / SwiftUI / AppKit (macOS app)

**Spec:** `docs/superpowers/specs/2026-03-31-meetings-tab-and-sidebar-design.md`

---

## Phase 1: Server Endpoints

### Task 1: Add `last_seen` column to `participant_profiles`

**Files:**
- Modify: `server/context-receiver.py:119-131` (init_db, participant_profiles table)
- Modify: `server/meeting_processor.py:368-409` (update_participant_profiles)

- [ ] **Step 1: Add migration in init_db**

In `server/context-receiver.py`, after the existing `participant_profiles` CREATE TABLE, add an ALTER TABLE to add the `last_seen` column (same pattern as the existing `whatsapp_messages` migration at line ~155):

```python
try:
    db.execute("ALTER TABLE participant_profiles ADD COLUMN last_seen TEXT")
except Exception:
    pass  # Column already exists
```

- [ ] **Step 2: Update meeting_processor to write `last_seen`**

In `server/meeting_processor.py`, inside `update_participant_profiles()`, update the UPDATE and INSERT statements to include `last_seen`. The function receives `meeting_id` — load the meeting's `ended_at` first, then use it:

In the UPDATE branch (existing profile found):
```python
db.execute("""
    UPDATE participant_profiles
    SET meetings_observed = meetings_observed + 1,
        last_updated = ?,
        last_seen = ?
    WHERE id = ?
""", (datetime.now(timezone.utc).isoformat(), ended_at, row['id']))
```

In the INSERT branch (new profile):
```python
db.execute("""
    INSERT OR IGNORE INTO participant_profiles
    (id, display_name, meetings_observed, profile_json, last_updated, last_seen)
    VALUES (?, ?, 1, '{}', ?, ?)
""", (profile_id, name, datetime.now(timezone.utc).isoformat(), ended_at))
```

To get `ended_at`, add at the top of the function:
```python
meeting_row = db.execute(
    "SELECT ended_at FROM meeting_sessions WHERE id = ?", (meeting_id,)
).fetchone()
ended_at = meeting_row['ended_at'] if meeting_row else datetime.now(timezone.utc).isoformat()
```

- [ ] **Step 3: Run existing tests to verify no breakage**

Run: `cd server && python3 -m pytest tests/ -v`
Expected: All existing tests pass.

- [ ] **Step 4: Commit**

```bash
git add server/context-receiver.py server/meeting_processor.py
git commit -m "feat(server): add last_seen column to participant_profiles"
```

---

### Task 2: Add `GET /context/meetings` endpoint

**Files:**
- Modify: `server/context-receiver.py` (add endpoint after `get_projects` at line ~594)
- Create: `server/tests/test_meetings_list_endpoint.py`

- [ ] **Step 1: Write the failing tests**

Create `server/tests/test_meetings_list_endpoint.py`:

```python
"""Tests for GET /context/meetings endpoint."""
import json
from datetime import datetime, timedelta, timezone


class TestGetMeetings:
    def test_returns_empty_list_when_no_meetings(self, client, auth_headers):
        resp = client.get("/context/meetings", headers=auth_headers)
        assert resp.status_code == 200
        data = resp.get_json()
        assert data["meetings"] == []

    def test_returns_meetings_sorted_by_started_at_desc(self, client, auth_headers):
        # Insert two meetings directly
        from db_utils import get_db
        db = get_db()
        db.execute(
            "INSERT INTO meeting_sessions (id, started_at, ended_at, duration_seconds, app, participants, transcript_json, summary_md) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            ("m1", "2026-03-30T09:00:00Z", "2026-03-30T09:30:00Z", 1800, "Zoom", '["Alice"]', '[]', "Summary 1"),
        )
        db.execute(
            "INSERT INTO meeting_sessions (id, started_at, ended_at, duration_seconds, app, participants, transcript_json, summary_md) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            ("m2", "2026-03-31T10:00:00Z", "2026-03-31T10:45:00Z", 2700, "Google Meet", '["Bob"]', None, "Summary 2"),
        )
        db.commit()
        db.close()

        resp = client.get("/context/meetings", headers=auth_headers)
        assert resp.status_code == 200
        meetings = resp.get_json()["meetings"]
        assert len(meetings) == 2
        assert meetings[0]["id"] == "m2"  # newer first
        assert meetings[1]["id"] == "m1"

    def test_has_transcript_derived_field(self, client, auth_headers):
        from db_utils import get_db
        db = get_db()
        db.execute(
            "INSERT INTO meeting_sessions (id, started_at, ended_at, duration_seconds, app, participants, transcript_json, summary_md) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            ("m1", "2026-03-31T09:00:00Z", "2026-03-31T09:30:00Z", 1800, "Zoom", '["Alice"]', '[{"text":"hi"}]', "Sum"),
        )
        db.execute(
            "INSERT INTO meeting_sessions (id, started_at, ended_at, duration_seconds, app, participants, summary_md) VALUES (?, ?, ?, ?, ?, ?, ?)",
            ("m2", "2026-03-31T10:00:00Z", "2026-03-31T10:30:00Z", 1800, "Zoom", '["Bob"]', "Sum2"),
        )
        db.commit()
        db.close()

        resp = client.get("/context/meetings", headers=auth_headers)
        meetings = resp.get_json()["meetings"]
        m1 = next(m for m in meetings if m["id"] == "m1")
        m2 = next(m for m in meetings if m["id"] == "m2")
        assert m1["has_transcript"] is True
        assert m1["purge_status"] == "live"
        assert m2["has_transcript"] is False
        assert m2["purge_status"] == "summary_only"

    def test_days_filter(self, client, auth_headers):
        from db_utils import get_db
        db = get_db()
        db.execute(
            "INSERT INTO meeting_sessions (id, started_at, ended_at, duration_seconds, app, participants, summary_md) VALUES (?, ?, ?, ?, ?, ?, ?)",
            ("old", "2026-01-01T09:00:00Z", "2026-01-01T09:30:00Z", 1800, "Zoom", '[]', "Old"),
        )
        db.execute(
            "INSERT INTO meeting_sessions (id, started_at, ended_at, duration_seconds, app, participants, summary_md) VALUES (?, ?, ?, ?, ?, ?, ?)",
            ("recent", "2026-03-31T09:00:00Z", "2026-03-31T09:30:00Z", 1800, "Zoom", '[]', "Recent"),
        )
        db.commit()
        db.close()

        resp = client.get("/context/meetings?days=7", headers=auth_headers)
        meetings = resp.get_json()["meetings"]
        ids = [m["id"] for m in meetings]
        assert "recent" in ids
        # "old" may or may not be in results depending on current date vs test date

    def test_unauthorized(self, client):
        resp = client.get("/context/meetings")
        assert resp.status_code == 401

    def test_participants_parsed_from_json(self, client, auth_headers):
        from db_utils import get_db
        db = get_db()
        db.execute(
            "INSERT INTO meeting_sessions (id, started_at, ended_at, duration_seconds, app, participants, summary_md) VALUES (?, ?, ?, ?, ?, ?, ?)",
            ("m1", "2026-03-31T09:00:00Z", "2026-03-31T09:30:00Z", 1800, "Zoom", '["Alice", "Bob"]', "Sum"),
        )
        db.commit()
        db.close()

        resp = client.get("/context/meetings", headers=auth_headers)
        m = resp.get_json()["meetings"][0]
        assert m["participants"] == ["Alice", "Bob"]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && python3 -m pytest tests/test_meetings_list_endpoint.py -v`
Expected: FAIL — endpoint does not exist yet (404).

- [ ] **Step 3: Implement the endpoint**

In `server/context-receiver.py`, add after the `get_projects` endpoint (line ~594):

```python
@app.route("/context/meetings", methods=["GET"])
def get_meetings():
    if not verify_auth(request):
        return jsonify({'error': 'unauthorized'}), 401

    days = min(int(request.args.get('days', 7)), 30)
    cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()

    try:
        db = get_db()
        rows = db.execute("""
            SELECT id, started_at, ended_at, duration_seconds, app,
                   participants, summary_md, transcript_json
            FROM meeting_sessions
            WHERE started_at >= ?
            ORDER BY started_at DESC
        """, (cutoff,)).fetchall()
        db.close()

        meetings = []
        for r in rows:
            participants = []
            try:
                participants = json.loads(r['participants']) if r['participants'] else []
            except (json.JSONDecodeError, TypeError):
                pass

            meetings.append({
                'id': r['id'],
                'started_at': r['started_at'],
                'ended_at': r['ended_at'],
                'duration_seconds': r['duration_seconds'],
                'app': r['app'],
                'participants': participants,
                'summary_md': r['summary_md'],
                'has_transcript': r['transcript_json'] is not None,
                'purge_status': 'live' if r['transcript_json'] is not None else 'summary_only',
            })

        return jsonify({'meetings': meetings})
    except Exception:
        logger.exception("Failed to get meetings")
        return jsonify({'error': 'Internal error'}), 500
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && python3 -m pytest tests/test_meetings_list_endpoint.py -v`
Expected: All PASS.

- [ ] **Step 5: Run full test suite**

Run: `cd server && python3 -m pytest tests/ -v`
Expected: All pass.

- [ ] **Step 6: Commit**

```bash
git add server/context-receiver.py server/tests/test_meetings_list_endpoint.py
git commit -m "feat(server): add GET /context/meetings endpoint"
```

---

### Task 3: Add `GET /context/participants` endpoint

**Files:**
- Modify: `server/context-receiver.py` (add endpoint after meetings)
- Create: `server/tests/test_participants_endpoint.py`

- [ ] **Step 1: Write the failing tests**

Create `server/tests/test_participants_endpoint.py`:

```python
"""Tests for GET /context/participants endpoint."""
import json


class TestGetParticipants:
    def test_returns_empty_list_when_no_profiles(self, client, auth_headers):
        resp = client.get("/context/participants", headers=auth_headers)
        assert resp.status_code == 200
        assert resp.get_json()["participants"] == []

    def test_returns_profiles_sorted_by_meetings_observed(self, client, auth_headers):
        from db_utils import get_db
        db = get_db()
        db.execute(
            "INSERT INTO participant_profiles (id, display_name, meetings_observed, profile_json, last_updated, last_seen) VALUES (?, ?, ?, ?, ?, ?)",
            ("p1", "Alice", 3, '{"decision_style": "data-first"}', "2026-03-31T09:00:00Z", "2026-03-31T09:00:00Z"),
        )
        db.execute(
            "INSERT INTO participant_profiles (id, display_name, meetings_observed, profile_json, last_updated, last_seen) VALUES (?, ?, ?, ?, ?, ?)",
            ("p2", "Bob", 8, '{"decision_style": "consensus"}', "2026-03-31T10:00:00Z", "2026-03-31T10:00:00Z"),
        )
        db.commit()
        db.close()

        resp = client.get("/context/participants", headers=auth_headers)
        participants = resp.get_json()["participants"]
        assert len(participants) == 2
        assert participants[0]["display_name"] == "Bob"  # 8 meetings, first
        assert participants[1]["display_name"] == "Alice"  # 3 meetings

    def test_profile_json_parsed(self, client, auth_headers):
        from db_utils import get_db
        db = get_db()
        profile = json.dumps({"decision_style": "data-first", "stress_triggers": "vague timelines"})
        db.execute(
            "INSERT INTO participant_profiles (id, display_name, meetings_observed, profile_json, last_updated, last_seen) VALUES (?, ?, ?, ?, ?, ?)",
            ("p1", "Alice", 5, profile, "2026-03-31T09:00:00Z", "2026-03-31T09:00:00Z"),
        )
        db.commit()
        db.close()

        resp = client.get("/context/participants", headers=auth_headers)
        p = resp.get_json()["participants"][0]
        assert p["profile"]["decision_style"] == "data-first"
        assert p["last_seen"] == "2026-03-31T09:00:00Z"

    def test_unauthorized(self, client):
        resp = client.get("/context/participants")
        assert resp.status_code == 401
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && python3 -m pytest tests/test_participants_endpoint.py -v`
Expected: FAIL (404).

- [ ] **Step 3: Implement the endpoint**

In `server/context-receiver.py`, add after the meetings endpoint:

```python
@app.route("/context/participants", methods=["GET"])
def get_participants():
    if not verify_auth(request):
        return jsonify({'error': 'unauthorized'}), 401

    try:
        db = get_db()
        rows = db.execute("""
            SELECT id, display_name, meetings_observed, profile_json, last_seen
            FROM participant_profiles
            ORDER BY meetings_observed DESC
        """).fetchall()
        db.close()

        participants = []
        for r in rows:
            profile = {}
            try:
                profile = json.loads(r['profile_json']) if r['profile_json'] else {}
            except (json.JSONDecodeError, TypeError):
                pass

            participants.append({
                'id': r['id'],
                'display_name': r['display_name'],
                'meetings_observed': r['meetings_observed'],
                'last_seen': r.get('last_seen'),
                'profile': profile,
            })

        return jsonify({'participants': participants})
    except Exception:
        logger.exception("Failed to get participants")
        return jsonify({'error': 'Internal error'}), 500
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && python3 -m pytest tests/test_participants_endpoint.py -v`
Expected: All PASS.

- [ ] **Step 5: Commit**

```bash
git add server/context-receiver.py server/tests/test_participants_endpoint.py
git commit -m "feat(server): add GET /context/participants endpoint"
```

---

### Task 4: Add `GET /context/meetings/<id>/transcript` endpoint

**Files:**
- Modify: `server/context-receiver.py`
- Create: `server/tests/test_meeting_transcript_endpoint.py`

- [ ] **Step 1: Write the failing tests**

Create `server/tests/test_meeting_transcript_endpoint.py`:

```python
"""Tests for GET /context/meetings/<id>/transcript endpoint."""
import json


class TestGetMeetingTranscript:
    def test_returns_transcript_and_events(self, client, auth_headers):
        from db_utils import get_db
        db = get_db()
        transcript = json.dumps([{"ts": "2026-03-31T09:01:00Z", "speaker": "Alice", "text": "Hello"}])
        visual = json.dumps([
            {"ts": "2026-03-31T09:02:00Z", "type": "slide_change", "description": "Title slide"},
            {"ts": "2026-03-31T09:03:00Z", "type": "expression", "expression_analysis": [
                {"expression": "concerned", "confidence": 0.85}
            ]},
        ])
        db.execute(
            "INSERT INTO meeting_sessions (id, started_at, ended_at, duration_seconds, app, participants, transcript_json, visual_events_json, summary_md) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            ("m1", "2026-03-31T09:00:00Z", "2026-03-31T09:30:00Z", 1800, "Zoom", '["Alice"]', transcript, visual, "Sum"),
        )
        db.commit()
        db.close()

        resp = client.get("/context/meetings/m1/transcript", headers=auth_headers)
        assert resp.status_code == 200
        data = resp.get_json()
        assert len(data["transcript"]) == 1
        assert data["transcript"][0]["speaker"] == "Alice"
        assert len(data["visual_events"]) == 2
        # expression_analysis flattened from visual_events entries
        assert len(data["expression_analysis"]) == 1
        assert data["expression_analysis"][0]["expression"] == "concerned"

    def test_returns_404_for_nonexistent_meeting(self, client, auth_headers):
        resp = client.get("/context/meetings/nonexistent/transcript", headers=auth_headers)
        assert resp.status_code == 404

    def test_returns_purged_error_when_transcript_null(self, client, auth_headers):
        from db_utils import get_db
        db = get_db()
        db.execute(
            "INSERT INTO meeting_sessions (id, started_at, ended_at, duration_seconds, app, participants, summary_md) VALUES (?, ?, ?, ?, ?, ?, ?)",
            ("m2", "2026-03-31T09:00:00Z", "2026-03-31T09:30:00Z", 1800, "Zoom", '[]', "Sum"),
        )
        db.commit()
        db.close()

        resp = client.get("/context/meetings/m2/transcript", headers=auth_headers)
        assert resp.status_code == 200
        assert resp.get_json()["error"] == "purged"

    def test_unauthorized(self, client):
        resp = client.get("/context/meetings/m1/transcript")
        assert resp.status_code == 401
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && python3 -m pytest tests/test_meeting_transcript_endpoint.py -v`
Expected: FAIL (404).

- [ ] **Step 3: Implement the endpoint**

In `server/context-receiver.py`, add after participants endpoint:

```python
@app.route("/context/meetings/<meeting_id>/transcript", methods=["GET"])
def get_meeting_transcript(meeting_id):
    if not verify_auth(request):
        return jsonify({'error': 'unauthorized'}), 401

    try:
        db = get_db()
        row = db.execute(
            "SELECT transcript_json, visual_events_json FROM meeting_sessions WHERE id = ?",
            (meeting_id,)
        ).fetchone()
        db.close()

        if not row:
            return jsonify({'error': 'not found'}), 404

        if row['transcript_json'] is None:
            return jsonify({'error': 'purged'})

        transcript = []
        try:
            transcript = json.loads(row['transcript_json']) if row['transcript_json'] else []
        except (json.JSONDecodeError, TypeError):
            pass

        visual_events = []
        expression_analysis = []
        try:
            raw_visual = json.loads(row['visual_events_json']) if row['visual_events_json'] else []
            for event in raw_visual:
                visual_events.append(event)
                # Flatten expression_analysis from visual event entries
                if 'expression_analysis' in event:
                    for expr in event['expression_analysis']:
                        expr_entry = {'ts': event.get('ts', '')}
                        expr_entry.update(expr)
                        expression_analysis.append(expr_entry)
        except (json.JSONDecodeError, TypeError):
            pass

        return jsonify({
            'transcript': transcript,
            'visual_events': visual_events,
            'expression_analysis': expression_analysis,
        })
    except Exception:
        logger.exception("Failed to get meeting transcript")
        return jsonify({'error': 'Internal error'}), 500
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && python3 -m pytest tests/test_meeting_transcript_endpoint.py -v`
Expected: All PASS.

- [ ] **Step 5: Run full test suite**

Run: `cd server && python3 -m pytest tests/ -v`
Expected: All pass — no regressions.

- [ ] **Step 6: Commit**

```bash
git add server/context-receiver.py server/tests/test_meeting_transcript_endpoint.py
git commit -m "feat(server): add GET /context/meetings/<id>/transcript endpoint"
```

---

## Phase 2: Daemon Helper Commands

### Task 5: Add `meetings` and `participants` helperctl commands

**Files:**
- Modify: `mac-daemon/context-helperctl.sh:469-541` (add commands, update dispatch + usage)

- [ ] **Step 1: Add `do_fetch_meetings` function**

In `mac-daemon/context-helperctl.sh`, add after `do_fetch_projects()` (line ~512). Follow the exact same curl pattern as `do_fetch_projects`:

```bash
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
  auth_token=$(security find-generic-password -s "context-bridge" -a "token" -w 2>/dev/null || echo "")
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
```

- [ ] **Step 2: Add `do_fetch_participants` function**

Same pattern, placed right after `do_fetch_meetings`:

```bash
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
  auth_token=$(security find-generic-password -s "context-bridge" -a "token" -w 2>/dev/null || echo "")
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
```

- [ ] **Step 3: Add to dispatch case statement**

In the main dispatch `case` block (line ~520), add two new entries before the `*` catch-all:

```bash
  meetings)              do_fetch_meetings "$@" ;;
  participants)          do_fetch_participants ;;
```

- [ ] **Step 4: Update the usage/error string**

In the `*` catch-all (line ~538), add `meetings|participants` to the usage string.

- [ ] **Step 5: Test manually**

Run: `cd mac-daemon && bash context-helperctl.sh meetings 7`
Expected: JSON response with `{"meetings": [...]}` (or `{}` if server unreachable).

Run: `cd mac-daemon && bash context-helperctl.sh participants`
Expected: JSON response with `{"participants": [...]}` (or `{}` if server unreachable).

- [ ] **Step 6: Commit**

```bash
git add mac-daemon/context-helperctl.sh
git commit -m "feat(mac-daemon): add meetings and participants helperctl commands"
```

---

## Phase 3: Consent Gate

### Task 6: Add `.awaitingConsent` to MeetingLifecycleState

**Files:**
- Modify: `mac-helper/OpenClawHelper/Models/MeetingState.swift:3-39`

- [ ] **Step 1: Add the new case**

In `MeetingState.swift`, add `case awaitingConsent` between `idle` and `preparing` (after line 4):

```swift
enum MeetingLifecycleState: String, Codable {
    case idle
    case awaitingConsent
    case preparing
    case recording
    case finalizing
```

- [ ] **Step 2: Add display properties for the new case**

Update the computed properties in the enum to handle `.awaitingConsent`:
- `displayLabel`: return `"Consent Pending"`
- `systemImage`: return `"questionmark.circle"`
- `tintColor`: return `.orange`
- `isActive`: return `false`

Follow the existing pattern of the switch statements in the file.

- [ ] **Step 3: Build to verify compilation**

Run: `cd mac-helper && xcodebuild build -project OpenClawHelper.xcodeproj -scheme OpenClawHelper -configuration Debug -quiet 2>&1 | grep -E '(error:|BUILD)'`
Expected: `BUILD SUCCEEDED` (will likely have warnings from unhandled switch cases — that's expected and will be fixed in next tasks).

- [ ] **Step 4: Commit**

```bash
git add mac-helper/OpenClawHelper/Models/MeetingState.swift
git commit -m "feat(model): add awaitingConsent case to MeetingLifecycleState"
```

---

### Task 7: Implement consent prompt in MeetingSessionManager

**Files:**
- Modify: `mac-helper/OpenClawHelper/Services/MeetingSessionManager.swift:31,55-80`

- [ ] **Step 1: Change startMeeting guard to transition to awaitingConsent**

In `MeetingSessionManager.swift`, modify the `startMeeting()` method (line ~31). Instead of `guard state == .idle else { return }` followed by calling `beginPreparing()`, change to:

```swift
func startMeeting(meetingId: String? = nil, app: String? = nil, manual: Bool = false) {
    guard state == .idle else { return }

    pendingMeetingId = meetingId
    pendingMeetingApp = app

    if manual {
        // Manual start bypasses consent
        state = .awaitingConsent
        beginPreparing(meetingId: pendingMeetingId, app: pendingMeetingApp)
    } else {
        // Auto-detect requires consent
        state = .awaitingConsent
        requestConsent()
    }
}
```

- [ ] **Step 2: Implement requestConsent()**

Add a new private method `requestConsent()`:

```swift
private var consentTask: Task<Void, Never>?
private var pendingMeetingId: String?
private var pendingMeetingApp: String?

private func requestConsent() {
    consentTask = Task { @MainActor in
        let accepted = await showConsentAlert()

        if accepted {
            beginPreparing(meetingId: pendingMeetingId, app: pendingMeetingApp)
        } else {
            state = .idle
            suppressDetectionUntilAppCloses()
        }
    }
}

private func showConsentAlert() async -> Bool {
    await withCheckedContinuation { continuation in
        let alert = NSAlert()
        alert.messageText = "Record this meeting?"
        alert.informativeText = "ClawRelay detected a meeting. Accept to start recording and receive live intelligence."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Accept")
        alert.addButton(withTitle: "Decline")

        // 15-second auto-decline timer
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 15)
        timer.setEventHandler {
            alert.window.orderOut(nil)
            NSApp.stopModal(withCode: .alertSecondButtonReturn)
        }
        timer.resume()

        let response = alert.runModal()
        timer.cancel()

        continuation.resume(returning: response == .alertFirstButtonReturn)
    }
}
```

- [ ] **Step 3: Implement suppressDetectionUntilAppCloses()**

Add a method that tells the detector to ignore meetings until the current meeting app closes:

```swift
private func suppressDetectionUntilAppCloses() {
    // Notify the detector to suppress until meeting app terminates
    // The detector already watches NSWorkspace — set a flag
    NotificationCenter.default.post(
        name: .meetingConsentDeclined,
        object: nil
    )
}
```

Add the notification name extension at the bottom of `MeetingSessionManager.swift`:

```swift
extension Notification.Name {
    static let meetingConsentDeclined = Notification.Name("meetingConsentDeclined")
}
```

- [ ] **Step 4: Update beginPreparing guard**

In `beginPreparing()` (line ~55), change any state guard to:

```swift
guard state == .awaitingConsent else { return }
state = .preparing
```

- [ ] **Step 5: Build to verify compilation**

Run: `cd mac-helper && xcodebuild build -project OpenClawHelper.xcodeproj -scheme OpenClawHelper -configuration Debug -quiet 2>&1 | grep -E '(error:|BUILD)'`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add mac-helper/OpenClawHelper/Services/MeetingSessionManager.swift
git commit -m "feat(meetings): add consent gate before auto-detected recording"
```

---

### Task 8: Handle consent suppression in MeetingDetectorService

**Files:**
- Modify: `mac-helper/OpenClawHelper/Services/MeetingDetectorService.swift:81,147-157`

- [ ] **Step 1: Add suppression flag and observer**

Add a `private var suppressedUntilAppCloses = false` property and observe the consent-declined notification:

```swift
private var suppressedUntilAppCloses = false

// In init or setup method:
NotificationCenter.default.addObserver(
    self,
    selector: #selector(handleConsentDeclined),
    name: .meetingConsentDeclined,
    object: nil
)

@objc private func handleConsentDeclined() {
    suppressedUntilAppCloses = true
}
```

- [ ] **Step 2: Guard detection with suppression flag**

In the `debounceMeetingCheck()` method (line ~147), add a guard at the top:

```swift
guard !suppressedUntilAppCloses else { return }
```

- [ ] **Step 3: Reset suppression when meeting app terminates**

In the existing app termination observation (or add one using `NSWorkspace.didTerminateApplicationNotification`):

```swift
// When Zoom/Meet app terminates:
suppressedUntilAppCloses = false
```

- [ ] **Step 4: Build to verify**

Run: `cd mac-helper && xcodebuild build -project OpenClawHelper.xcodeproj -scheme OpenClawHelper -configuration Debug -quiet 2>&1 | grep -E '(error:|BUILD)'`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add mac-helper/OpenClawHelper/Services/MeetingDetectorService.swift
git commit -m "feat(meetings): suppress detection after consent decline until app closes"
```

---

## Phase 4: Meetings Tab (Control Center)

### Task 9: Add `.meetings` tab to ControlCenterViewModel

**Files:**
- Modify: `mac-helper/OpenClawHelper/ViewModels/ControlCenterViewModel.swift:3-6`

- [ ] **Step 1: Add meetings case to tab enum**

In `ControlCenterViewModel.swift`, add `case meetings` after `dashboard` (2nd position) in the `ControlCenterTab` enum (line ~4):

```swift
enum ControlCenterTab: String, CaseIterable {
    case dashboard, meetings, overview, permissions, privacy, handoffs, diagnostics
}
```

- [ ] **Step 2: Build to verify**

Run: `cd mac-helper && xcodebuild build -project OpenClawHelper.xcodeproj -scheme OpenClawHelper -configuration Debug -quiet 2>&1 | grep -E '(error:|BUILD)'`
Expected: `BUILD SUCCEEDED` (or errors from ControlCenterView switch needing the new case — fix in next task).

- [ ] **Step 3: Commit**

```bash
git add mac-helper/OpenClawHelper/ViewModels/ControlCenterViewModel.swift
git commit -m "feat(ui): add meetings case to ControlCenterTab enum"
```

---

### Task 10: Add Swift models for meetings history data

**Files:**
- Create: `mac-helper/OpenClawHelper/Models/MeetingHistory.swift`

- [ ] **Step 1: Create the models file**

Create `mac-helper/OpenClawHelper/Models/MeetingHistory.swift`:

```swift
import Foundation

// MARK: - Server Response Models

struct MeetingsResponse: Codable {
    let meetings: [MeetingRecord]
}

struct MeetingRecord: Codable, Identifiable {
    let id: String
    let startedAt: String
    let endedAt: String?
    let durationSeconds: Int?
    let app: String?
    let participants: [String]
    let summaryMd: String?
    let hasTranscript: Bool
    let purgeStatus: String

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSeconds = "duration_seconds"
        case app, participants
        case summaryMd = "summary_md"
        case hasTranscript = "has_transcript"
        case purgeStatus = "purge_status"
    }

    var displayTitle: String {
        if let summary = summaryMd, !summary.isEmpty {
            let firstLine = summary.components(separatedBy: .newlines).first ?? summary
            let trimmed = firstLine.prefix(60)
            return String(trimmed)
        }
        // Fallback: format from ID — e.g., "2026-03-31-153000-zoom" → "Zoom, Mar 31"
        return app.map { "\($0) Meeting" } ?? id
    }

    var formattedDuration: String {
        guard let secs = durationSeconds else { return "" }
        let mins = secs / 60
        return "\(mins)min"
    }

    var formattedDate: String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: startedAt) else { return startedAt }
        let display = DateFormatter()
        display.dateFormat = "E HH:mm"
        return display.string(from: date)
    }
}

struct ParticipantsResponse: Codable {
    let participants: [ParticipantRecord]
}

struct ParticipantRecord: Codable, Identifiable {
    let id: String
    let displayName: String
    let meetingsObserved: Int
    let lastSeen: String?
    let profile: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case meetingsObserved = "meetings_observed"
        case lastSeen = "last_seen"
        case profile
    }

    var initials: String {
        let parts = displayName.split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(displayName.prefix(2)).uppercased()
    }

    var oneLiner: String {
        profile?["decision_style"].map { String($0.prefix(50)) } ?? ""
    }
}

struct TranscriptResponse: Codable {
    let transcript: [TranscriptSegment]?
    let visualEvents: [VisualEvent]?
    let expressionAnalysis: [ExpressionEntry]?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case transcript
        case visualEvents = "visual_events"
        case expressionAnalysis = "expression_analysis"
        case error
    }
}

struct TranscriptSegment: Codable, Identifiable {
    var id: String { "\(ts)-\(speaker)" }
    let ts: String
    let speaker: String
    let text: String
}

struct VisualEvent: Codable {
    let ts: String
    let type: String
    let description: String?
}

struct ExpressionEntry: Codable {
    let ts: String
    let expression: String
    let confidence: Double
}
```

- [ ] **Step 2: Add file to Xcode project and build**

Run: `cd mac-helper && xcodebuild build -project OpenClawHelper.xcodeproj -scheme OpenClawHelper -configuration Debug -quiet 2>&1 | grep -E '(error:|BUILD)'`

Note: If the file is not auto-discovered by Xcode, it may need to be added to the project file. Check if other model files in `Models/` are auto-included or manually listed.

- [ ] **Step 3: Commit**

```bash
git add mac-helper/OpenClawHelper/Models/MeetingHistory.swift
git commit -m "feat(model): add MeetingRecord, ParticipantRecord, TranscriptResponse models"
```

---

### Task 11: Extend MeetingViewModel with history and participant data

**Files:**
- Modify: `mac-helper/OpenClawHelper/ViewModels/MeetingViewModel.swift:6-7` (add published props)

- [ ] **Step 1: Add published properties for history data**

In `MeetingViewModel.swift`, add after the existing `@Published` properties (line ~7):

```swift
@Published var meetingHistory: [MeetingRecord] = []
@Published var participantProfiles: [ParticipantRecord] = []
@Published var selectedMeetingTranscript: TranscriptResponse?
@Published var meetingsSubTab: MeetingsSubTab = .meetings

enum MeetingsSubTab {
    case meetings, people
}
```

- [ ] **Step 1.5: Add BridgeCommandRunner to MeetingViewModel**

`MeetingViewModel` currently has no access to `BridgeCommandRunner`. Add it as a stored property, following the same pattern as `MenuBarViewModel` which receives `runner` via its initializer. In `MeetingViewModel.swift`:

```swift
private let runner: BridgeCommandRunner

// Update init to accept runner:
init(sessionManager: MeetingSessionManager, runner: BridgeCommandRunner) {
    self.runner = runner
    // ... existing init logic
}
```

Then in `AppModel.swift` (or wherever `MeetingViewModel` is created), pass the runner:

```swift
meetingViewModel = MeetingViewModel(sessionManager: meetingSessionManager, runner: runner)
```

- [ ] **Step 2: Add fetch methods**

Add methods to fetch from the server via helperctl:

```swift
func fetchMeetingHistory(days: Int = 7) {
    let capturedRunner = runner
    Task.detached {
        do {
            let raw = try capturedRunner.runActionWithOutput("meetings", "\(days)")
            let decoded = try JSONDecoder().decode(MeetingsResponse.self, from: raw)
            await MainActor.run { [weak self] in
                self?.meetingHistory = decoded.meetings
            }
        } catch {
            // Silently fail — keep current list
        }
    }
}

func fetchParticipants() {
    let capturedRunner = runner
    Task.detached {
        do {
            let raw = try capturedRunner.runActionWithOutput("participants")
            let decoded = try JSONDecoder().decode(ParticipantsResponse.self, from: raw)
            await MainActor.run { [weak self] in
                self?.participantProfiles = decoded.participants
            }
        } catch {
            // Silently fail
        }
    }
}

func fetchTranscript(meetingId: String) {
    // Deferred: needs a `meeting-transcript <id>` helperctl command.
    // Track as follow-up work after this plan.
    selectedMeetingTranscript = nil
}
```

- [ ] **Step 3: Build to verify**

Run: `cd mac-helper && xcodebuild build -project OpenClawHelper.xcodeproj -scheme OpenClawHelper -configuration Debug -quiet 2>&1 | grep -E '(error:|BUILD)'`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add mac-helper/OpenClawHelper/ViewModels/MeetingViewModel.swift
git commit -m "feat(viewmodel): extend MeetingViewModel with history and participant fetching"
```

---

### Task 12: Create MeetingsTabView

**Files:**
- Create: `mac-helper/OpenClawHelper/Views/Tabs/MeetingsTabView.swift`
- Modify: `mac-helper/OpenClawHelper/Views/ControlCenterView.swift:34-51` (add case to switch)

- [ ] **Step 1: Create the MeetingsTabView**

Create `mac-helper/OpenClawHelper/Views/Tabs/MeetingsTabView.swift`. This is the main tab view that switches between live mode and idle mode:

```swift
import SwiftUI

struct MeetingsTabView: View {
    @ObservedObject var meetingVM: MeetingViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if meetingVM.state == .recording || meetingVM.state == .preparing {
                    liveBanner
                }

                if meetingVM.state == .idle || meetingVM.state == .finalizing {
                    statsStrip
                    subTabPicker
                }

                switch meetingVM.meetingsSubTab {
                case .meetings:
                    meetingsListSection
                case .people:
                    peopleListSection
                }
            }
            .padding(16)
        }
        .onAppear {
            meetingVM.fetchMeetingHistory()
            meetingVM.fetchParticipants()
        }
    }

    // MARK: - Live Banner

    private var liveBanner: some View {
        VStack(spacing: 10) {
            HStack {
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                Text("Recording")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(meetingVM.formattedElapsed)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("Toggle Sidebar") {
                    meetingVM.toggleSidebar()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Stop") {
                    meetingVM.stopMeeting()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)

                Spacer()
            }

            HStack(spacing: 16) {
                Label("Cards: \(meetingVM.firedCardCount)", systemImage: "rectangle.stack")
                if meetingVM.briefing != nil {
                    Label("Briefing loaded", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
                Spacer()
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.red.opacity(0.08))
                .strokeBorder(Color.red.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Stats Strip

    private var statsStrip: some View {
        HStack(spacing: 12) {
            statCard(title: "This Week", value: "\(meetingVM.meetingHistory.count)", subtitle: "meetings")
            statCard(title: "Total Hours", value: totalHours, subtitle: avgDuration)
            statCard(title: "Top Participant", value: topParticipant, subtitle: "")
            statCard(title: "Pattern", value: topPattern, subtitle: "")
        }
    }

    private func statCard(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .semibold))
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.03))
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Sub-Tab Picker

    private var subTabPicker: some View {
        Picker("", selection: $meetingVM.meetingsSubTab) {
            Text("Meetings").tag(MeetingViewModel.MeetingsSubTab.meetings)
            Text("People").tag(MeetingViewModel.MeetingsSubTab.people)
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Meetings List

    private var meetingsListSection: some View {
        VStack(spacing: 8) {
            if meetingVM.meetingHistory.isEmpty {
                Text("No meetings recorded yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 20)
            } else {
                ForEach(meetingVM.meetingHistory) { meeting in
                    MeetingRowView(meeting: meeting)
                }
            }
        }
    }

    // MARK: - People List

    private var peopleListSection: some View {
        VStack(spacing: 8) {
            if meetingVM.participantProfiles.isEmpty {
                Text("No participant profiles yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 20)
            } else {
                ForEach(meetingVM.participantProfiles) { participant in
                    ParticipantRowView(participant: participant)
                }
            }
        }
    }

    // MARK: - Computed Stats

    private var totalHours: String {
        let totalSecs = meetingVM.meetingHistory.compactMap(\.durationSeconds).reduce(0, +)
        let hours = Double(totalSecs) / 3600.0
        return String(format: "%.1fh", hours)
    }

    private var avgDuration: String {
        let durations = meetingVM.meetingHistory.compactMap(\.durationSeconds)
        guard !durations.isEmpty else { return "" }
        let avg = durations.reduce(0, +) / durations.count / 60
        return "avg \(avg)min"
    }

    private var topParticipant: String {
        var counts: [String: Int] = [:]
        for meeting in meetingVM.meetingHistory {
            for p in meeting.participants {
                counts[p, default: 0] += 1
            }
        }
        return counts.max(by: { $0.value < $1.value })?.key ?? "—"
    }

    private var topPattern: String {
        // Pull from the first participant profile that has patterns
        for p in meetingVM.participantProfiles {
            if let patterns = p.profile?["patterns"], !patterns.isEmpty {
                return String(patterns.prefix(60))
            }
        }
        return "—"
    }
}
```

- [ ] **Step 2: Create MeetingRowView**

Create `mac-helper/OpenClawHelper/Views/Tabs/MeetingRowView.swift`:

```swift
import SwiftUI

struct MeetingRowView: View {
    let meeting: MeetingRecord
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.displayTitle)
                        .font(.system(size: 12, weight: .medium))
                    Text("\(meeting.formattedDate) · \(meeting.app ?? "") · \(meeting.formattedDuration)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Participant avatars
                HStack(spacing: -4) {
                    ForEach(meeting.participants.prefix(3), id: \.self) { name in
                        initialsCircle(for: name, size: 22)
                    }
                    if meeting.participants.count > 3 {
                        Text("+\(meeting.participants.count - 3)")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.orange.opacity(0.3)))
                    }
                }

                statusBadge
            }
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }

            // Expanded detail
            if isExpanded, let summary = meeting.summaryMd, !summary.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Divider().padding(.vertical, 8)
                    Text(summary)
                        .font(.system(size: 11))
                        .lineSpacing(3)

                    if meeting.hasTranscript {
                        Button("View transcript") {
                            // TODO: fetch transcript
                        }
                        .font(.system(size: 10))
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.03))
                .strokeBorder(Color.primary.opacity(isExpanded ? 0.08 : 0.06), lineWidth: 1)
        )
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = {
            switch meeting.purgeStatus {
            case "live": return ("Summary ready", .green)
            case "summary_only": return ("Raw purged", .gray)
            default: return ("Processing", .blue)
            }
        }()

        return Text(text)
            .font(.system(size: 10))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.1).cornerRadius(4))
    }

    private func initialsCircle(for name: String, size: CGFloat) -> some View {
        let parts = name.split(separator: " ")
        let initials = parts.count >= 2
            ? "\(parts[0].prefix(1))\(parts[1].prefix(1))"
            : String(name.prefix(2))

        return Text(initials.uppercased())
            .font(.system(size: size * 0.4, weight: .semibold))
            .frame(width: size, height: size)
            .background(Circle().fill(Color.blue.opacity(0.3)))
            .clipShape(Circle())
    }
}
```

- [ ] **Step 3: Create ParticipantRowView**

Create `mac-helper/OpenClawHelper/Views/Tabs/ParticipantRowView.swift`:

```swift
import SwiftUI

struct ParticipantRowView: View {
    let participant: ParticipantRecord
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed row
            HStack(spacing: 10) {
                Text(participant.initials)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.purple.opacity(0.3)))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(participant.displayName)
                        .font(.system(size: 12, weight: .medium))
                    Text("\(participant.meetingsObserved) meetings")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(participant.oneLiner)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }

            // Expanded profile
            if isExpanded, let profile = participant.profile {
                VStack(alignment: .leading, spacing: 10) {
                    Divider().padding(.vertical, 8)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        profileQuadrant(
                            title: "Decision Style",
                            text: [profile["decision_style"], profile["authority_deference"]]
                                .compactMap { $0 }.joined(separator: " ")
                        )
                        profileQuadrant(
                            title: "Stress Triggers",
                            text: [profile["stress_triggers"], profile["money_reaction"]]
                                .compactMap { $0 }.joined(separator: " ")
                        )
                        profileQuadrant(
                            title: "Engagement",
                            text: [profile["engagement_peak"], profile["commitment_signals"]]
                                .compactMap { $0 }.joined(separator: " ")
                        )
                        profileQuadrant(
                            title: "Reliability",
                            text: profile["reliability"] ?? ""
                        )
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.03))
                .strokeBorder(Color.primary.opacity(isExpanded ? 0.08 : 0.06), lineWidth: 1)
        )
    }

    private func profileQuadrant(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(text.isEmpty ? "—" : text)
                .font(.system(size: 11))
                .lineSpacing(2)
        }
    }
}
```

- [ ] **Step 4: Pass MeetingViewModel into ControlCenterView**

`ControlCenterView` currently only receives `viewModel: ControlCenterViewModel`. It needs access to `MeetingViewModel` for the Meetings tab. Add it as a second parameter:

In `mac-helper/OpenClawHelper/Views/ControlCenterView.swift`, add:
```swift
@ObservedObject var meetingViewModel: MeetingViewModel
```

Then update the call site in `OpenClawHelperApp.swift` (or wherever `ControlCenterView` is created) to pass both:
```swift
ControlCenterView(viewModel: appModel.controlCenterViewModel, meetingViewModel: appModel.meetingViewModel)
```

- [ ] **Step 5: Wire MeetingsTabView into ControlCenterView switch**

In `ControlCenterView.swift`, find the switch statement that renders tab content (line ~34-51). Add the `.meetings` case:

```swift
case .meetings:
    MeetingsTabView(meetingVM: meetingViewModel)
```

Also update the tab icon list. Find where tab icons are mapped (likely in the sidebar section, lines ~62-71). Add for `.meetings`:

```swift
case .meetings: Image(systemName: "mic.and.signal.meter")
```

And the tab label:

```swift
case .meetings: Text("Meetings")
```

- [ ] **Step 6: Build to verify**

Run: `cd mac-helper && xcodebuild build -project OpenClawHelper.xcodeproj -scheme OpenClawHelper -configuration Debug -quiet 2>&1 | grep -E '(error:|BUILD)'`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
git add mac-helper/OpenClawHelper/Views/Tabs/MeetingsTabView.swift \
        mac-helper/OpenClawHelper/Views/Tabs/MeetingRowView.swift \
        mac-helper/OpenClawHelper/Views/Tabs/ParticipantRowView.swift \
        mac-helper/OpenClawHelper/Views/ControlCenterView.swift \
        mac-helper/OpenClawHelper/OpenClawHelperApp.swift
git commit -m "feat(ui): add Meetings tab to Control Center with history and people views"
```

---

## Phase 5: Meeting Sidebar Panel

### Task 13: Create MeetingSidebarPanel (NSPanel + window tracking)

**Files:**
- Modify: `mac-helper/OpenClawHelper/Views/MeetingSidebarView.swift:4-42` (rewrite panel class)

- [ ] **Step 1: Rewrite the panel class**

Replace the existing `MeetingSidebarPanel` class (lines 4-42) with one that polls `CGWindowListCopyWindowInfo` to track the meeting window:

```swift
import AppKit
import SwiftUI

final class MeetingSidebarPanel: NSPanel {
    private var trackingTimer: Timer?
    private var meetingAppBundleId: String?
    private let sidebarWidth: CGFloat = 300

    init(meetingAppBundleId: String?) {
        self.meetingAppBundleId = meetingAppBundleId

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = NSRect(
            x: screen.visibleFrame.maxX - sidebarWidth,
            y: screen.visibleFrame.origin.y,
            width: sidebarWidth,
            height: screen.visibleFrame.height
        )

        super.init(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = NSColor(red: 0.05, green: 0.07, blue: 0.09, alpha: 0.95)
        isOpaque = false
        hasShadow = true
    }

    func startTracking() {
        updatePosition()
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updatePosition()
        }
    }

    func stopTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    private func updatePosition() {
        guard let bundleId = meetingAppBundleId,
              let meetingFrame = findMeetingWindowFrame(bundleId: bundleId) else {
            // Fallback: right edge of screen
            positionAtScreenEdge()
            return
        }

        let newFrame = NSRect(
            x: meetingFrame.maxX,
            y: meetingFrame.origin.y,
            width: sidebarWidth,
            height: meetingFrame.height
        )
        setFrame(newFrame, display: true, animate: false)
    }

    private func findMeetingWindowFrame(bundleId: String) -> CGRect? {
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0  // Normal window layer
            else { continue }

            let app = NSRunningApplication(processIdentifier: ownerPID)
            if app?.bundleIdentifier == bundleId {
                return CGRect(
                    x: bounds["X"] ?? 0,
                    y: bounds["Y"] ?? 0,
                    width: bounds["Width"] ?? 0,
                    height: bounds["Height"] ?? 0
                )
            }
        }
        return nil
    }

    private func positionAtScreenEdge() {
        guard let screen = NSScreen.main else { return }
        let newFrame = NSRect(
            x: screen.visibleFrame.maxX - sidebarWidth,
            y: screen.visibleFrame.origin.y,
            width: sidebarWidth,
            height: screen.visibleFrame.height
        )
        setFrame(newFrame, display: true, animate: false)
    }

    deinit {
        stopTracking()
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `cd mac-helper && xcodebuild build -project OpenClawHelper.xcodeproj -scheme OpenClawHelper -configuration Debug -quiet 2>&1 | grep -E '(error:|BUILD)'`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add mac-helper/OpenClawHelper/Views/MeetingSidebarView.swift
git commit -m "feat(ui): rewrite MeetingSidebarPanel with CGWindowList tracking"
```

---

### Task 14: Create sidebar content view

**Files:**
- Modify: `mac-helper/OpenClawHelper/Views/MeetingSidebarView.swift:44-184` (rewrite view)

- [ ] **Step 1: Add SidebarCardType enum**

At the top of the file (or in `BriefingPackage.swift` alongside `BriefingCard`), add:

```swift
enum SidebarCardType: String {
    case talkingPoint, context, suggestion, warning

    var color: Color {
        switch self {
        case .talkingPoint: return Color(red: 0.545, green: 0.361, blue: 0.965) // #8b5cf6
        case .context: return Color(red: 0.345, green: 0.651, blue: 1.0)       // #58a6ff
        case .suggestion: return Color(red: 0.247, green: 0.725, blue: 0.314)   // #3fb950
        case .warning: return Color(red: 0.824, green: 0.600, blue: 0.133)      // #d29922
        }
    }

    var label: String {
        switch self {
        case .talkingPoint: return "TALKING POINT"
        case .context: return "CONTEXT"
        case .suggestion: return "SUGGESTION"
        case .warning: return "WARNING"
        }
    }

    static func from(category: String) -> SidebarCardType {
        switch category {
        case "context": return .context
        case "behavioural": return .warning
        case "data": return .talkingPoint
        default: return .suggestion
        }
    }
}
```

- [ ] **Step 2: Rewrite MeetingSidebarView**

Replace the existing `MeetingSidebarView` struct (lines 44-184) with the spec layout — header, participants, intelligence cards, transcript ticker:

```swift
struct MeetingSidebarView: View {
    @ObservedObject var meetingVM: MeetingViewModel

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider().opacity(0.2)
            participantsSection
            Divider().opacity(0.2)
            intelligenceCards
            Spacer(minLength: 0)
            Divider().opacity(0.2)
            transcriptTicker
        }
        .frame(width: 300)
        .background(Color(red: 0.086, green: 0.106, blue: 0.133))
    }

    // MARK: - Header

    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                Text("Recording")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(meetingVM.formattedElapsed)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(meetingVM.state.displayLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    // MARK: - Participants

    private var participantsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PARTICIPANTS")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .tracking(0.5)

            if let briefing = meetingVM.briefing {
                ForEach(briefing.attendees ?? [], id: \.self) { name in
                    participantRow(name: name, insight: nil)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Detecting...")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
    }

    private func participantRow(name: String, insight: String?) -> some View {
        HStack(spacing: 8) {
            let parts = name.split(separator: " ")
            let initials = parts.count >= 2
                ? "\(parts[0].prefix(1))\(parts[1].prefix(1))"
                : String(name.prefix(2))

            Text(initials.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.blue.opacity(0.3)))

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 11))
                if let insight = insight {
                    Text(insight)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Intelligence Cards

    private var intelligenceCards: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("INTELLIGENCE")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)

                if meetingVM.notifications.isEmpty && meetingVM.briefing == nil {
                    VStack(spacing: 8) {
                        Text("Listening for topics...")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("Cards will appear as context is matched")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    ForEach(meetingVM.notifications) { notification in
                        sidebarCard(
                            type: SidebarCardType.from(category: notification.card.category),
                            title: notification.card.title,
                            body: notification.card.body
                        )
                    }
                }
            }
            .padding(12)
        }
    }

    private func sidebarCard(type: SidebarCardType, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(type.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(type.color)
            Text(body)
                .font(.system(size: 11))
                .lineSpacing(2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(type.color.opacity(0.1))
                .strokeBorder(type.color.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Transcript Ticker

    private var transcriptTicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LIVE")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .tracking(0.5)

            // Show last few transcript segments from notifications or buffer
            Text("Listening...")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.black.opacity(0.2))
    }
}
```

Note: The transcript ticker will need to be wired to the live transcript buffer. The implementer should check how `BriefingCacheService` reads `meeting-buffer.jsonl` and expose the last ~30 seconds of segments through `MeetingViewModel`.

- [ ] **Step 3: Build to verify**

Run: `cd mac-helper && xcodebuild build -project OpenClawHelper.xcodeproj -scheme OpenClawHelper -configuration Debug -quiet 2>&1 | grep -E '(error:|BUILD)'`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add mac-helper/OpenClawHelper/Views/MeetingSidebarView.swift
git commit -m "feat(ui): rewrite MeetingSidebarView with layered content layout"
```

---

### Task 15: Wire sidebar lifecycle to MeetingSessionManager

**Files:**
- Modify: `mac-helper/OpenClawHelper/ViewModels/MeetingViewModel.swift`
- Modify: `mac-helper/OpenClawHelper/Services/MeetingSessionManager.swift`

- [ ] **Step 1: Add sidebar panel management to MeetingViewModel**

In `MeetingViewModel.swift`, add panel lifecycle management:

```swift
private var sidebarPanel: MeetingSidebarPanel?

func showSidebarPanel(meetingAppBundleId: String?) {
    guard sidebarPanel == nil else { return }
    let panel = MeetingSidebarPanel(meetingAppBundleId: meetingAppBundleId)
    let sidebarView = MeetingSidebarView(meetingVM: self)
    panel.contentView = NSHostingView(rootView: sidebarView)
    panel.startTracking()
    panel.orderFront(nil)
    sidebarPanel = panel
    showSidebar = true
}

func dismissSidebarPanel() {
    sidebarPanel?.stopTracking()
    sidebarPanel?.orderOut(nil)
    sidebarPanel = nil
    showSidebar = false
}
```

- [ ] **Step 1.5: Add meeting app bundle ID mapping**

`MeetingDetectorService` stores the detected app as a name string (e.g., `"zoom"`, `"google-meet"`), not a bundle ID. Add a mapping to `MeetingSessionManager`:

```swift
private static let appBundleIds: [String: String] = [
    "zoom": "us.zoom.xos",
    "google-meet": "com.google.Chrome",  // Meet runs in Chrome
]

var detectedMeetingAppBundleId: String? {
    guard let app = detector.detectedApp else { return nil }
    return Self.appBundleIds[app]
}
```

- [ ] **Step 2: Replace updatePanels() with sidebar-aware version**

In `MeetingViewModel`, **replace the entire `updatePanels()` method** (line ~43-66) — do not extend it, as the existing logic manages the old overlay/sidebar separately. The new version handles only the sidebar panel:

```swift
func updatePanels() {
    if sessionManager.state == .recording && sidebarPanel == nil && showSidebar {
        let bundleId = sessionManager.detectedMeetingAppBundleId
        showSidebarPanel(meetingAppBundleId: bundleId)
    } else if sessionManager.state != .recording && sidebarPanel != nil {
        dismissSidebarPanel()
    }
}
```

- [ ] **Step 3: Update toggleSidebar to show/hide the panel**

Replace `toggleSidebar()` (line ~89):

```swift
func toggleSidebar() {
    showSidebar.toggle()
    if showSidebar && sessionManager.state == .recording {
        let bundleId = sessionManager.detectedMeetingAppBundleId
        showSidebarPanel(meetingAppBundleId: bundleId)
    } else {
        dismissSidebarPanel()
    }
}
```

- [ ] **Step 4: Build to verify**

Run: `cd mac-helper && xcodebuild build -project OpenClawHelper.xcodeproj -scheme OpenClawHelper -configuration Debug -quiet 2>&1 | grep -E '(error:|BUILD)'`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add mac-helper/OpenClawHelper/ViewModels/MeetingViewModel.swift \
        mac-helper/OpenClawHelper/Services/MeetingSessionManager.swift
git commit -m "feat(meetings): wire sidebar panel lifecycle to meeting state"
```

---

## Phase 6: Build & Install

### Task 16: Build release and install

**Files:**
- None (build and deploy)

- [ ] **Step 1: Build the release**

Run: `cd /Users/jonassorensen/Desktop/Hobby/AI/clawrelay && bash scripts/build-release.sh`
Expected: `Build succeeded: .../ClawRelay.app`

- [ ] **Step 2: Kill running app, install, relaunch**

```bash
pkill -f "ClawRelay" 2>/dev/null || true
rm -rf /Applications/ClawRelay.app
cp -R mac-helper/build/Build/Products/Release/ClawRelay.app /Applications/ClawRelay.app
open /Applications/ClawRelay.app
```

- [ ] **Step 3: Verify Meetings tab appears in Control Center**

Open the Control Center window. The sidebar should show "Meetings" as the 2nd tab (after Dashboard). Click it — it should show the idle mode with empty state text.

- [ ] **Step 4: Verify server endpoints work**

```bash
cd mac-daemon && bash context-helperctl.sh meetings 7
cd mac-daemon && bash context-helperctl.sh participants
```
Expected: JSON responses from the server.

- [ ] **Step 5: Commit any final fixes**

```bash
git add -A
git commit -m "feat: complete meetings tab and sidebar implementation"
```
