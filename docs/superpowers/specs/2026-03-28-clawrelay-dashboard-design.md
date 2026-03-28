# ClawRelay Dashboard Design

**Date:** 2026-03-28
**Status:** Approved
**Goal:** Add a personal operations dashboard to ClawRelay's Control Center that surfaces the intelligence the system produces — time allocation, focus level, JC's activity, project neglect, and handoff status — so Jonas has the same operational visibility that JC has.

## Background

ClawRelay sends data out but gives nothing back. The daemon captures activity, the digest produces intelligence (time allocation, neglect, focus level, cross-digest diffs), and JC can query all of it. But Jonas — the person doing the work — sees none of it. The dashboard closes this loop.

JC recently added a `/context/jc-work-log` endpoint that exposes JC's own work activity (project, description, status, duration). This makes bidirectional visibility possible.

## Constraints

- macOS SwiftUI app, follows existing DarkUtilityGlass theme with `.environment(\.colorScheme, .dark)`
- Data comes from the server via a single combined endpoint (one network call per refresh)
- Refreshes every 2 minutes when the Dashboard tab is visible, stops when tab is not selected
- Uses existing `BridgeCommandRunner.runActionWithOutput()` → `context-helperctl.sh` → `curl` pattern
- Must handle server unreachable gracefully (show stale data or "No data" state)

---

## 1. Dashboard Tab Placement

New tab in the Control Center sidebar, positioned first (before Overview). Icon: `chart.bar.xaxis` (SF Symbol). Default selected tab when Control Center opens.

**Files:**
- Modify: `mac-helper/OpenClawHelper/ViewModels/ControlCenterViewModel.swift` — add `.dashboard` as first case in `ControlCenterTab` enum, set as default `selectedTab`
- Modify: `mac-helper/OpenClawHelper/Views/ControlCenterView.swift` — add `.dashboard` case to detail switch and `tabIcon()`

---

## 2. Server Endpoint: `GET /context/dashboard`

Single endpoint that aggregates all dashboard data. Requires Bearer auth.

**Response:**
```json
{
  "status": {
    "current_app": "Cursor",
    "current_project": "prescrivia",
    "idle_state": "active",
    "idle_seconds": 45,
    "in_call": false,
    "focus_mode": null,
    "focus_level": "focused",
    "focus_switches_per_hour": 1.5,
    "daemon_stale": false,
    "last_activity": "2026-03-28T14:32:00Z"
  },
  "time_allocation": [
    {"project": "prescrivia", "hours": 2.3, "percentage": 48},
    {"project": "leverwork", "hours": 1.5, "percentage": 31},
    {"project": "jsvhq", "hours": 1.0, "percentage": 21}
  ],
  "neglected": [
    {"project": "sonopeace", "days": 5},
    {"project": "jsvhq", "days": 1},
    {"project": "openclaw", "days": 0}
  ],
  "jc_activity": [
    {"project": "leverwork", "description": "PR review", "status": "in-progress", "started_at": "2026-03-28T13:00:00Z"},
    {"project": "jsvhq", "description": "tax residency research", "status": "done", "completed_at": "2026-03-28T11:30:00Z", "duration_minutes": 45}
  ],
  "handoffs": [
    {"id": 1, "project": "jsvhq", "task": "tax research", "message": "", "priority": "normal", "status": "done", "created_at": "2026-03-28T10:00:00Z"},
    {"id": 2, "project": "leverwork", "task": "PR review", "message": "", "priority": "high", "status": "in-progress", "created_at": "2026-03-28T12:00:00Z"}
  ]
}
```

**Implementation:** The endpoint runs these queries in one DB connection:
1. **Status:** Latest `activity_stream` row for current app/project/idle state. Focus level computed from last 60 min of transitions (same logic as `cmd_status` in context-query.py). `focus_switches_per_hour` is the raw count of (app, project) transitions in the last hour.
2. **Time allocation:** Count captures per project from today's `activity_stream` rows, multiply by 2 min interval (same logic as `cmd_today`).
3. **Neglect:** Query `project_last_seen` table for days since last activity per portfolio project (same logic as `cmd_neglected`).
4. **JC activity:** Query `jc_work_log` table for last 48h entries.
5. **Handoffs:** Query `handoffs` table for last 10, include `message` field.

**NOW card data path:** The NOW card shows "time on it today" by looking up `status.current_project` in the `time_allocation` array to find matching hours. This cross-reference happens in the SwiftUI view, not the server.

**Files:**
- Modify: `server/context-receiver.py` — add `GET /context/dashboard` endpoint

---

## 3. Helperctl Command: `dashboard`

New command in `context-helperctl.sh` that curls `GET /context/dashboard` and returns the JSON.

Same pattern as `list-handoffs`: reads server-url, gets auth token from Keychain, curls with TLS args, prints response or `{}` on failure.

**Files:**
- Modify: `mac-daemon/context-helperctl.sh` — add `do_dashboard` function and `dashboard)` dispatch case

---

## 4. Swift Models

**`DashboardData`** — top-level decodable:
```swift
struct DashboardData: Decodable {
    let status: DashboardStatus
    let timeAllocation: [ProjectTime]
    let neglected: [ProjectNeglect]
    let jcActivity: [JCWorkEntry]
    let handoffs: [Handoff]  // reuse existing Handoff model
}
```

**Nested models:**
```swift
struct DashboardStatus: Decodable {
    let currentApp: String
    let currentProject: String
    let idleState: String
    let idleSeconds: Int
    let inCall: Bool
    let focusMode: String?
    let focusLevel: String
    let focusSwitchesPerHour: Double
    let daemonStale: Bool
    let lastActivity: String
}

struct ProjectTime: Decodable, Identifiable {
    var id: String { project }
    let project: String
    let hours: Double
    let percentage: Int
}

struct ProjectNeglect: Decodable, Identifiable {
    var id: String { project }
    let project: String
    let days: Int
}

struct JCWorkEntry: Decodable, Identifiable {
    let id: Int
    let project: String
    let description: String
    let status: String
    let startedAt: String
    let completedAt: String?
    let durationMinutes: Int?
}
```

All use `CodingKeys` for snake_case → camelCase mapping.

**Files:**
- Create: `mac-helper/OpenClawHelper/Models/DashboardData.swift`

---

## 5. DashboardViewModel

Annotated `@MainActor final class DashboardViewModel: ObservableObject` (matches existing `HandoffsTabViewModel` pattern).

Fetches dashboard data via `BridgeCommandRunner.runActionWithOutput("dashboard")`, decodes, publishes.

- `@Published var data: DashboardData?` — nil means no data yet
- `@Published var lastError: String?`
- `refreshDashboard()` — captures `runner` in local variable, runs blocking work in `Task.detached`, publishes results back via `await MainActor.run { [weak self] in ... }` (same pattern as `HandoffsTabViewModel.refreshHandoffs()`)
- `startPolling()` — `RefreshTimer` at 120 seconds, only while tab is visible
- `stopPolling()` — stops timer

**Files:**
- Create: `mac-helper/OpenClawHelper/ViewModels/DashboardViewModel.swift`

---

## 6. DashboardTabView — Cards Grid Layout

**Top row — 3 status cards (equal width):**

| Card | Content |
|------|---------|
| NOW | Current project name (bold), time on it today, idle state indicator |
| FOCUS | Focus level label (focused/multitasking/scattered), switches/hr, color-coded |
| JC | What JC is doing — latest in-progress entry from `jcActivity`, or "Idle" if none |

**Middle — Time allocation:**
- Horizontal progress bars per project, sorted by hours desc
- Each bar shows: project name, hours, percentage
- Color-coded per project (fixed palette)

**Bottom row — 2 panels:**

| Panel | Content |
|-------|---------|
| Needs Attention | Three groups in order: (1) Neglected projects >2 days, sorted by days desc; (2) JC in-progress items; (3) JC completed items (last 24h only). Each group has a distinct icon/color prefix. |
| Recent Handoffs | Last 5 handoffs with status badges (reuse badge components from HandoffsTabView) |

**Empty/error states:**
- No data: "Connecting to server..." with spinner
- Server unreachable: "Dashboard unavailable — server not reachable" with retry button
- Stale daemon: amber banner "Daemon data is stale — last capture was X ago"

**Files:**
- Create: `mac-helper/OpenClawHelper/Views/Tabs/DashboardTabView.swift`

---

## 7. Popover Summary Line

Add a single compact line at the top of the menu bar popover showing the current project and JC status. This is NOT a full dashboard — just a glanceable summary.

Format: `prescrivia 2.3h | JC: leverwork`

Data source: same `dashboard` helperctl command. `MenuBarViewModel` decodes the full `DashboardData` model but the popover only renders `data.status.currentProject`, `data.timeAllocation` (to find hours for current project), and `data.jcActivity.first` (latest JC entry). Fetched once on `onAppear`, no timer. Independent from `DashboardViewModel` — two separate fetches is acceptable since they don't overlap (popover opens when Control Center is closed and vice versa).

**Files:**
- Modify: `mac-helper/OpenClawHelper/Views/MenuBarPopoverView.swift` — add summary line above StatusHeaderView
- Modify: `mac-helper/OpenClawHelper/ViewModels/MenuBarViewModel.swift` — add `@Published var dashboard: DashboardData?`, fetch on appear via `runActionWithOutput("dashboard")`

---

## What This Does NOT Include

- Charts or graphs (time bars are simple progress bars, not charting library)
- Historical trends (shows today only, not week/month)
- Clickable project cards that navigate to project details
- Notifications or alerts pushed to macOS notification center
- Offline/local data fallback (server-only for now)
