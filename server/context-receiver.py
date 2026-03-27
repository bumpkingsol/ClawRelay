#!/usr/bin/env python3
"""
OpenClaw Context Bridge - Server Receiver
Accepts activity pushes from Mac daemon, stores in SQLite.
"""

import os
import json
import sqlite3
import logging
from datetime import datetime, timedelta, timezone
from pathlib import Path
from flask import Flask, request, jsonify

app = Flask(__name__)
logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
logger = logging.getLogger(__name__)

# --- Config ---
DB_PATH = os.environ.get('CONTEXT_BRIDGE_DB', '/home/user/clawrelay/data/context-bridge.db')
AUTH_TOKEN = os.environ.get('CONTEXT_BRIDGE_TOKEN', '')
PURGE_HOURS = 48

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
    db.close()
    os.chmod(DB_PATH, 0o600)
    logger.info(f"Database initialized at {DB_PATH}")

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
    if not AUTH_TOKEN:
        logger.warning("No AUTH_TOKEN configured - accepting all requests")
        return True
    auth = req.headers.get('Authorization', '')
    return auth == f'Bearer {AUTH_TOKEN}'

@app.route('/context/push', methods=['POST'])
def push_activity():
    """Receive activity data from Mac daemon."""
    if not verify_auth(request):
        return jsonify({'error': 'unauthorized'}), 401
    
    try:
        data = request.get_json(force=True)
    except Exception:
        return jsonify({'error': 'invalid json'}), 400
    
    if not data or 'ts' not in data:
        return jsonify({'error': 'missing ts field'}), 400
    
    db = get_db()
    db.execute("""
        INSERT INTO activity_stream 
        (ts, app, window_title, url, file_path, git_repo, git_branch, 
         terminal_cmds, all_tabs, idle_state, idle_seconds, raw_payload)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (
        data.get('ts'),
        data.get('app'),
        data.get('window_title'),
        data.get('url'),
        data.get('file_path'),
        data.get('git_repo'),
        data.get('git_branch'),
        json.dumps(data.get('terminal_cmds', '')) if data.get('terminal_cmds') else None,
        data.get('all_tabs'),
        data.get('idle_state', 'active'),
        data.get('idle_seconds', 0),
        json.dumps(data)
    ))
    db.commit()
    db.close()
    
    return jsonify({'status': 'ok'}), 201

@app.route('/context/commit', methods=['POST'])
def push_commit():
    """Receive git commit data from post-commit hooks."""
    if not verify_auth(request):
        return jsonify({'error': 'unauthorized'}), 401
    
    try:
        data = request.get_json(force=True)
    except Exception:
        return jsonify({'error': 'invalid json'}), 400
    
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

@app.route('/context/health', methods=['GET'])
def health():
    """Health check endpoint - also used for capture verification."""
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
    except Exception as e:
        return jsonify({'status': 'error', 'detail': str(e)}), 500

@app.before_request
def before_request():
    """Purge old data periodically (every ~100 requests)."""
    import random
    if random.random() < 0.01:
        purge_old_data()

if __name__ == '__main__':
    init_db()
    port = int(os.environ.get('CONTEXT_BRIDGE_PORT', 7890))
    logger.info(f"Context Bridge receiver starting on port {port}")
    app.run(host='0.0.0.0', port=port, debug=False)
