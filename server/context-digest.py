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
from db_utils import get_db as _shared_get_db, DB_PATH
DIGEST_DIR = Path('/home/admin/clawd/memory/activity-digest')
REPOS_DIR = Path('/home/admin/clawd')

from config import ALL_PROJECTS as PROJECTS, PORTFOLIO_PROJECTS, NOISE_APPS


def update_project_last_seen(db_path, project_activity):
    """Update the project_last_seen table with latest activity timestamps."""
    conn = sqlite3.connect(db_path)
    for project, details in project_activity.items():
        if project == 'other':
            continue
        last_seen = details.get('last_seen')
        last_branch = ''
        if details.get('branches'):
            last_branch = list(details['branches'])[-1]
        if last_seen:
            conn.execute(
                """INSERT INTO project_last_seen (project, last_seen, last_branch)
                   VALUES (?, ?, ?)
                   ON CONFLICT(project) DO UPDATE SET
                   last_seen = excluded.last_seen,
                   last_branch = excluded.last_branch""",
                (project, last_seen, last_branch)
            )
    conn.commit()
    conn.close()


def get_project_last_seen(db_path):
    """Read all project_last_seen records."""
    conn = sqlite3.connect(db_path)
    rows = conn.execute("SELECT project, last_seen, last_branch FROM project_last_seen").fetchall()
    conn.close()
    return {row[0]: {'last_seen': row[1], 'last_branch': row[2]} for row in rows}


def get_db():
    return _shared_get_db()


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
    # NOTE: db.close() moved to end of function so Task 5 cross-digest queries can still use DB

    if not rows:
        db.close()
        return None
    
    # --- Time allocation ---
    interval_min = 2  # moved here so it's available during accumulation
    project_captures = defaultdict(int)
    project_details = defaultdict(lambda: {
        'files': set(),
        'urls': set(),
        'branches': set(),
        'apps': set(),
        'terminal_cmds': [],
        'file_changes': [],
        'whatsapp': [],
        'codex_sessions': [],
        'codex_running_count': 0,
        'notifications': [],
        'in_call_minutes': 0,
        'call_apps': set(),
        'focus_modes': [],
        'calendar_events': [],
        'first_seen': None,
        'last_seen': None,
    })

    total_active = 0
    total_idle = 0

    # Global (non-project-specific) accumulators
    all_whatsapp = []
    all_notifications = []
    all_tabs_snapshots = []
    all_codex_sessions = []

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

        # --- Accumulate new fields per project ---

        # File changes
        if row['file_changes']:
            details['file_changes'].append(row['file_changes'])

        # WhatsApp context
        if row['whatsapp_context']:
            details['whatsapp'].append({'ts': row['ts'], 'context': row['whatsapp_context']})

        # Codex/Claude sessions
        if row['codex_session']:
            details['codex_sessions'].append(row['codex_session'])
        if row['codex_running']:
            details['codex_running_count'] += 1

        # Notifications
        if row.get('notifications'):
            details['notifications'].append({'ts': row['ts'], 'data': row['notifications']})

        # Call detection (Phase 2 columns -- safe to read even before daemon sends them)
        if row.get('in_call'):
            details['in_call_minutes'] += interval_min

            if row.get('call_app'):
                details['call_apps'].add(row['call_app'])

        # Focus mode
        if row.get('focus_mode'):
            details['focus_modes'].append({'ts': row['ts'], 'mode': row['focus_mode']})

        # Calendar
        if row.get('calendar_events'):
            details['calendar_events'].append({'ts': row['ts'], 'events': row['calendar_events']})

        # --- Accumulate global (non-project-specific) lists ---
        if row['whatsapp_context']:
            all_whatsapp.append({'ts': row['ts'], 'context': row['whatsapp_context']})
        if row.get('notifications'):
            all_notifications.append({'ts': row['ts'], 'data': row['notifications']})
        if row['all_tabs']:
            all_tabs_snapshots.append(row['all_tabs'])
        if row['codex_session']:
            all_codex_sessions.append({'ts': row['ts'], 'session': row['codex_session']})

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
    
    # --- Cross-digest comparison ---
    prev_since = (datetime.fromisoformat(since) - timedelta(hours=hours_back)).isoformat()
    prev_until = since

    prev_rows = db.execute(
        "SELECT app, window_title, url, git_repo, git_branch, file_path FROM activity_stream WHERE ts >= ? AND ts < ? AND idle_state = 'active'",
        (prev_since, prev_until)
    ).fetchall()

    prev_projects = set()
    for prow in prev_rows:
        haystack = f"{prow['window_title']} {prow['git_repo']} {prow['url']} {prow['file_path']}".lower()
        for project, keywords in PROJECTS.items():
            if any(kw in haystack for kw in keywords):
                prev_projects.add(project)
                break

    current_projects = set(p for p, c in project_captures.items() if c > 0 and p != 'other')

    new_work = current_projects - prev_projects
    continued_work = current_projects & prev_projects
    dropped_work = prev_projects - current_projects

    # Update project_last_seen
    update_project_last_seen(DB_PATH, project_details)

    # Write daily_summary rows for each project this period
    try:
        today_str = datetime.now(timezone.utc).strftime('%Y-%m-%d')
        summary_db = get_db()
        summary_db.execute("""CREATE TABLE IF NOT EXISTS daily_summary (
            date TEXT NOT NULL, project TEXT NOT NULL, hours REAL NOT NULL,
            captures INTEGER NOT NULL, PRIMARY KEY (date, project))""")
        for proj, count in project_captures.items():
            if proj == 'other' or count == 0:
                continue
            hours = round(count * interval_min / 60, 1)
            summary_db.execute(
                "INSERT OR REPLACE INTO daily_summary (date, project, hours, captures) VALUES (?, ?, ?, ?)",
                (today_str, proj, hours, count)
            )
        summary_db.commit()
        summary_db.close()
    except Exception:
        pass

    # Get neglect data
    last_seen_data = get_project_last_seen(DB_PATH)

    # --- Context switching / focus metric ---
    focus_periods = []
    if rows:
        from collections import defaultdict as _dd
        hourly_switches = _dd(int)
        prev_context = None
        for row in rows:
            if row['idle_state'] != 'active' or row['app'] in NOISE_APPS:
                continue
            ts_str = row['ts'][:13]  # YYYY-MM-DDTHH
            haystack = f"{row['window_title']} {row['git_repo']} {row['url']} {row['file_path']}".lower()
            current_project = 'other'
            for project, keywords in PROJECTS.items():
                if any(kw in haystack for kw in keywords):
                    current_project = project
                    break
            ctx = (row['app'], current_project)
            if prev_context and ctx != prev_context:
                hourly_switches[ts_str] += 1
            prev_context = ctx

        for hour, switches in sorted(hourly_switches.items()):
            if switches <= 3:
                level = 'focused'
            elif switches <= 7:
                level = 'multitasking'
            else:
                level = 'scattered'
            focus_periods.append(f"- {hour}:00: {level} ({switches} switches/hr)")

    # --- Build output ---
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

    # Changes since last digest
    lines.append("## Changes Since Last Digest")
    lines.append("")

    if new_work:
        lines.append("### New work this period")
        for p in sorted(new_work):
            days_info = ""
            if p in last_seen_data:
                try:
                    last = datetime.fromisoformat(last_seen_data[p]['last_seen']).replace(tzinfo=timezone.utc)
                    days_ago = (datetime.now(timezone.utc) - last).days
                    if days_ago > 0:
                        days_info = f" (first activity in {days_ago} days)"
                except:
                    pass
            lines.append(f"- {p}{days_info}")
        lines.append("")

    if continued_work:
        lines.append("### Continued from last period")
        for p in sorted(continued_work):
            branch_info = ""
            if project_details[p]['branches']:
                branches = list(project_details[p]['branches'])
                branch_info = f" (branch: {branches[0]})"
            lines.append(f"- {p}{branch_info}")
        lines.append("")

    if dropped_work:
        lines.append("### Dropped since last period")
        for p in sorted(dropped_work):
            lines.append(f"- {p}")
        lines.append("")

    # Neglect tracker
    lines.append("### Project neglect")
    for p in sorted(PORTFOLIO_PROJECTS.keys()):
        if p in current_projects:
            lines.append(f"- {p}: 0 days (active now)")
        elif p in last_seen_data:
            try:
                last = datetime.fromisoformat(last_seen_data[p]['last_seen']).replace(tzinfo=timezone.utc)
                days_ago = (datetime.now(timezone.utc) - last).days
                lines.append(f"- {p}: {days_ago} days since last activity")
            except:
                lines.append(f"- {p}: unknown")
        else:
            lines.append(f"- {p}: never tracked")
    lines.append("")

    # Focus level
    if focus_periods:
        lines.append("## Focus Level")
        lines.append("")
        for fp in focus_periods:
            lines.append(fp)
        lines.append("")

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

        # Terminal commands (last 5 blocks)
        if details['terminal_cmds']:
            lines.append("\n### Terminal Commands")
            for cmd_block in details['terminal_cmds'][-5:]:
                lines.append(f"```\n{cmd_block}\n```")

        # File changes
        if details['file_changes']:
            lines.append("\n### File Changes")
            seen = set()
            for fc in details['file_changes']:
                for line in str(fc).split('\n'):
                    line = line.strip()
                    if line and line not in seen:
                        seen.add(line)
                        lines.append(f"- {line}")

        # Call time
        if details['in_call_minutes'] > 0:
            call_apps_str = ', '.join(details['call_apps']) if details['call_apps'] else 'unknown'
            lines.append(f"\n*Includes {details['in_call_minutes']} min in calls ({call_apps_str})*")

    # --- Global sections (Communication, AI sessions, tabs, notifications) ---

    # Communication section
    if all_whatsapp:
        lines.append("")
        lines.append("## Communication")
        lines.append("")
        seen_contexts = set()
        for entry in all_whatsapp:
            ctx = entry['context']
            if ctx not in seen_contexts:
                seen_contexts.add(ctx)
                lines.append(f"- {entry['ts']}: WhatsApp — {ctx}")

    # AI Agent Sessions
    if all_codex_sessions:
        lines.append("")
        lines.append("## AI Agent Sessions")
        lines.append("")
        for entry in all_codex_sessions:
            lines.append(f"- {entry['ts']}: {entry['session'][:200]}")

    # Open Tabs (deduplicated, last snapshot)
    if all_tabs_snapshots:
        lines.append("")
        lines.append("## Open Tabs (Last Snapshot)")
        lines.append("")
        last_tabs = all_tabs_snapshots[-1]
        for tab_entry in str(last_tabs).split(';;;')[:30]:
            parts = tab_entry.split('|', 1)
            if len(parts) == 2:
                url, title = parts
                lines.append(f"- [{title.strip()[:80]}]({url.strip()})")
            elif parts[0].strip():
                lines.append(f"- {parts[0].strip()[:100]}")

    # Notifications
    if all_notifications:
        lines.append("")
        lines.append("## Notifications")
        lines.append("")
        for entry in all_notifications:
            try:
                notifs = json.loads(entry['data']) if isinstance(entry['data'], str) else entry['data']
                for n in notifs[:3]:
                    lines.append(f"- {entry['ts']}: {n.get('app', '?')} — {n.get('title', '')}")
            except:
                pass

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
    
    db.close()
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
