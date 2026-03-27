#!/usr/bin/env python3
"""
OpenClaw Context Bridge - Watchdog
Checks if Mac daemon is sending data. Alerts if captures go stale.
Run periodically via cron (every 15 minutes).
"""

import os
import sys
import json
import sqlite3
from datetime import datetime, timedelta, timezone

DB_PATH = os.environ.get('CONTEXT_BRIDGE_DB', '/home/user/clawrelay/data/context-bridge.db')
STALE_MINUTES = 15  # Alert if no captures for this long (and not idle/away)


def check():
    if not os.path.exists(DB_PATH):
        return {'status': 'error', 'message': 'No database found. Receiver may not be running.'}
    
    db = sqlite3.connect(DB_PATH)
    db.row_factory = sqlite3.Row
    
    # Get latest capture
    latest = db.execute(
        "SELECT * FROM activity_stream ORDER BY id DESC LIMIT 1"
    ).fetchone()
    
    if not latest:
        return {'status': 'warning', 'message': 'No captures in database. Mac daemon may not be installed.'}
    
    # Parse latest timestamp
    latest_ts = latest['ts']
    try:
        latest_dt = datetime.fromisoformat(latest_ts.replace('Z', '+00:00'))
    except ValueError:
        latest_dt = datetime.now(timezone.utc) - timedelta(hours=1)  # assume old
    
    age_minutes = (datetime.now(timezone.utc) - latest_dt).total_seconds() / 60
    idle_state = latest['idle_state']
    
    # If Jonas is idle/away/locked, no alert needed
    if idle_state in ('idle', 'away', 'locked'):
        return {
            'status': 'ok',
            'message': f'Mac is {idle_state}. Last capture {age_minutes:.0f} min ago.',
            'idle_state': idle_state,
            'age_minutes': round(age_minutes)
        }
    
    # If active but captures are stale
    if age_minutes > STALE_MINUTES:
        return {
            'status': 'stale',
            'message': f'No captures for {age_minutes:.0f} minutes. Daemon may have stopped.',
            'last_capture': latest_ts,
            'age_minutes': round(age_minutes),
            'action': 'Check Mac daemon: launchctl list | grep context-bridge'
        }
    
    # Healthy
    recent_count = db.execute(
        "SELECT COUNT(*) as cnt FROM activity_stream WHERE created_at > datetime('now', '-1 hour')"
    ).fetchone()['cnt']
    
    db.close()
    
    return {
        'status': 'healthy',
        'message': f'Daemon active. {recent_count} captures in last hour. Latest: {age_minutes:.0f} min ago.',
        'captures_last_hour': recent_count,
        'age_minutes': round(age_minutes)
    }


def main():
    result = check()
    
    if '--json' in sys.argv:
        print(json.dumps(result, indent=2))
    else:
        status_icon = {'healthy': '✅', 'ok': '✅', 'stale': '🔴', 'warning': '⚠️', 'error': '❌'}.get(result['status'], '❓')
        print(f"{status_icon} {result['message']}")
        if result.get('action'):
            print(f"   Action: {result['action']}")
    
    # Exit code for cron/monitoring
    if result['status'] in ('stale', 'error'):
        sys.exit(1)
    sys.exit(0)


if __name__ == '__main__':
    main()
