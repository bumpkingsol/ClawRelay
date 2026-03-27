#!/usr/bin/env python3
"""
OpenClaw Context Bridge - Server Receiver
Accepts activity pushes from Mac daemon, stores in SQLite.
"""

import os
import json
import sqlite3
import logging
import hmac
from datetime import datetime, timedelta, timezone
from pathlib import Path
from flask import Flask, request, jsonify

app = Flask(__name__)
logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
logger = logging.getLogger(__name__)

# --- Config ---
DB_PATH = os.environ.get('CONTEXT_BRIDGE_DB', '/home/admin/clawd/data/context-bridge.db')
AUTH_TOKEN = os.environ.get('CONTEXT_BRIDGE_TOKEN', '').strip()
MAX_CONTENT_LENGTH = int(os.environ.get('CONTEXT_BRIDGE_MAX_CONTENT_LENGTH', '262144'))
PURGE_HOURS = 48

app.config['MAX_CONTENT_LENGTH'] = MAX_CONTENT_LENGTH

def get_db():
    """Get SQLite connection with WAL mode for concurrent reads."""
    db = sqlite3.connect(DB_PATH)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA busy_timeout=5000")
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
            notification_app TEXT,
            notification_text TEXT,
            all_tabs TEXT,
            clipboard TEXT,
            clipboard_changed INTEGER DEFAULT 0,
            file_changes TEXT,
            codex_session TEXT,
            codex_running INTEGER DEFAULT 0,
            whatsapp_context TEXT,
            idle_state TEXT DEFAULT 'active',
            idle_seconds INTEGER DEFAULT 0,
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
        'notifications': data.get('notifications'),
        'idle_state': data.get('idle_state', 'active'),
    }

    try:
        sanitized['idle_seconds'] = int(data.get('idle_seconds', 0) or 0)
    except (TypeError, ValueError):
        sanitized['idle_seconds'] = 0

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

    db = get_db()
    db.execute("""
        INSERT INTO activity_stream 
        (ts, app, window_title, url, file_path, git_repo, git_branch, 
         terminal_cmds, all_tabs, clipboard, clipboard_changed, file_changes,
         codex_session, codex_running, whatsapp_context,
         idle_state, idle_seconds, raw_payload)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (
        sanitized['ts'],
        sanitized['app'],
        sanitized['window_title'],
        sanitized['url'],
        sanitized['file_path'],
        sanitized['git_repo'],
        sanitized['git_branch'],
        json.dumps(sanitized['terminal_cmds']) if sanitized['terminal_cmds'] else None,
        sanitized['all_tabs'],
        None,
        1 if sanitized['clipboard_changed'] else 0,
        sanitized['file_changes'],
        sanitized['codex_session'],
        1 if sanitized['codex_running'] else 0,
        sanitized['whatsapp_context'],
        sanitized['idle_state'],
        sanitized['idle_seconds'],
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
    """Receive explicit task handoff from Jonas.
    
    Jonas sends: /handoff prescrivia p0-6
    Telegram bot (or direct POST) converts to API call.
    JC reads handoffs and picks up the task.
    """
    if not verify_auth(request):
        return jsonify({'error': 'unauthorized'}), 401

    data, error = parse_json_request()
    if error:
        return error

    db = get_db()
    db.execute("""
        CREATE TABLE IF NOT EXISTS handoffs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            project TEXT NOT NULL,
            task TEXT,
            message TEXT,
            status TEXT DEFAULT 'pending',
            created_at TEXT DEFAULT (datetime('now'))
        )
    """)
    db.execute("""
        INSERT INTO handoffs (project, task, message)
        VALUES (?, ?, ?)
    """, (
        data.get('project', ''),
        data.get('task', ''),
        data.get('message', '')
    ))
    db.commit()
    db.close()

    return jsonify({'status': 'ok', 'message': f"Handoff received: {data.get('project')} - {data.get('task')}"}), 201


@app.route('/context/health', methods=['GET'])
def health():
    """Health check endpoint - also used for capture verification."""
    if not verify_auth(request):
        return jsonify({'error': 'unauthorized'}), 401

    try:
        db = get_db()
        count = db.execute("SELECT COUNT(*) FROM activity_stream").fetchone()[0]
        latest = db.execute(
            "SELECT ts FROM activity_stream ORDER BY id DESC LIMIT 1"
        ).fetchone()
        
        # Check if captures are arriving (last 10 minutes)
        recent = db.execute(
            "SELECT COUNT(*) FROM activity_stream WHERE created_at > datetime('now', '-10 minutes')"
        ).fetchone()[0]
        
        # Check if captures are stale (nothing in last 15 minutes while not idle)
        last_active = db.execute(
            "SELECT ts, idle_state FROM activity_stream ORDER BY id DESC LIMIT 1"
        ).fetchone()
        
        capture_status = 'healthy'
        if recent == 0 and count > 0:
            if last_active and last_active[1] in ('locked', 'away'):
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
            'latest_activity': latest[0] if latest else None,
            'latest_idle_state': last_active[1] if last_active else None
        })
    except Exception:
        logger.exception("Health check failed")
        return jsonify({'status': 'error'}), 500


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
