# ClawRelay Handoff Redesign

**Date:** 2026-03-28
**Status:** Approved
**Goal:** Rename the helper app to ClawRelay, redesign the task handoff feature with a two-tier UI (quick handoff in menu bar, full form in Control Center), add bidirectional status tracking, and wire the handoff outbox flush into the daemon.

## Background

The helper app (currently "OpenClaw Helper") provides a menu bar popover and a Control Center window for managing the context bridge daemon. It has a basic handoff feature — a modal with Project/Task/Message fields — but the UI has dark-on-dark text issues, and handoff JSON files written to the outbox are never actually sent to the server (no flush mechanism).

The app is being renamed to **ClawRelay** to give it a distinct identity from the OpenClaw project itself.

## Constraints

- macOS app built in SwiftUI (Apple Silicon, latest macOS)
- Handoffs flow through `context-helperctl.sh` CLI → JSON files in `~/.context-bridge/handoff-outbox/` → daemon flushes to server
- Server runs Flask on VPS, accessed via Tailscale
- Bearer token auth on all server endpoints
- All UI uses the existing DarkUtilityGlass theme with `.environment(\.colorScheme, .dark)`
- Portfolio projects list is hardcoded in the Swift app (matching server/config.py's PORTFOLIO_PROJECTS)

---

## 1. Rename: OpenClaw Helper → ClawRelay

All user-facing strings change:
- Menu bar item label: "ClawRelay"
- Window title: "ClawRelay" (was "OpenClaw Control Center")
- App bundle display name in Info.plist: "ClawRelay"
- Xcode scheme/target names remain unchanged (internal)

**Files:**
- `mac-helper/OpenClawHelper/OpenClawHelperApp.swift` — MenuBarExtra title, Window title
- `mac-helper/OpenClawHelper/Support/OpenClawHelper-Info.plist` — CFBundleDisplayName / CFBundleName

---

## 2. Menu Bar Quick Handoff

Added to the menu bar popover (MenuBarPopoverView), between the quick actions grid and the "Open Control Center" button.

**Layout (compact, fits popover width of 340pt):**
- Row 1: Combo box for project (dropdown with portfolio projects + freeform typing)
- Row 2: Single-line text field (placeholder: "What should the agent do?") + send button (SF Symbol `arrow.up.circle.fill`)
- Visual separator (thin divider) above the handoff row to distinguish it from quick actions

**Behavior:**
- Enter key or send button click → creates handoff with project + task, empty message, "normal" priority
- After sending: text field clears, brief inline "Sent" label that fades after 2 seconds
- Project combo box remembers last selection via UserDefaults
- If task field is empty, send button is disabled
- If project is empty, defaults to "general"

**Data flow:**
- Calls `BridgeCommandRunner.runAction("queue-handoff", project, task, "", "normal")` — `runAction` accepts variadic `String...` args (confirmed in BridgeCommandRunner.swift:36)
- Same path as the full form — writes JSON to handoff outbox

**Validation:** The menu bar quick handoff uses simpler validation than the full form — only task must be non-empty. If project is empty, it defaults to "general" before calling runAction (coerced in the view model, not in HandoffDraft.isValid).

**Files:**
- `mac-helper/OpenClawHelper/Views/MenuBarPopoverView.swift` — add quick handoff section
- `mac-helper/OpenClawHelper/ViewModels/MenuBarViewModel.swift` — add handoff state (project, task, lastProject in UserDefaults, send method, sent confirmation timer)

---

## 3. Handoffs Tab in Control Center

New 5th tab in the sidebar, between Privacy and Diagnostics. Icon: `paperplane` (SF Symbol).

### 3a. Compose Section (top)

- **Project:** Combo box — dropdown with portfolio projects (Project Gamma, Project Alpha, Project Beta, Project Delta, OpenClaw) + freeform typing. Remembers last selection.
- **Task:** Single-line text field. Required.
- **Message:** Multi-line TextEditor for detailed context (links, file paths, instructions). Optional.
- **Priority:** Segmented picker — Normal (default), High, Urgent.
- **Send button:** Disabled if task is empty. On send: clears form, shows brief confirmation.

### 3b. Handoff History (bottom)

A scrollable list of recent handoffs, most recent first (up to 50).

**Each row shows:**
- Project name (bold)
- Task description (truncated to one line)
- Priority badge: Normal = no badge, High = orange pill, Urgent = red pill
- Status badge: pending = gray, in-progress = orange, done = green
- Relative timestamp ("2 min ago", "1h ago", "yesterday")

**Expanding a row** reveals the full message text (if any).

**Data source:** Polled from server via `context-helperctl.sh list-handoffs` every 30 seconds while the Handoffs tab is visible. Stops polling when tab is not selected.

### 3c. View Model

New `HandoffsTabViewModel`:
- Published properties: `handoffs: [Handoff]`, `draft: HandoffDraft`, `isSubmitting`, `sentConfirmation`
- Methods: `submit()`, `refreshHandoffs()`, `startPolling()`, `stopPolling()`
- Uses `BridgeCommandRunner` for both sending and listing

### 3d. Model Updates

Extend `HandoffDraft` to include `priority: String` (values: "normal", "high", "urgent"). Default: "normal".

New `Handoff` model (for the history list):
```
struct Handoff: Identifiable, Decodable {
    let id: Int
    let project: String
    let task: String
    let message: String
    let priority: String
    let status: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, project, task, message, priority, status
        case createdAt = "created_at"
    }
}
```

Note: The server returns `created_at` (snake_case). The CodingKeys enum maps it to `createdAt` for Swift convention.

**Files:**
- Create: `mac-helper/OpenClawHelper/Views/Tabs/HandoffsTabView.swift`
- Create: `mac-helper/OpenClawHelper/ViewModels/HandoffsTabViewModel.swift`
- Create: `mac-helper/OpenClawHelper/Models/Handoff.swift`
- Modify: `mac-helper/OpenClawHelper/Models/HandoffDraft.swift` — add priority field
- Modify: `mac-helper/OpenClawHelper/Views/ControlCenterView.swift` — add .handoffs case to sidebar detail switch AND to `tabIcon()` function (must be exhaustive)
- Modify: `mac-helper/OpenClawHelper/ViewModels/ControlCenterViewModel.swift` — add .handoffs to ControlCenterTab enum (ForEach(ControlCenterTab.allCases) auto-picks it up)

---

## 4. Server-side Changes

### 4a. Schema: add priority column

```sql
ALTER TABLE handoffs ADD COLUMN priority TEXT DEFAULT 'normal';
```

Since the handoffs table is created lazily (CREATE TABLE IF NOT EXISTS inside the POST handler), just add `priority` to the CREATE statement. Existing rows get NULL which is treated as "normal".

### 4b. Update `POST /context/handoff`

Accept and store `priority` from the request body. Validate that priority is one of: normal, high, urgent. Default to "normal" if missing.

### 4c. New endpoint: `GET /context/handoffs`

Returns the last 50 handoffs ordered by created_at desc. Requires Bearer auth.

Response body:
```json
[
  {
    "id": 1,
    "project": "project-gamma",
    "task": "fix deploy script",
    "message": "The staging deploy is broken since the last merge...",
    "priority": "high",
    "status": "pending",
    "created_at": "2026-03-28T15:00:00"
  }
]
```

### 4d. New endpoint: `PATCH /context/handoffs/<id>`

The agent updates handoff status. Requires Bearer auth.

Request body: `{"status": "in-progress"}` or `{"status": "done"}`

Valid transitions: pending → in-progress, in-progress → done, pending → done (skip in-progress). Returns 400 with `{"error": "invalid status transition"}` for invalid transitions or unknown status values. Returns 404 with `{"error": "handoff not found"}` for unknown IDs.

**Files:**
- `server/context-receiver.py` — update POST handler, add GET and PATCH endpoints, update CREATE TABLE

---

## 5. Daemon Handoff Flush

### 5a. Flush outbox in daemon capture cycle

Add a flush step at the end of `mac-daemon/context-daemon.sh` (deployed as `~/.context-bridge/bin/context-bridge-daemon.sh`), after sending the main payload:

```
Scan ~/.context-bridge/handoff-outbox/ for *.json files
For each file:
  POST contents to $SERVER_URL (replacing /push with /handoff in the URL)
  If 201 response: delete the file
  If failure: leave for next cycle
```

Uses the same auth token and TLS cert as the main payload. Runs every 2 minutes with the daemon.

### 5b. New helperctl action: `list-handoffs`

Add `list-handoffs` command to `context-helperctl.sh` that:
- Curls `GET /context/handoffs` (same server URL base, same auth token, same TLS args)
- Returns the JSON response to stdout
- On curl failure (network error, non-200 status): prints `[]` to stdout (empty array), exits 0. The Swift app treats empty arrays as "no data" — the UI shows "No handoffs yet" rather than an error.
- The Swift app's HandoffsTabViewModel parses this JSON via `BridgeCommandRunner.runAction` extended with a new `runActionWithOutput` method that returns stdout as Data.

### 5c. Update `queue-handoff` to accept priority

The `do_queue_handoff()` function in `context-helperctl.sh` accepts an optional 4th argument for priority. Default to `"normal"` when the 4th arg is absent (backward-compatible with old callers). Include it in the JSON file:
```json
{"project": "...", "task": "...", "message": "...", "priority": "high", "ts": "..."}
```

**Files:**
- `mac-daemon/context-daemon.sh` — add handoff outbox flush after main payload
- `mac-daemon/context-helperctl.sh` — update queue-handoff, add list-handoffs
- `~/.context-bridge/bin/context-helperctl.sh` — deployed copy

---

## 6. Old Handoff UI Cleanup

Remove the old handoff sheet and its references:
- Delete: `mac-helper/OpenClawHelper/Views/Sheets/HandoffSheetView.swift`
- Delete: `mac-helper/OpenClawHelper/ViewModels/HandoffViewModel.swift`
- Modify: `mac-helper/OpenClawHelper/Views/Tabs/PrivacyTabView.swift` — remove "Quick Handoff" section and sheet presentation

---

## What This Does NOT Include

- Keyboard shortcut / global hotkey for handoff (could add later)
- File attachments on handoffs
- the agent auto-acknowledging handoffs (The agent updates status manually or via its own logic)
- Handoff editing or deletion after sending
- Push notifications when the agent updates status (polling only)
