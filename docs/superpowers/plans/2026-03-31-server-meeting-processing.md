# Server-Side Meeting Processing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the server to receive, store, process, and summarize meeting data — final transcripts, screenshots, and visual events — producing meeting intelligence summaries that JC can act on.

**Architecture:** Three new API endpoints in context-receiver.py, a new meeting_processor.py that runs Claude Vision analysis on screenshots and generates unified meeting summaries, extensions to context-digest.py for meeting sections, and data lifecycle management (48h purge of raw data, permanent summaries and profiles).

**Tech Stack:** Python 3, Flask, SQLite (WAL mode), Anthropic Claude API (claude-sonnet-4-20250514 for vision analysis, claude-opus-4-20250514 for pattern detection)

**Spec:** `docs/superpowers/specs/2026-03-31-meeting-intelligence-design.md`

**Scope:** This is Plan 3 of 3. Plan 1 (claw-meeting binary) and Plan 2 (ClawRelay UI integration) handle the Mac-side capture and overlay.

---

## File Structure

### New Files
```
server/
  meeting_processor.py              # Post-meeting processing: Claude Vision, timeline merge, summaries
  tests/
    test_meeting_endpoints.py        # pytest tests for all three new endpoints
    test_meeting_processor.py        # pytest tests for processing logic
    conftest.py                      # Shared fixtures (test DB, test client, temp dirs)
```

### Modified Files
```
server/
  context-receiver.py               # Add 3 new endpoints + meeting DB tables + meeting purge
  context-digest.py                  # Add "Meetings" section to digest output
  requirements.txt                   # Add anthropic SDK dependency
```

---

## Task 1: Database Schema + Init

**Files:**
- Modify: `server/context-receiver.py`

- [ ] **Step 1: Add meeting tables to init_db()**

Add the following after the existing `CREATE TABLE IF NOT EXISTS jc_questions` block in `init_db()`:

```python
    db.execute("""
        CREATE TABLE IF NOT EXISTS participant_profiles (
            id TEXT PRIMARY KEY,
            display_name TEXT,
            face_embedding BLOB,
            meetings_observed INTEGER DEFAULT 0,
            profile_json TEXT,
            last_updated TEXT
        )
    """)
    db.execute("""
        CREATE INDEX IF NOT EXISTS idx_participant_display_name
        ON participant_profiles(display_name)
    """)
    db.execute("""
        CREATE TABLE IF NOT EXISTS meeting_sessions (
            id TEXT PRIMARY KEY,
            started_at TEXT,
            ended_at TEXT,
            duration_seconds INTEGER,
            app TEXT,
            participants TEXT,
            transcript_json TEXT,
            visual_events_json TEXT,
            summary_md TEXT,
            raw_data_purge_at TEXT
        )
    """)
    db.execute("""
        CREATE INDEX IF NOT EXISTS idx_meeting_started
        ON meeting_sessions(started_at)
    """)
    db.execute("""
        CREATE INDEX IF NOT EXISTS idx_meeting_purge
        ON meeting_sessions(raw_data_purge_at)
    """)
```

- [ ] **Step 2: Add screenshot storage directory constant**

Add near the top of `context-receiver.py`, after the existing config constants:

```python
MEETING_FRAMES_DIR = Path(os.environ.get(
    'MEETING_FRAMES_DIR',
    str(Path(DB_PATH).parent / 'meeting-frames')
))
```

- [ ] **Step 3: Verify tables are created**

```bash
cd server && CONTEXT_BRIDGE_TOKEN=dev-token python3 -c "
import os; os.environ['CONTEXT_BRIDGE_TOKEN'] = 'dev-token'
import importlib.util
spec = importlib.util.spec_from_file_location('cr', 'context-receiver.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print('Tables created successfully')
"
```

Expected: `participant_profiles` and `meeting_sessions` tables exist.

---

## Task 2: Meeting Purge Extension

**Files:**
- Modify: `server/context-receiver.py`

- [ ] **Step 1: Extend purge_old_data() to handle meeting data**

Add the following to the end of `purge_old_data()`, before `db.close()`:

```python
    # Purge raw meeting data (transcript_json, visual_events_json) after 48h
    # Keep summary_md permanently
    purged_meetings = db.execute("""
        UPDATE meeting_sessions
        SET transcript_json = NULL, visual_events_json = NULL
        WHERE raw_data_purge_at IS NOT NULL
          AND raw_data_purge_at < ?
          AND transcript_json IS NOT NULL
    """, (cutoff,)).rowcount

    if purged_meetings:
        logger.info(f"Purged raw data from {purged_meetings} meeting sessions")

    # Purge screenshot files for expired meetings
    try:
        expired_sessions = db.execute("""
            SELECT id FROM meeting_sessions
            WHERE raw_data_purge_at IS NOT NULL
              AND raw_data_purge_at < ?
        """, (cutoff,)).fetchall()

        for session in expired_sessions:
            session_dir = MEETING_FRAMES_DIR / session['id']
            if session_dir.exists():
                import shutil
                shutil.rmtree(session_dir)
                logger.info(f"Purged screenshots for meeting {session['id']}")
    except Exception:
        logger.exception("Failed to purge meeting screenshots")
```

- [ ] **Step 2: Write test fixtures**

Create `server/tests/conftest.py`:

```python
import os
import sys
import pytest

# Add server directory to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

os.environ['CONTEXT_BRIDGE_TOKEN'] = 'test-token-12345'


@pytest.fixture
def temp_db(tmp_path):
    """Create a temporary database for testing."""
    db_path = str(tmp_path / 'test.db')
    os.environ['CONTEXT_BRIDGE_DB'] = db_path
    return db_path


@pytest.fixture
def temp_frames_dir(tmp_path):
    """Create a temporary frames directory."""
    frames_dir = tmp_path / 'meeting-frames'
    frames_dir.mkdir()
    os.environ['MEETING_FRAMES_DIR'] = str(frames_dir)
    return frames_dir


@pytest.fixture
def app(temp_db, temp_frames_dir):
    """Create a test Flask app with fresh database."""
    # Re-import to pick up new env vars
    import importlib
    import db_utils
    importlib.reload(db_utils)

    # Flask app import workaround for hyphenated filename
    if 'context_receiver' in sys.modules:
        del sys.modules['context_receiver']

    import importlib.util
    spec = importlib.util.spec_from_file_location(
        'context_receiver',
        os.path.join(os.path.dirname(__file__), '..', 'context-receiver.py')
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    mod.app.config['TESTING'] = True
    return mod.app


@pytest.fixture
def client(app):
    """Create a test client."""
    return app.test_client()


@pytest.fixture
def auth_headers():
    """Standard auth headers for testing."""
    return {
        'Authorization': 'Bearer test-token-12345',
        'Content-Type': 'application/json',
    }
```

- [ ] **Step 3: Verify test infrastructure works**

```bash
cd server && python3 -m pytest tests/conftest.py --co 2>&1 | tail -5
```

---

## Task 3: POST /context/meeting/session Endpoint

**Files:**
- Modify: `server/context-receiver.py`

- [ ] **Step 1: Add `import sys` to top of context-receiver.py if not already present**

```python
import sys
```

- [ ] **Step 2: Increase MAX_CONTENT_LENGTH for meeting payloads**

The existing default is 256KB (262144). Final transcripts and frame uploads can be large. Update the config section near the top:

```python
MEETING_MAX_CONTENT_LENGTH = int(os.environ.get('MEETING_MAX_CONTENT_LENGTH', '52428800'))  # 50MB
```

Then update the `app.config` line:

```python
app.config['MAX_CONTENT_LENGTH'] = max(MAX_CONTENT_LENGTH, MEETING_MAX_CONTENT_LENGTH)
```

- [ ] **Step 3: Add the session endpoint**

Add after the existing `/context/jc-question/<int:qid>` route:

```python
@app.route('/context/meeting/session', methods=['POST'])
def push_meeting_session():
    """Receive final transcript + metadata for a completed meeting."""
    if not verify_auth(request):
        return jsonify({'error': 'unauthorized'}), 401

    data, error = parse_json_request()
    if error:
        return error

    meeting_id = data.get('meeting_id')
    if not meeting_id:
        return jsonify({'error': 'missing meeting_id'}), 400

    started_at = data.get('started_at')
    ended_at = data.get('ended_at')
    if not started_at or not ended_at:
        return jsonify({'error': 'missing started_at or ended_at'}), 400

    duration_seconds = data.get('duration_seconds', 0)
    app_name = data.get('app', '')
    participants = data.get('participants', '')
    transcript_json = data.get('transcript_json')
    visual_events_json = data.get('visual_events_json')

    # Calculate purge time: 48h from now
    purge_at = (datetime.now(timezone.utc) + timedelta(hours=PURGE_HOURS)).isoformat()

    db = get_db()
    db.execute("""
        INSERT INTO meeting_sessions
        (id, started_at, ended_at, duration_seconds, app, participants,
         transcript_json, visual_events_json, summary_md, raw_data_purge_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)
        ON CONFLICT(id) DO UPDATE SET
            started_at = excluded.started_at,
            ended_at = excluded.ended_at,
            duration_seconds = excluded.duration_seconds,
            app = excluded.app,
            participants = excluded.participants,
            transcript_json = excluded.transcript_json,
            visual_events_json = excluded.visual_events_json,
            raw_data_purge_at = excluded.raw_data_purge_at
    """, (
        meeting_id,
        started_at,
        ended_at,
        duration_seconds,
        app_name,
        json.dumps(participants) if isinstance(participants, list) else participants,
        json.dumps(transcript_json) if transcript_json else None,
        json.dumps(visual_events_json) if visual_events_json else None,
        purge_at,
    ))
    db.commit()
    db.close()

    # Trigger async processing (meeting_processor.py)
    try:
        import subprocess
        processor_path = Path(__file__).parent / 'meeting_processor.py'
        if processor_path.exists():
            subprocess.Popen(
                [sys.executable, str(processor_path), '--meeting-id', meeting_id],
                stdout=open('/tmp/meeting-processor.log', 'a'),
                stderr=subprocess.STDOUT,
            )
            logger.info(f"Triggered meeting processor for {meeting_id}")
    except Exception:
        logger.exception(f"Failed to trigger meeting processor for {meeting_id}")

    return jsonify({
        'status': 'ok',
        'meeting_id': meeting_id,
        'purge_at': purge_at,
    }), 201
```

- [ ] **Step 4: Write tests for session endpoint**

Create `server/tests/test_meeting_endpoints.py`:

```python
import io
import json
import os
import sys
import pytest
from pathlib import Path

# Fixtures come from conftest.py


class TestMeetingSessionEndpoint:
    """Tests for POST /context/meeting/session."""

    def test_push_session_success(self, client, auth_headers):
        """Valid session data is stored."""
        payload = {
            'meeting_id': 'test-2026-03-31-zoom-david',
            'started_at': '2026-03-31T15:00:00Z',
            'ended_at': '2026-03-31T15:40:00Z',
            'duration_seconds': 2400,
            'app': 'Zoom',
            'participants': ['Jonas', 'David Rotman'],
            'transcript_json': [
                {'timestamp': 0, 'speaker': 'speaker_1', 'text': 'Hello David'}
            ],
            'visual_events_json': [
                {'timestamp': 0, 'type': 'visual', 'participants': []}
            ],
        }
        resp = client.post(
            '/context/meeting/session',
            data=json.dumps(payload),
            headers=auth_headers,
        )
        assert resp.status_code == 201
        data = resp.get_json()
        assert data['status'] == 'ok'
        assert data['meeting_id'] == 'test-2026-03-31-zoom-david'
        assert 'purge_at' in data

    def test_push_session_missing_meeting_id(self, client, auth_headers):
        """Missing meeting_id returns 400."""
        payload = {
            'started_at': '2026-03-31T15:00:00Z',
            'ended_at': '2026-03-31T15:40:00Z',
        }
        resp = client.post(
            '/context/meeting/session',
            data=json.dumps(payload),
            headers=auth_headers,
        )
        assert resp.status_code == 400
        assert 'meeting_id' in resp.get_json()['error']

    def test_push_session_missing_timestamps(self, client, auth_headers):
        """Missing started_at or ended_at returns 400."""
        payload = {
            'meeting_id': 'test-meeting',
            'started_at': '2026-03-31T15:00:00Z',
            # missing ended_at
        }
        resp = client.post(
            '/context/meeting/session',
            data=json.dumps(payload),
            headers=auth_headers,
        )
        assert resp.status_code == 400

    def test_push_session_upsert(self, client, auth_headers):
        """Pushing same meeting_id twice updates the existing record."""
        payload = {
            'meeting_id': 'test-upsert',
            'started_at': '2026-03-31T15:00:00Z',
            'ended_at': '2026-03-31T15:40:00Z',
            'duration_seconds': 2400,
            'app': 'Zoom',
            'participants': ['Jonas'],
            'transcript_json': [{'text': 'first version'}],
        }
        resp1 = client.post(
            '/context/meeting/session',
            data=json.dumps(payload),
            headers=auth_headers,
        )
        assert resp1.status_code == 201

        payload['transcript_json'] = [{'text': 'final version'}]
        resp2 = client.post(
            '/context/meeting/session',
            data=json.dumps(payload),
            headers=auth_headers,
        )
        assert resp2.status_code == 201

    def test_push_session_unauthorized(self, client):
        """No auth token returns 401."""
        payload = {
            'meeting_id': 'test',
            'started_at': '2026-03-31T15:00:00Z',
            'ended_at': '2026-03-31T15:40:00Z',
        }
        resp = client.post(
            '/context/meeting/session',
            data=json.dumps(payload),
            content_type='application/json',
        )
        assert resp.status_code == 401
```

- [ ] **Step 5: Run tests**

```bash
cd server && python3 -m pytest tests/test_meeting_endpoints.py -v -k "Session" --tb=short
```

Expected: All TestMeetingSessionEndpoint tests PASS.

---

## Task 4: POST /context/meeting/frames Endpoint

**Files:**
- Modify: `server/context-receiver.py`

- [ ] **Step 1: Add the frames upload endpoint**

```python
@app.route('/context/meeting/frames', methods=['POST'])
def push_meeting_frames():
    """Receive screenshot PNGs for a meeting session.

    Expects multipart/form-data with:
    - meeting_id (form field)
    - frames: up to 10 PNG files, max 50MB total
    """
    if not verify_auth(request):
        return jsonify({'error': 'unauthorized'}), 401

    meeting_id = request.form.get('meeting_id')
    if not meeting_id:
        return jsonify({'error': 'missing meeting_id'}), 400

    files = request.files.getlist('frames')
    if not files:
        return jsonify({'error': 'no files uploaded'}), 400

    if len(files) > 10:
        return jsonify({'error': 'max 10 files per request'}), 400

    # Create session directory
    session_dir = MEETING_FRAMES_DIR / meeting_id
    session_dir.mkdir(parents=True, exist_ok=True)

    saved = []
    for f in files:
        if not f.filename:
            continue
        # Sanitize filename: only allow alphanumeric, hyphens, underscores, dots
        import re
        safe_name = re.sub(r'[^a-zA-Z0-9._-]', '_', f.filename)
        if not safe_name.lower().endswith('.png'):
            safe_name += '.png'
        dest = session_dir / safe_name
        f.save(str(dest))
        saved.append(safe_name)

    logger.info(f"Saved {len(saved)} frames for meeting {meeting_id}")

    return jsonify({
        'status': 'ok',
        'meeting_id': meeting_id,
        'frames_saved': len(saved),
        'filenames': saved,
    }), 201
```

- [ ] **Step 2: Add tests for frames endpoint**

Add to `server/tests/test_meeting_endpoints.py`:

```python
class TestMeetingFramesEndpoint:
    """Tests for POST /context/meeting/frames."""

    def test_upload_frames_success(self, client, temp_frames_dir):
        """Upload PNG frames for a meeting."""
        resp = client.post(
            '/context/meeting/frames',
            data={
                'meeting_id': 'test-meeting-frames',
                'frames': [
                    (io.BytesIO(b'\x89PNG\r\n\x1a\n' + b'\x00' * 50), f'frame_{i:03d}.png')
                    for i in range(3)
                ],
            },
            headers={'Authorization': 'Bearer test-token-12345'},
            content_type='multipart/form-data',
        )
        assert resp.status_code == 201
        result = resp.get_json()
        assert result['frames_saved'] == 3

        # Verify files on disk
        session_dir = temp_frames_dir / 'test-meeting-frames'
        assert session_dir.exists()
        assert len(list(session_dir.iterdir())) == 3

    def test_upload_frames_missing_meeting_id(self, client):
        """Missing meeting_id returns 400."""
        resp = client.post(
            '/context/meeting/frames',
            data={'frames': (io.BytesIO(b'fake'), 'test.png')},
            headers={'Authorization': 'Bearer test-token-12345'},
            content_type='multipart/form-data',
        )
        assert resp.status_code == 400

    def test_upload_frames_no_files(self, client):
        """No files returns 400."""
        resp = client.post(
            '/context/meeting/frames',
            data={'meeting_id': 'test'},
            headers={'Authorization': 'Bearer test-token-12345'},
            content_type='multipart/form-data',
        )
        assert resp.status_code == 400

    def test_upload_frames_too_many(self, client):
        """More than 10 files returns 400."""
        resp = client.post(
            '/context/meeting/frames',
            data={
                'meeting_id': 'test',
                'frames': [
                    (io.BytesIO(b'\x89PNG' + b'\x00' * 20), f'frame_{i:03d}.png')
                    for i in range(11)
                ],
            },
            headers={'Authorization': 'Bearer test-token-12345'},
            content_type='multipart/form-data',
        )
        assert resp.status_code == 400

    def test_upload_frames_unauthorized(self, client):
        """No auth returns 401."""
        resp = client.post(
            '/context/meeting/frames',
            data={'meeting_id': 'test'},
            content_type='multipart/form-data',
        )
        assert resp.status_code == 401
```

- [ ] **Step 3: Run tests**

```bash
cd server && python3 -m pytest tests/test_meeting_endpoints.py -v -k "Frames" --tb=short
```

Expected: All TestMeetingFramesEndpoint tests PASS.

---

## Task 5: POST /meeting/context-request Endpoint

**Files:**
- Modify: `server/context-receiver.py`

- [ ] **Step 1: Add the live context-request endpoint**

This endpoint is called by ClawRelay during a meeting when no local briefing card matches. It forwards the request to JC's processing logic and returns a card. For now, we implement the endpoint and storage; the actual JC integration is a separate concern.

```python
@app.route('/meeting/context-request', methods=['POST'])
def meeting_context_request():
    """Handle live fallback card requests from ClawRelay during meetings.

    ClawRelay sends transcript context when no local briefing card matches.
    Server generates a contextual card and returns it.

    Rate limited: max 5 per meeting, min 60s between requests.
    """
    if not verify_auth(request):
        return jsonify({'error': 'unauthorized'}), 401

    data, error = parse_json_request()
    if error:
        return error

    meeting_id = data.get('meeting_id')
    if not meeting_id:
        return jsonify({'error': 'missing meeting_id'}), 400

    transcript_context = data.get('transcript_context', '')
    if not transcript_context:
        return jsonify({'error': 'missing transcript_context'}), 400

    topic = data.get('topic', '')
    participants = data.get('participants', [])

    # Rate limiting: check recent requests for this meeting
    db = get_db()

    # Ensure context_requests table exists
    db.execute("""
        CREATE TABLE IF NOT EXISTS meeting_context_requests (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            meeting_id TEXT NOT NULL,
            transcript_context TEXT,
            response_card TEXT,
            created_at TEXT DEFAULT (datetime('now'))
        )
    """)

    recent_requests = db.execute("""
        SELECT COUNT(*) as cnt, MAX(created_at) as last_at
        FROM meeting_context_requests
        WHERE meeting_id = ?
    """, (meeting_id,)).fetchone()

    request_count = recent_requests['cnt']
    last_request_at = recent_requests['last_at']

    # Rate limit: max 5 per meeting
    if request_count >= 5:
        db.close()
        return jsonify({
            'error': 'rate_limited',
            'message': 'Maximum 5 context requests per meeting',
        }), 429

    # Rate limit: min 60s between requests
    if last_request_at:
        try:
            last_dt = datetime.fromisoformat(last_request_at)
            elapsed = (datetime.now() - last_dt).total_seconds()
            if elapsed < 60:
                db.close()
                return jsonify({
                    'error': 'rate_limited',
                    'message': f'Minimum 60s between requests. Wait {int(60 - elapsed)}s.',
                    'retry_after': int(60 - elapsed),
                }), 429
        except (ValueError, TypeError):
            pass

    # Generate a placeholder card.
    # In production, this calls JC's memory search + Claude to generate a card.
    # For now, return an acknowledgement that the request was received.
    card = {
        'title': f'Context: {topic[:50]}' if topic else 'Analyzing...',
        'body': 'JC is searching memory for relevant context. Card will be updated.',
        'priority': 'medium',
        'category': 'fallback',
        'source': 'jc_generated',
    }

    db.execute("""
        INSERT INTO meeting_context_requests
        (meeting_id, transcript_context, response_card)
        VALUES (?, ?, ?)
    """, (meeting_id, transcript_context[:5000], json.dumps(card)))
    db.commit()
    db.close()

    logger.info(f"Context request for meeting {meeting_id} (request #{request_count + 1})")

    return jsonify({
        'status': 'ok',
        'card': card,
        'requests_remaining': 4 - request_count,
    }), 200
```

- [ ] **Step 2: Add tests for context-request endpoint**

Add to `server/tests/test_meeting_endpoints.py`:

```python
class TestMeetingContextRequest:
    """Tests for POST /meeting/context-request."""

    def test_context_request_success(self, client, auth_headers):
        """Valid context request returns a card."""
        payload = {
            'meeting_id': 'test-ctx-meeting',
            'transcript_context': 'David just mentioned a new CRM integration timeline.',
            'topic': 'CRM integration',
            'participants': ['Jonas', 'David'],
        }
        resp = client.post(
            '/meeting/context-request',
            data=json.dumps(payload),
            headers=auth_headers,
        )
        assert resp.status_code == 200
        data = resp.get_json()
        assert data['status'] == 'ok'
        assert 'card' in data
        assert data['card']['category'] == 'fallback'
        assert 'requests_remaining' in data

    def test_context_request_missing_meeting_id(self, client, auth_headers):
        """Missing meeting_id returns 400."""
        payload = {'transcript_context': 'some context'}
        resp = client.post(
            '/meeting/context-request',
            data=json.dumps(payload),
            headers=auth_headers,
        )
        assert resp.status_code == 400

    def test_context_request_missing_context(self, client, auth_headers):
        """Missing transcript_context returns 400."""
        payload = {'meeting_id': 'test'}
        resp = client.post(
            '/meeting/context-request',
            data=json.dumps(payload),
            headers=auth_headers,
        )
        assert resp.status_code == 400

    def test_context_request_rate_limit_count(self, client, auth_headers):
        """6th request to same meeting returns 429."""
        for i in range(5):
            payload = {
                'meeting_id': 'test-rate-limit',
                'transcript_context': f'context {i}',
            }
            resp = client.post(
                '/meeting/context-request',
                data=json.dumps(payload),
                headers=auth_headers,
            )
            # First 5 should succeed (ignoring 60s rate limit in test
            # since they are in the same second -- we test the count limit here)
            if resp.status_code == 429:
                # The 60s rate limit may kick in first; that is also acceptable
                break

        # The 6th should definitely be rate-limited
        payload = {
            'meeting_id': 'test-rate-limit',
            'transcript_context': 'context 5',
        }
        resp = client.post(
            '/meeting/context-request',
            data=json.dumps(payload),
            headers=auth_headers,
        )
        assert resp.status_code == 429

    def test_context_request_unauthorized(self, client):
        """No auth returns 401."""
        payload = {
            'meeting_id': 'test',
            'transcript_context': 'hello',
        }
        resp = client.post(
            '/meeting/context-request',
            data=json.dumps(payload),
            content_type='application/json',
        )
        assert resp.status_code == 401
```

- [ ] **Step 3: Run tests**

```bash
cd server && python3 -m pytest tests/test_meeting_endpoints.py -v -k "ContextRequest" --tb=short
```

Expected: All TestMeetingContextRequest tests PASS.

---

## Task 6: Meeting Processor -- Core Logic

**Files:**
- Create: `server/meeting_processor.py`

- [ ] **Step 1: Create meeting_processor.py with the full processing pipeline**

```python
#!/usr/bin/env python3
"""
Meeting Processor -- Post-meeting intelligence generation.

Triggered after final transcript arrives. Performs:
1. Claude Vision batch analysis on screenshots (expression classification)
2. Merge transcript + visual events + expression analysis into unified timeline
3. Generate meeting intelligence summary (markdown)
4. Match face embeddings to participant profiles
5. Update participant profiles
6. Pattern detection after 3+ meetings with same participant
"""

import os
import sys
import json
import base64
import logging
import argparse
from datetime import datetime, timezone
from pathlib import Path

from db_utils import get_db, DB_PATH

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s %(levelname)s [meeting-processor] %(message)s',
)
logger = logging.getLogger(__name__)

MEETING_FRAMES_DIR = Path(os.environ.get(
    'MEETING_FRAMES_DIR',
    str(Path(DB_PATH).parent / 'meeting-frames')
))

EXPRESSION_CONFIDENCE_THRESHOLD = 0.6

# Claude model for vision analysis
VISION_MODEL = os.environ.get('MEETING_VISION_MODEL', 'claude-sonnet-4-20250514')
# Claude model for summary + pattern detection
SUMMARY_MODEL = os.environ.get('MEETING_SUMMARY_MODEL', 'claude-sonnet-4-20250514')


def get_anthropic_client():
    """Get Anthropic client. Returns None if API key not set."""
    api_key = os.environ.get('ANTHROPIC_API_KEY')
    if not api_key:
        logger.warning("ANTHROPIC_API_KEY not set -- skipping Claude analysis")
        return None

    try:
        import anthropic
        return anthropic.Anthropic(api_key=api_key)
    except ImportError:
        logger.warning("anthropic package not installed -- skipping Claude analysis")
        return None


def load_meeting(meeting_id):
    """Load meeting session from database."""
    db = get_db()
    row = db.execute(
        "SELECT * FROM meeting_sessions WHERE id = ?", (meeting_id,)
    ).fetchone()
    db.close()
    return dict(row) if row else None


def load_frames(meeting_id):
    """Load screenshot file paths for a meeting."""
    session_dir = MEETING_FRAMES_DIR / meeting_id
    if not session_dir.exists():
        return []

    frames = sorted(session_dir.glob('*.png'))
    return frames


def analyze_frame_expression(client, frame_path):
    """Run Claude Vision on a single frame to classify expressions.

    Returns a list of participant observations.
    """
    if not client:
        return []

    try:
        with open(frame_path, 'rb') as f:
            image_data = base64.standard_b64encode(f.read()).decode('utf-8')

        response = client.messages.create(
            model=VISION_MODEL,
            max_tokens=1024,
            messages=[{
                'role': 'user',
                'content': [
                    {
                        'type': 'image',
                        'source': {
                            'type': 'base64',
                            'media_type': 'image/png',
                            'data': image_data,
                        },
                    },
                    {
                        'type': 'text',
                        'text': (
                            'Analyze the people visible in this meeting screenshot. '
                            'For each person, classify their expression as one of: '
                            'neutral, concerned, interested, skeptical, confident, '
                            'uncomfortable, surprised, disengaged. '
                            'Also describe their body language briefly. '
                            'Return JSON array with objects containing: '
                            'position (e.g. "top-left"), expression, confidence (0-1), '
                            'body_language (string). '
                            'Only return the JSON array, no other text.'
                        ),
                    },
                ],
            }],
        )

        result_text = response.content[0].text.strip()

        # Parse JSON, handling potential markdown code fences
        if result_text.startswith('```'):
            result_text = result_text.split('\n', 1)[1].rsplit('```', 1)[0].strip()

        observations = json.loads(result_text)
        return observations if isinstance(observations, list) else []

    except Exception:
        logger.exception(f"Failed to analyze frame {frame_path.name}")
        return []


def batch_analyze_frames(client, frames):
    """Run expression analysis on a batch of frames.

    Returns dict mapping frame filename to list of observations.
    """
    results = {}
    for frame_path in frames:
        logger.info(f"Analyzing frame: {frame_path.name}")
        observations = analyze_frame_expression(client, frame_path)
        results[frame_path.name] = observations
    return results


def merge_timeline(transcript_json, visual_events_json, expression_results):
    """Merge transcript, visual events, and expression analysis into unified timeline.

    Returns a list of timeline events sorted by timestamp.
    """
    timeline = []

    # Add transcript segments
    if transcript_json:
        segments = json.loads(transcript_json) if isinstance(transcript_json, str) else transcript_json
        for seg in segments:
            timeline.append({
                'type': 'transcript',
                'timestamp': seg.get('timestamp', 0),
                'speaker': seg.get('speaker', 'unknown'),
                'text': seg.get('text', ''),
                'confidence': seg.get('confidence', 1.0),
            })

    # Add visual events with expression analysis overlay
    if visual_events_json:
        events = json.loads(visual_events_json) if isinstance(visual_events_json, str) else visual_events_json
        for evt in events:
            entry = {
                'type': 'visual',
                'timestamp': evt.get('timestamp', 0),
                'trigger': evt.get('trigger', ''),
                'participants': evt.get('participants', []),
            }

            # Overlay expression results if available for this frame
            frame_key = evt.get('frame_filename')
            if frame_key and frame_key in expression_results:
                observations = expression_results[frame_key]
                # Filter by confidence threshold
                entry['expression_analysis'] = [
                    obs for obs in observations
                    if obs.get('confidence', 0) >= EXPRESSION_CONFIDENCE_THRESHOLD
                ]

            timeline.append(entry)

    # Sort by timestamp
    timeline.sort(key=lambda x: x.get('timestamp', 0))

    return timeline


def generate_summary(client, meeting, timeline):
    """Generate a meeting intelligence summary using Claude.

    Returns markdown string.
    """
    if not client:
        return _generate_basic_summary(meeting, timeline)

    transcript_parts = [
        f"[{e['timestamp']}s] {e.get('speaker', '?')}: {e.get('text', '')}"
        for e in timeline if e['type'] == 'transcript'
    ]
    transcript_text = '\n'.join(transcript_parts[:500])  # Cap at 500 segments

    expression_notes = []
    for e in timeline:
        if e['type'] == 'visual' and e.get('expression_analysis'):
            for obs in e['expression_analysis']:
                ts = e.get('timestamp', 0)
                minutes = int(ts // 60)
                seconds = int(ts % 60)
                expression_notes.append(
                    f"- {minutes:02d}:{seconds:02d} -- {obs.get('position', '?')}: "
                    f"{obs.get('expression', '?')} ({obs.get('confidence', 0):.2f}), "
                    f"{obs.get('body_language', '')}"
                )
    expression_text = '\n'.join(expression_notes) if expression_notes else 'No visual analysis available.'

    participants_str = meeting.get('participants', 'Unknown')
    app_name = meeting.get('app', 'Unknown')
    started_at = meeting.get('started_at', '')
    ended_at = meeting.get('ended_at', '')
    duration = meeting.get('duration_seconds', 0)
    duration_min = duration // 60 if duration else 0

    prompt = f"""Analyze this meeting and generate a structured intelligence summary.

Meeting metadata:
- App: {app_name}
- Participants: {participants_str}
- Start: {started_at}
- End: {ended_at}
- Duration: {duration_min} minutes

Transcript:
{transcript_text}

Visual/Expression observations:
{expression_text}

Generate a markdown summary with these exact sections:
1. **Key Decisions** -- bullet list of decisions made
2. **Action Items** -- checkbox list with owner and deadline if mentioned
3. **Unresolved** -- topics discussed but not concluded
4. **Emotional Hotspots** -- significant expression/body language moments with timestamps (MM:SS format), only include observations with confidence >= 0.6
5. **Behavioural Notes** -- patterns observed about participants

Keep it concise and actionable. Use the participant names, not "speaker_1".
If the transcript is empty or too short, note that the meeting data was limited.
Return only the markdown content for these sections (no title header -- I will add that)."""

    try:
        response = client.messages.create(
            model=SUMMARY_MODEL,
            max_tokens=4096,
            messages=[{'role': 'user', 'content': prompt}],
        )
        body = response.content[0].text.strip()
    except Exception:
        logger.exception("Failed to generate summary via Claude")
        body = _generate_basic_summary_body(meeting, timeline)

    # Build full summary with header
    header = f"""# Meeting: {meeting.get('id', 'Unknown')}
**Date:** {started_at[:10] if started_at else 'Unknown'} {started_at[11:16] if len(started_at) > 16 else ''}-{ended_at[11:16] if len(ended_at) > 16 else ''} | **Duration:** {duration_min} min
**Participants:** {participants_str}
**App:** {app_name}

"""
    return header + body


def _generate_basic_summary(meeting, timeline):
    """Generate a minimal summary without Claude API."""
    body = _generate_basic_summary_body(meeting, timeline)
    started_at = meeting.get('started_at', '')
    ended_at = meeting.get('ended_at', '')
    duration = meeting.get('duration_seconds', 0)
    duration_min = duration // 60 if duration else 0

    header = f"""# Meeting: {meeting.get('id', 'Unknown')}
**Date:** {started_at[:10] if started_at else 'Unknown'} | **Duration:** {duration_min} min
**Participants:** {meeting.get('participants', 'Unknown')}
**App:** {meeting.get('app', 'Unknown')}

"""
    return header + body


def _generate_basic_summary_body(meeting, timeline):
    """Generate basic summary body from timeline data."""
    transcript_count = sum(1 for e in timeline if e['type'] == 'transcript')
    visual_count = sum(1 for e in timeline if e['type'] == 'visual')

    lines = [
        "## Key Decisions",
        "*(Claude API unavailable -- manual review needed)*",
        "",
        "## Action Items",
        "*(Claude API unavailable -- manual review needed)*",
        "",
        f"## Stats",
        f"- Transcript segments: {transcript_count}",
        f"- Visual events: {visual_count}",
    ]
    return '\n'.join(lines)


def match_face_embeddings(meeting_id, visual_events_json):
    """Match face embeddings from visual events to participant profiles.

    Creates new profiles for unknown faces.
    Returns dict mapping face_id to participant profile id.
    """
    if not visual_events_json:
        return {}

    events = json.loads(visual_events_json) if isinstance(visual_events_json, str) else visual_events_json

    db = get_db()
    profiles = db.execute("SELECT id, face_embedding FROM participant_profiles").fetchall()

    # Build a map of known embeddings
    known = {}
    for p in profiles:
        if p['face_embedding']:
            known[p['id']] = p['face_embedding']

    matches = {}
    new_faces = set()

    for evt in events:
        for participant in evt.get('participants', []):
            face_id = participant.get('face_id')
            embedding_hash = participant.get('face_embedding_hash')
            if face_id and embedding_hash:
                if embedding_hash in known:
                    matches[face_id] = known[embedding_hash]
                else:
                    new_faces.add((face_id, embedding_hash))

    # Create stub profiles for new faces
    for face_id, emb_hash in new_faces:
        profile_id = f"face_{emb_hash[:12]}"
        try:
            db.execute("""
                INSERT OR IGNORE INTO participant_profiles
                (id, display_name, face_embedding, meetings_observed, profile_json, last_updated)
                VALUES (?, ?, NULL, 1, '{}', ?)
            """, (profile_id, face_id, datetime.now(timezone.utc).isoformat()))
            matches[face_id] = profile_id
        except Exception:
            logger.exception(f"Failed to create profile for {face_id}")

    db.commit()
    db.close()

    return matches


def update_participant_profiles(meeting_id, participants_str):
    """Increment meetings_observed for participants in this meeting."""
    db = get_db()

    # Parse participants
    try:
        participants = json.loads(participants_str) if isinstance(participants_str, str) else participants_str
    except (json.JSONDecodeError, TypeError):
        participants = []

    if not isinstance(participants, list):
        db.close()
        return

    for name in participants:
        if not name:
            continue
        # Try to find by display_name
        row = db.execute(
            "SELECT id, meetings_observed FROM participant_profiles WHERE display_name = ?",
            (name,)
        ).fetchone()

        if row:
            db.execute("""
                UPDATE participant_profiles
                SET meetings_observed = meetings_observed + 1,
                    last_updated = ?
                WHERE id = ?
            """, (datetime.now(timezone.utc).isoformat(), row['id']))
        else:
            # Create new profile
            import hashlib
            profile_id = f"name_{hashlib.sha256(name.encode()).hexdigest()[:12]}"
            db.execute("""
                INSERT OR IGNORE INTO participant_profiles
                (id, display_name, meetings_observed, profile_json, last_updated)
                VALUES (?, ?, 1, '{}', ?)
            """, (profile_id, name, datetime.now(timezone.utc).isoformat()))

    db.commit()
    db.close()


def detect_patterns(client, participant_name):
    """Detect cross-meeting patterns for a participant with 3+ meetings.

    Uses Claude to analyze historical meeting summaries.
    Returns updated profile_json or None.
    """
    db = get_db()
    profile = db.execute(
        "SELECT * FROM participant_profiles WHERE display_name = ?",
        (participant_name,)
    ).fetchone()

    if not profile or profile['meetings_observed'] < 3:
        db.close()
        return None

    # Find all meetings with this participant
    meetings = db.execute("""
        SELECT id, started_at, summary_md, participants
        FROM meeting_sessions
        WHERE participants LIKE ?
        AND summary_md IS NOT NULL
        ORDER BY started_at DESC
        LIMIT 10
    """, (f'%{participant_name}%',)).fetchall()
    db.close()

    if len(meetings) < 3 or not client:
        return None

    summaries_text = '\n\n---\n\n'.join([
        f"Meeting: {m['id']} ({m['started_at']})\n{m['summary_md'][:2000]}"
        for m in meetings
    ])

    prompt = f"""Analyze these {len(meetings)} meeting summaries involving {participant_name}.

{summaries_text}

Identify recurring patterns in {participant_name}'s behaviour:
- Decision-making style
- Emotional reactions to specific topics
- Authority/deference patterns
- Commitment reliability
- Stress triggers
- Engagement patterns

Return a JSON object with these keys:
- decision_style (string)
- money_reaction (string)
- authority_deference (string)
- commitment_signals (string)
- stress_triggers (list of strings)
- engagement_peak (string)
- reliability (string)

Only include patterns you have strong evidence for across multiple meetings.
Return only the JSON object, no other text."""

    try:
        response = client.messages.create(
            model=SUMMARY_MODEL,
            max_tokens=2048,
            messages=[{'role': 'user', 'content': prompt}],
        )
        result_text = response.content[0].text.strip()
        if result_text.startswith('```'):
            result_text = result_text.split('\n', 1)[1].rsplit('```', 1)[0].strip()

        patterns = json.loads(result_text)

        # Update profile
        db = get_db()
        profile_json = json.dumps({
            'participant': participant_name,
            'meetings_observed': profile['meetings_observed'],
            'patterns': patterns,
            'last_updated': datetime.now(timezone.utc).isoformat(),
        })
        db.execute(
            "UPDATE participant_profiles SET profile_json = ?, last_updated = ? WHERE display_name = ?",
            (profile_json, datetime.now(timezone.utc).isoformat(), participant_name)
        )
        db.commit()
        db.close()

        logger.info(f"Updated patterns for {participant_name}")
        return patterns

    except Exception:
        logger.exception(f"Failed to detect patterns for {participant_name}")
        return None


def process_meeting(meeting_id):
    """Full processing pipeline for a completed meeting."""
    logger.info(f"Processing meeting: {meeting_id}")

    # 1. Load meeting data
    meeting = load_meeting(meeting_id)
    if not meeting:
        logger.error(f"Meeting {meeting_id} not found in database")
        return False

    # 2. Load frames
    frames = load_frames(meeting_id)
    logger.info(f"Found {len(frames)} frames for meeting {meeting_id}")

    # 3. Get Claude client
    client = get_anthropic_client()

    # 4. Run expression analysis on frames
    expression_results = {}
    if frames and client:
        expression_results = batch_analyze_frames(client, frames)
        logger.info(f"Analyzed {len(expression_results)} frames")

    # 5. Merge into unified timeline
    timeline = merge_timeline(
        meeting.get('transcript_json'),
        meeting.get('visual_events_json'),
        expression_results,
    )
    logger.info(f"Unified timeline: {len(timeline)} events")

    # 6. Generate summary
    summary_md = generate_summary(client, meeting, timeline)
    logger.info(f"Generated summary: {len(summary_md)} chars")

    # 7. Store summary
    db = get_db()
    db.execute(
        "UPDATE meeting_sessions SET summary_md = ? WHERE id = ?",
        (summary_md, meeting_id)
    )
    db.commit()
    db.close()

    # 8. Match face embeddings
    match_face_embeddings(meeting_id, meeting.get('visual_events_json'))

    # 9. Update participant profiles
    update_participant_profiles(meeting_id, meeting.get('participants'))

    # 10. Detect patterns (for participants with 3+ meetings)
    try:
        participants = json.loads(meeting['participants']) if isinstance(meeting['participants'], str) else (meeting['participants'] or [])
        if isinstance(participants, list):
            for name in participants:
                detect_patterns(client, name)
    except (json.JSONDecodeError, TypeError):
        pass

    logger.info(f"Meeting {meeting_id} processing complete")
    return True


def main():
    parser = argparse.ArgumentParser(description='Meeting Processor')
    parser.add_argument('--meeting-id', required=True, help='Meeting session ID to process')
    parser.add_argument('--dry-run', action='store_true', help='Print summary without saving')
    args = parser.parse_args()

    success = process_meeting(args.meeting_id)
    if not success:
        sys.exit(1)


if __name__ == '__main__':
    main()
```

- [ ] **Step 2: Write tests for meeting processor**

Create `server/tests/test_meeting_processor.py`:

```python
import json
import os
import sys
import pytest
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))


@pytest.fixture
def processor_db(tmp_path):
    """Set up a temp database with meeting tables."""
    db_path = str(tmp_path / 'test-processor.db')
    os.environ['CONTEXT_BRIDGE_DB'] = db_path
    os.environ['CONTEXT_BRIDGE_TOKEN'] = 'test-token'

    import importlib
    import db_utils
    importlib.reload(db_utils)

    db = db_utils.get_db(db_path)
    db.execute("""
        CREATE TABLE IF NOT EXISTS meeting_sessions (
            id TEXT PRIMARY KEY, started_at TEXT, ended_at TEXT,
            duration_seconds INTEGER, app TEXT, participants TEXT,
            transcript_json TEXT, visual_events_json TEXT,
            summary_md TEXT, raw_data_purge_at TEXT
        )
    """)
    db.execute("""
        CREATE TABLE IF NOT EXISTS participant_profiles (
            id TEXT PRIMARY KEY, display_name TEXT, face_embedding BLOB,
            meetings_observed INTEGER DEFAULT 0, profile_json TEXT,
            last_updated TEXT
        )
    """)
    db.commit()
    db.close()
    return db_path


@pytest.fixture
def frames_dir(tmp_path):
    """Set up temp frames directory."""
    d = tmp_path / 'meeting-frames'
    d.mkdir()
    os.environ['MEETING_FRAMES_DIR'] = str(d)
    return d


@pytest.fixture
def sample_meeting(processor_db):
    """Insert a sample meeting into the test DB."""
    import importlib
    import db_utils
    importlib.reload(db_utils)

    db = db_utils.get_db()
    db.execute("""
        INSERT INTO meeting_sessions
        (id, started_at, ended_at, duration_seconds, app, participants,
         transcript_json, visual_events_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    """, (
        'test-meeting-001',
        '2026-03-31T15:00:00Z',
        '2026-03-31T15:40:00Z',
        2400,
        'Zoom',
        json.dumps(['Jonas', 'David Rotman']),
        json.dumps([
            {'timestamp': 0, 'speaker': 'speaker_1', 'text': 'Hello David'},
            {'timestamp': 5, 'speaker': 'speaker_2', 'text': 'Hi Jonas, lets discuss pricing'},
            {'timestamp': 30, 'speaker': 'speaker_1', 'text': 'The total is $50,000'},
        ]),
        json.dumps([
            {
                'timestamp': 30,
                'type': 'visual',
                'trigger': 'keyword_price',
                'frame_filename': 'frame_030.png',
                'participants': [{'face_id': 'face_001', 'grid_position': 'top-right'}],
            },
        ]),
    ))
    db.commit()
    db.close()
    return 'test-meeting-001'


class TestMergeTimeline:
    """Tests for merge_timeline()."""

    def test_merge_transcript_only(self, processor_db, frames_dir):
        import importlib
        import meeting_processor
        importlib.reload(meeting_processor)

        transcript = [
            {'timestamp': 0, 'speaker': 'A', 'text': 'Hello'},
            {'timestamp': 5, 'speaker': 'B', 'text': 'Hi'},
        ]
        timeline = meeting_processor.merge_timeline(
            json.dumps(transcript), None, {}
        )
        assert len(timeline) == 2
        assert timeline[0]['type'] == 'transcript'
        assert timeline[0]['speaker'] == 'A'

    def test_merge_with_visual_events(self, processor_db, frames_dir):
        import importlib
        import meeting_processor
        importlib.reload(meeting_processor)

        transcript = [{'timestamp': 0, 'speaker': 'A', 'text': 'Hello'}]
        visual = [{'timestamp': 2, 'trigger': 'keyword', 'participants': []}]
        timeline = meeting_processor.merge_timeline(
            json.dumps(transcript), json.dumps(visual), {}
        )
        assert len(timeline) == 2
        assert timeline[0]['type'] == 'transcript'
        assert timeline[1]['type'] == 'visual'

    def test_merge_sorted_by_timestamp(self, processor_db, frames_dir):
        import importlib
        import meeting_processor
        importlib.reload(meeting_processor)

        transcript = [{'timestamp': 10, 'speaker': 'A', 'text': 'Late'}]
        visual = [{'timestamp': 2, 'trigger': 'early', 'participants': []}]
        timeline = meeting_processor.merge_timeline(
            json.dumps(transcript), json.dumps(visual), {}
        )
        assert timeline[0]['timestamp'] == 2
        assert timeline[1]['timestamp'] == 10

    def test_expression_filter_threshold(self, processor_db, frames_dir):
        import importlib
        import meeting_processor
        importlib.reload(meeting_processor)

        visual = [{
            'timestamp': 5,
            'trigger': 'test',
            'participants': [],
            'frame_filename': 'frame.png',
        }]
        expressions = {
            'frame.png': [
                {'position': 'top-left', 'expression': 'concerned', 'confidence': 0.8, 'body_language': 'leaning back'},
                {'position': 'top-right', 'expression': 'neutral', 'confidence': 0.4, 'body_language': 'still'},
            ]
        }
        timeline = meeting_processor.merge_timeline(
            None, json.dumps(visual), expressions
        )
        assert len(timeline) == 1
        analysis = timeline[0].get('expression_analysis', [])
        # Only the 0.8 confidence observation should be included
        assert len(analysis) == 1
        assert analysis[0]['expression'] == 'concerned'


class TestGenerateSummary:
    """Tests for summary generation."""

    def test_basic_summary_without_claude(self, processor_db, frames_dir, sample_meeting):
        import importlib
        import meeting_processor
        importlib.reload(meeting_processor)

        meeting = meeting_processor.load_meeting(sample_meeting)
        timeline = meeting_processor.merge_timeline(
            meeting['transcript_json'], meeting['visual_events_json'], {}
        )
        summary = meeting_processor.generate_summary(None, meeting, timeline)

        assert 'test-meeting-001' in summary
        assert 'Zoom' in summary
        assert 'Claude API unavailable' in summary


class TestUpdateProfiles:
    """Tests for participant profile updates."""

    def test_creates_new_profiles(self, processor_db, frames_dir):
        import importlib
        import meeting_processor
        importlib.reload(meeting_processor)

        meeting_processor.update_participant_profiles(
            'test-meeting', json.dumps(['Alice', 'Bob'])
        )

        import db_utils
        importlib.reload(db_utils)
        db = db_utils.get_db()
        profiles = db.execute("SELECT * FROM participant_profiles").fetchall()
        db.close()

        assert len(profiles) == 2
        names = {p['display_name'] for p in profiles}
        assert 'Alice' in names
        assert 'Bob' in names

    def test_increments_existing_profile(self, processor_db, frames_dir):
        import importlib
        import meeting_processor
        importlib.reload(meeting_processor)

        # First meeting
        meeting_processor.update_participant_profiles(
            'meeting-1', json.dumps(['Alice'])
        )
        # Second meeting
        meeting_processor.update_participant_profiles(
            'meeting-2', json.dumps(['Alice'])
        )

        import db_utils
        importlib.reload(db_utils)
        db = db_utils.get_db()
        profile = db.execute(
            "SELECT * FROM participant_profiles WHERE display_name = 'Alice'"
        ).fetchone()
        db.close()

        assert profile['meetings_observed'] == 2


class TestProcessMeeting:
    """Tests for the full processing pipeline."""

    def test_process_nonexistent_meeting(self, processor_db, frames_dir):
        import importlib
        import meeting_processor
        importlib.reload(meeting_processor)

        result = meeting_processor.process_meeting('nonexistent')
        assert result is False

    def test_process_meeting_without_claude(self, processor_db, frames_dir, sample_meeting):
        import importlib
        import meeting_processor
        importlib.reload(meeting_processor)

        # Process without ANTHROPIC_API_KEY (no Claude calls)
        os.environ.pop('ANTHROPIC_API_KEY', None)
        result = meeting_processor.process_meeting(sample_meeting)
        assert result is True

        # Check that summary was stored
        meeting = meeting_processor.load_meeting(sample_meeting)
        assert meeting['summary_md'] is not None
        assert 'test-meeting-001' in meeting['summary_md']

        # Check participant profiles were created
        import db_utils
        importlib.reload(db_utils)
        db = db_utils.get_db()
        profiles = db.execute("SELECT * FROM participant_profiles").fetchall()
        db.close()
        assert len(profiles) >= 1  # At least Jonas or David
```

- [ ] **Step 3: Run processor tests**

```bash
cd server && python3 -m pytest tests/test_meeting_processor.py -v --tb=short
```

Expected: All tests PASS.

---

## Task 7: Digest Extension -- Meetings Section

**Files:**
- Modify: `server/context-digest.py`

- [ ] **Step 1: Add meeting query function**

Add before `build_digest()`:

```python
def get_recent_meetings(since_ts):
    """Get meeting sessions within the digest window."""
    db = get_db()
    try:
        meetings = db.execute("""
            SELECT id, started_at, ended_at, duration_seconds, app, participants, summary_md
            FROM meeting_sessions
            WHERE started_at >= ?
            ORDER BY started_at
        """, (since_ts,)).fetchall()
    except Exception:
        # meeting_sessions table may not exist yet
        meetings = []
    db.close()
    return meetings
```

- [ ] **Step 2: Add Meetings section to build_digest() output**

Add the following block in `build_digest()`, after the "Focus Level" section and before the "Time Allocation" section (after the `focus_periods` block):

```python
    # --- Meetings ---
    try:
        meetings = get_recent_meetings(since)
        if meetings:
            lines.append("## Meetings")
            lines.append("")
            for m in meetings:
                duration_min = (m['duration_seconds'] or 0) // 60
                start_time = m['started_at'][11:16] if m['started_at'] and len(m['started_at']) > 16 else '??:??'
                end_time = m['ended_at'][11:16] if m['ended_at'] and len(m['ended_at']) > 16 else '??:??'
                app_name = m['app'] or 'Unknown'

                # Parse participants for display
                try:
                    participants = json.loads(m['participants']) if isinstance(m['participants'], str) else (m['participants'] or [])
                    if isinstance(participants, list):
                        others = [p for p in participants if p.lower() != 'jonas']
                        participant_str = ', '.join(others) if others else 'Solo'
                    else:
                        participant_str = str(participants)
                except (json.JSONDecodeError, TypeError):
                    participant_str = m['participants'] or 'Unknown'

                meeting_title = m['id'].replace('-', ' ').title() if m['id'] else 'Unknown'
                lines.append(f"- **{start_time}-{end_time}** {meeting_title} ({app_name}, {participant_str})")

                # Include summary excerpt if available
                if m['summary_md']:
                    summary_lines = m['summary_md'].split('\n')
                    excerpt_parts = []
                    for sl in summary_lines:
                        sl = sl.strip()
                        if sl and not sl.startswith('#') and not sl.startswith('**') and not sl.startswith('*'):
                            excerpt_parts.append(sl)
                            if len(excerpt_parts) >= 2:
                                break
                    if excerpt_parts:
                        lines.append(f"  {' '.join(excerpt_parts)[:200]}")

                lines.append(f"  Full summary: meeting_sessions/{m['id']}")

            lines.append("")
    except Exception:
        pass
```

- [ ] **Step 3: Verify digest still runs without meeting data**

```bash
cd server && CONTEXT_BRIDGE_TOKEN=dev-token python3 context-digest.py --dry-run --hours 1 2>&1 | head -20
```

Expected: Digest runs without errors. No "Meetings" section appears if no meeting data exists.

---

## Task 8: Requirements Update

**Files:**
- Modify: `server/requirements.txt`

- [ ] **Step 1: Add anthropic to requirements.txt**

Add the following line:

```
anthropic>=0.40.0
```

- [ ] **Step 2: Verify install**

```bash
cd server && pip install anthropic 2>&1 | tail -3
```

Expected: anthropic package installs successfully.

---

## Task 9: Integration Test -- Full Flow

**Files:**
- Modify: `server/tests/test_meeting_endpoints.py`

- [ ] **Step 1: Add end-to-end integration test**

Add to `server/tests/test_meeting_endpoints.py`:

```python
class TestMeetingIntegration:
    """End-to-end integration tests."""

    def test_full_meeting_flow(self, client, auth_headers, temp_frames_dir):
        """Test: push session -> upload frames -> verify storage."""
        # 1. Push session
        session_payload = {
            'meeting_id': 'integration-test-001',
            'started_at': '2026-03-31T15:00:00Z',
            'ended_at': '2026-03-31T15:40:00Z',
            'duration_seconds': 2400,
            'app': 'Zoom',
            'participants': ['Jonas', 'David'],
            'transcript_json': [
                {'timestamp': 0, 'speaker': 'Jonas', 'text': 'Hello'},
                {'timestamp': 5, 'speaker': 'David', 'text': 'Hi there'},
            ],
        }
        resp = client.post(
            '/context/meeting/session',
            data=json.dumps(session_payload),
            headers=auth_headers,
        )
        assert resp.status_code == 201

        # 2. Upload frames
        resp = client.post(
            '/context/meeting/frames',
            data={
                'meeting_id': 'integration-test-001',
                'frames': [
                    (io.BytesIO(b'\x89PNG' + b'\x00' * 100), 'frame_000.png'),
                    (io.BytesIO(b'\x89PNG' + b'\x00' * 100), 'frame_030.png'),
                ],
            },
            headers={'Authorization': 'Bearer test-token-12345'},
            content_type='multipart/form-data',
        )
        assert resp.status_code == 201
        assert resp.get_json()['frames_saved'] == 2

        # 3. Verify frames on disk
        session_dir = temp_frames_dir / 'integration-test-001'
        assert session_dir.exists()
        assert len(list(session_dir.glob('*.png'))) == 2

        # 4. Verify health endpoint still works
        resp = client.get(
            '/context/health',
            headers=auth_headers,
        )
        assert resp.status_code == 200
```

- [ ] **Step 2: Run all tests**

```bash
cd server && python3 -m pytest tests/ -v --tb=short
```

Expected: All tests PASS.

---

## Task 10: Manual Testing Script

- [ ] **Step 1: Test the full flow manually with curl**

```bash
# Start the server (in a separate terminal)
cd server && CONTEXT_BRIDGE_TOKEN=dev-token python3 context-receiver.py

# 1. Push a meeting session
curl -X POST http://localhost:7890/context/meeting/session \
  -H "Authorization: Bearer dev-token" \
  -H "Content-Type: application/json" \
  -d '{
    "meeting_id": "2026-03-31-zoom-david-sonopeace",
    "started_at": "2026-03-31T15:00:00Z",
    "ended_at": "2026-03-31T15:40:00Z",
    "duration_seconds": 2400,
    "app": "Zoom",
    "participants": ["Jonas", "David Rotman", "Liz Chen"],
    "transcript_json": [
      {"timestamp": 0, "speaker": "speaker_1", "text": "Lets talk about pricing."},
      {"timestamp": 124, "speaker": "speaker_2", "text": "The total would be $50,000."},
      {"timestamp": 130, "speaker": "speaker_1", "text": "That seems high."}
    ],
    "visual_events_json": [
      {
        "timestamp": 124,
        "type": "visual",
        "trigger": "keyword_price",
        "frame_filename": "frame_124.png",
        "participants": [{"face_id": "face_001", "grid_position": "top-right"}]
      }
    ]
  }'

# Expected: 201 with meeting_id and purge_at

# 2. Upload frames (create a dummy PNG first)
printf '\x89PNG\r\n\x1a\n' > /tmp/frame_124.png
curl -X POST http://localhost:7890/context/meeting/frames \
  -H "Authorization: Bearer dev-token" \
  -F "meeting_id=2026-03-31-zoom-david-sonopeace" \
  -F "frames=@/tmp/frame_124.png"

# Expected: 201 with frames_saved=1

# 3. Test context request
curl -X POST http://localhost:7890/meeting/context-request \
  -H "Authorization: Bearer dev-token" \
  -H "Content-Type: application/json" \
  -d '{
    "meeting_id": "2026-03-31-zoom-david-sonopeace",
    "transcript_context": "David just asked about the CRM integration timeline",
    "topic": "CRM integration",
    "participants": ["Jonas", "David"]
  }'

# Expected: 200 with card and requests_remaining

# 4. Run meeting processor (requires ANTHROPIC_API_KEY for full analysis)
cd server && python3 meeting_processor.py \
  --meeting-id 2026-03-31-zoom-david-sonopeace

# 5. Check digest includes meeting
cd server && CONTEXT_BRIDGE_TOKEN=dev-token python3 context-digest.py \
  --dry-run --hours 24 2>&1 | grep -A5 "Meetings"
```

---

## Summary of Changes

| File | Change | Type |
|---|---|---|
| `server/context-receiver.py` | Add meeting tables to `init_db()`, extend `purge_old_data()`, add 3 new endpoints, increase MAX_CONTENT_LENGTH | Modified |
| `server/meeting_processor.py` | Full meeting processing pipeline: Claude Vision analysis, timeline merge, summary generation, participant profiles, pattern detection | New |
| `server/context-digest.py` | Add `get_recent_meetings()` and "Meetings" section to digest output | Modified |
| `server/requirements.txt` | Add `anthropic>=0.40.0` | Modified |
| `server/tests/conftest.py` | Shared pytest fixtures for test DB, test client, auth headers | New |
| `server/tests/test_meeting_endpoints.py` | Tests for all 3 endpoints + integration test | New |
| `server/tests/test_meeting_processor.py` | Tests for processing logic: timeline merge, summary generation, profile updates | New |

## Data Flow

```
claw-meeting (Mac)
  -> POST /context/meeting/session (final transcript + metadata)
  -> POST /context/meeting/frames (screenshots, batches of 10)

context-receiver.py
  -> stores in meeting_sessions table
  -> saves PNGs to data/meeting-frames/<session_id>/
  -> triggers meeting_processor.py async

meeting_processor.py
  -> Claude Vision on screenshots (expression classification)
  -> merge transcript + visual + expressions -> unified timeline
  -> Claude generates summary_md
  -> updates participant_profiles
  -> pattern detection for 3+ meeting participants

context-digest.py
  -> queries meeting_sessions
  -> adds "Meetings" section to digest output

purge_old_data()
  -> after 48h: NULLs transcript_json + visual_events_json
  -> after 48h: deletes screenshot files
  -> summary_md + participant_profiles persist permanently
```
