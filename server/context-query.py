#!/usr/bin/env python3
"""
OpenClaw Context Bridge - Query Tool
CLI for JC to check what Jonas is doing / has done.
"""

import os
import sys
import json
import sqlite3
import argparse
from datetime import datetime, timedelta, timezone

from config import PORTFOLIO_PROJECTS, ALL_PROJECTS

DB_PATH = os.environ.get('CONTEXT_BRIDGE_DB', '/home/user/clawrelay/data/context-bridge.db')

def get_db():
    if not os.path.exists(DB_PATH):
        print("No context bridge database found. Is the receiver running?")
        sys.exit(1)
    db = sqlite3.connect(DB_PATH)
    db.row_factory = sqlite3.Row
    return db

def cmd_now(args):
    """What is Jonas doing right now?"""
    db = get_db()
    row = db.execute(
        "SELECT * FROM activity_stream ORDER BY id DESC LIMIT 1"
    ).fetchone()
    
    if not row:
        print("No activity data available.")
        return
    
    idle = row['idle_state']
    if idle in ('locked', 'away'):
        print(f"Jonas is {idle} (idle for {row['idle_seconds']}s)")
        return
    if idle == 'idle':
        print(f"Jonas is idle ({row['idle_seconds']}s since last input)")
        return
    
    parts = [f"App: {row['app']}"]
    if row['window_title']:
        parts.append(f"Window: {row['window_title']}")
    if row['url']:
        parts.append(f"URL: {row['url']}")
    if row['git_repo']:
        parts.append(f"Repo: {row['git_repo']} ({row['git_branch']})")
    if row['file_path']:
        parts.append(f"File: {row['file_path']}")
    
    print(f"Active ({row['ts']})")
    for p in parts:
        print(f"  {p}")

def cmd_today(args):
    """Summary of today's activity."""
    db = get_db()
    today = datetime.now(timezone.utc).strftime('%Y-%m-%d')
    
    rows = db.execute(
        "SELECT * FROM activity_stream WHERE ts >= ? AND idle_state = 'active' ORDER BY ts",
        (today,)
    ).fetchall()
    
    if not rows:
        print("No activity recorded today.")
        return
    
    # Group by app
    apps = {}
    projects = {}
    for r in rows:
        app = r['app'] or 'unknown'
        apps[app] = apps.get(app, 0) + 1
        
        # Infer project from git_repo, url, window_title, or file_path
        project = ''
        haystack = f"{r['git_repo']} {r['url']} {r['window_title']} {r['file_path']}".lower()
        for p, keywords in ALL_PROJECTS.items():
            if any(kw in haystack for kw in keywords):
                project = p
                break
        if project:
            projects[project] = projects.get(project, 0) + 1
    
    total = len(rows)
    interval_min = 2  # captures every 2 min
    
    print(f"Today's activity ({total} captures, ~{total * interval_min} minutes tracked)")
    print()
    
    if projects:
        print("Projects:")
        for proj, count in sorted(projects.items(), key=lambda x: -x[1]):
            hours = round(count * interval_min / 60, 1)
            print(f"  {proj}: ~{hours}h ({count} captures)")
    
    print()
    print("Apps:")
    for app, count in sorted(apps.items(), key=lambda x: -x[1]):
        hours = round(count * interval_min / 60, 1)
        print(f"  {app}: ~{hours}h")
    
    # Recent commits
    commits = db.execute(
        "SELECT * FROM commits WHERE ts >= ? ORDER BY ts", (today,)
    ).fetchall()
    if commits:
        print()
        print("Commits:")
        for c in commits:
            print(f"  [{c['repo']}:{c['branch']}] {c['message']}")

def cmd_project(args):
    """Activity for a specific project."""
    db = get_db()
    project = args.project.lower()
    since = args.since or datetime.now(timezone.utc).strftime('%Y-%m-%d')
    
    rows = db.execute(
        """SELECT * FROM activity_stream 
           WHERE ts >= ? AND idle_state = 'active'
           AND (LOWER(git_repo) LIKE ? OR LOWER(window_title) LIKE ? 
                OR LOWER(url) LIKE ? OR LOWER(file_path) LIKE ?)
           ORDER BY ts""",
        (since, f'%{project}%', f'%{project}%', f'%{project}%', f'%{project}%')
    ).fetchall()
    
    if not rows:
        print(f"No activity for '{project}' since {since}")
        return
    
    print(f"Activity for '{project}' since {since} ({len(rows)} captures)")
    
    # Show unique files/URLs touched
    files = set()
    urls = set()
    for r in rows:
        if r['file_path']:
            files.add(r['file_path'])
        if r['url']:
            urls.add(r['url'])
    
    if files:
        print("\nFiles touched:")
        for f in sorted(files):
            print(f"  {f}")
    if urls:
        print("\nURLs visited:")
        for u in sorted(urls):
            print(f"  {u}")
    
    # Commits
    commits = db.execute(
        "SELECT * FROM commits WHERE ts >= ? AND LOWER(repo) LIKE ? ORDER BY ts",
        (since, f'%{project}%')
    ).fetchall()
    if commits:
        print("\nCommits:")
        for c in commits:
            print(f"  [{c['branch']}] {c['message']}")

def cmd_gaps(args):
    """Projects NOT touched recently."""
    db = get_db()
    days = args.days or 3
    since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    
    known = list(PORTFOLIO_PROJECTS.keys())
    
    rows = db.execute(
        "SELECT * FROM activity_stream WHERE ts >= ? AND idle_state = 'active'",
        (since,)
    ).fetchall()
    
    active = set()
    for r in rows:
        for p in known:
            haystack = ' '.join(filter(None, [
                r['git_repo'], r['window_title'], r['url'], r['file_path']
            ])).lower()
            if p in haystack:
                active.add(p)
    
    neglected = [p for p in known if p not in active]
    if neglected:
        print(f"Not touched in last {days} days:")
        for p in neglected:
            print(f"  ⚠️  {p}")
    else:
        print(f"All known projects touched in last {days} days.")

def cmd_status(args):
    """One-shot pre-action summary for JC."""
    conn = get_db()
    row = conn.execute(
        "SELECT * FROM activity_stream ORDER BY ts DESC LIMIT 1"
    ).fetchone()

    if not row:
        print("daemon_stale: true")
        print("last_activity: never")
        return

    print(f"current_app: {row['app'] or 'unknown'}")

    # Infer project
    haystack = f"{row['window_title']} {row['git_repo']} {row['url']} {row['file_path']}".lower()
    current_project = 'unknown'
    for project, keywords in ALL_PROJECTS.items():
        if any(kw in haystack for kw in keywords):
            current_project = project
            break
    print(f"current_project: {current_project}")

    print(f"idle_state: {row['idle_state'] or 'unknown'}")
    print(f"idle_seconds: {row['idle_seconds'] or 0}")
    print(f"in_call: {bool(row.get('in_call', 0))}")
    print(f"focus_mode: {row.get('focus_mode') or 'null'}")

    # Focus level from last 60 minutes
    since_1h = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
    recent = conn.execute(
        "SELECT app, window_title, git_repo, url, file_path FROM activity_stream WHERE ts >= ? AND idle_state = 'active' ORDER BY ts",
        (since_1h,)
    ).fetchall()

    switches = 0
    prev_ctx = None
    for r in recent:
        h = f"{r['window_title']} {r['git_repo']} {r['url']} {r['file_path']}".lower()
        proj = 'other'
        for p, kws in ALL_PROJECTS.items():
            if any(kw in h for kw in kws):
                proj = p
                break
        ctx = (r['app'], proj)
        if prev_ctx and ctx != prev_ctx:
            switches += 1
        prev_ctx = ctx

    if switches <= 3:
        print("focus_level: focused")
    elif switches <= 7:
        print("focus_level: multitasking")
    else:
        print("focus_level: scattered")

    # Time on current project today
    today_start = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0).isoformat()
    project_time = conn.execute(
        """SELECT COUNT(*) as captures FROM activity_stream
           WHERE ts >= ? AND idle_state = 'active'
           AND (lower(window_title) LIKE ? OR lower(git_repo) LIKE ? OR lower(url) LIKE ? OR lower(file_path) LIKE ?)""",
        (today_start, f'%{current_project}%', f'%{current_project}%', f'%{current_project}%', f'%{current_project}%')
    ).fetchone()
    hours = round((project_time['captures'] or 0) * 2 / 60, 1)
    print(f"time_on_current_project_today: {hours}h")

    # Calendar
    cal = row.get('calendar_events', '[]')
    if cal and cal != '[]':
        try:
            events = json.loads(cal)
            print("upcoming_calendar:")
            for evt in events:
                print(f"  - \"{evt.get('title', '?')}\" {'(now)' if evt.get('is_now') else ''} {evt.get('start', '')[:16]}")
        except:
            pass

    # Staleness
    stale_flag = '/tmp/context-bridge-stale'
    print(f"daemon_stale: {os.path.exists(stale_flag)}")
    print(f"last_activity: {row['ts']}")

    conn.close()


def cmd_since(args):
    """Cross-digest style diff for the last N hours."""
    hours = args.hours
    conn = get_db()
    now = datetime.now(timezone.utc)
    current_since = (now - timedelta(hours=hours)).isoformat()
    prev_since = (now - timedelta(hours=hours * 2)).isoformat()
    prev_until = current_since

    def get_active_projects(since, until=None):
        query = "SELECT window_title, git_repo, url, file_path FROM activity_stream WHERE ts >= ? AND idle_state = 'active'"
        params = [since]
        if until:
            query += " AND ts < ?"
            params.append(until)
        rows = conn.execute(query, params).fetchall()
        projects = set()
        for r in rows:
            h = f"{r['window_title']} {r['git_repo']} {r['url']} {r['file_path']}".lower()
            for p, kws in ALL_PROJECTS.items():
                if any(kw in h for kw in kws):
                    projects.add(p)
                    break
        return projects

    current = get_active_projects(current_since)
    previous = get_active_projects(prev_since, prev_until)

    new = current - previous
    continued = current & previous
    dropped = previous - current

    if new:
        print("New work:")
        for p in sorted(new):
            print(f"  - {p}")
    if continued:
        print("Continued:")
        for p in sorted(continued):
            print(f"  - {p}")
    if dropped:
        print("Dropped:")
        for p in sorted(dropped):
            print(f"  - {p}")

    conn.close()


def cmd_neglected(args):
    """Portfolio projects ranked by days since last activity."""
    conn = get_db()

    try:
        rows = conn.execute("SELECT project, last_seen FROM project_last_seen ORDER BY last_seen ASC").fetchall()
        last_seen = {r['project']: r['last_seen'] for r in rows}
    except:
        last_seen = {}

    recent_since = (datetime.now(timezone.utc) - timedelta(hours=48)).isoformat()
    recent_rows = conn.execute(
        "SELECT window_title, git_repo, url, file_path, MAX(ts) as latest FROM activity_stream WHERE ts >= ? AND idle_state = 'active' GROUP BY window_title, git_repo",
        (recent_since,)
    ).fetchall()

    for r in recent_rows:
        h = f"{r['window_title']} {r['git_repo']} {r['url']} {r['file_path']}".lower()
        for p, kws in PORTFOLIO_PROJECTS.items():
            if any(kw in h for kw in kws):
                if p not in last_seen or r['latest'] > last_seen.get(p, ''):
                    last_seen[p] = r['latest']
                break

    results = []
    for p in PORTFOLIO_PROJECTS:
        if p in last_seen:
            try:
                last = datetime.fromisoformat(last_seen[p])
                days = (datetime.now(timezone.utc) - last.replace(tzinfo=timezone.utc)).days
                results.append((days, p))
            except:
                results.append((999, p))
        else:
            results.append((999, p))

    results.sort(reverse=True)
    for days, p in results:
        if days == 0:
            print(f"{p}: 0 days (active now)")
        elif days >= 999:
            print(f"{p}: never tracked")
        else:
            print(f"{p}: {days} days")

    conn.close()


def main():
    parser = argparse.ArgumentParser(description='Context Bridge Query Tool')
    sub = parser.add_subparsers(dest='command')

    sub.add_parser('now', help="What is Jonas doing right now?")
    sub.add_parser('today', help="Summary of today's activity")

    p_proj = sub.add_parser('project', help="Activity for a specific project")
    p_proj.add_argument('project', help="Project name to search for")
    p_proj.add_argument('--since', help="Start date (YYYY-MM-DD)", default=None)

    p_gaps = sub.add_parser('gaps', help="Projects not touched recently")
    p_gaps.add_argument('--days', type=int, default=3, help="Lookback days (default: 3)")

    sub.add_parser('status', help='Pre-action summary for JC')

    sp_since = sub.add_parser('since', help='Cross-digest diff for last N hours')
    sp_since.add_argument('hours', type=int, help='Hours to look back')

    sub.add_parser('neglected', help='Portfolio projects by inactivity')

    args = parser.parse_args()

    if args.command == 'now':
        cmd_now(args)
    elif args.command == 'today':
        cmd_today(args)
    elif args.command == 'project':
        cmd_project(args)
    elif args.command == 'gaps':
        cmd_gaps(args)
    elif args.command == 'status':
        cmd_status(args)
    elif args.command == 'since':
        cmd_since(args)
    elif args.command == 'neglected':
        cmd_neglected(args)
    else:
        parser.print_help()

if __name__ == '__main__':
    main()
