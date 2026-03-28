# ClawRelay Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a personal operations dashboard to ClawRelay showing time allocation, focus level, JC's activity, project neglect, and handoff status — closing the intelligence loop so Jonas sees the same data JC sees.

**Architecture:** Server-side `GET /context/dashboard` endpoint aggregates all data in one response. ClawRelay's new Dashboard tab (first in sidebar) renders a cards grid layout. Data flows: server DB → Flask endpoint → helperctl curl → BridgeCommandRunner → DashboardViewModel → SwiftUI. Refreshes every 2 min when visible.

**Tech Stack:** Python 3/Flask/SQLite (server), Bash (helperctl), SwiftUI (macOS app)

**Spec:** `docs/superpowers/specs/2026-03-28-clawrelay-dashboard-design.md`

---

## File Structure

**New files:**
- `mac-helper/OpenClawHelper/Models/DashboardData.swift` — decodable response models
- `mac-helper/OpenClawHelper/ViewModels/DashboardViewModel.swift` — data fetching + polling
- `mac-helper/OpenClawHelper/Views/Tabs/DashboardTabView.swift` — cards grid UI

**Modified files:**
- `server/context-receiver.py` — add `GET /context/dashboard` endpoint
- `mac-daemon/context-helperctl.sh` — add `dashboard` command
- `mac-helper/OpenClawHelper/ViewModels/ControlCenterViewModel.swift` — add .dashboard to enum
- `mac-helper/OpenClawHelper/Views/ControlCenterView.swift` — add .dashboard tab + icon, make default
- `mac-helper/OpenClawHelper/ViewModels/MenuBarViewModel.swift` — add dashboard summary fetch
- `mac-helper/OpenClawHelper/Views/MenuBarPopoverView.swift` — add summary line

---

## Task 1: Server endpoint — GET /context/dashboard

**Files:**
- Modify: `server/context-receiver.py` (insert after line 436, before error handlers)

- [ ] **Step 1: Add the dashboard endpoint**

Insert after the health endpoint (line 436) and before `@app.errorhandler(413)` (line 483):

```python
@app.route('/context/dashboard', methods=['GET'])
def dashboard():
    """Combined dashboard data for ClawRelay app."""
    if not verify_auth(request):
        return jsonify({'error': 'unauthorized'}), 401

    try:
        db = get_db()
        from config import PORTFOLIO_PROJECTS, ALL_PROJECTS, NOISE_APPS

        # --- Status (latest row) ---
        latest = db.execute(
            "SELECT * FROM activity_stream ORDER BY ts DESC LIMIT 1"
        ).fetchone()

        status = {
            'current_app': 'unknown',
            'current_project': 'unknown',
            'idle_state': 'unknown',
            'idle_seconds': 0,
            'in_call': False,
            'focus_mode': None,
            'focus_level': 'unknown',
            'focus_switches_per_hour': 0.0,
            'daemon_stale': False,
            'last_activity': None,
        }

        if latest:
            status['current_app'] = latest['app'] or 'unknown'
            status['idle_state'] = latest['idle_state'] or 'unknown'
            status['idle_seconds'] = latest['idle_seconds'] or 0
            status['in_call'] = bool(latest.get('in_call', 0))
            status['focus_mode'] = latest.get('focus_mode') or None
            status['last_activity'] = latest['ts']

            # Infer project
            haystack = f"{latest['window_title']} {latest['git_repo']} {latest['url']} {latest['file_path']}".lower()
            for proj, keywords in ALL_PROJECTS.items():
                if any(kw in haystack for kw in keywords):
                    status['current_project'] = proj
                    break

            # Staleness check
            import os
            status['daemon_stale'] = os.path.exists('/tmp/context-bridge-stale')

            # Focus level (last 60 min)
            since_1h = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
            recent = db.execute(
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

            status['focus_switches_per_hour'] = round(switches, 1)
            if switches <= 3:
                status['focus_level'] = 'focused'
            elif switches <= 7:
                status['focus_level'] = 'multitasking'
            else:
                status['focus_level'] = 'scattered'

        # --- Time allocation (today) ---
        today_start = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0).isoformat()
        today_rows = db.execute(
            "SELECT window_title, git_repo, url, file_path FROM activity_stream WHERE ts >= ? AND idle_state = 'active'",
            (today_start,)
        ).fetchall()

        project_counts = {}
        for r in today_rows:
            h = f"{r['window_title']} {r['git_repo']} {r['url']} {r['file_path']}".lower()
            matched = 'other'
            for p, kws in ALL_PROJECTS.items():
                if any(kw in h for kw in kws):
                    matched = p
                    break
            project_counts[matched] = project_counts.get(matched, 0) + 1

        total_captures = sum(project_counts.values())
        time_allocation = []
        for proj, count in sorted(project_counts.items(), key=lambda x: -x[1]):
            if proj == 'other':
                continue
            hours = round(count * 2 / 60, 1)
            pct = round(count / total_captures * 100) if total_captures else 0
            time_allocation.append({'project': proj, 'hours': hours, 'percentage': pct})

        # --- Neglected projects ---
        neglected = []
        try:
            last_seen_rows = db.execute("SELECT project, last_seen FROM project_last_seen").fetchall()
            last_seen = {r['project']: r['last_seen'] for r in last_seen_rows}
        except Exception:
            last_seen = {}

        for p in PORTFOLIO_PROJECTS:
            if p in last_seen:
                try:
                    ls = datetime.fromisoformat(last_seen[p]).replace(tzinfo=timezone.utc)
                    days = (datetime.now(timezone.utc) - ls).days
                except Exception:
                    days = 999
            else:
                days = 999
            neglected.append({'project': p, 'days': days})
        neglected.sort(key=lambda x: -x['days'])

        # --- JC activity ---
        jc_activity = []
        try:
            tables = [r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()]
            if 'jc_work_log' in tables:
                jc_since = (datetime.now(timezone.utc) - timedelta(hours=48)).isoformat()
                jc_rows = db.execute(
                    "SELECT * FROM jc_work_log WHERE started_at >= ? ORDER BY started_at DESC LIMIT 10",
                    (jc_since,)
                ).fetchall()
                for r in jc_rows:
                    jc_activity.append({
                        'id': r[0],
                        'project': r[1],
                        'description': r[2],
                        'status': r[3],
                        'started_at': r[5],
                        'completed_at': r[6],
                        'duration_minutes': r[7],
                    })
        except Exception:
            pass

        # --- Handoffs ---
        handoffs = []
        try:
            h_rows = db.execute(
                "SELECT id, project, task, message, priority, status, created_at FROM handoffs ORDER BY created_at DESC LIMIT 10"
            ).fetchall()
            for r in h_rows:
                handoffs.append({
                    'id': r['id'],
                    'project': r['project'],
                    'task': r['task'],
                    'message': r['message'] or '',
                    'priority': r['priority'] or 'normal',
                    'status': r['status'] or 'pending',
                    'created_at': r['created_at'],
                })
        except Exception:
            pass

        db.close()

        return jsonify({
            'status': status,
            'time_allocation': time_allocation,
            'neglected': neglected,
            'jc_activity': jc_activity,
            'handoffs': handoffs,
        })
    except Exception:
        logger.exception("Dashboard query failed")
        return jsonify({'error': 'internal error'}), 500
```

- [ ] **Step 2: Verify syntax**

Run: `cd server && python3 -c "import ast; ast.parse(open('context-receiver.py').read()); print('OK')"`

- [ ] **Step 3: Commit**

```bash
git add server/context-receiver.py
git commit -m "feat: add GET /context/dashboard endpoint"
```

---

## Task 2: Helperctl dashboard command

**Files:**
- Modify: `mac-daemon/context-helperctl.sh`

- [ ] **Step 1: Add do_fetch_dashboard function**

Read the file first. Add before the main dispatch case statement (before `case "$action" in`):

```bash
do_fetch_dashboard() {
  local server_url=""
  if [ -f "$(cb_dir)/server-url" ]; then
    server_url=$(cat "$(cb_dir)/server-url" 2>/dev/null || echo "")
  fi
  if [ -z "$server_url" ]; then
    echo "{}"
    exit 0
  fi

  local dashboard_url
  dashboard_url=$(echo "$server_url" | sed 's|/context/push|/context/dashboard|')

  local auth_token=""
  auth_token=$(security find-generic-password -s "context-bridge" -a "token" -w 2>/dev/null || echo "")
  if [ -z "$auth_token" ]; then
    echo "{}"
    exit 0
  fi

  local curl_args=()
  local ca_cert="$(cb_dir)/server-ca.pem"
  if [[ "$dashboard_url" == https://* ]] && [ -f "$ca_cert" ]; then
    curl_args+=(--cacert "$ca_cert")
  fi

  local response
  response=$(curl -sf \
    -H "Authorization: Bearer $auth_token" \
    --connect-timeout 5 --max-time 10 \
    "${curl_args[@]}" \
    "$dashboard_url" 2>/dev/null || echo "{}")

  echo "$response"
}
```

- [ ] **Step 2: Add dispatch case**

In the case statement, add before the `*)` fallback:

```bash
dashboard)      do_fetch_dashboard ;;
```

- [ ] **Step 3: Verify and commit**

```bash
bash -n mac-daemon/context-helperctl.sh
git add mac-daemon/context-helperctl.sh
git commit -m "feat: add dashboard command to helperctl"
```

---

## Task 3: Swift models — DashboardData

**Files:**
- Create: `mac-helper/OpenClawHelper/Models/DashboardData.swift`

- [ ] **Step 1: Create the models file**

```swift
import Foundation

// Note: Handoff model already exists in Handoff.swift — reused here, no import needed (same module)
struct DashboardData: Decodable {
    let status: DashboardStatus
    let timeAllocation: [ProjectTime]
    let neglected: [ProjectNeglect]
    let jcActivity: [JCWorkEntry]
    let handoffs: [Handoff]  // uses existing Handoff model from Handoff.swift

    enum CodingKeys: String, CodingKey {
        case status
        case timeAllocation = "time_allocation"
        case neglected
        case jcActivity = "jc_activity"
        case handoffs
    }
}

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
    let lastActivity: String?

    enum CodingKeys: String, CodingKey {
        case currentApp = "current_app"
        case currentProject = "current_project"
        case idleState = "idle_state"
        case idleSeconds = "idle_seconds"
        case inCall = "in_call"
        case focusMode = "focus_mode"
        case focusLevel = "focus_level"
        case focusSwitchesPerHour = "focus_switches_per_hour"
        case daemonStale = "daemon_stale"
        case lastActivity = "last_activity"
    }
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

    enum CodingKeys: String, CodingKey {
        case id, project, description, status
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case durationMinutes = "duration_minutes"
    }
}
```

- [ ] **Step 2: Build and commit**

```bash
cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Release build 2>&1 | tail -3
git add mac-helper/OpenClawHelper/Models/DashboardData.swift
git commit -m "feat: add DashboardData decodable models"
```

---

## Task 4: DashboardViewModel

**Files:**
- Create: `mac-helper/OpenClawHelper/ViewModels/DashboardViewModel.swift`

- [ ] **Step 1: Create the view model**

Follow the `HandoffsTabViewModel` pattern exactly — `@MainActor`, `Task.detached`, `await MainActor.run`:

```swift
import SwiftUI

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var data: DashboardData?
    @Published var lastError: String?

    private let runner: BridgeCommandRunner
    private var refreshTimer: RefreshTimer?

    init(runner: BridgeCommandRunner) {
        self.runner = runner
    }

    func refreshDashboard() {
        let capturedRunner = runner
        Task.detached {
            do {
                let raw = try capturedRunner.runActionWithOutput("dashboard")
                let decoded = try JSONDecoder().decode(DashboardData.self, from: raw)
                await MainActor.run { [weak self] in
                    self?.data = decoded
                    self?.lastError = nil
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.lastError = "Dashboard unavailable"
                }
            }
        }
    }

    func startPolling() {
        refreshTimer = RefreshTimer(interval: 120.0) { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshDashboard()
            }
        }
        refreshTimer?.start()
        refreshDashboard()
    }

    func stopPolling() {
        refreshTimer?.stop()
        refreshTimer = nil
    }
}
```

- [ ] **Step 2: Build and commit**

```bash
cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Release build 2>&1 | tail -3
git add mac-helper/OpenClawHelper/ViewModels/DashboardViewModel.swift
git commit -m "feat: add DashboardViewModel with 2-min polling"
```

---

## Task 5: DashboardTabView — cards grid UI

**Files:**
- Create: `mac-helper/OpenClawHelper/Views/Tabs/DashboardTabView.swift`
- Modify: `mac-helper/OpenClawHelper/ViewModels/ControlCenterViewModel.swift:4` — add .dashboard
- Modify: `mac-helper/OpenClawHelper/Views/ControlCenterView.swift:34-49,60-68` — add tab + icon

- [ ] **Step 1: Add .dashboard to ControlCenterTab enum**

In `ControlCenterViewModel.swift` line 4, change:
```swift
case overview, permissions, privacy, handoffs, diagnostics
```
to:
```swift
case dashboard, overview, permissions, privacy, handoffs, diagnostics
```

Also change the default `selectedTab` from `.overview` to `.dashboard` (line 8):
```swift
@Published var selectedTab: ControlCenterTab? = .dashboard
```

- [ ] **Step 2: Update ControlCenterView switch + tabIcon**

In `ControlCenterView.swift`, add to the detail switch (before `.overview`):
```swift
case .dashboard:
    DashboardTabView(viewModel: DashboardViewModel(runner: viewModel.runner))
```

Add to `tabIcon()` (first case, before `.overview`):
```swift
case .dashboard: return "chart.bar.xaxis"
```

- [ ] **Step 3: Create DashboardTabView**

Create `mac-helper/OpenClawHelper/Views/Tabs/DashboardTabView.swift`:

```swift
import SwiftUI

struct DashboardTabView: View {
    @StateObject var viewModel: DashboardViewModel

    var body: some View {
        ScrollView {
            if let data = viewModel.data {
                VStack(alignment: .leading, spacing: 16) {
                    // Stale daemon warning
                    if data.status.daemonStale {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Daemon data is stale — last capture was \(relativeTime(data.status.lastActivity ?? ""))")
                                .font(.callout)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard()
                    }

                    statusCards(data)
                    timeAllocation(data.timeAllocation)
                    bottomPanels(data)
                }
                .padding()
            } else if let error = viewModel.lastError {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .foregroundStyle(.secondary)
                    Button("Retry") { viewModel.refreshDashboard() }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Connecting to server...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
        .onAppear { viewModel.startPolling() }
        .onDisappear { viewModel.stopPolling() }
    }

    // MARK: - Status Cards

    private func statusCards(_ data: DashboardData) -> some View {
        HStack(spacing: 12) {
            // NOW card
            statusCard(
                label: "NOW",
                value: data.status.currentProject.capitalized,
                detail: {
                    let hours = data.timeAllocation.first(where: { $0.project == data.status.currentProject })?.hours ?? 0
                    return "\(hours)h today"
                }(),
                color: data.status.idleState == "active" ? .green : .secondary
            )

            // FOCUS card
            statusCard(
                label: "FOCUS",
                value: data.status.focusLevel.capitalized,
                detail: "\(data.status.focusSwitchesPerHour, specifier: "%.1f") switches/hr",
                color: focusColor(data.status.focusLevel)
            )

            // JC card
            statusCard(
                label: "JC",
                value: {
                    if let active = data.jcActivity.first(where: { $0.status == "in-progress" }) {
                        return "Working"
                    }
                    return "Idle"
                }(),
                detail: {
                    if let active = data.jcActivity.first(where: { $0.status == "in-progress" }) {
                        return "\(active.project) — \(active.description)"
                    }
                    if let last = data.jcActivity.first {
                        return "Last: \(last.project)"
                    }
                    return "No recent activity"
                }(),
                color: data.jcActivity.contains(where: { $0.status == "in-progress" }) ? .blue : .secondary
            )
        }
    }

    private func statusCard(label: String, value: String, detail: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .foregroundStyle(color)
            Text(detail)
                .font(DarkUtilityGlass.monoCaption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .glassCard()
    }

    // MARK: - Time Allocation

    private func timeAllocation(_ projects: [ProjectTime]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Today's Time")
                .font(.headline)

            if projects.isEmpty {
                Text("No activity yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(projects) { project in
                    VStack(spacing: 4) {
                        HStack {
                            Text(project.project.capitalized)
                                .font(.callout)
                            Spacer()
                            Text("\(project.hours, specifier: "%.1f")h (\(project.percentage)%)")
                                .font(DarkUtilityGlass.monoCaption)
                                .foregroundStyle(.secondary)
                        }
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(projectColor(project.project))
                                .frame(width: geo.size.width * Double(project.percentage) / 100.0)
                        }
                        .frame(height: 6)
                        .background(Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
            }
        }
        .padding()
        .glassCard()
    }

    // MARK: - Bottom Panels

    private func bottomPanels(_ data: DashboardData) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Needs Attention
            VStack(alignment: .leading, spacing: 8) {
                Text("Needs Attention")
                    .font(.headline)

                // Neglected projects (>2 days)
                ForEach(data.neglected.filter { $0.days > 2 }) { item in
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text("\(item.project.capitalized) — \(item.days) days neglected")
                            .font(.caption)
                    }
                }

                // JC in-progress
                ForEach(data.jcActivity.filter { $0.status == "in-progress" }) { entry in
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundStyle(.blue)
                            .font(.caption)
                        Text("JC: \(entry.description)")
                            .font(.caption)
                            .lineLimit(1)
                    }
                }

                // JC completed (recent)
                ForEach(Array(data.jcActivity.filter { $0.status == "done" }.prefix(3))) { entry in
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text("JC done: \(entry.description)")
                            .font(.caption)
                            .lineLimit(1)
                    }
                }

                if data.neglected.filter({ $0.days > 2 }).isEmpty &&
                   data.jcActivity.isEmpty {
                    Text("Nothing needs attention")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .glassCard()

            // Recent Handoffs
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent Handoffs")
                    .font(.headline)

                if data.handoffs.isEmpty {
                    Text("No handoffs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(data.handoffs.prefix(5))) { handoff in
                        HStack(spacing: 6) {
                            Text(handoff.status)
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(handoffStatusColor(handoff.status).opacity(0.2), in: Capsule())
                                .foregroundStyle(handoffStatusColor(handoff.status))
                            Text("\(handoff.project) — \(handoff.task)")
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .glassCard()
        }
    }

    // MARK: - Colors

    private func focusColor(_ level: String) -> Color {
        switch level {
        case "focused": return .green
        case "multitasking": return .orange
        case "scattered": return .red
        default: return .secondary
        }
    }

    private func projectColor(_ project: String) -> Color {
        switch project {
        case "project-gamma": return .green
        case "project-alpha": return .blue
        case "project-beta": return .orange
        case "project-delta": return .purple
        case "openclaw": return .cyan
        default: return .secondary
        }
    }

    private func relativeTime(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: isoString)
                ?? ISO8601DateFormatter().date(from: isoString) else {
            return "unknown"
        }
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60)) min ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400)) days ago"
    }

    private func handoffStatusColor(_ status: String) -> Color {
        switch status {
        case "done": return .green
        case "in-progress": return .orange
        default: return .secondary
        }
    }
}
```

- [ ] **Step 4: Build and commit**

```bash
cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Release build 2>&1 | tail -5
git add mac-helper/OpenClawHelper/ViewModels/ControlCenterViewModel.swift \
  mac-helper/OpenClawHelper/Views/ControlCenterView.swift \
  mac-helper/OpenClawHelper/Views/Tabs/DashboardTabView.swift
git commit -m "feat: add Dashboard tab with cards grid layout"
```

---

## Task 6: Popover summary line

**Files:**
- Modify: `mac-helper/OpenClawHelper/ViewModels/MenuBarViewModel.swift`
- Modify: `mac-helper/OpenClawHelper/Views/MenuBarPopoverView.swift`

- [ ] **Step 1: Add dashboard data to MenuBarViewModel**

Read MenuBarViewModel.swift. Add a published property and fetch method:

```swift
@Published var dashboard: DashboardData?

func fetchDashboard() {
    let capturedRunner = runner
    Task.detached {
        do {
            let raw = try capturedRunner.runActionWithOutput("dashboard")
            let decoded = try JSONDecoder().decode(DashboardData.self, from: raw)
            await MainActor.run { [weak self] in
                self?.dashboard = decoded
            }
        } catch {
            // Silently fail — popover summary is best-effort
        }
    }
}
```

Call `fetchDashboard()` inside the existing `refresh()` method (alongside `fetchStatus()`).

- [ ] **Step 2: Add summary line to popover**

In `MenuBarPopoverView.swift`, add after `StatusHeaderView` and before `HealthStripView`:

```swift
// Dashboard summary
if let dash = viewModel.dashboard {
    HStack(spacing: 8) {
        let hours = dash.timeAllocation.first(where: { $0.project == dash.status.currentProject })?.hours ?? 0
        Text("\(dash.status.currentProject.capitalized) \(hours, specifier: "%.1f")h")
            .font(.caption)
            .foregroundStyle(.primary)

        Text("|")
            .foregroundStyle(.secondary)
            .font(.caption)

        if let active = dash.jcActivity.first(where: { $0.status == "in-progress" }) {
            Text("JC: \(active.project)")
                .font(.caption)
                .foregroundStyle(.blue)
        } else {
            Text("JC: idle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Spacer()

        Text(dash.status.focusLevel.capitalized)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(focusColor(dash.status.focusLevel).opacity(0.2), in: Capsule())
            .foregroundStyle(focusColor(dash.status.focusLevel))
    }
    .padding(.horizontal, 4)
}
```

Also add a helper function at the bottom of the view:
```swift
private func focusColor(_ level: String) -> Color {
    switch level {
    case "focused": return .green
    case "multitasking": return .orange
    case "scattered": return .red
    default: return .secondary
    }
}
```

- [ ] **Step 3: Build and commit**

```bash
cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Release build 2>&1 | tail -3
git add mac-helper/OpenClawHelper/ViewModels/MenuBarViewModel.swift \
  mac-helper/OpenClawHelper/Views/MenuBarPopoverView.swift
git commit -m "feat: add dashboard summary line to menu bar popover"
```

---

## Task 7: Build, deploy, and push

- [ ] **Step 1: Final build**

```bash
cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Release build 2>&1 | tail -3
```

- [ ] **Step 2: Install app**

```bash
osascript -e 'tell application "OpenClawHelper" to quit' 2>/dev/null
pkill -9 -x OpenClawHelper 2>/dev/null
sleep 1
rm -rf /Applications/OpenClawHelper.app
cp -R ~/Library/Developer/Xcode/DerivedData/OpenClawHelper-*/Build/Products/Release/OpenClawHelper.app /Applications/OpenClawHelper.app
open /Applications/OpenClawHelper.app
```

- [ ] **Step 3: Deploy helperctl**

```bash
cp mac-daemon/context-helperctl.sh ~/.context-bridge/bin/context-helperctl.sh
```

- [ ] **Step 4: Push**

```bash
git push origin main
```
