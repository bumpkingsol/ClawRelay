#!/usr/bin/env python3
"""
OpenClaw Context Bridge - Digest Processor (Layer 2)
Processes raw activity stream into structured daily summaries.
Runs 3x daily via cron (10:00, 16:00, 23:00 CET).

This is the intelligence layer - it turns raw captures into
operational context JC can act on.
"""

import os
import sys
import json
import sqlite3
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path
from collections import defaultdict

DB_PATH = os.environ.get('CONTEXT_BRIDGE_DB', '/home/admin/clawd/data/context-bridge.db')
DIGEST_DIR = Path('/home/admin/clawd/memory/activity-digest')
REPOS_DIR = Path('/home/admin/clawd')

from config import ALL_PROJECTS as PROJECTS, PORTFOLIO_PROJECTS, NOISE_APPS


def get_db():
    db = sqlite3.connect(DB_PATH)
    db.row_factory = sqlite3.Row
    return db


def infer_project(row):
    """Infer which project a capture belongs to."""
    haystack = ' '.join(filter(None, [
        row['app'] or '',
        row['window_title'] or '',
        row['url'] or '',
        row['file_path'] or '',
        row['git_repo'] or '',
        row['all_tabs'] or '',
        row['terminal_cmds'] or '',
    ])).lower()
    
    for project, keywords in PROJECTS.items():
        for kw in keywords:
            if kw in haystack:
                return project
    return 'other'


def extract_google_doc_urls(rows):
    """Extract unique Google Docs/Slides/Sheets URLs from activity."""
    urls = set()
    google_prefixes = [
        'https://docs.google.com/document/',
        'https://docs.google.com/spreadsheets/',
        'https://docs.google.com/presentation/',
    ]
    
    for row in rows:
        for field in ['url', 'all_tabs']:
            val = row[field] or ''
            for prefix in google_prefixes:
                if prefix in val:
                    for part in val.split(';;;'):
                        url_part = part.split('|')[0] if '|' in part else part
                        if any(p in url_part for p in google_prefixes):
                            urls.add(url_part.strip())
    return urls


def extract_doc_id(url):
    """Extract Google Doc/Sheet/Slides ID from URL."""
    # URLs look like: https://docs.google.com/document/d/DOC_ID/edit
    import re
    match = re.search(r'/d/([a-zA-Z0-9_-]+)', url)
    return match.group(1) if match else None


def read_google_doc_content(url):
    """Read a Google Doc/Slides/Sheet content via gog CLI.
    
    This is JC's tool, NOT the daemon's. The daemon captures URLs,
    this function reads the actual content during digest processing.
    """
    doc_id = extract_doc_id(url)
    if not doc_id:
        return None
    
    doc_type = None
    if '/document/' in url:
        doc_type = 'docs'
    elif '/spreadsheets/' in url:
        doc_type = 'sheets'
    elif '/presentation/' in url:
        doc_type = 'slides'
    
    if not doc_type:
        return None
    
    try:
        if doc_type == 'docs':
            result = subprocess.run(
                ['gog', 'docs', 'get', doc_id],
                capture_output=True, text=True, timeout=30
            )
        elif doc_type == 'sheets':
            result = subprocess.run(
                ['gog', 'sheets', 'get', doc_id, 'A1:Z100'],
                capture_output=True, text=True, timeout=30
            )
        elif doc_type == 'slides':
            # gog may not have a slides get command - fall back to Drive metadata
            result = subprocess.run(
                ['gog', 'drive', 'info', doc_id],
                capture_output=True, text=True, timeout=30
            )
        
        if result.returncode == 0 and result.stdout.strip():
            # Truncate to avoid massive content in digest
            content = result.stdout.strip()
            if len(content) > 3000:
                content = content[:3000] + "\n... (truncated)"
            return content
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    
    return None


def get_recent_commits(since_ts):
    """Get commits from the context bridge DB."""
    db = get_db()
    commits = db.execute(
        "SELECT * FROM commits WHERE ts >= ? ORDER BY ts",
        (since_ts,)
    ).fetchall()
    db.close()
    return commits


def get_git_diffs(repo_name, since_hours=8):
    """Read recent git diffs from local repo clones."""
    diffs = {}
    for d in REPOS_DIR.iterdir():
        if d.is_dir() and repo_name.lower() in d.name.lower():
            git_dir = d / '.git'
            if git_dir.exists():
                try:
                    since = f"{since_hours} hours ago"
                    result = subprocess.run(
                        ['git', 'log', f'--since={since}', '--oneline', '--stat'],
                        cwd=str(d), capture_output=True, text=True, timeout=10
                    )
                    if result.stdout.strip():
                        diffs[d.name] = result.stdout.strip()
                except Exception:
                    pass
    return diffs


def build_digest(hours_back=8):
    """Build a structured digest from recent activity."""
    db = get_db()
    since = (datetime.now(timezone.utc) - timedelta(hours=hours_back)).isoformat()
    
    rows = db.execute(
        "SELECT * FROM activity_stream WHERE ts >= ? ORDER BY ts",
        (since,)
    ).fetchall()
    db.close()
    
    if not rows:
        return None
    
    # --- Time allocation ---
    project_captures = defaultdict(int)
    project_details = defaultdict(lambda: {
        'files': set(),
        'urls': set(),
        'branches': set(),
        'apps': set(),
        'terminal_cmds': [],
        'first_seen': None,
        'last_seen': None,
    })
    
    total_active = 0
    total_idle = 0
    
    for row in rows:
        if row['idle_state'] in ('idle', 'away', 'locked'):
            total_idle += 1
            continue
        if row['app'] in NOISE_APPS:
            continue
        
        total_active += 1
        project = infer_project(row)
        project_captures[project] += 1
        
        details = project_details[project]
        if row['file_path']:
            details['files'].add(row['file_path'])
        if row['url']:
            details['urls'].add(row['url'])
        if row['git_branch']:
            details['branches'].add(row['git_branch'])
        if row['app']:
            details['apps'].add(row['app'])
        if row['terminal_cmds']:
            try:
                cmds = json.loads(row['terminal_cmds'])
                if cmds:
                    details['terminal_cmds'].append(cmds)
            except (json.JSONDecodeError, TypeError):
                pass
        
        ts = row['ts']
        if not details['first_seen'] or ts < details['first_seen']:
            details['first_seen'] = ts
        if not details['last_seen'] or ts > details['last_seen']:
            details['last_seen'] = ts
    
    # --- Commits ---
    commits = get_recent_commits(since)
    commits_by_project = defaultdict(list)
    for c in commits:
        repo = (c['repo'] or '').lower()
        assigned = 'other'
        for project, keywords in PROJECTS.items():
            if any(kw in repo for kw in keywords):
                assigned = project
                break
        commits_by_project[assigned].append(c)
    
    # --- Google Doc URLs ---
    google_urls = extract_google_doc_urls(rows)
    
    # --- Build output ---
    interval_min = 2
    today = datetime.now().strftime('%Y-%m-%d')
    now = datetime.now().strftime('%H:%M')
    
    lines = [
        f"# Activity Digest - {today} ({now})",
        "",
        f"*Period: last {hours_back} hours | "
        f"{total_active} active captures, {total_idle} idle | "
        f"~{total_active * interval_min} min tracked*",
        "",
    ]
    
    # Time allocation summary
    if project_captures:
        lines.append("## Time Allocation")
        for proj, count in sorted(project_captures.items(), key=lambda x: -x[1]):
            hours = round(count * interval_min / 60, 1)
            pct = round(count / total_active * 100) if total_active else 0
            lines.append(f"- **{proj}**: ~{hours}h ({pct}%)")
        lines.append("")
    
    # Per-project details
    for proj, count in sorted(project_captures.items(), key=lambda x: -x[1]):
        if proj == 'other' and count < 3:
            continue
        
        details = project_details[proj]
        hours = round(count * interval_min / 60, 1)
        lines.append(f"## {proj.title()}")
        lines.append(f"*~{hours}h | {details['first_seen']} → {details['last_seen']}*")
        lines.append("")
        
        if details['files']:
            lines.append("**Files touched:**")
            for f in sorted(details['files']):
                lines.append(f"- `{f}`")
            lines.append("")
        
        if details['branches']:
            lines.append(f"**Branches:** {', '.join(sorted(details['branches']))}")
            lines.append("")
        
        if details['urls']:
            lines.append("**URLs:**")
            for u in sorted(details['urls']):
                lines.append(f"- {u}")
            lines.append("")
        
        proj_commits = commits_by_project.get(proj, [])
        if proj_commits:
            lines.append("**Commits:**")
            for c in proj_commits:
                lines.append(f"- [{c['branch']}] {c['message']}")
            lines.append("")
        
        # Git diffs from local repos
        for kw in PROJECTS.get(proj, [proj]):
            diffs = get_git_diffs(kw, hours_back)
            if diffs:
                for repo_name, diff_text in diffs.items():
                    lines.append(f"**Git log ({repo_name}):**")
                    lines.append("```")
                    # Truncate if very long
                    if len(diff_text) > 2000:
                        diff_text = diff_text[:2000] + "\n... (truncated)"
                    lines.append(diff_text)
                    lines.append("```")
                    lines.append("")
    
    # Google docs found - read content via gog
    if google_urls:
        lines.append("## Google Workspace Documents Accessed")
        for u in sorted(google_urls):
            lines.append(f"### {u}")
            content = read_google_doc_content(u)
            if content:
                lines.append("```")
                lines.append(content)
                lines.append("```")
            else:
                lines.append("*(Could not read content - check gog auth)*")
            lines.append("")
    
    # Unfinished / gaps
    all_known = set(PROJECTS.keys()) - {'other', 'legal', 'openclaw'}
    active_projects = set(project_captures.keys())
    neglected = all_known - active_projects
    if neglected:
        lines.append("## Not Touched This Period")
        for p in sorted(neglected):
            lines.append(f"- ⚠️ {p}")
        lines.append("")
    
    return '\n'.join(lines)


def save_digest(content):
    """Save digest to file."""
    DIGEST_DIR.mkdir(parents=True, exist_ok=True)
    today = datetime.now().strftime('%Y-%m-%d')
    hour = datetime.now().strftime('%H')
    path = DIGEST_DIR / f"{today}-{hour}.md"
    path.write_text(content)
    
    # Also maintain a "latest" symlink
    latest = DIGEST_DIR / "latest.md"
    if latest.is_symlink() or latest.exists():
        latest.unlink()
    latest.symlink_to(path.name)
    
    return path


def main():
    import argparse
    parser = argparse.ArgumentParser(description='Context Bridge Digest Processor')
    parser.add_argument('--hours', type=int, default=8, help='Hours to look back')
    parser.add_argument('--dry-run', action='store_true', help='Print without saving')
    args = parser.parse_args()
    
    digest = build_digest(args.hours)
    
    if not digest:
        print("No activity data found for the specified period.")
        return
    
    if args.dry_run:
        print(digest)
    else:
        path = save_digest(digest)
        print(f"Digest saved to {path}")
        print()
        print(digest)


if __name__ == '__main__':
    main()
