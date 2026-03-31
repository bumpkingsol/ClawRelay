# Context Bridge Enhancements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the context bridge deliver actionable intelligence to the agent by fixing bugs, enriching the digest with all captured signals, adding new daemon signals, and wiring the agent's pre-action context checks.

**Architecture:** Three-phase bottom-up approach. Phase 1 fixes the data foundation (notification bug, digest enrichment, cross-digest comparison). Phase 2 adds new daemon-side signals (meeting detection, Focus mode, calendar). Phase 3 wires the agent integration (new query commands, staleness watchdog, pre-action pattern docs).

**Tech Stack:** Bash (daemon), Python 3 / Flask / SQLite (server), AppleScript (macOS queries)

**Spec:** `docs/superpowers/specs/2026-03-28-context-bridge-enhancements-design.md`

---

## File Structure

**New files:**
- `server/config.py` — shared constants (portfolio projects, noise apps)
- `server/staleness-watchdog.sh` — cron script for daemon staleness detection (note: `server/watchdog.py` exists with similar logic but doesn't write the stale flag file — this script replaces its purpose)
- `docs/jc-integration-guide.md` — pre-action check pattern documentation

**Modified files:**
- `server/context-receiver.py` — schema migration, notification fix, new columns
- `server/context-digest.py` — all new digest sections, cross-digest comparison, focus metric
- `server/context-query.py` — new `status`, `since`, `neglected` commands
- `mac-daemon/context-daemon.sh` — notification format fix, meeting detection, Focus mode, calendar capture
- `~/.context-bridge/privacy-rules.json` — `calendar_enabled` flag

---

## Phase 1: Fix + Enrich Foundation

### Task 1: Create shared config module

**Files:**
- Create: `server/config.py`
- Modify: `server/context-digest.py:25-37` (replace PROJECTS and NOISE_APPS with imports)
- Modify: `server/context-query.py:79-93,180` (replace hardcoded project lists with imports)

- [ ] **Step 1: Create `server/config.py`**

```python
"""Shared constants for the context bridge server."""

# Canonical portfolio project list.
# Keys are display names, values are lists of keywords that match
# window titles, git repos, file paths, and URLs.
PORTFOLIO_PROJECTS = {
    'project-gamma': ['project-gamma'],
    'project-alpha': ['project-alpha'],
    'project-delta': ['project-delta'],
    'project-beta': ['project-beta', 'project-beta'],
    'openclaw': ['openclaw-computer-vision', 'openclaw-macos-helper', 'clawd'],
}

# Extended project list including non-portfolio projects.
# Used by the digest for classification, but not by neglect tracking.
ALL_PROJECTS = {
    **PORTFOLIO_PROJECTS,
    'aeoa': ['aeoa', 'aeoa-studio'],
    'nilsy': ['nilsy'],
    'legal': ['mcol', 'sehaj', 'azika', 'sorna', 'rohu'],
}

# Apps that generate noise and should be excluded from time tracking.
NOISE_APPS = {'Finder', 'SystemUIServer', 'loginwindow', 'Dock', 'Spotlight'}
```

- [ ] **Step 2: Update `context-digest.py` to import from config**

Replace lines 25-37 in `server/context-digest.py`:

```python
from config import ALL_PROJECTS as PROJECTS, PORTFOLIO_PROJECTS, NOISE_APPS
```

Remove the old `PROJECTS = { ... }` dict and `NOISE_APPS = ...` line.

- [ ] **Step 3: Update `context-query.py` to import from config**

Add at top of `server/context-query.py`:

```python
from config import PORTFOLIO_PROJECTS, ALL_PROJECTS
```

Replace the entire project-inference block (lines 78-92) in `cmd_today()` with a shared pattern:

```python
# Infer project from git_repo, url, window_title, or file_path
project = ''
haystack = f"{r['git_repo']} {r['url']} {r['window_title']} {r['file_path']}".lower()
for p, keywords in ALL_PROJECTS.items():
    if any(kw in haystack for kw in keywords):
        project = p
        break
```

This replaces both the hardcoded URL checks at lines 80-86 and the title checks at lines 87-92.

Replace the hardcoded list at line 180 in `cmd_gaps()`:

```python
known = list(PORTFOLIO_PROJECTS.keys())
```

- [ ] **Step 4: Verify imports work**

Run: `cd server && python3 -c "from config import PORTFOLIO_PROJECTS, ALL_PROJECTS, NOISE_APPS; print('OK:', len(ALL_PROJECTS), 'projects')"`
Expected: `OK: 8 projects`

- [ ] **Step 5: Commit**

```bash
git add server/config.py server/context-digest.py server/context-query.py
git commit -m "refactor: extract shared project config into server/config.py"
```

---

### Task 2: Fix notification storage bug — server side

**Files:**
- Modify: `server/context-receiver.py:39-64` (schema — replace notification_app/notification_text with notifications)
- Modify: `server/context-receiver.py:148-174` (sanitize — pass through notifications)
- Modify: `server/context-receiver.py:192-218` (INSERT — add notifications column)

- [ ] **Step 1: Update schema in `init_db()`**

In `server/context-receiver.py`, in the `CREATE TABLE activity_stream` block (lines 39-64), replace:

```sql
notification_app TEXT,
notification_text TEXT,
```

with:

```sql
notifications TEXT,
```

Also add the new Phase 2 columns now (avoids a second migration):

```sql
in_call BOOLEAN DEFAULT 0,
call_app TEXT,
call_type TEXT,
focus_mode TEXT,
calendar_events TEXT,
```

Add the `project_last_seen` table after the `commits` table creation:

```sql
CREATE TABLE IF NOT EXISTS project_last_seen (
    project TEXT PRIMARY KEY,
    last_seen TEXT NOT NULL,
    last_branch TEXT
);
```

- [ ] **Step 2: Update `sanitize_activity_payload()`**

At line 165, the existing `data.get('notifications')` extraction is correct. Ensure it passes through to the return dict. Also add the new fields with defaults:

```python
sanitized['notifications'] = data.get('notifications', '')
sanitized['in_call'] = bool(data.get('in_call', False))
sanitized['call_app'] = str(data.get('call_app', ''))[:100]
sanitized['call_type'] = str(data.get('call_type', ''))[:20]
sanitized['focus_mode'] = data.get('focus_mode') or None
sanitized['calendar_events'] = data.get('calendar_events', '')
```

- [ ] **Step 3: Update INSERT statement**

Add `notifications, in_call, call_app, call_type, focus_mode, calendar_events` to the INSERT column list (line 193) and add matching values to the tuple (after line 218):

```python
sanitized.get('notifications', ''),
1 if sanitized.get('in_call') else 0,
sanitized.get('call_app', ''),
sanitized.get('call_type', ''),
sanitized.get('focus_mode'),
sanitized.get('calendar_events', ''),
```

- [ ] **Step 4: Test the receiver starts**

Note: The file is `context-receiver.py` (hyphenated), which cannot be imported directly with `import`. Use:

Run: `cd server && CONTEXT_BRIDGE_TOKEN=test timeout 3 python3 context-receiver.py 2>&1 || true`
Expected: Flask startup output (or "Address already in use" if port is taken). No import/syntax errors.

- [ ] **Step 5: Commit**

```bash
git add server/context-receiver.py
git commit -m "fix: notification storage bug + add new schema columns for Phase 2"
```

---

### Task 3: Fix notification format — daemon side

**Files:**
- Modify: `mac-daemon/context-daemon.sh:463-488` (notification capture)

- [ ] **Step 1: Replace notification capture with proper JSON output**

Replace the notification capture section (lines 463-488 in `mac-daemon/context-daemon.sh`) with:

```bash
# --- Notifications (with Full Disk Access support) ---
NOTIFICATIONS=""
NOTIF_DB="$HOME/Library/Group Containers/group.com.apple.usernoted/db2/db"
if [ -f "$NOTIF_DB" ] && [ -r "$NOTIF_DB" ]; then
  NOTIFICATIONS=$(python3 -c "
import sqlite3, json, sys
try:
    conn = sqlite3.connect('$NOTIF_DB')
    rows = conn.execute('''
        SELECT app_id, title, body
        FROM record
        WHERE delivered_date > strftime('%s','now') - 180
        ORDER BY delivered_date DESC
        LIMIT 5
    ''').fetchall()
    conn.close()
    print(json.dumps([{'app': r[0] or '', 'title': r[1] or '', 'body': r[2] or ''} for r in rows]))
except:
    print('[]')
" 2>/dev/null || echo "[]")
fi
# Fallback: alternative DB path for different macOS versions
if [ "$NOTIFICATIONS" = "[]" ] || [ -z "$NOTIFICATIONS" ]; then
  ALT_NOTIF_DB="$HOME/Library/Group Containers/group.com.apple.usernoted/db/db"
  if [ -f "$ALT_NOTIF_DB" ] && [ -r "$ALT_NOTIF_DB" ]; then
    NOTIFICATIONS=$(python3 -c "
import sqlite3, json
try:
    conn = sqlite3.connect('$ALT_NOTIF_DB')
    rows = conn.execute('''
        SELECT app_id, title, body
        FROM record
        WHERE delivered_date > strftime('%s','now') - 180
        ORDER BY delivered_date DESC
        LIMIT 5
    ''').fetchall()
    conn.close()
    print(json.dumps([{'app': r[0] or '', 'title': r[1] or '', 'body': r[2] or ''} for r in rows]))
except:
    print('[]')
" 2>/dev/null || echo "[]")
  fi
fi
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n mac-daemon/context-daemon.sh`
Expected: no output (clean syntax)

- [ ] **Step 3: Copy to deployed location**

```bash
cp mac-daemon/context-daemon.sh ~/.context-bridge/bin/context-bridge-daemon.sh
```

- [ ] **Step 4: Commit**

```bash
git add mac-daemon/context-daemon.sh
git commit -m "fix: daemon sends notifications as proper JSON array"
```

---

### Task 4: Wire all captured-but-ignored fields into digest

**Files:**
- Modify: `server/context-digest.py:192-200` (project_details — add new tracked fields)
- Modify: `server/context-digest.py:204-237` (main loop — accumulate new fields)
- Modify: `server/context-digest.py:259-349` (markdown output — add new sections)

**IMPORTANT prerequisite:** The existing `build_digest()` closes the DB at line 185 (`db.close()`). Move this `db.close()` call to the END of the function (after all markdown generation), so the cross-digest comparison in Task 5 can query the DB. Also, the existing code uses `db` as the variable name, not `conn` — all new code must use `db`.

Additionally, `interval_min = 2` is defined at line 255 (after the loop). Move it to BEFORE the loop (e.g., line 203) so it's available during accumulation.

- [ ] **Step 1: Extend project_details to track new fields**

In `build_digest()`, extend the `defaultdict` lambda (around line 192) to include:

```python
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
```

- [ ] **Step 2: Accumulate new fields in the main loop**

In the row iteration loop (around lines 204-237), after the existing accumulation logic, add:

```python
# Terminal commands
if row['terminal_cmds']:
    details['terminal_cmds'].append(row['terminal_cmds'])

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

# Call detection (Phase 2 columns — safe to read even before daemon sends them)
# interval_min must be moved before the loop (see prerequisite note above)
if row.get('in_call'):
    details['in_call_minutes'] += interval_min  # interval_min = 2, defined before loop
    if row.get('call_app'):
        details['call_apps'].add(row['call_app'])

# Focus mode
if row.get('focus_mode'):
    details['focus_modes'].append({'ts': row['ts'], 'mode': row['focus_mode']})

# Calendar
if row.get('calendar_events'):
    details['calendar_events'].append({'ts': row['ts'], 'events': row['calendar_events']})
```

Also accumulate global (non-project-specific) data in separate lists above the loop:

```python
all_whatsapp = []
all_notifications = []
all_tabs_snapshots = []
all_codex_sessions = []
```

And in the loop, for the global lists:

```python
if row['whatsapp_context']:
    all_whatsapp.append({'ts': row['ts'], 'context': row['whatsapp_context']})
if row.get('notifications'):
    all_notifications.append({'ts': row['ts'], 'data': row['notifications']})
if row['all_tabs']:
    all_tabs_snapshots.append(row['all_tabs'])
if row['codex_session']:
    all_codex_sessions.append({'ts': row['ts'], 'session': row['codex_session']})
```

- [ ] **Step 3: Add new sections to markdown output**

After the existing per-project detail sections (around line 323), add these new sections before the Google docs section:

**IMPORTANT:** The existing `context-digest.py` builds markdown using a `lines = []` list with `lines.append()`, then returns `'\n'.join(lines)`. All new code MUST use this same `lines.append()` pattern. Do NOT use `md +=` string concatenation.

**Terminal commands within each project section:**

```python
if details['terminal_cmds']:
    lines.append("\n### Terminal Commands")
    for cmd_block in details['terminal_cmds'][-5:]:
        lines.append(f"```\n{cmd_block}\n```")
```

**File changes within each project section:**

```python
if details['file_changes']:
    lines.append("\n### File Changes")
    seen = set()
    for fc in details['file_changes']:
        for line in str(fc).split('\n'):
            line = line.strip()
            if line and line not in seen:
                seen.add(line)
                lines.append(f"- {line}")
```

**Call time within each project section (if any):**

```python
if details['in_call_minutes'] > 0:
    call_apps_str = ', '.join(details['call_apps']) if details['call_apps'] else 'unknown'
    lines.append(f"\n*Includes {details['in_call_minutes']} min in calls ({call_apps_str})*")
```

**After all project sections, add global sections:**

```python
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
```

- [ ] **Step 4: Verify digest builds without errors**

Run: `cd server && python3 -c "from context_digest import build_digest; print('Digest loads OK')"`

- [ ] **Step 5: Commit**

```bash
git add server/context-digest.py
git commit -m "feat: wire all captured fields into digest output"
```

---

### Task 5: Add cross-digest comparison and focus metric

**Files:**
- Modify: `server/context-digest.py` (add comparison logic and focus metric before markdown output)

- [ ] **Step 1: Add `update_project_last_seen()` function**

Add near the top of `context-digest.py`, after imports:

```python
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
```

- [ ] **Step 2: Add cross-digest comparison to `build_digest()`**

After the time allocation computation but before the markdown generation, add:

Note: uses `db` (existing variable name) not `conn`. `db.close()` was moved to end of function in Task 4.

```python
# --- Cross-digest comparison ---
# Previous period: same-length window immediately before current window
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

# Get neglect data
last_seen_data = get_project_last_seen(DB_PATH)
```

- [ ] **Step 3: Add focus metric computation**

After the cross-digest comparison:

```python
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
```

- [ ] **Step 4: Add comparison + focus sections to markdown output**

Insert at the TOP of the markdown output (before `## Time Allocation`):

**IMPORTANT:** Use `lines.append()` (matching existing pattern), `datetime.now(timezone.utc)` (not `datetime.now(timezone.utc)` which is deprecated and returns naive datetimes), and `PORTFOLIO_PROJECTS` (already imported at module level in Task 1 Step 2).

```python
# Changes since last digest — insert BEFORE the existing Time Allocation section
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

# Neglect tracker (portfolio projects only)
# PORTFOLIO_PROJECTS imported at module level via config
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
```

- [ ] **Step 5: Verify digest builds**

Run: `cd server && python3 -c "from context_digest import build_digest; print('OK')"`

- [ ] **Step 6: Commit**

```bash
git add server/context-digest.py
git commit -m "feat: add cross-digest comparison, neglect tracker, and focus metric"
```

---

## Phase 2: New Daemon Signals

### Task 6: Add meeting/call detection to daemon

**Files:**
- Modify: `mac-daemon/context-daemon.sh` (insert after line 488, before exports at line 490)

- [ ] **Step 1: Add call detection section**

Insert after the notifications section and before the environment exports:

```bash
# --- Meeting / Call Detection ---
IN_CALL="false"
CALL_APP=""
CALL_TYPE="unknown"

# Check camera (VDCAssistant = camera in use)
CAMERA_ACTIVE="false"
if pgrep -x "VDCAssistant" >/dev/null 2>&1; then
  CAMERA_ACTIVE="true"
fi

# Check mic via ioreg (audio input active)
MIC_ACTIVE="false"
if ioreg -c AppleHDAEngineInput 2>/dev/null | grep -q "IOAudioEngineState = 1" 2>/dev/null; then
  MIC_ACTIVE="true"
fi

# If mic or camera is active, we're in a call
if [ "$CAMERA_ACTIVE" = "true" ] || [ "$MIC_ACTIVE" = "true" ]; then
  IN_CALL="true"

  if [ "$CAMERA_ACTIVE" = "true" ]; then
    CALL_TYPE="video"
  else
    CALL_TYPE="audio"
  fi

  # Identify the call app
  if pgrep -x "zoom.us" >/dev/null 2>&1; then
    CALL_APP="Zoom"
  elif pgrep -x "FaceTime" >/dev/null 2>&1; then
    CALL_APP="FaceTime"
  elif pgrep -x "Microsoft Teams" >/dev/null 2>&1 || pgrep -f "MSTeams" >/dev/null 2>&1; then
    CALL_APP="Teams"
  elif pgrep -x "Discord" >/dev/null 2>&1; then
    CALL_APP="Discord"
  elif pgrep -x "Slack" >/dev/null 2>&1; then
    CALL_APP="Slack"
  elif [ -n "$CHROME_ALL_TABS" ] && echo "$CHROME_ALL_TABS" | grep -qi "meet.google.com" 2>/dev/null; then
    CALL_APP="Google Meet"
  else
    CALL_APP="unknown"
  fi
fi
```

- [ ] **Step 2: Add exports and payload fields**

Add to the environment exports block:

```bash
export CB_IN_CALL="$IN_CALL"
export CB_CALL_APP="$CALL_APP"
export CB_CALL_TYPE="$CALL_TYPE"
```

Add to the Python payload builder dict:

```python
'in_call': os.environ.get('CB_IN_CALL', 'false') == 'true',
'call_app': os.environ.get('CB_CALL_APP', ''),
'call_type': os.environ.get('CB_CALL_TYPE', 'unknown'),
```

- [ ] **Step 3: Verify syntax**

Run: `bash -n mac-daemon/context-daemon.sh`

- [ ] **Step 4: Commit**

```bash
git add mac-daemon/context-daemon.sh
git commit -m "feat: add meeting/call detection to daemon"
```

---

### Task 7: Add Focus mode detection to daemon

**Files:**
- Modify: `mac-daemon/context-daemon.sh` (insert after call detection, before exports)

- [ ] **Step 1: Add Focus mode detection section**

```bash
# --- macOS Focus / DND Mode ---
FOCUS_MODE=""
# Try the shortcuts CLI approach first (most reliable on modern macOS)
FOCUS_MODE=$(osascript -e '
  try
    set focusState to do shell script "defaults read com.apple.controlcenter NSStatusItem\\ Visible\\ FocusModes 2>/dev/null || echo 0"
    if focusState is "1" then
      return "Focus"
    end if
  end try
  try
    set dndState to do shell script "plutil -extract dnd_prefs.userPref.enabled raw ~/Library/DoNotDisturb/DB/Assertions/DND.json 2>/dev/null || echo false"
    if dndState is "true" then
      return "Do Not Disturb"
    end if
  end try
  return ""
' 2>/dev/null || echo "")
```

- [ ] **Step 2: Add export and payload field**

Add to exports:

```bash
export CB_FOCUS_MODE="$FOCUS_MODE"
```

Add to Python payload builder:

```python
'focus_mode': os.environ.get('CB_FOCUS_MODE', '') or None,
```

- [ ] **Step 3: Verify syntax**

Run: `bash -n mac-daemon/context-daemon.sh`

- [ ] **Step 4: Commit**

```bash
git add mac-daemon/context-daemon.sh
git commit -m "feat: add macOS Focus/DND mode detection to daemon"
```

---

### Task 8: Add calendar awareness to daemon (opt-in)

**Files:**
- Modify: `mac-daemon/context-daemon.sh` (insert after Focus mode, before exports)
- Modify: `~/.context-bridge/privacy-rules.json` (add `calendar_enabled` flag)

- [ ] **Step 1: Add `calendar_enabled` to privacy rules**

Add to `~/.context-bridge/privacy-rules.json` at the top level:

```json
"calendar_enabled": true
```

- [ ] **Step 2: Add calendar capture section to daemon**

```bash
# --- Calendar Awareness (opt-in) ---
CALENDAR_EVENTS="[]"
CALENDAR_ENABLED=$(python3 -c "
import json
try:
    with open('$PRIVACY_RULES_FILE') as f:
        print('true' if json.load(f).get('calendar_enabled') else 'false')
except:
    print('false')
" 2>/dev/null || echo "false")

if [ "$CALENDAR_ENABLED" = "true" ]; then
  CALENDAR_EVENTS=$(osascript -l JavaScript -e '
    const app = Application("Calendar");
    app.includeStandardAdditions = true;
    const now = new Date();
    const twoHoursLater = new Date(now.getTime() + 2 * 60 * 60 * 1000);
    const results = [];
    try {
      const calendars = app.calendars();
      for (const cal of calendars) {
        const events = cal.events.whose({
          _and: [
            { startDate: { _lessThanEquals: twoHoursLater } },
            { endDate: { _greaterThanEquals: now } }
          ]
        })();
        for (const evt of events) {
          const title = evt.summary();
          const start = evt.startDate().toISOString();
          const end = evt.endDate().toISOString();
          const isNow = evt.startDate() <= now && evt.endDate() >= now;
          results.push({ title: title, start: start, end: end, is_now: isNow });
        }
      }
    } catch(e) {}
    JSON.stringify(results.slice(0, 10));
  ' 2>/dev/null || echo "[]")

  # Redact sensitive event titles (pass via env vars to avoid shell quoting issues)
  if [ "$CALENDAR_EVENTS" != "[]" ] && [ -n "$SENSITIVE_TITLE_KEYWORDS" ]; then
    export _CB_CAL_EVENTS="$CALENDAR_EVENTS"
    export _CB_SENSITIVE_KW="$SENSITIVE_TITLE_KEYWORDS"
    CALENDAR_EVENTS=$(python3 -c "
import json, os
events = json.loads(os.environ.get('_CB_CAL_EVENTS', '[]'))
sensitive = [kw.strip().lower() for kw in os.environ.get('_CB_SENSITIVE_KW', '').split('\n') if kw.strip()]
for evt in events:
    title_lower = evt.get('title', '').lower()
    for kw in sensitive:
        if kw in title_lower:
            evt['title'] = '[private event]'
            break
print(json.dumps(events))
" 2>/dev/null || echo "$CALENDAR_EVENTS")
    unset _CB_CAL_EVENTS _CB_SENSITIVE_KW
  fi
fi
```

- [ ] **Step 3: Add export and payload field**

Add to exports:

```bash
export CB_CALENDAR_EVENTS="$CALENDAR_EVENTS"
```

Add to Python payload builder:

```python
'calendar_events': os.environ.get('CB_CALENDAR_EVENTS', '[]'),
```

- [ ] **Step 4: Verify syntax**

Run: `bash -n mac-daemon/context-daemon.sh`

- [ ] **Step 5: Copy to deployed location**

```bash
cp mac-daemon/context-daemon.sh ~/.context-bridge/bin/context-bridge-daemon.sh
```

- [ ] **Step 6: Commit**

```bash
git add mac-daemon/context-daemon.sh
git commit -m "feat: add opt-in calendar awareness to daemon"
```

---

## Phase 3: the agent Integration

### Task 9: Add `status`, `since`, and `neglected` commands to context-query

**Files:**
- Modify: `server/context-query.py` (add three new command handlers + argparse subparsers)

- [ ] **Step 1: Add `cmd_status()` function**

Add after the existing `cmd_gaps()` function:

```python
def cmd_status(args):
    """One-shot pre-action summary for the agent."""
    conn = get_db()
    # Latest activity
    row = conn.execute(
        "SELECT * FROM activity_stream ORDER BY ts DESC LIMIT 1"
    ).fetchone()

    if not row:
        print("daemon_stale: true")
        print("last_activity: never")
        return

    # Current state
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
    import os
    print(f"daemon_stale: {os.path.exists(stale_flag)}")
    print(f"last_activity: {row['ts']}")

    conn.close()
```

- [ ] **Step 2: Add `cmd_since()` function**

```python
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
```

- [ ] **Step 3: Add `cmd_neglected()` function**

```python
def cmd_neglected(args):
    """Portfolio projects ranked by days since last activity."""
    conn = get_db()

    # Check project_last_seen table
    try:
        rows = conn.execute("SELECT project, last_seen FROM project_last_seen ORDER BY last_seen ASC").fetchall()
        last_seen = {r['project']: r['last_seen'] for r in rows}
    except:
        last_seen = {}

    # Also check recent raw data
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
                days = (datetime.now(timezone.utc) - last).days
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
```

- [ ] **Step 4: Add argparse subparsers**

**IMPORTANT:** The existing `context-query.py` does NOT use `set_defaults(func=...)`. It uses manual `if args.command == 'now':` dispatch (lines 220-229). You must match this existing pattern.

In the argparse setup section (around line 204), add the subparser definitions:

```python
sp_status = subparsers.add_parser('status', help='Pre-action summary for the agent')

sp_since = subparsers.add_parser('since', help='Cross-digest diff for last N hours')
sp_since.add_argument('hours', type=int, help='Hours to look back')

sp_neglected = subparsers.add_parser('neglected', help='Portfolio projects by inactivity')
```

Then in the dispatch block (lines 220-229), add the new elif branches:

```python
    elif args.command == 'status':
        cmd_status(args)
    elif args.command == 'since':
        cmd_since(args)
    elif args.command == 'neglected':
        cmd_neglected(args)
```

- [ ] **Step 5: Verify**

Run: `cd server && python3 context-query.py status --help && python3 context-query.py since --help && python3 context-query.py neglected --help`

- [ ] **Step 6: Commit**

```bash
git add server/context-query.py
git commit -m "feat: add status, since, and neglected commands to context-query"
```

---

### Task 10: Create staleness watchdog

**Files:**
- Create: `server/staleness-watchdog.sh`

- [ ] **Step 1: Create the watchdog script**

```bash
#!/bin/bash
# OpenClaw Context Bridge - Staleness Watchdog
# Runs via cron every 5 minutes.
# Writes /tmp/context-bridge-stale if no data arrived in the last 10 minutes.

set -euo pipefail

DB_PATH="${CONTEXT_BRIDGE_DB:-/home/user/clawrelay/data/context-bridge.db}"
STALE_FLAG="/tmp/context-bridge-stale"
THRESHOLD_MINUTES=10

if [ ! -f "$DB_PATH" ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) stale=true reason=db_missing" > "$STALE_FLAG"
  exit 0
fi

LATEST=$(sqlite3 "$DB_PATH" "SELECT MAX(created_at) FROM activity_stream;" 2>/dev/null || echo "")

if [ -z "$LATEST" ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) stale=true reason=no_data" > "$STALE_FLAG"
  exit 0
fi

AGE_SECONDS=$(python3 -c "
from datetime import datetime, timezone
latest = datetime.fromisoformat('$LATEST').replace(tzinfo=timezone.utc)
age = (datetime.now(timezone.utc) - latest).total_seconds()
print(int(age))
" 2>/dev/null || echo "9999")

if [ "$AGE_SECONDS" -gt $((THRESHOLD_MINUTES * 60)) ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) stale=true age_seconds=$AGE_SECONDS last=$LATEST" > "$STALE_FLAG"
else
  rm -f "$STALE_FLAG"
fi
```

- [ ] **Step 2: Make executable**

```bash
chmod +x server/staleness-watchdog.sh
```

- [ ] **Step 3: Commit**

```bash
git add server/staleness-watchdog.sh
git commit -m "feat: add staleness watchdog cron script"
```

---

### Task 11: Write the agent integration guide

**Files:**
- Create: `docs/jc-integration-guide.md`

- [ ] **Step 1: Write the guide**

```markdown
# the agent Integration Guide — Context Bridge

## Pre-Action Check

Before any autonomous action, the agent should run:

    STATUS=$(python3 /home/user/clawrelay/context-query.py status)

## Decision Rules

| Condition | Action |
|-----------|--------|
| `current_project: X` and the agent wants to work on X | **Don't.** the operator is active on it. Pick another project. |
| `in_call: True` | **Don't send Telegram.** the operator is in a meeting. |
| `focus_mode: <anything non-null>` | **Don't interrupt.** the operator enabled Focus mode. |
| `focus_level: scattered` | Good time to take things off the operator's plate. |
| `focus_level: focused` | Don't interrupt unless urgent. |
| `idle_state: away` or `locked` | the operator is away. Safe to work, but don't expect input. |
| `daemon_stale: True` | **Be conservative.** No recent data — you're operating blind. |

## Choosing What to Work On

    python3 /home/user/clawrelay/context-query.py neglected

Pick the project with the highest inactivity that has pending work.

## Checking What Changed

    python3 /home/user/clawrelay/context-query.py since 8

Shows new/continued/dropped work in the last 8 hours. Use this to detect abandoned work the operator started but didn't finish.

## Reading the Digest

The latest digest is always at:

    /home/user/clawrelay/memory/activity-digest/latest.md

Read it for full context: time allocation, project details, communication, AI sessions, open tabs, focus level, and cross-digest comparison.

## Digest Schedule

Digests are generated 3x daily at 10:00, 16:00, 23:00 CET.

## Crontab Setup (the agent's Server)

```cron
# Context Bridge - staleness watchdog
*/5 * * * * /home/user/clawrelay/staleness-watchdog.sh

# Context Bridge - digests (10:00, 16:00, 23:00 CET = 09:00, 15:00, 22:00 UTC)
0 9 * * * cd /opt/context-bridge && python3 context-digest.py >> /var/log/context-digest.log 2>&1
0 15 * * * cd /opt/context-bridge && python3 context-digest.py >> /var/log/context-digest.log 2>&1
0 22 * * * cd /opt/context-bridge && python3 context-digest.py >> /var/log/context-digest.log 2>&1
```
```

- [ ] **Step 2: Commit**

```bash
git add docs/jc-integration-guide.md
git commit -m "docs: add the agent integration guide with pre-action check pattern"
```

---

### Task 12: Update architecture docs to reflect changes

**Files:**
- Modify: `ARCHITECTURE.md` (note removal of LLM synthesis step)
- Modify: `ROADMAP.md` (check off completed Phase 1 items, update Phase 2/3 status)

- [ ] **Step 1: Update ARCHITECTURE.md**

Add a note in the digest section clarifying that LLM synthesis has been replaced by the agent's direct interpretation of rich mechanical digests.

- [ ] **Step 2: Update ROADMAP.md**

Mark completed items and note that Phase 2 integration and Phase 3 autonomy items covered by this implementation.

- [ ] **Step 3: Commit**

```bash
git add ARCHITECTURE.md ROADMAP.md
git commit -m "docs: update architecture and roadmap to reflect enhancement work"
```

---

### Task 13: Final deploy and push

- [ ] **Step 1: Copy updated daemon to deployed location**

```bash
cp mac-daemon/context-daemon.sh ~/.context-bridge/bin/context-bridge-daemon.sh
```

- [ ] **Step 2: Push all commits**

```bash
git push origin main
```
