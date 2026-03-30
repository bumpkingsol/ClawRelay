# ClawRelay: Notifications, Historical View, and Bootstrap Fix

**Date:** 2026-03-28
**Status:** Approved
**Goal:** Three independent improvements: (1) push macOS notifications for handoff updates, neglect alerts, and the agent questions; (2) add a historical time view to the dashboard; (3) fix the "999 days" bootstrap problem so the dashboard shows real data immediately.

---

## Feature 1: Bootstrap Neglect Data

### Problem

The `project_last_seen` table is only populated when the digest processor runs (3x daily via cron). Until then, the dashboard shows "999d" for every project.

### Fix

In the `GET /context/dashboard` endpoint, when building the neglect section:

1. Query `project_last_seen` as today.
2. Also scan `activity_stream` (last 48h) for the most recent timestamp per portfolio project.
3. Use whichever is more recent for each project.
4. Call `update_project_last_seen()` (or equivalent inline upsert) from the dashboard endpoint itself, so the table gets populated on every dashboard request — not just on digest runs.

This is a server-side change only. No Swift changes needed.

**Files:**
- Modify: `server/context-receiver.py` — update the neglect section of the dashboard endpoint

---

## Feature 2: macOS Notifications

### Triggers

Three events trigger native macOS notifications from ClawRelay:

1. **Handoff status change** — the agent marks a handoff as "in-progress" or "done"
   - Example: "The agent started: fix deploy script (project-alpha)"
   - Example: "The agent completed: PR review (project-alpha)"

2. **Neglect threshold** — any portfolio project crosses 7+ days of inactivity
   - Example: "Project Delta hasn't been touched in 10 days"
   - Checked once daily (tracked via UserDefaults date flag, not on every poll)

3. **Agent question** — the agent posts a question that needs the operator's attention
   - Example: "The agent asks: Should I pick up the auth migration on project-alpha?"

### Detection Mechanism

ClawRelay already polls the dashboard every 2 minutes (DashboardViewModel). On each poll, compare new data against the previous snapshot:

- **Handoffs:** Diff handoff statuses. If any changed to "in-progress" or "done" since last poll, send notification. Track seen handoff state by ID in a local dictionary (not persisted — resets on app restart, which is fine).
- **Neglect:** On each poll, check if any project in `neglected` has `days >= 7`. Only notify once per day per project (store last-notified date per project in UserDefaults).
- **agent questions:** Dashboard response includes a `agent_questions` array. If it contains entries with IDs not seen before, notify for each. Mark as seen via PATCH.

### Server-Side Additions

**New table:**
```sql
CREATE TABLE IF NOT EXISTS agent_questions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    question TEXT NOT NULL,
    project TEXT,
    created_at TEXT DEFAULT (datetime('now')),
    seen INTEGER DEFAULT 0
);
```

**New endpoint: `POST /context/jc-question`**
The agent writes a question. Requires Bearer auth. Body: `{"question": "Should I pick up X?", "project": "project-alpha"}`

**New endpoint: `PATCH /context/jc-question/<id>`**
ClawRelay marks a question as seen. Requires Bearer auth. Body: `{"seen": true}`

**Dashboard response addition:**
Add `agent_questions` to the dashboard response — unseen questions only:
```json
"agent_questions": [
    {"id": 1, "question": "Should I pick up the auth migration?", "project": "project-alpha", "created_at": "2026-03-28T20:00:00"}
]
```

### Swift-Side Implementation

**Notification service:** New `NotificationService.swift` that wraps `UNUserNotificationCenter`:
- `requestPermission()` — called on first app launch
- `sendNotification(title:body:)` — posts a local notification
- Tapping a notification opens the Control Center (via `UNNotificationAction`)

**Detection logic in DashboardViewModel:**
- After each successful `refreshDashboard()`, call `checkForNotifications(old: previousData, new: data)`
- This method diffs handoffs, checks neglect, checks agent_questions
- Calls `NotificationService` for each trigger
- Stores previous data snapshot for comparison

**Helperctl addition:** New `mark-question-seen` command that PATCHes `/context/jc-question/<id>`.

### Models

Add to `DashboardData`:
```swift
let agentQuestions: [AgentQuestion]

// In CodingKeys:
case agentQuestions = "agent_questions"
```

New model:
```swift
struct AgentQuestion: Decodable, Identifiable {
    let id: Int
    let question: String
    let project: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, question, project
        case createdAt = "created_at"
    }
}
```

**Files:**
- Create: `mac-helper/OpenClawHelper/Services/NotificationService.swift`
- Modify: `mac-helper/OpenClawHelper/Models/DashboardData.swift` — add `agentQuestions` and `AgentQuestion`
- Modify: `mac-helper/OpenClawHelper/ViewModels/DashboardViewModel.swift` — add notification detection
- Modify: `mac-daemon/context-helperctl.sh` — add `mark-question-seen` command
- Modify: `server/context-receiver.py` — add agent_questions table, POST/PATCH endpoints, include in dashboard

---

## Feature 3: Historical View

### Storage

New `daily_summary` table:
```sql
CREATE TABLE IF NOT EXISTS daily_summary (
    date TEXT NOT NULL,
    project TEXT NOT NULL,
    hours REAL NOT NULL,
    captures INTEGER NOT NULL,
    PRIMARY KEY (date, project)
);
```

### Population

Two sources populate this table:

1. **Digest processor** (`context-digest.py`) — writes rows per project per day each time it runs. Uses `INSERT OR REPLACE` for idempotency.
2. **Dashboard endpoint** — populates today's row from live `activity_stream` data on each request, so the historical view is current even between digest runs.

### Server Endpoint

Extend `GET /context/dashboard` with optional `?history_days=7` query parameter (default: 7, max: 30).

Add to the response:
```json
"history": [
    {"date": "2026-03-28", "project": "project-gamma", "hours": 2.3},
    {"date": "2026-03-28", "project": "project-alpha", "hours": 1.5},
    {"date": "2026-03-27", "project": "project-gamma", "hours": 4.1}
]
```

Queries `daily_summary` for the requested range, supplements today with live data.

### Swift Models

Add to `DashboardData`:
```swift
let history: [DailyEntry]
```

Default to empty for backward compatibility (use `decodeIfPresent` or make optional).

New model:
```swift
struct DailyEntry: Decodable, Identifiable {
    var id: String { "\(date)-\(project)" }
    let date: String
    let project: String
    let hours: Double
}
```

### UI

New "This Week" section in `DashboardTabView`, below Time Allocation:
- Segmented picker: "7 days" / "30 days" (changes `history_days` parameter on next refresh)
- Per-day horizontal stacked bars, one row per date (most recent at top)
- Each segment of the bar represents a project, color-coded (same palette as Time Allocation)
- Day label on the left (Mon, Tue, etc.), total hours on the right

**Files:**
- Create: `daily_summary` table in `init_db()` in `server/context-receiver.py`
- Modify: `server/context-receiver.py` — dashboard endpoint adds history data, populates today's summary
- Modify: `server/context-digest.py` — write daily_summary rows during digest run
- Modify: `mac-helper/OpenClawHelper/Models/DashboardData.swift` — add `history` and `DailyEntry`
- Modify: `mac-helper/OpenClawHelper/Views/Tabs/DashboardTabView.swift` — add history section with stacked bars
- Modify: `mac-helper/OpenClawHelper/ViewModels/DashboardViewModel.swift` — add `historyDays` state and pass as parameter

---

## What This Does NOT Include

- Notification grouping or threading (each notification is standalone)
- Notification preferences UI in ClawRelay (all three types are always on)
- Historical data export or CSV download
- Weekly/monthly summary reports
- the agent question response from ClawRelay (the operator responds via Telegram, not the app)
