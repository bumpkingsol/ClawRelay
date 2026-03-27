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

DB_PATH = os.environ.get('CONTEXT_BRIDGE_DB', '/home/admin/clawd/data/context-bridge.db')

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
        
        # Infer project from git_repo, url, or file_path
        project = r['git_repo'] or ''
        if not project and r['url']:
            if 'prescrivia' in r['url'].lower():
                project = 'prescrivia'
            elif 'leverwork' in r['url'].lower():
                project = 'leverwork'
            elif 'sonopeace' in r['url'].lower():
                project = 'sonopeace'
        if not project and r['window_title']:
            title_lower = r['window_title'].lower()
            for p in ['prescrivia', 'leverwork', 'sonopeace', 'jsvhq', 'aeoa']:
                if p in title_lower:
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
    
    # Known projects
    known = ['prescrivia', 'leverwork', 'sonopeace', 'jsvhq', 'aeoa']
    
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
    
    args = parser.parse_args()
    
    if args.command == 'now':
        cmd_now(args)
    elif args.command == 'today':
        cmd_today(args)
    elif args.command == 'project':
        cmd_project(args)
    elif args.command == 'gaps':
        cmd_gaps(args)
    else:
        parser.print_help()

if __name__ == '__main__':
    main()
