# ClawRelay Handoff Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the helper app to ClawRelay, add two-tier task handoff (quick in menu bar, full in Control Center), bidirectional status tracking, and daemon handoff flush.

**Architecture:** Swift/SwiftUI menu bar app communicates with shell scripts via BridgeCommandRunner. Handoffs flow: Swift → helperctl → JSON outbox → daemon flush → server endpoint. Server stores handoffs in SQLite, exposes GET/PATCH for status tracking, ClawRelay polls for updates.

**Tech Stack:** SwiftUI (macOS), Bash (helperctl/daemon), Python 3/Flask/SQLite (server)

**Spec:** `docs/superpowers/specs/2026-03-28-clawrelay-handoff-design.md`

---

## File Structure

**New files:**
- `mac-helper/OpenClawHelper/Views/Tabs/HandoffsTabView.swift` — compose form + history list
- `mac-helper/OpenClawHelper/ViewModels/HandoffsTabViewModel.swift` — handoff state, polling, submission
- `mac-helper/OpenClawHelper/Models/Handoff.swift` — decodable model for server handoff records

**Modified files:**
- `mac-helper/OpenClawHelper/OpenClawHelperApp.swift` — rename strings
- `mac-helper/OpenClawHelper/Support/OpenClawHelper-Info.plist` — add CFBundleDisplayName
- `mac-helper/OpenClawHelper/Views/MenuBarPopoverView.swift` — add quick handoff row
- `mac-helper/OpenClawHelper/ViewModels/MenuBarViewModel.swift` — add handoff state/methods
- `mac-helper/OpenClawHelper/Views/ControlCenterView.swift` — add .handoffs tab + icon
- `mac-helper/OpenClawHelper/ViewModels/ControlCenterViewModel.swift` — add .handoffs to enum
- `mac-helper/OpenClawHelper/Models/HandoffDraft.swift` — add priority field
- `mac-helper/OpenClawHelper/Services/BridgeCommandRunner.swift` — add runActionWithOutput
- `mac-helper/OpenClawHelper/Views/Tabs/PrivacyTabView.swift` — remove handoff section
- `mac-daemon/context-helperctl.sh` — update queue-handoff, add list-handoffs
- `mac-daemon/context-daemon.sh` — add handoff outbox flush
- `server/context-receiver.py` — add priority, GET /context/handoffs, PATCH /context/handoffs/<id>

**Deleted files:**
- `mac-helper/OpenClawHelper/Views/Sheets/HandoffSheetView.swift`
- `mac-helper/OpenClawHelper/ViewModels/HandoffViewModel.swift`

---

## Task 1: Rename to ClawRelay

**Files:**
- Modify: `mac-helper/OpenClawHelper/OpenClawHelperApp.swift:8,13`
- Modify: `mac-helper/OpenClawHelper/Support/OpenClawHelper-Info.plist`

- [ ] **Step 1: Update app strings in OpenClawHelperApp.swift**

Change line 8:
```swift
MenuBarExtra("ClawRelay", systemImage: appModel.menuBarSymbol) {
```

Change line 13:
```swift
Window("ClawRelay", id: "control-center") {
```

- [ ] **Step 2: Add CFBundleDisplayName to Info.plist**

Add to the dict in `OpenClawHelper-Info.plist`:
```xml
<key>CFBundleDisplayName</key>
<string>ClawRelay</string>
<key>CFBundleName</key>
<string>ClawRelay</string>
```

- [ ] **Step 3: Verify and commit**

Run: `cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Release build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

```bash
git add mac-helper/OpenClawHelper/OpenClawHelperApp.swift mac-helper/OpenClawHelper/Support/OpenClawHelper-Info.plist
git commit -m "feat: rename helper app to ClawRelay"
```

---

## Task 2: Add runActionWithOutput to BridgeCommandRunner

**Files:**
- Modify: `mac-helper/OpenClawHelper/Services/BridgeCommandRunner.swift`

- [ ] **Step 1: Add runActionWithOutput method**

Add after the existing `runAction` method (after line 47):

```swift
func runActionWithOutput(_ action: String, _ args: String...) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [executablePath, action] + args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw BridgeCommandError.actionFailed(action: action, exitCode: process.terminationStatus)
    }
    return data
}
```

- [ ] **Step 2: Build and commit**

Run: `cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Release build 2>&1 | tail -3`

```bash
git add mac-helper/OpenClawHelper/Services/BridgeCommandRunner.swift
git commit -m "feat: add runActionWithOutput to BridgeCommandRunner"
```

---

## Task 3: Update HandoffDraft model + create Handoff model

**Files:**
- Modify: `mac-helper/OpenClawHelper/Models/HandoffDraft.swift`
- Create: `mac-helper/OpenClawHelper/Models/Handoff.swift`

- [ ] **Step 1: Add priority to HandoffDraft**

Replace the entire `HandoffDraft.swift` content:

```swift
import Foundation

struct HandoffDraft {
    var project: String = ""
    var task: String = ""
    var message: String = ""
    var priority: String = "normal"

    var isValid: Bool { !task.isEmpty }
    var projectOrDefault: String { project.isEmpty ? "general" : project }
}
```

Note: `isValid` now only requires non-empty task. `projectOrDefault` provides the fallback.

- [ ] **Step 2: Create Handoff model**

Create `mac-helper/OpenClawHelper/Models/Handoff.swift`:

```swift
import Foundation

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

- [ ] **Step 3: Build and commit**

Run: `cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Release build 2>&1 | tail -3`

```bash
git add mac-helper/OpenClawHelper/Models/HandoffDraft.swift mac-helper/OpenClawHelper/Models/Handoff.swift
git commit -m "feat: add priority to HandoffDraft, create Handoff model"
```

---

## Task 4: Add Handoffs tab to Control Center

**Files:**
- Modify: `mac-helper/OpenClawHelper/ViewModels/ControlCenterViewModel.swift:4` (enum)
- Modify: `mac-helper/OpenClawHelper/Views/ControlCenterView.swift:34-46,58-66` (switch + tabIcon)
- Create: `mac-helper/OpenClawHelper/ViewModels/HandoffsTabViewModel.swift`
- Create: `mac-helper/OpenClawHelper/Views/Tabs/HandoffsTabView.swift`

- [ ] **Step 1: Add .handoffs to ControlCenterTab enum**

In `ControlCenterViewModel.swift` line 4, change:
```swift
case overview, permissions, privacy, diagnostics
```
to:
```swift
case overview, permissions, privacy, handoffs, diagnostics
```

- [ ] **Step 2: Add handoffs case to ControlCenterView switch and tabIcon**

In `ControlCenterView.swift`, add to the detail switch (after the `.privacy` case, before `.none`):
```swift
case .handoffs:
    HandoffsTabView(viewModel: HandoffsTabViewModel(runner: viewModel.runner))
```

Add to `tabIcon()` (before the `.diagnostics` case):
```swift
case .handoffs: return "paperplane"
```

- [ ] **Step 3: Create HandoffsTabViewModel**

Create `mac-helper/OpenClawHelper/ViewModels/HandoffsTabViewModel.swift`:

```swift
import SwiftUI

@MainActor
final class HandoffsTabViewModel: ObservableObject {
    @Published var draft = HandoffDraft(project: UserDefaults.standard.string(forKey: "lastHandoffProject") ?? "")
    @Published var handoffs: [Handoff] = []
    @Published var isSubmitting = false
    @Published var sentConfirmation = false
    @Published var lastError: String?

    private let runner: BridgeCommandRunner
    private var refreshTimer: RefreshTimer?

    static let portfolioProjects = ["project-gamma", "project-alpha", "project-beta", "project-delta", "openclaw"]

    init(runner: BridgeCommandRunner) {
        self.runner = runner
    }

    func submit() {
        guard draft.isValid else { return }
        isSubmitting = true
        lastError = nil
        let project = draft.projectOrDefault
        let task = draft.task
        let message = draft.message
        let priority = draft.priority
        let capturedRunner = runner
        // Run blocking Process off the main actor to avoid UI freeze
        Task.detached {
            do {
                try capturedRunner.runAction("queue-handoff", project, task, message, priority)
                await MainActor.run { [weak self] in
                    self?.draft = HandoffDraft()
                    self?.isSubmitting = false
                    self?.sentConfirmation = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        self?.sentConfirmation = false
                    }
                    self?.refreshHandoffs()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastError = "Send failed: \(error.localizedDescription)"
                    self?.isSubmitting = false
                }
            }
        }
        // Persist last project
        UserDefaults.standard.set(draft.project, forKey: "lastHandoffProject")
    }

    func refreshHandoffs() {
        let capturedRunner = runner
        // Run blocking Process off the main actor to avoid UI freeze
        Task.detached {
            do {
                let data = try capturedRunner.runActionWithOutput("list-handoffs")
                let decoded = try JSONDecoder().decode([Handoff].self, from: data)
                await MainActor.run { [weak self] in
                    self?.handoffs = decoded
                }
            } catch {
                // Silently keep existing list on failure
            }
        }
    }

    func startPolling() {
        refreshTimer = RefreshTimer(interval: 30.0) { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshHandoffs()
            }
        }
        refreshTimer?.start()
        refreshHandoffs()
    }

    func stopPolling() {
        refreshTimer?.stop()
        refreshTimer = nil
    }
}
```

- [ ] **Step 4: Create HandoffsTabView**

Create `mac-helper/OpenClawHelper/Views/Tabs/HandoffsTabView.swift`:

```swift
import SwiftUI

struct HandoffsTabView: View {
    @StateObject var viewModel: HandoffsTabViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Compose section
                composeSection

                // History section
                historySection
            }
            .padding()
        }
        .onAppear { viewModel.startPolling() }
        .onDisappear { viewModel.stopPolling() }
    }

    // MARK: - Compose

    private var composeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hand Off to the agent")
                .font(.title2)

            // Project
            HStack {
                Text("Project")
                    .frame(width: 60, alignment: .trailing)
                    .foregroundStyle(.secondary)
                ComboBox(
                    text: $viewModel.draft.project,
                    options: HandoffsTabViewModel.portfolioProjects
                )
            }

            // Task
            HStack {
                Text("Task")
                    .frame(width: 60, alignment: .trailing)
                    .foregroundStyle(.secondary)
                TextField("What should the agent do?", text: $viewModel.draft.task)
                    .textFieldStyle(.roundedBorder)
            }

            // Message
            HStack(alignment: .top) {
                Text("Details")
                    .frame(width: 60, alignment: .trailing)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                TextEditor(text: $viewModel.draft.message)
                    .font(.body)
                    .frame(minHeight: 80, maxHeight: 150)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            }

            // Priority + Send
            HStack {
                Text("Priority")
                    .frame(width: 60, alignment: .trailing)
                    .foregroundStyle(.secondary)
                Picker("", selection: $viewModel.draft.priority) {
                    Text("Normal").tag("normal")
                    Text("High").tag("high")
                    Text("Urgent").tag("urgent")
                }
                .pickerStyle(.segmented)
                .frame(width: 240)

                Spacer()

                if viewModel.sentConfirmation {
                    Text("Sent")
                        .foregroundStyle(.green)
                        .font(.callout)
                }

                Button("Send") {
                    viewModel.submit()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.draft.isValid || viewModel.isSubmitting)
            }

            if let error = viewModel.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .padding()
        .glassCard()
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Handoff History")
                .font(.title2)

            if viewModel.handoffs.isEmpty {
                Text("No handoffs yet")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ForEach(viewModel.handoffs) { handoff in
                    handoffRow(handoff)
                }
            }
        }
        .padding()
        .glassCard()
    }

    private func handoffRow(_ handoff: Handoff) -> some View {
        DisclosureGroup {
            if !handoff.message.isEmpty {
                Text(handoff.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(handoff.project)
                        .font(.headline)
                    Text(handoff.task)
                        .font(.callout)
                        .lineLimit(1)
                }

                Spacer()

                if handoff.priority != "normal" {
                    priorityBadge(handoff.priority)
                }

                statusBadge(handoff.status)

                Text(relativeTime(handoff.createdAt))
                    .font(DarkUtilityGlass.monoCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
    }

    private func priorityBadge(_ priority: String) -> some View {
        Text(priority.capitalized)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                priority == "urgent" ? Color.red.opacity(0.3) : Color.orange.opacity(0.3),
                in: Capsule()
            )
            .foregroundStyle(priority == "urgent" ? .red : .orange)
    }

    private func statusBadge(_ status: String) -> some View {
        Text(status.replacingOccurrences(of: "-", with: " ").capitalized)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor(status).opacity(0.2), in: Capsule())
            .foregroundStyle(statusColor(status))
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "done": return .green
        case "in-progress": return .orange
        default: return .secondary
        }
    }
}

    private func relativeTime(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: isoString)
                ?? ISO8601DateFormatter().date(from: isoString) else {
            return String(isoString.prefix(16)).replacingOccurrences(of: "T", with: " ")
        }
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60)) min ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        if interval < 172800 { return "yesterday" }
        return "\(Int(interval / 86400)) days ago"
    }
}

// MARK: - ComboBox (dropdown + freeform)

struct ComboBox: View {
    @Binding var text: String
    let options: [String]
    @State private var showMenu = false

    var body: some View {
        HStack(spacing: 4) {
            TextField("Project", text: $text)
                .textFieldStyle(.roundedBorder)
            Menu {
                ForEach(options, id: \.self) { option in
                    Button(option.capitalized) {
                        text = option
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 20)
        }
    }
}
```

- [ ] **Step 5: Build and commit**

Run: `cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Release build 2>&1 | tail -3`

```bash
git add mac-helper/OpenClawHelper/ViewModels/ControlCenterViewModel.swift \
  mac-helper/OpenClawHelper/Views/ControlCenterView.swift \
  mac-helper/OpenClawHelper/ViewModels/HandoffsTabViewModel.swift \
  mac-helper/OpenClawHelper/Views/Tabs/HandoffsTabView.swift
git commit -m "feat: add Handoffs tab with compose form and status history"
```

---

## Task 5: Add quick handoff to menu bar popover

**Files:**
- Modify: `mac-helper/OpenClawHelper/Views/MenuBarPopoverView.swift`
- Modify: `mac-helper/OpenClawHelper/ViewModels/MenuBarViewModel.swift`

- [ ] **Step 1: Add handoff state to MenuBarViewModel**

Add published properties and methods to `MenuBarViewModel.swift` (after existing properties):

```swift
@Published var handoffProject: String = UserDefaults.standard.string(forKey: "lastHandoffProject") ?? ""
@Published var handoffTask: String = ""
@Published var handoffSent: Bool = false

static let portfolioProjects = ["project-gamma", "project-alpha", "project-beta", "project-delta", "openclaw"]

func sendQuickHandoff() {
    let project = handoffProject.isEmpty ? "general" : handoffProject
    do {
        try runner.runAction("queue-handoff", project, handoffTask, "", "normal")
        UserDefaults.standard.set(handoffProject, forKey: "lastHandoffProject")
        handoffTask = ""
        handoffSent = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.handoffSent = false
        }
    } catch {
        // Silently fail for menu bar quick actions
    }
}
```

- [ ] **Step 2: Add quick handoff UI to MenuBarPopoverView**

In `MenuBarPopoverView.swift`, add between `QuickActionsGrid` and the "Open Control Center" button:

```swift
Divider()

// Quick handoff
VStack(spacing: 8) {
    HStack(spacing: 4) {
        TextField("Project", text: $viewModel.handoffProject)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
        Menu {
            ForEach(MenuBarViewModel.portfolioProjects, id: \.self) { p in
                Button(p.capitalized) { viewModel.handoffProject = p }
            }
        } label: {
            Image(systemName: "chevron.down")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 20)
    }
    HStack(spacing: 8) {
        TextField("What should the agent do?", text: $viewModel.handoffTask)
            .textFieldStyle(.roundedBorder)
            .onSubmit {
                if !viewModel.handoffTask.isEmpty {
                    viewModel.sendQuickHandoff()
                }
            }
        if viewModel.handoffSent {
            Text("Sent")
                .foregroundStyle(.green)
                .font(.caption)
        }
        Button(action: { viewModel.sendQuickHandoff() }) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.title2)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.handoffTask.isEmpty)
    }
}
```

- [ ] **Step 3: Build and commit**

Run: `cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Release build 2>&1 | tail -3`

```bash
git add mac-helper/OpenClawHelper/Views/MenuBarPopoverView.swift \
  mac-helper/OpenClawHelper/ViewModels/MenuBarViewModel.swift
git commit -m "feat: add quick handoff to menu bar popover"
```

---

## Task 6: Remove old handoff sheet

**Files:**
- Delete: `mac-helper/OpenClawHelper/Views/Sheets/HandoffSheetView.swift`
- Delete: `mac-helper/OpenClawHelper/ViewModels/HandoffViewModel.swift`
- Modify: `mac-helper/OpenClawHelper/Views/Tabs/PrivacyTabView.swift` — remove handoff section

- [ ] **Step 1: Remove handoff section from PrivacyTabView**

In `PrivacyTabView.swift`, remove the "Quick Handoff" VStack section and the `.sheet(isPresented: $showHandoffSheet)` modifier, and the `@State private var showHandoffSheet = false` property.

- [ ] **Step 2: Delete old files**

```bash
rm mac-helper/OpenClawHelper/Views/Sheets/HandoffSheetView.swift
rm mac-helper/OpenClawHelper/ViewModels/HandoffViewModel.swift
```

- [ ] **Step 3: Remove from Xcode project**

The deleted files need to be removed from the Xcode project file. If using `xcodebuild`, the build will warn about missing files. Remove references in the `.xcodeproj/project.pbxproj` — search for `HandoffSheetView.swift` and `HandoffViewModel.swift` and delete those lines.

Alternatively, just build — if the files aren't referenced from any remaining code, the build will succeed even if pbxproj still lists them (Xcode shows them as red/missing but compiles fine if not imported).

- [ ] **Step 4: Build and commit**

Run: `cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Release build 2>&1 | tail -3`

```bash
git add -A mac-helper/
git commit -m "refactor: remove old handoff sheet, move to Handoffs tab"
```

---

## Task 7: Update helperctl — queue-handoff priority + list-handoffs

**Files:**
- Modify: `mac-daemon/context-helperctl.sh:183-216,221-239`

- [ ] **Step 1: Update do_queue_handoff to accept priority**

In `do_queue_handoff()`, add a 4th argument for priority with a default:

After line 185 (`local message="${3:-}"`), add:
```bash
local priority="${4:-normal}"
```

In the Python JSON builder (around line 204-213), add the priority field:
```python
obj = {
    'project': sys.argv[1],
    'task':    sys.argv[2],
    'message': sys.argv[3],
    'priority': sys.argv[4],
    'ts':      sys.argv[5],
}
```

Update the Python call to pass priority and ts as args 4 and 5:
```bash
" "$project" "$task" "$message" "$priority" "$ts" > "$outbox/$filename"
```

- [ ] **Step 2: Add do_list_handoffs function**

Add before the main dispatch section:

```bash
do_list_handoffs() {
  local server_url=""
  if [ -f "$(cb_dir)/server-url" ]; then
    server_url=$(cat "$(cb_dir)/server-url" 2>/dev/null || echo "")
  fi
  if [ -z "$server_url" ]; then
    echo "[]"
    exit 0
  fi

  # Replace /push with /handoffs in the URL
  # Assumes server-url contains the full push endpoint (e.g. https://host:7890/context/push)
  # This is the format written by install.sh
  local handoffs_url="${server_url/\/context\/push/\/context\/handoffs}"

  local auth_token=""
  auth_token=$(security find-generic-password -s "context-bridge" -a "token" -w 2>/dev/null || echo "")
  if [ -z "$auth_token" ]; then
    echo "[]"
    exit 0
  fi

  local curl_args=()
  local ca_cert="$(cb_dir)/server-ca.pem"
  if [[ "$handoffs_url" == https://* ]] && [ -f "$ca_cert" ]; then
    curl_args+=(--cacert "$ca_cert")
  fi

  local response
  response=$(curl -sf \
    -H "Authorization: Bearer $auth_token" \
    --connect-timeout 5 --max-time 10 \
    "${curl_args[@]}" \
    "$handoffs_url" 2>/dev/null || echo "[]")

  echo "$response"
}
```

- [ ] **Step 3: Add list-handoffs to dispatch**

In the dispatch case statement, add:
```bash
list-handoffs) do_list_handoffs ;;
```

- [ ] **Step 4: Verify syntax and commit**

Run: `bash -n mac-daemon/context-helperctl.sh`

```bash
git add mac-daemon/context-helperctl.sh
git commit -m "feat: add priority to queue-handoff, add list-handoffs command"
```

---

## Task 8: Add handoff outbox flush to daemon

**Files:**
- Modify: `mac-daemon/context-daemon.sh` (after line 685, after `send_payload`)

- [ ] **Step 1: Add flush section**

After `send_payload "$PAYLOAD" || true` (the last line before EOF), add:

```bash
# --- Flush handoff outbox ---
HANDOFF_OUTBOX="$CB_DIR/handoff-outbox"
if [ -d "$HANDOFF_OUTBOX" ]; then
  HANDOFF_URL="${SERVER_URL/\/context\/push/\/context\/handoff}"
  for hf in "$HANDOFF_OUTBOX"/*.json; do
    [ -f "$hf" ] || continue
    local_curl_args=()
    while IFS= read -r arg; do
      local_curl_args+=("$arg")
    done < <(curl_tls_args)

    if [ ${#local_curl_args[@]} -gt 0 ]; then
      http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
        -X POST "$HANDOFF_URL" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -H "Content-Type: application/json" \
        -d @"$hf" \
        --connect-timeout 5 --max-time 10 \
        "${local_curl_args[@]}" \
        2>/dev/null || echo "000")
    else
      http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
        -X POST "$HANDOFF_URL" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -H "Content-Type: application/json" \
        -d @"$hf" \
        --connect-timeout 5 --max-time 10 \
        2>/dev/null || echo "000")
    fi

    if [ "$http_code" = "201" ]; then
      rm -f "$hf"
    fi
  done
fi
```

- [ ] **Step 2: Verify syntax and deploy**

Run: `bash -n mac-daemon/context-daemon.sh`

```bash
cp mac-daemon/context-daemon.sh ~/.context-bridge/bin/context-bridge-daemon.sh
cp mac-daemon/context-helperctl.sh ~/.context-bridge/bin/context-helperctl.sh
```

- [ ] **Step 3: Commit**

```bash
git add mac-daemon/context-daemon.sh
git commit -m "feat: add handoff outbox flush to daemon capture cycle"
```

---

## Task 9: Server-side — priority, GET handoffs, PATCH status

**Files:**
- Modify: `server/context-receiver.py:273-311`

- [ ] **Step 1: Update POST /context/handoff**

In the handoff() function, update the CREATE TABLE to include priority:

```sql
CREATE TABLE IF NOT EXISTS handoffs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    project TEXT NOT NULL,
    task TEXT,
    message TEXT,
    priority TEXT DEFAULT 'normal',
    status TEXT DEFAULT 'pending',
    created_at TEXT DEFAULT (datetime('now'))
)
```

Validate and store priority:

```python
priority = data.get('priority', 'normal')
if priority not in ('normal', 'high', 'urgent'):
    priority = 'normal'

db.execute("""
    INSERT INTO handoffs (project, task, message, priority)
    VALUES (?, ?, ?, ?)
""", (
    data.get('project', ''),
    data.get('task', ''),
    data.get('message', ''),
    priority,
))
```

- [ ] **Step 2: Add GET /context/handoffs**

Add after the POST handler:

```python
@app.route('/context/handoffs', methods=['GET'])
def list_handoffs():
    """List recent handoffs with status."""
    if not verify_auth(request):
        return jsonify({'error': 'unauthorized'}), 401

    db = get_db()
    db.execute("""
        CREATE TABLE IF NOT EXISTS handoffs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            project TEXT NOT NULL,
            task TEXT,
            message TEXT,
            priority TEXT DEFAULT 'normal',
            status TEXT DEFAULT 'pending',
            created_at TEXT DEFAULT (datetime('now'))
        )
    """)
    rows = db.execute(
        "SELECT id, project, task, message, priority, status, created_at FROM handoffs ORDER BY created_at DESC LIMIT 50"
    ).fetchall()
    db.close()

    return jsonify([
        {
            'id': r['id'],
            'project': r['project'],
            'task': r['task'],
            'message': r['message'] or '',
            'priority': r['priority'] or 'normal',
            'status': r['status'] or 'pending',
            'created_at': r['created_at'],
        }
        for r in rows
    ])
```

- [ ] **Step 3: Add PATCH /context/handoffs/<id>**

```python
@app.route('/context/handoffs/<int:handoff_id>', methods=['PATCH'])
def update_handoff(handoff_id):
    """The agent updates handoff status."""
    if not verify_auth(request):
        return jsonify({'error': 'unauthorized'}), 401

    data, error = parse_json_request()
    if error:
        return error

    new_status = data.get('status', '')
    if new_status not in ('in-progress', 'done'):
        return jsonify({'error': 'invalid status, must be in-progress or done'}), 400

    db = get_db()
    row = db.execute("SELECT status FROM handoffs WHERE id = ?", (handoff_id,)).fetchone()
    if not row:
        db.close()
        return jsonify({'error': 'handoff not found'}), 404

    current = row['status']
    valid_transitions = {
        'pending': ('in-progress', 'done'),
        'in-progress': ('done',),
    }
    if new_status not in valid_transitions.get(current, ()):
        db.close()
        return jsonify({'error': f'invalid status transition from {current} to {new_status}'}), 400

    db.execute("UPDATE handoffs SET status = ? WHERE id = ?", (new_status, handoff_id))
    db.commit()
    db.close()

    return jsonify({'status': 'ok', 'handoff_id': handoff_id, 'new_status': new_status})
```

- [ ] **Step 4: Verify syntax and commit**

Run: `cd server && python3 -c "import ast; ast.parse(open('context-receiver.py').read()); print('OK')"`

```bash
git add server/context-receiver.py
git commit -m "feat: add priority to handoffs, GET listing, PATCH status updates"
```

---

## Task 10: Build, deploy, and push

- [ ] **Step 1: Build the app**

```bash
cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Release build 2>&1 | tail -3
```

- [ ] **Step 2: Install the app**

```bash
osascript -e 'tell application "OpenClawHelper" to quit' 2>/dev/null
pkill -9 -x OpenClawHelper 2>/dev/null
sleep 1
rm -rf /Applications/OpenClawHelper.app
cp -R ~/Library/Developer/Xcode/DerivedData/OpenClawHelper-*/Build/Products/Release/OpenClawHelper.app /Applications/OpenClawHelper.app
open /Applications/OpenClawHelper.app
```

- [ ] **Step 3: Deploy daemon scripts**

```bash
cp mac-daemon/context-daemon.sh ~/.context-bridge/bin/context-bridge-daemon.sh
cp mac-daemon/context-helperctl.sh ~/.context-bridge/bin/context-helperctl.sh
```

- [ ] **Step 4: Push**

```bash
git push origin main
```
