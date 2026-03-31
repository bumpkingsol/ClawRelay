# App Switch Tracker Design

**Date:** 2026-03-28
**Status:** Approved
**Goal:** Replace snapshot-based activity capture with continuous app switch tracking, so time allocation and project detection are accurate regardless of what's frontmost at the 2-minute capture mark.

## Problem

The daemon captures a single snapshot every 2 minutes — whichever app is frontmost at that instant. If you work in VS Code for 1m50s and switch to Spotify for 10s at capture time, the system records Spotify. This makes time allocation inaccurate, project detection unreliable, and focus level misleading.

## Solution

ClawRelay (already running as a menu bar app) listens for every foreground app change via `NSWorkspace.didActivateApplicationNotification`. Each switch is logged with timestamp, app name, and window title. The daemon reads this log every 2 minutes, computes accurate time-per-app, and sends the weighted data instead of a single snapshot.

## Constraints

- ClawRelay must be running for switch tracking to work. If it's not running, the daemon falls back to the current snapshot behavior.
- The switch log file must respect pause state — if paused, don't write switches.
- Window title capture uses AppleScript (~50ms per switch). Acceptable overhead.
- The switch log is ephemeral — daemon truncates after reading.

---

## 1. ClawRelay: AppSwitchTracker Service

New `AppSwitchTracker.swift` singleton that:

1. Subscribes to `NSWorkspace.shared.notificationCenter` for `NSWorkspace.didActivateApplicationNotification` on init
2. On each notification:
   - Gets the activated app's `localizedName` from the notification's `NSWorkspaceApplicationKey`
   - Captures the window title via AppleScript: `tell application "System Events" to get name of front window of application process "<app>"`
   - Checks pause state: reads `~/.context-bridge/pause-until` — if paused, skip
   - Writes a JSON line to `~/.context-bridge/app-switches.jsonl`
3. Format per line:
   ```json
   {"ts":"2026-03-28T21:15:00Z","app":"Code","title":"project-delta-comingsoon-site"}
   ```
4. Prunes entries older than 5 minutes on each write (keeps file small)

**Started from:** `AppModel.init()` — called once on app launch, runs for the lifetime of the app.

**Pause awareness:** Before writing, check if `~/.context-bridge/pause-until` exists and is still in the future or "indefinite". If paused, don't log the switch.

**Files:**
- Create: `mac-helper/OpenClawHelper/Services/AppSwitchTracker.swift`
- Modify: `mac-helper/OpenClawHelper/AppModel.swift` — start tracker in init

---

## 2. Daemon: Read and Aggregate Switch Log

Replace the single-snapshot approach with switch log aggregation.

**Current flow (lines ~340-345 in context-daemon.sh):**
```
ACTIVE_APP = frontmost app at capture time
WINDOW_TITLE = window title at capture time
```

**New flow:**
```
1. Read ~/.context-bridge/app-switches.jsonl
2. If file exists and has entries:
   a. Compute time per app (each entry's duration = time until next entry)
   b. Pick dominant app (most total time)
   c. Use dominant app's most recent window title as WINDOW_TITLE
   d. Build app_times dict: {"Code": 85, "Google Chrome": 25}
   e. Build all window titles from the log for project matching
   f. Truncate the file
3. If file is empty or missing:
   a. Fall back to current snapshot behavior (osascript frontmost app)
```

**Aggregation logic (Python inline in the daemon):**
```python
import json, sys
from datetime import datetime

lines = open(sys.argv[1]).readlines()
entries = [json.loads(l) for l in lines if l.strip()]
if not entries:
    print(json.dumps({"fallback": True}))
    sys.exit(0)

# Compute time per app
app_times = {}
all_titles = []
for i, entry in enumerate(entries):
    ts = datetime.fromisoformat(entry['ts'])
    if i + 1 < len(entries):
        next_ts = datetime.fromisoformat(entries[i+1]['ts'])
        duration = (next_ts - ts).total_seconds()
    else:
        duration = (datetime.utcnow() - ts).total_seconds()
    duration = min(duration, 300)  # cap at 5 min
    app = entry['app']
    app_times[app] = app_times.get(app, 0) + duration
    if entry.get('title'):
        all_titles.append(entry['title'])

# Dominant app
dominant = max(app_times, key=app_times.get)
# Most recent title for dominant app
dominant_title = ''
for entry in reversed(entries):
    if entry['app'] == dominant:
        dominant_title = entry.get('title', '')
        break

print(json.dumps({
    "app": dominant,
    "title": dominant_title,
    "app_times": app_times,
    "all_titles": list(set(all_titles)),
}))
```

The daemon uses the output to set:
- `ACTIVE_APP` = dominant app
- `WINDOW_TITLE` = dominant app's title + all other titles appended as `[also: title1, title2]`
- No new DB column needed — the enriched `window_title` flows through existing storage

**Files:**
- Modify: `mac-daemon/context-daemon.sh` — replace snapshot capture with switch log aggregation, fallback to snapshot if no log

---

## 3. Server: No Changes Required

The enriched `window_title` field (containing all window titles from the switch log) flows through existing storage and matching. The dashboard endpoint already searches `window_title` for project keywords. No server changes needed.

---

## 4. What This Fixes

| Issue | Before | After |
|-------|--------|-------|
| "unknown" project when Spotify frontmost | Only sees Spotify | Sees VS Code had 85% of time, uses its title |
| Inaccurate time allocation | 1 sample per 2 min | Continuous tracking, accurate to the second |
| "Scattered" focus level | Random app sampling | Actual switch count between captures |
| Background editor workaround | Extra AppleScript per capture | Not needed — switches already include editor visits |
| Chrome tab detection | Fails when Chrome has no windows | Captured at switch time when Chrome was activated |

---

## What This Does NOT Include

- Tracking which window/tab within an app (only app-level switches)
- Persisting switch data beyond 5 minutes (ephemeral by design)
- Modifying the server schema (works with existing columns)
- Running without ClawRelay (falls back to snapshot mode)
