#!/usr/bin/env python3
"""
OpenClaw Context Bridge - Server Receiver
Accepts activity pushes from Mac daemon, stores in SQLite.
"""

import os
import sys
import json
import sqlite3
import logging
import hmac
from datetime import datetime, timedelta, timezone
from pathlib import Path
from flask import Flask, request, jsonify
from db_utils import get_db as _get_db, DB_PATH, is_encrypted

app = Flask(__name__)
logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
logger = logging.getLogger(__name__)

# --- Config ---
AUTH_TOKEN = os.environ.get('CONTEXT_BRIDGE_TOKEN', '').strip()
MAX_CONTENT_LENGTH = int(os.environ.get('CONTEXT_BRIDGE_MAX_CONTENT_LENGTH', '262144'))
PURGE_HOURS = 48
MEETING_FRAMES_DIR = Path(os.environ.get(
    'MEETING_FRAMES_DIR',
    str(Path(DB_PATH).parent / 'meeting-frames')
))
MEETING_MAX_CONTENT_LENGTH = int(os.environ.get('MEETING_MAX_CONTENT_LENGTH', '52428800'))  # 50MB

app.config['MAX_CONTENT_LENGTH'] = max(MAX_CONTENT_LENGTH, MEETING_MAX_CONTENT_LENGTH)

def get_db():
    """Get SQLite connection with WAL mode and optional encryption."""
    db = _get_db()
    db.row_factory = lambda cursor, row: {col[0]: row[idx] for idx, col in enumerate(cursor.description)}
    return db

def init_db():
    """Create tables if they don't exist."""
    Path(DB_PATH).parent.mkdir(parents=True, exist_ok=True)
    db = get_db()
    db.execute("""
        CREATE TABLE IF NOT EXISTS activity_stream (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts TEXT NOT NULL,
            app TEXT,
            window_title TEXT,
            url TEXT,
            file_path TEXT,
            git_repo TEXT,
            git_branch TEXT,
            terminal_cmds TEXT,
            notifications TEXT,
            all_tabs TEXT,
            clipboard TEXT,
            clipboard_changed INTEGER DEFAULT 0,
            file_changes TEXT,
            codex_session TEXT,
            codex_running INTEGER DEFAULT 0,
            whatsapp_context TEXT,
            idle_state TEXT DEFAULT 'active',
            idle_seconds INTEGER DEFAULT 0,
            in_call BOOLEAN DEFAULT 0,
            call_app TEXT,
            call_type TEXT,
            focus_mode TEXT,
            calendar_events TEXT,
            raw_payload TEXT,
            created_at TEXT DEFAULT (datetime('now'))
        )
    """)
    db.execute("""
        CREATE INDEX IF NOT EXISTS idx_activity_created 
        ON activity_stream(created_at)
    """)
    db.execute("""
        CREATE INDEX IF NOT EXISTS idx_activity_ts 
        ON activity_stream(ts)
    """)
    db.execute("""
        CREATE TABLE IF NOT EXISTS commits (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            repo TEXT NOT NULL,
            branch TEXT,
            message TEXT,
            diff_stat TEXT,
            ts TEXT NOT NULL,
            created_at TEXT DEFAULT (datetime('now'))
        )
    """)
    db.execute("""
        CREATE TABLE IF NOT EXISTS project_last_seen (
            project TEXT PRIMARY KEY,
            last_seen TEXT NOT NULL,
            last_branch TEXT
        )
    """)
    db.execute("""
        CREATE TABLE IF NOT EXISTS daily_summary (
            date TEXT NOT NULL,
            project TEXT NOT NULL,
            hours REAL NOT NULL,
            captures INTEGER NOT NULL,
            PRIMARY KEY (date, project)
        )
    """)
    db.execute("""
        CREATE TABLE IF NOT EXISTS jc_questions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            question TEXT NOT NULL,
            project TEXT,
            created_at TEXT DEFAULT (datetime('now')),
            seen INTEGER DEFAULT 0
        )
    """)
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
    try:
        db.execute("ALTER TABLE activity_stream ADD COLUMN whatsapp_messages TEXT")
    except Exception:
        pass  # Column already exists
    try:
        db.execute("ALTER TABLE participant_profiles ADD COLUMN last_seen TEXT")
    except Exception:
        pass  # Column already exists
    db.execute("""
        CREATE TABLE IF NOT EXISTS portfolio_projects (
            name TEXT PRIMARY KEY
        )
    """)
    db.commit()
    db.execute("UPDATE activity_stream SET clipboard = NULL WHERE clipboard IS NOT NULL")
    scrub_raw_payloads(db)
    db.commit()
    db.close()
    os.chmod(DB_PATH, 0o600)
    logger.info(f"Database initialized at {DB_PATH}")


def scrub_raw_payloads(db):
    """Remove clipboard content from stored payloads to match secure defaults."""
    rows = db.execute(
        "SELECT id, raw_payload FROM activity_stream WHERE raw_payload LIKE '%\"clipboard\"%'"
    ).fetchall()

    for row_id, raw_payload in rows:
        try:
            payload = json.loads(raw_payload)
        except (TypeError, json.JSONDecodeError):
            continue

        if isinstance(payload, dict) and 'clipboard' in payload:
            payload.pop('clipboard', None)
            db.execute(
                "UPDATE activity_stream SET raw_payload = ? WHERE id = ?",
                (json.dumps(payload), row_id)
            )

def purge_old_data():
    """Delete records older than PURGE_HOURS."""
    db = get_db()
    cutoff = (datetime.now(timezone.utc) - timedelta(hours=PURGE_HOURS)).isoformat()
    deleted_activity = db.execute(
        "DELETE FROM activity_stream WHERE created_at < ?", (cutoff,)
    ).rowcount
    deleted_commits = db.execute(
        "DELETE FROM commits WHERE created_at < ?", (cutoff,)
    ).rowcount

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

    db.commit()
    db.close()
    if deleted_activity or deleted_commits:
        logger.info(f"Purged {deleted_activity} activity rows, {deleted_commits} commit rows (older than {PURGE_HOURS}h)")

def verify_auth(req):
    """Check Bearer token."""
    auth = req.headers.get('Authorization', '')
    scheme, _, provided = auth.partition(' ')
    if scheme != 'Bearer' or not provided:
        return False
    return hmac.compare_digest(provided.strip(), AUTH_TOKEN)


def parse_json_request():
    """Parse JSON requests without forcing non-JSON bodies."""
    if not request.is_json:
        return None, (jsonify({'error': 'content type must be application/json'}), 415)

    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return None, (jsonify({'error': 'invalid json'}), 400)

    return data, None


def sanitize_activity_payload(data):
    """Drop sensitive fields and normalize activity payloads before storage."""
    sanitized = {
        'ts': data.get('ts'),
        'app': data.get('app'),
        'window_title': data.get('window_title'),
        'url': data.get('url'),
        'file_path': data.get('file_path'),
        'git_repo': data.get('git_repo'),
        'git_branch': data.get('git_branch'),
        'terminal_cmds': data.get('terminal_cmds'),
        'all_tabs': data.get('all_tabs'),
        'clipboard_changed': bool(data.get('clipboard_changed')),
        'file_changes': data.get('file_changes'),
        'codex_session': data.get('codex_session'),
        'codex_running': bool(data.get('codex_running')),
        'whatsapp_context': data.get('whatsapp_context'),
        'idle_state': data.get('idle_state', 'active'),
    }

    try:
        sanitized['idle_seconds'] = int(data.get('idle_seconds', 0) or 0)
    except (TypeError, ValueError):
        sanitized['idle_seconds'] = 0

    sanitized['notifications'] = data.get('notifications', '')
    sanitized['in_call'] = bool(data.get('in_call', False))
    sanitized['call_app'] = str(data.get('call_app', ''))[:100]
    sanitized['call_type'] = str(data.get('call_type', ''))[:20]
    sanitized['focus_mode'] = data.get('focus_mode') or None
    sanitized['calendar_events'] = data.get('calendar_events', '')
    sanitized['whatsapp_messages'] = json.dumps(data.get('whatsapp_messages', [])) if data.get('whatsapp_messages') else None

    return sanitized

@app.route('/context/push', methods=['POST'])
def push_activity():
    """Receive activity data from Mac daemon."""
    if not verify_auth(request):
        return jsonify({'error': 'unauthorized'}), 401

    data, error = parse_json_request()
    if error:
        return error

    if 'ts' not in data:
        return jsonify({'error': 'missing ts field'}), 400

    sanitized = sanitize_activity_payload(data)

    log_safe = dict(sanitized)
    if log_safe.get('whatsapp_messages'):
        try:
            msgs = json.loads(log_safe['whatsapp_messages'])
            log_safe['whatsapp_messages'] = f"[{len(msgs)} messages]"
        except Exception:
            pass

    db = get_db()
    db.execute("""
        INSERT INTO activity_stream
        (ts, app, window_title, url, file_path, git_repo, git_branch,
         terminal_cmds, notifications, all_tabs, clipboard, clipboard_changed, file_changes,
         codex_session, codex_running, whatsapp_context,
         idle_state, idle_seconds, in_call, call_app, call_type, focus_mode, calendar_events,
         whatsapp_messages, raw_payload)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (
        sanitized['ts'],
        sanitized['app'],
        sanitized['window_title'],
        sanitized['url'],
        sanitized['file_path'],
        sanitized['git_repo'],
        sanitized['git_branch'],
        json.dumps(sanitized['terminal_cmds']) if sanitized['terminal_cmds'] else None,
        sanitized.get('notifications', ''),
        sanitized['all_tabs'],
        None,
        1 if sanitized['clipboard_changed'] else 0,
        sanitized['file_changes'],
        sanitized['codex_session'],
        1 if sanitized['codex_running'] else 0,
        sanitized['whatsapp_context'],
        sanitized['idle_state'],
        sanitized['idle_seconds'],
        1 if sanitized.get('in_call') else 0,
        sanitized.get('call_app', ''),
        sanitized.get('call_type', ''),
        sanitized.get('focus_mode'),
        sanitized.get('calendar_events', ''),
        sanitized.get('whatsapp_messages'),
        json.dumps(sanitized)
    ))
    db.commit()
    db.close()

    return jsonify({'status': 'ok'}), 201

@app.route('/context/commit', methods=['POST'])
def push_commit():
    """Receive git commit data from post-commit hooks."""
    if not verify_auth(request):
        return jsonify({'error': 'unauthorized'}), 401

    data, error = parse_json_request()
    if error:
        return error

    db = get_db()
    db.execute("""
        INSERT INTO commits (repo, branch, message, diff_stat, ts)
        VALUES (?, ?, ?, ?, ?)
    """, (
        data.get('repo'),
        data.get('branch'),
        data.get('message'),
        data.get('diff_stat'),
        data.get('timestamp', datetime.now(timezone.utc).isoformat())
    ))
    db.commit()
    db.close()

    return jsonify({'status': 'ok'}), 201

@app.route('/context/handoff', methods=['POST'])
def handoff():
    """Receive explicit task handoff from the operator.

    The operator sends: /handoff project-gamma p0-6
    Telegram bot (or direct POST) converts to API call.
    The agent reads handoffs and picks up the task.
    """
    if not verify_auth(request):
        return jsonify({'error': 'unauthorized'}), 401

    data, error = parse_json_request()
    if error:
        return error

    priority = data.get('priority', 'normal')
    if priority not in ('normal', 'high', 'urgent'):
        priority = 'normal'

    db = get_db()
    db.execute("""
        CREATE TABLE IF NOT EXISTS handoffs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            project TEXT NOT NULL,
            task TEXT,
            message TEXT,
            priority TEXT DEFAULT 'normal',
            status TEXT DEFAULT 'pending',
            created_at TEXT DEFAULT (datetime('now'))
        )
    """)
    db.execute("""
        INSERT INTO handoffs (project, task, message, priority)
        VALUES (?, ?, ?, ?)
    """, (
        data.get('project', ''),
        data.get('task', ''),
        data.get('message', ''),
        priority,
    ))
    db.commit()
    handoff_id = db.execute("SELECT last_insert_rowid()").fetchone()
    hid = list(handoff_id.values())[0] if handoff_id else '?'
    db.close()

    # Webhook: immediately notify JC's active session via Telegram
    _notify_handoff(hid, data.get('project', ''), data.get('task', ''), data.get('message', ''), priority)

    return jsonify({'status': 'ok', 'id': hid, 'message': f"Handoff received: {data.get('project')} - {data.get('task')}"}), 201


def _notify_handoff(hid, project, task, message, priority):
    """Fire-and-forget notification to JC's Telegram session."""
    import subprocess, threading

    prio_flag = "🔴 URGENT: " if priority in ('urgent', 'high') else ""
    text = f"📋 HANDOFF #{hid}: {prio_flag}[{project}] {task}"
    if message:
        text += f"\nContext: {message}"
    text += "\n\nExecute this now."

    def _send():
        try:
            subprocess.run(
                ['/home/linuxbrew/.linuxbrew/bin/openclaw', 'message', 'send',
                 '--channel', 'telegram',
                 '--target', '-1003550009817',
                 '--thread-id', '1',
                 '-m', text],
                capture_output=True, text=True, timeout=15
            )
        except Exception:
            pass

    # Run async so the API response isn't delayed
    threading.Thread(target=_send, daemon=True).start()


@app.route('/context/handoffs', methods=['GET'])
def list_handoffs():
    """List recent handoffs with status."""
    if not verify_auth(request):
        return jsonify({'error': 'unauthorized'}), 401

    db = get_db()
    db.execute("""
        CREATE TABLE IF NOT EXISTS handoffs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            project TEXT NOT NULL,
            task TEXT,
            message TEXT,
            priority TEXT DEFAULT 'normal',
            status TEXT DEFAULT 'pending',
            created_at TEXT DEFAULT (datetime('now'))
        )
    """)
    rows = db.execute(
        "SELECT id, project, task, message, priority, status, created_at FROM handoffs ORDER BY created_at DESC LIMIT 50"
    ).fetchall()
    db.close()

    return jsonify([
        {
            'id': r['id'],
            'project': r['project'],
            'task': r['task'],
            'message': r['message'] or '',
            'priority': r['priority'] or 'normal',
            'status': r['status'] or 'pending',
            'created_at': r['created_at'],
        }
        for r in rows
    ])


@app.route('/context/handoffs/<int:handoff_id>', methods=['PATCH'])
def update_handoff(handoff_id):
    """The agent updates handoff status."""
    if not verify_auth(request):
        return jsonify({'error': 'unauthorized'}), 401

    data, error = parse_json_request()
    if error:
        return error

    new_status = data.get('status', '')
    if new_status not in ('in-progress', 'done'):
        return jsonify({'error': 'invalid status, must be in-progress or done'}), 400

    db = get_db()
    row = db.execute("SELECT status FROM handoffs WHERE id = ?", (handoff_id,)).fetchone()
    if not row:
        db.close()
        return jsonify({'error': 'handoff not found'}), 404

    current = row['status']
    valid_transitions = {
        'pending': ('in-progress', 'done'),
        'in-progress': ('done',),
    }
    if new_status not in valid_transitions.get(current, ()):
        db.close()
        return jsonify({'error': f'invalid status transition from {current} to {new_status}'}), 400

    db.execute("UPDATE handoffs SET status = ? WHERE id = ?", (new_status, handoff_id))
    db.commit()
    db.close()

    return jsonify({'status': 'ok', 'handoff_id': handoff_id, 'new_status': new_status})


@app.route('/context/health', methods=['GET'])
def health():
    """Health check endpoint - also used for capture verification."""
    if not verify_auth(request):
        return jsonify({'error': 'unauthorized'}), 401

    try:
        db = get_db()
        count = db.execute("SELECT COUNT(*) as cnt FROM activity_stream").fetchone()['cnt']
        latest = db.execute(
            "SELECT ts FROM activity_stream ORDER BY id DESC LIMIT 1"
        ).fetchone()
        
        # Check if captures are arriving (last 10 minutes)
        recent = db.execute(
            "SELECT COUNT(*) as cnt FROM activity_stream WHERE created_at > datetime('now', '-10 minutes')"
        ).fetchone()['cnt']
        
        # Check if captures are stale (nothing in last 15 minutes while not idle)
        last_active = db.execute(
            "SELECT ts, idle_state FROM activity_stream ORDER BY id DESC LIMIT 1"
        ).fetchone()
        
        capture_status = 'healthy'
        if recent == 0 and count > 0:
            if last_active and dict(last_active).get('idle_state') in ('locked', 'away'):
                capture_status = 'mac_idle'
            else:
                capture_status = 'stale'  # daemon may have stopped
        elif count == 0:
            capture_status = 'no_data'
        
        db.close()
        return jsonify({
            'status': 'ok',
            'capture_status': capture_status,
            'total_rows': count,
            'recent_captures_10min': recent,
            'latest_activity': dict(latest).get('ts') if latest else None,
            'latest_idle_state': dict(last_active).get('idle_state') if last_active else None,
            'db_encrypted': is_encrypted(),
        })
    except Exception:
        logger.exception("Health check failed")
        return jsonify({'status': 'error'}), 500


@app.route("/context/projects", methods=["GET"])
def get_projects():
    if not verify_auth(request):
        return jsonify({'error': 'unauthorized'}), 401

    try:
        db = get_db()
        rows = db.execute(
            "SELECT name FROM portfolio_projects ORDER BY name ASC"
        ).fetchall()
        db.close()
        return jsonify({"projects": [r["name"] for r in rows]})
    except Exception:
        return jsonify({"error": "Internal error"}), 500


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


@app.route('/context/jc-work-log', methods=['GET'])
def jc_work_log():
    """Agent work log - readable by ClawRelay app."""
    if not verify_auth(request):
        return jsonify({'error': 'unauthorized'}), 401
    
    try:
        db = get_db()
        # Check if table exists
        tables = [list(r.values())[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()]
        if 'jc_work_log' not in tables:
            db.close()
            return jsonify({'entries': [], 'total': 0})
        
        # Get recent entries (last 48h by default, or use ?hours= param)
        hours = request.args.get('hours', 48, type=int)
        from datetime import datetime, timedelta, timezone
        since = (datetime.now(timezone.utc) - timedelta(hours=hours)).isoformat()
        
        rows = db.execute(
            "SELECT * FROM jc_work_log WHERE started_at >= ? ORDER BY started_at DESC",
            (since,)
        ).fetchall()
        db.close()
        
        entries = []
        for r in rows:
            entries.append({
                'id': dict(r).get('id'),
                'project': r.get('project'),
                'description': r.get('description'),
                'status': r.get('status'),
                'result': r[4],
                'started_at': r.get('started_at'),
                'completed_at': r.get('completed_at'),
                'duration_minutes': r.get('duration_minutes'),
            })
        
        return jsonify({'entries': entries, 'total': len(entries)})
    except Exception:
        logger.exception("Agent work log query failed")
        return jsonify({'error': 'internal error'}), 500


@app.route('/context/jc-question', methods=['POST'])
def post_jc_question():
    """The agent posts a question for the operator."""
    if not verify_auth(request):
        return jsonify({'error': 'unauthorized'}), 401
    data, error = parse_json_request()
    if error:
        return error
    db = get_db()
    db.execute("""CREATE TABLE IF NOT EXISTS jc_questions (
        id INTEGER PRIMARY KEY AUTOINCREMENT, question TEXT NOT NULL,
        project TEXT, created_at TEXT DEFAULT (datetime('now')), seen INTEGER DEFAULT 0)""")
    db.execute("INSERT INTO jc_questions (question, project) VALUES (?, ?)",
               (data.get('question', ''), data.get('project', '')))
    db.commit()
    db.close()
    return jsonify({'status': 'ok'}), 201


@app.route('/context/jc-question/<int:qid>', methods=['PATCH'])
def mark_jc_question(qid):
    """ClawRelay marks a question as seen by the operator."""
    if not verify_auth(request):
        return jsonify({'error': 'unauthorized'}), 401
    db = get_db()
    db.execute("UPDATE jc_questions SET seen = 1 WHERE id = ?", (qid,))
    db.commit()
    db.close()
    return jsonify({'status': 'ok'})


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


@app.route('/context/dashboard', methods=['GET'])
def dashboard():
    """Combined dashboard data for ClawRelay app."""
    if not verify_auth(request):
        return jsonify({'error': 'unauthorized'}), 401

    try:
        db = get_db()
        from config import PORTFOLIO_PROJECTS, ALL_PROJECTS, NOISE_APPS

        # --- Status (latest row) ---
        latest = db.execute(
            "SELECT * FROM activity_stream ORDER BY ts DESC LIMIT 1"
        ).fetchone()

        status = {
            'current_app': 'unknown',
            'current_project': 'unknown',
            'idle_state': 'unknown',
            'idle_seconds': 0,
            'in_call': False,
            'focus_mode': None,
            'focus_level': 'unknown',
            'focus_switches_per_hour': 0.0,
            'daemon_stale': False,
            'last_activity': None,
        }

        if latest:
            latest = dict(latest)  # convert Row to dict for .get() access
            status['current_app'] = latest.get('app') or 'unknown'
            status['idle_state'] = latest.get('idle_state') or 'unknown'
            status['idle_seconds'] = latest.get('idle_seconds') or 0
            status['in_call'] = bool(latest.get('in_call', 0))
            status['focus_mode'] = latest.get('focus_mode') or None
            status['last_activity'] = latest.get('ts')

            # Infer project
            haystack = f"{latest.get('window_title', '')} {latest.get('git_repo', '')} {latest.get('url', '')} {latest.get('file_path', '')} {latest.get('all_tabs', '')}".lower()
            for proj, keywords in ALL_PROJECTS.items():
                if any(kw in haystack for kw in keywords):
                    status['current_project'] = proj
                    break

            # Staleness check: stale if last activity is older than 5 minutes
            try:
                last_ts = datetime.fromisoformat(latest.get('ts', '').replace('Z', '+00:00'))
                age_seconds = (datetime.now(timezone.utc) - last_ts).total_seconds()
                status['daemon_stale'] = age_seconds > 300
            except (ValueError, TypeError):
                status['daemon_stale'] = True

            # Focus level (last 60 min)
            since_1h = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
            recent = db.execute(
                "SELECT app, window_title, git_repo, url, file_path, all_tabs FROM activity_stream WHERE ts >= ? AND idle_state = 'active' ORDER BY ts",
                (since_1h,)
            ).fetchall()

            switches = 0
            prev_ctx = None
            for r in recent:
                r = dict(r)  # convert Row to dict
                h = f"{r.get('window_title', '')} {r.get('git_repo', '')} {r.get('url', '')} {r.get('file_path', '')} {r.get('all_tabs', '')}".lower()
                proj = 'other'
                for p, kws in ALL_PROJECTS.items():
                    if any(kw in h for kw in kws):
                        proj = p
                        break
                ctx = (r['app'], proj)
                if prev_ctx and ctx != prev_ctx:
                    switches += 1
                prev_ctx = ctx

            status['focus_switches_per_hour'] = round(switches, 1)
            if switches <= 3:
                status['focus_level'] = 'focused'
            elif switches <= 7:
                status['focus_level'] = 'multitasking'
            else:
                status['focus_level'] = 'scattered'

        # --- Time allocation (today) ---
        today_start = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0).isoformat()
        today_rows = db.execute(
            "SELECT window_title, git_repo, url, file_path, all_tabs FROM activity_stream WHERE ts >= ? AND idle_state = 'active'",
            (today_start,)
        ).fetchall()

        project_counts = {}
        for r in today_rows:
            r = dict(r)
            h = f"{r.get('window_title', '')} {r.get('git_repo', '')} {r.get('url', '')} {r.get('file_path', '')} {r.get('all_tabs', '')}".lower()
            matched = 'other'
            for p, kws in ALL_PROJECTS.items():
                if any(kw in h for kw in kws):
                    matched = p
                    break
            project_counts[matched] = project_counts.get(matched, 0) + 1

        total_captures = sum(project_counts.values())
        time_allocation = []
        for proj, count in sorted(project_counts.items(), key=lambda x: -x[1]):
            if proj == 'other':
                continue
            hours = round(count * 2 / 60, 1)
            pct = round(count / total_captures * 100) if total_captures else 0
            time_allocation.append({'project': proj, 'hours': hours, 'percentage': pct})

        # --- Neglected projects ---
        neglected = []
        try:
            last_seen_rows = db.execute("SELECT project, last_seen FROM project_last_seen").fetchall()
            last_seen = {}
            for r in last_seen_rows:
                ls_proj = r.get('id') if isinstance(r, (list, tuple)) else r['project']
                ls_ts = r.get('project') if isinstance(r, (list, tuple)) else r['last_seen']
                last_seen[ls_proj] = ls_ts
        except Exception:
            last_seen = {}

        # Bootstrap: scan raw activity_stream (last 48h) for more recent data
        try:
            raw_since = (datetime.now(timezone.utc) - timedelta(hours=48)).isoformat()
            raw_rows = db.execute(
                "SELECT window_title, git_repo, url, file_path, MAX(ts) as latest FROM activity_stream WHERE ts >= ? AND idle_state = 'active' GROUP BY window_title, git_repo",
                (raw_since,)
            ).fetchall()
            for r in raw_rows:
                wt = r.get('id') if isinstance(r, (list, tuple)) else r['window_title']
                gr = r.get('project') if isinstance(r, (list, tuple)) else r['git_repo']
                u = r.get('description') if isinstance(r, (list, tuple)) else r['url']
                fp = r.get('status') if isinstance(r, (list, tuple)) else r['file_path']
                lt = r[4] if isinstance(r, (list, tuple)) else r['latest']
                h = f"{wt} {gr} {u} {fp}".lower()
                for p, kws in PORTFOLIO_PROJECTS.items():
                    if any(kw in h for kw in kws):
                        if p not in last_seen or lt > last_seen.get(p, ''):
                            last_seen[p] = lt
                            try:
                                db.execute(
                                    "INSERT INTO project_last_seen (project, last_seen, last_branch) VALUES (?, ?, '') ON CONFLICT(project) DO UPDATE SET last_seen = excluded.last_seen",
                                    (p, lt)
                                )
                            except Exception:
                                pass
                        break
            db.commit()
        except Exception:
            pass

        for p in PORTFOLIO_PROJECTS:
            if p in last_seen:
                try:
                    ls = datetime.fromisoformat(last_seen[p]).replace(tzinfo=timezone.utc)
                    days = (datetime.now(timezone.utc) - ls).days
                except Exception:
                    days = 999
            else:
                days = 999
            neglected.append({'project': p, 'days': days})
        neglected.sort(key=lambda x: -x['days'])

        # --- Agent activity ---
        jc_activity = []
        try:
            tables = [list(r.values())[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()]
            if 'jc_work_log' in tables:
                jc_since = (datetime.now(timezone.utc) - timedelta(hours=48)).isoformat()
                jc_rows = db.execute(
                    "SELECT * FROM jc_work_log WHERE started_at >= ? ORDER BY started_at DESC LIMIT 10",
                    (jc_since,)
                ).fetchall()
                for r in jc_rows:
                    r = dict(r)
                    jc_activity.append({
                        'id': r.get('id'),
                        'project': r.get('project'),
                        'description': r.get('description'),
                        'status': r.get('status'),
                        'started_at': r.get('started_at'),
                        'completed_at': r.get('completed_at'),
                        'duration_minutes': r.get('duration_minutes'),
                    })
        except Exception:
            pass

        # --- Handoffs ---
        handoffs = []
        try:
            h_rows = db.execute(
                "SELECT id, project, task, message, priority, status, created_at FROM handoffs ORDER BY created_at DESC LIMIT 10"
            ).fetchall()
            for r in h_rows:
                r = dict(r)
                handoffs.append({
                    'id': r.get('id'),
                    'project': r.get('project'),
                    'task': r.get('task'),
                    'message': r.get('message') or '',
                    'priority': r.get('priority') or 'normal',
                    'status': r.get('status') or 'pending',
                    'created_at': r.get('created_at'),
                })
        except Exception:
            pass

        # --- Agent Questions (unseen) ---
        jc_questions = []
        try:
            tables = [list(r.values())[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()]
            if 'jc_questions' in tables:
                q_rows = db.execute(
                    "SELECT id, question, project, created_at FROM jc_questions WHERE seen = 0 ORDER BY created_at DESC LIMIT 10"
                ).fetchall()
                for r in q_rows:
                    jc_questions.append({
                        'id': r.get('id') if isinstance(r, (list, tuple)) else r['id'],
                        'question': r.get('project') if isinstance(r, (list, tuple)) else r['question'],
                        'project': r.get('description') if isinstance(r, (list, tuple)) else r['project'],
                        'created_at': r.get('status') if isinstance(r, (list, tuple)) else r['created_at'],
                    })
        except Exception:
            pass

        # --- Historical data (daily_summary) ---
        history_days = request.args.get('history_days', 7, type=int)
        history_days = min(history_days, 30)
        history = []
        try:
            if 'daily_summary' in tables:
                history_since = (datetime.now(timezone.utc) - timedelta(days=history_days)).strftime('%Y-%m-%d')
                h_rows = db.execute(
                    "SELECT date, project, hours FROM daily_summary WHERE date >= ? ORDER BY date DESC",
                    (history_since,)
                ).fetchall()
                for r in h_rows:
                    history.append({
                        'date': r.get('id') if isinstance(r, (list, tuple)) else r['date'],
                        'project': r.get('project') if isinstance(r, (list, tuple)) else r['project'],
                        'hours': r.get('description') if isinstance(r, (list, tuple)) else r['hours'],
                    })

            # Supplement today from live data
            today_str = datetime.now(timezone.utc).strftime('%Y-%m-%d')
            for ta in time_allocation:
                if not any(h['date'] == today_str and h['project'] == ta['project'] for h in history):
                    history.append({'date': today_str, 'project': ta['project'], 'hours': ta['hours']})
                try:
                    captures = project_counts.get(ta['project'], 0)
                    db.execute(
                        "INSERT OR REPLACE INTO daily_summary (date, project, hours, captures) VALUES (?, ?, ?, ?)",
                        (today_str, ta['project'], ta['hours'], captures)
                    )
                except Exception:
                    pass
            db.commit()
        except Exception:
            pass

        db.close()

        return jsonify({
            'status': status,
            'time_allocation': time_allocation,
            'neglected': neglected,
            'jc_activity': jc_activity,
            'handoffs': handoffs,
            'jc_questions': jc_questions,
            'history': history,
        })
    except Exception:
        logger.exception("Dashboard query failed")
        return jsonify({'error': 'internal error'}), 500


@app.errorhandler(413)
def payload_too_large(_error):
    return jsonify({'error': 'payload too large'}), 413

@app.before_request
def before_request():
    """Purge old data periodically (every ~100 requests)."""
    import random
    if random.random() < 0.01:
        purge_old_data()


def configure_app():
    """Validate runtime security configuration and initialize storage."""
    if not AUTH_TOKEN:
        raise RuntimeError(
            "CONTEXT_BRIDGE_TOKEN must be set; refusing to start without authenticated writes"
        )

    init_db()


configure_app()

if __name__ == '__main__':
    port = int(os.environ.get('CONTEXT_BRIDGE_PORT', 7890))
    logger.info(f"Context Bridge receiver starting on port {port}")
    app.run(host='0.0.0.0', port=port, debug=False)
