# Context Bridge Enhancements Design

**Date:** 2026-03-28
**Status:** Approved
**Goal:** Make the context bridge deliver actionable intelligence to JC by fixing data loss bugs, enriching the digest with all captured signals, adding new daemon-side signals, and wiring JC's cron-based autonomy to check context before acting.

## Background

The context bridge captures activity from Jonas's Mac every 2 minutes and pushes it to JC's Hetzner server. An audit revealed:

- Several captured fields (WhatsApp, Codex sessions, terminal commands, file changes, notifications) are stored but never used by the digest processor.
- Notifications are captured by the daemon but silently dropped at the server due to a field mapping bug.
- The digest is mechanical extraction only — no cross-digest comparison, no abandoned work detection.
- High-value signals (meetings, calendar, Focus mode) are not captured at all.
- JC has no standard pattern for checking context before autonomous actions.

## Constraints

- Daemon runs on macOS (Apple Silicon, latest macOS).
- No third-party service dependencies. Calendar via macOS Calendar.app only (not Google Calendar API).
- JC interprets raw digests directly — no LLM synthesis in the digest. Note: ARCHITECTURE.md and DESIGN.md describe a Sonnet synthesis step in the digest. This spec intentionally removes that step — JC's own reasoning handles interpretation. The architecture docs should be updated to reflect this change.
- JC operates on cron-based scheduling.
- Privacy rules in `~/.context-bridge/privacy-rules.json` govern filtering. Calendar is opt-in.
- All existing security/privacy guarantees (sensitive app filtering, credential redaction, 48h raw data purge) remain in effect.

## Approach

Three phases, each building on the previous:

1. Fix + enrich foundation (make existing data useful)
2. New daemon signals (capture what's missing)
3. JC integration (wire JC to use the data)

---

## Phase 1: Fix + Enrich Foundation

### 1a. Fix notification storage bug

**Problem:** The daemon sends `notifications` as a JSON-encoded string containing pipe-delimited rows (`app_id|title|body`) from the macOS notification DB. `context-receiver.py`'s `sanitize_activity_payload()` extracts `data.get('notifications')` into the sanitized dict, but the INSERT statement does not include the `notification_app` or `notification_text` columns — it simply skips them entirely. The extracted value is discarded. The schema columns exist but remain NULL.

**Fix — two parts:**

1. **Daemon side:** change the notification capture to produce a proper JSON array instead of a pipe-delimited string wrapped in `json.dumps()`. Output: `[{"app": "com.apple.MobileSMS", "title": "New Message", "body": "Hey"}]`.
2. **Server side:** Replace the unused `notification_app` and `notification_text` columns with a single `notifications TEXT` column. In `sanitize_activity_payload()`, pass through the `notifications` JSON string. Add `notifications` to the INSERT statement column list and values tuple.

### 1b. Wire all captured-but-ignored fields into the digest

The digest processor (`context-digest.py`) currently outputs per-project time allocation, files touched, git branches, URLs visited, and git log. Add these sections to the digest markdown:

**Communication context:**
- WhatsApp active chat names from `whatsapp_context`, grouped by time period.
- Format: `## Communication` with timestamped entries showing who Jonas was chatting with.

**AI agent activity:**
- `codex_session` (task descriptions from active Claude/Codex sessions) and `codex_running` (boolean).
- Grouped by project when inferable from session task description or file path.
- Format: `## AI Agent Sessions` listing what AI tools were running and on what.

**Terminal activity:**
- `terminal_cmds` is already accumulated in `project_details['terminal_cmds']` but never rendered.
- Render the last N commands per project in the project detail section.
- Format: within each project section, a `### Terminal Commands` subsection.

**File change activity:**
- `file_changes` from fswatch, grouped by project directory.
- Format: within each project section, a `### File Changes` subsection listing changed paths.

**Active research (Chrome tabs):**
- `all_tabs` contains all open Chrome tab URLs and titles.
- Group tabs by project affinity (match URL/title against known project names/domains).
- Remaining tabs go in a "General Research" bucket.
- Format: `## Open Tabs` with grouped entries.

**Notifications:**
- `notifications` (once the storage bug is fixed), summarized as app + title.
- Format: `## Notifications` with timestamped entries.

### 1c. Cross-digest comparison

Each digest run queries the DB for the previous digest period's data (not by parsing markdown — by querying `activity_stream` for the prior time window).

**Computed diffs:**

- **New work:** projects/repos active in current period that were not active in the previous period.
- **Continued work:** same project active in both periods. If same branch, note as deep focus.
- **Dropped work:** projects active in previous period, absent in current period. Potential abandoned work signal.
- **Neglect tracker:** for each known portfolio project, compute days since last activity. Since raw data has 48h retention, the neglect tracker maintains a persistent `project_last_seen` table in the DB (updated each digest run with the latest activity timestamp per project). This table survives the raw data purge and provides accurate "days since last activity" even for projects inactive for weeks.

**Previous period boundary:** The "previous period" is defined as the time window of equal length immediately before the current digest window. For an 8-hour digest covering 05:00-13:00, the previous period is 21:00-05:00. If no data exists in the previous period (e.g., overnight), the comparison uses the most recent period that has data.

**Canonical project list:** All three files that reference portfolio projects (`context-digest.py`, `context-query.py`, and the neglect tracker) must import from a single shared constant defined in a `server/config.py` module. This eliminates the current divergence between hardcoded lists.

**Output:** A `## Changes Since Last Digest` section at the top of the digest, before time allocation. Contains:
```
### New work this period
- sonopeace (first activity in 4 days)

### Continued from last period
- prescrivia (same branch: feature/notifications, deep focus)

### Dropped since last period
- leverwork (was active last period, no activity this period)

### Project neglect
- jsvhq: 6 days since last activity
- sonopeace: 0 days (active now)
- leverwork: 1 day
- prescrivia: 0 days (active now)
```

---

## Phase 2: New Daemon Signals

### 2a. Meeting/call detection

At each capture cycle, the daemon detects whether Jonas is in a call.

**Detection methods:**

1. **Process detection:** check if Zoom (`zoom.us`), FaceTime, Microsoft Teams, Discord, or Slack is running with an active call window. For Google Meet, check Chrome tabs for `meet.google.com` URLs — but only consider it an active call if mic/camera is also active (to avoid false positives from lobby pages or stale tabs).
2. **Mic/camera state:** check if the microphone or camera is active by looking for `VDCAssistant` (camera) process or checking `ioreg` for audio input activity. This catches calls on any app, including ones not explicitly listed. Mic/camera detection is the primary signal; process detection provides the `call_app` label.

**Payload fields:**
```json
{
  "in_call": true,
  "call_app": "Zoom",
  "call_type": "video"
}
```

- `in_call`: boolean
- `call_app`: detected app name or "unknown"
- `call_type`: "video" (camera active), "audio" (mic only), "unknown"

**Behavior:** When `in_call` is true, the daemon still captures full context (open tabs, files, git state). This is intentional — JC needs to know what project the meeting is about (from screen shares or open tabs). The digest marks these periods as "in meeting."

**Server schema:** Add `in_call BOOLEAN DEFAULT FALSE`, `call_app TEXT`, `call_type TEXT` to `activity_stream`.

**Digest output:** Meeting periods appear in the time allocation with a meeting annotation:
```
- prescrivia: 2.5h (includes 1h in Zoom call)
```

### 2b. macOS Focus/DND mode

**Detection:** Best-effort, may require version-specific approaches across macOS releases. Primary method: use the `shortcuts` CLI to query DND/Focus status, or a small Swift helper using the private `FocusStatusCenter` framework. Fallback: check `defaults read com.apple.controlcenter` or `assertiond` DND assertions. If detection fails on the current macOS version, the field is `null` (graceful degradation, not an error).

**Payload field:**
```json
{
  "focus_mode": "Do Not Disturb"
}
```

- `focus_mode`: string name of active Focus mode, or `null` if none active.

**Server schema:** Add `focus_mode TEXT` to `activity_stream`.

**Digest output:** Focus mode periods noted in the time allocation:
```
- 14:00-16:30: Focus mode "Work" active
```

### 2c. Calendar awareness (opt-in)

**Opt-in gate:** Only runs if `~/.context-bridge/privacy-rules.json` contains `"calendar_enabled": true`. If the key is missing or false, calendar capture is skipped entirely.

**Detection:** AppleScript query to macOS Calendar.app:
- Events currently happening (start <= now <= end)
- Events starting in the next 2 hours

**Privacy filtering:** Event titles containing sensitive keywords ("medical", "doctor", "therapy", "lawyer", "dentist", "counselor") are redacted to `[private event]`. The sensitive title keywords list from `privacy-rules.json` is reused.

**Payload field:**
```json
{
  "calendar_events": [
    {"title": "Sprint Planning", "start": "2026-03-28T14:00:00", "end": "2026-03-28T14:30:00", "is_now": true},
    {"title": "1:1 with Nil", "start": "2026-03-28T16:00:00", "end": "2026-03-28T16:30:00", "is_now": false}
  ]
}
```

No attendees, no descriptions, no locations — titles only.

**Server schema:** Add `calendar_events TEXT` (JSON) to `activity_stream`.

**Digest output:** `## Calendar` section listing events that occurred during the period and upcoming events at digest generation time.

### 2d. Context switching metric (server-side)

Computed in the digest, not the daemon. The daemon already sends `app` and project context every 2 minutes.

**Computation:** For each hour in the digest period, count distinct (app, inferred_project) transitions. A transition is when the current record's app+project differs from the previous record's.

**Classification:**
- 0-3 transitions/hour: **focused**
- 4-7 transitions/hour: **multitasking**
- 8+ transitions/hour: **scattered**

**Digest output:** Per-period focus assessment:
```
## Focus Level
- 09:00-12:00: focused (1.5 switches/hr, primarily prescrivia)
- 12:00-13:00: scattered (9 switches/hr)
- 13:00-17:00: multitasking (5 switches/hr, prescrivia + leverwork)
```

---

## Phase 3: JC Integration

### 3a. Enhanced `context-query.py`

Existing commands: `now`, `today`, `project <name>`, `gaps`.

**New commands:**

**`context-query.py status`** — one-shot pre-action summary for JC. Returns:
```
current_app: Cursor
current_project: prescrivia
idle_state: active
idle_seconds: 45
in_call: false
focus_mode: null
focus_level: focused
time_on_current_project_today: 3.2h
upcoming_calendar:
  - "Sprint Planning" in 45 min
daemon_stale: false
last_activity: 2026-03-28T14:32:00Z
```

The `focus_level` is computed live by querying the last 60 minutes of `activity_stream` data and counting app+project transitions (same logic as the digest's context switching metric in 2d). Designed to be parsed by JC and used as a decision input.

**`context-query.py since <hours>`** — cross-digest style diff for the last N hours. Returns new/continued/dropped work and neglect data. Useful when JC wants a fresh comparison without waiting for the next scheduled digest.

**`context-query.py neglected`** — portfolio projects ranked by days since last activity. Returns:
```
jsvhq: 6 days
leverwork: 3 days
sonopeace: 1 day
prescrivia: 0 days (active now)
```

### 3b. JC pre-action check pattern

JC's cron jobs follow this convention before any autonomous action:

```bash
STATUS=$(python3 context-query.py status)
```

Decision rules (documented, not enforced by code):

- **Don't act on project X** if Jonas is currently active on X (`current_project` matches).
- **Don't send Telegram** if `in_call: true` or `focus_mode` is non-null.
- **Prefer project Y** if Y appears in `neglected` output with highest inactivity.
- **Be conservative** if `daemon_stale: true` — JC is operating blind.
- **Delay if idle/away** and the action would need Jonas's input soon.

This pattern is documented in a `docs/jc-integration-guide.md` that JC's system prompt can reference.

### 3c. Staleness watchdog

A lightweight cron job on JC's server, independent of JC's main cron:

- Runs every 5 minutes.
- Checks: has a new record arrived in `activity_stream` in the last 10 minutes?
- If stale: writes a flag file (e.g., `/tmp/context-bridge-stale`) that `context-query.py status` checks.
- If fresh: removes the flag file.

The `status` command reads this flag and includes `daemon_stale: true/false` in its output.

### 3d. Digest scheduling

Install crontab entries on JC's server for 3x daily digest runs. The existing schedule documented in ARCHITECTURE.md, DESIGN.md, and the `context-digest.py` docstring is 10:00, 16:00, 23:00 CET. **Keep this existing schedule** — no change.

- 10:00 CET — covers early morning work
- 16:00 CET — covers midday work
- 23:00 CET — covers afternoon/evening work

Each run: `python3 context-digest.py` which produces `memory/activity-digest/YYYY-MM-DD-HH.md` and updates the `latest.md` symlink.

These cron entries do not currently exist on the server and need to be installed.

---

## Schema Changes Summary

**`activity_stream` table — new/modified columns:**

| Column | Type | Description |
|--------|------|-------------|
| `notifications` | TEXT | JSON array of {app, title, body} (replaces unused notification_app/notification_text) |
| `in_call` | BOOLEAN | Whether Jonas is in a call |
| `call_app` | TEXT | Which app the call is on |
| `call_type` | TEXT | "video", "audio", or "unknown" |
| `focus_mode` | TEXT | Active macOS Focus mode name, or NULL |
| `calendar_events` | TEXT | JSON array of {title, start, end, is_now} |

**Removed columns:** `notification_app`, `notification_text` (migrated to single `notifications` column).

**New table:**

| Table | Purpose |
|-------|---------|
| `project_last_seen` | Persistent record of last activity timestamp per project. Updated each digest run. Survives the 48h raw data purge. Columns: `project TEXT PRIMARY KEY`, `last_seen TEXT`, `last_branch TEXT`. |

**Migration strategy:** Given the 48h raw data retention, the simplest migration is to drop and recreate the `activity_stream` table with the new schema. No data older than 48h exists, and any in-flight data will be re-captured within 2 minutes. The `init_db()` function should be updated to include the new columns. The `project_last_seen` table is created fresh (no existing data to migrate).

---

## New File: `server/config.py`

Shared constants imported by `context-receiver.py`, `context-digest.py`, and `context-query.py`:

```python
PORTFOLIO_PROJECTS = {
    'prescrivia': ['prescrivia'],
    'leverwork': ['leverwork'],
    'jsvhq': ['jsvhq', 'jsvcapital'],
    'sonopeace': ['sonopeace'],
    'openclaw': ['openclaw-computer-vision', 'openclaw-macos-helper'],
}
```

This eliminates the current divergence between three separate hardcoded project lists.

---

## Files Modified

**Daemon side (Mac):**
- `mac-daemon/context-daemon.sh` — add meeting detection, Focus mode, calendar capture
- `~/.context-bridge/privacy-rules.json` — add `calendar_enabled` flag, calendar-specific sensitive title keywords

**Server side (Hetzner):**
- `server/context-receiver.py` — fix notification mapping, add new columns to schema + INSERT
- `server/context-digest.py` — wire all fields into digest output, add cross-digest comparison, add focus level computation, add new sections (communication, AI sessions, terminal, file changes, tabs, notifications, calendar, changes since last digest)
- `server/context-query.py` — add `status`, `since`, `neglected` commands

**New files:**
- `server/config.py` — shared constants (portfolio project list) imported by all server scripts
- `server/staleness-watchdog.sh` — lightweight cron script for daemon staleness detection
- `docs/jc-integration-guide.md` — documents the pre-action check pattern for JC

---

## What This Does NOT Include

- LLM synthesis in the digest (JC reasons over raw data directly).
- Google Calendar API integration (macOS Calendar.app only).
- Content capture from documents (daemon captures metadata/URLs, JC reads docs via `gog` CLI during digest).
- Notification content filtering beyond what macOS provides (we store what the notification DB gives us).
- Real-time push/websocket to JC (stays pull-based via cron + query).
