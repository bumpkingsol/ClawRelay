# ClawRelay: Notifications, Historical View & Bootstrap Fix

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the "999 days" bootstrap problem, add macOS notifications for handoff/neglect/JC questions, and add a historical time view with daily summaries.

**Architecture:** Three independent features sharing the same server endpoint and Swift app. Bootstrap is a server-side fix to the dashboard endpoint. Notifications use UNUserNotificationCenter triggered by diffing dashboard poll results. Historical view adds a daily_summary table populated by the digest and queried by an extended dashboard endpoint.

**Tech Stack:** Python 3/Flask/SQLite (server), Bash (helperctl), SwiftUI/UserNotifications (macOS app)

**Spec:** `docs/superpowers/specs/2026-03-28-clawrelay-notifications-history-bootstrap-design.md`

---

## File Structure

**New files:**
- `mac-helper/OpenClawHelper/Services/NotificationService.swift` — UNUserNotificationCenter wrapper
- `mac-helper/OpenClawHelper/Models/JCQuestion.swift` — decodable model
- `mac-helper/OpenClawHelper/Models/DailyEntry.swift` — decodable model

**Modified files:**
- `server/context-receiver.py` — bootstrap fix in dashboard, daily_summary table, jc_questions table + endpoints, history in dashboard
- `server/context-digest.py` — write daily_summary rows
- `mac-helper/OpenClawHelper/Models/DashboardData.swift` — add jcQuestions, history
- `mac-helper/OpenClawHelper/ViewModels/DashboardViewModel.swift` — notification detection, historyDays state
- `mac-helper/OpenClawHelper/Views/Tabs/DashboardTabView.swift` — history section with stacked bars
- `mac-daemon/context-helperctl.sh` — add mark-question-seen command

---

## Task 1: Bootstrap neglect data (server fix)

**Files:**
- Modify: `server/context-receiver.py` — dashboard endpoint neglect section (lines 588-606)

- [ ] **Step 1: Update the neglect section in the dashboard endpoint**

Read `server/context-receiver.py`. Find the neglect section in the `dashboard()` function (around lines 585-606). Replace it with a version that also scans `activity_stream`:

```python
        # --- Neglected projects ---
        neglected = []
        # Read persistent last_seen data
        try:
            last_seen_rows = db.execute("SELECT project, last_seen FROM project_last_seen").fetchall()
            last_seen = {r['project']: r['last_seen'] for r in last_seen_rows}
        except Exception:
            last_seen = {}

        # Bootstrap: also scan raw activity_stream (last 48h) for more recent data
        try:
            raw_since = (datetime.now(timezone.utc) - timedelta(hours=48)).isoformat()
            raw_rows = db.execute(
                "SELECT window_title, git_repo, url, file_path, MAX(ts) as latest FROM activity_stream WHERE ts >= ? AND idle_state = 'active' GROUP BY window_title, git_repo",
                (raw_since,)
            ).fetchall()
            for r in raw_rows:
                h = f"{r['window_title']} {r['git_repo']} {r['url']} {r['file_path']}".lower()
                for p, kws in PORTFOLIO_PROJECTS.items():
                    if any(kw in h for kw in kws):
                        if p not in last_seen or r['latest'] > last_seen.get(p, ''):
                            last_seen[p] = r['latest']
                            # Persist to project_last_seen
                            try:
                                db.execute(
                                    "INSERT INTO project_last_seen (project, last_seen, last_branch) VALUES (?, ?, '') ON CONFLICT(project) DO UPDATE SET last_seen = excluded.last_seen",
                                    (p, r['latest'])
                                )
                            except Exception:
                                pass
                        break
            db.commit()
        except Exception:
            pass

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
```

- [ ] **Step 2: Verify syntax**

Run: `cd server && python3 -c "import ast; ast.parse(open('context-receiver.py').read()); print('OK')"`

- [ ] **Step 3: Commit**

```bash
git add server/context-receiver.py
git commit -m "fix: bootstrap project_last_seen from raw activity_stream in dashboard"
```

---

## Task 2: Server — daily_summary table + jc_questions table + endpoints

**Files:**
- Modify: `server/context-receiver.py` — init_db (add tables), add POST/PATCH jc_questions endpoints, add history + jc_questions to dashboard response

- [ ] **Step 1: Add tables to init_db()**

In `init_db()`, after the `project_last_seen` table creation (around line 93), add:

```python
    db.execute("""
        CREATE TABLE IF NOT EXISTS daily_summary (
            date TEXT NOT NULL,
            project TEXT NOT NULL,
            hours REAL NOT NULL,
            captures INTEGER NOT NULL,
            PRIMARY KEY (date, project)
        )
    """)
    db.execute("""
        CREATE TABLE IF NOT EXISTS jc_questions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            question TEXT NOT NULL,
            project TEXT,
            created_at TEXT DEFAULT (datetime('now')),
            seen INTEGER DEFAULT 0
        )
    """)
```

- [ ] **Step 2: Add POST /context/jc-question endpoint**

Add after the existing jc_work_log endpoint:

```python
@app.route('/context/jc-question', methods=['POST'])
def post_jc_question():
    """JC posts a question for Jonas."""
    if not verify_auth(request):
        return jsonify({'error': 'unauthorized'}), 401

    data, error = parse_json_request()
    if error:
        return error

    db = get_db()
    db.execute("""
        CREATE TABLE IF NOT EXISTS jc_questions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            question TEXT NOT NULL,
            project TEXT,
            created_at TEXT DEFAULT (datetime('now')),
            seen INTEGER DEFAULT 0
        )
    """)
    db.execute(
        "INSERT INTO jc_questions (question, project) VALUES (?, ?)",
        (data.get('question', ''), data.get('project', ''))
    )
    db.commit()
    db.close()
    return jsonify({'status': 'ok'}), 201


@app.route('/context/jc-question/<int:qid>', methods=['PATCH'])
def mark_jc_question(qid):
    """ClawRelay marks a question as seen."""
    if not verify_auth(request):
        return jsonify({'error': 'unauthorized'}), 401

    db = get_db()
    db.execute("UPDATE jc_questions SET seen = 1 WHERE id = ?", (qid,))
    db.commit()
    db.close()
    return jsonify({'status': 'ok'})
```

- [ ] **Step 3: Add jc_questions and history to dashboard response**

In the `dashboard()` function, after the handoffs section and before `db.close()`, add:

```python
        # --- JC Questions (unseen) ---
        jc_questions = []
        try:
            tables = [r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()]
            if 'jc_questions' in tables:
                q_rows = db.execute(
                    "SELECT id, question, project, created_at FROM jc_questions WHERE seen = 0 ORDER BY created_at DESC LIMIT 10"
                ).fetchall()
                for r in q_rows:
                    jc_questions.append({
                        'id': r[0] if isinstance(r, (list, tuple)) else r['id'],
                        'question': r[1] if isinstance(r, (list, tuple)) else r['question'],
                        'project': r[2] if isinstance(r, (list, tuple)) else r['project'],
                        'created_at': r[3] if isinstance(r, (list, tuple)) else r['created_at'],
                    })
        except Exception:
            pass

        # --- Historical data (daily_summary) ---
        history_days = request.args.get('history_days', 7, type=int)
        history_days = min(history_days, 30)
        history = []
        try:
            if 'daily_summary' in tables:
                history_since = (datetime.now(timezone.utc) - timedelta(days=history_days)).strftime('%Y-%m-%d')
                h_rows = db.execute(
                    "SELECT date, project, hours FROM daily_summary WHERE date >= ? ORDER BY date DESC",
                    (history_since,)
                ).fetchall()
                for r in h_rows:
                    history.append({
                        'date': r[0] if isinstance(r, (list, tuple)) else r['date'],
                        'project': r[1] if isinstance(r, (list, tuple)) else r['project'],
                        'hours': r[2] if isinstance(r, (list, tuple)) else r['hours'],
                    })

            # Supplement today from live activity_stream
            today_str = datetime.now(timezone.utc).strftime('%Y-%m-%d')
            for ta in time_allocation:
                # Only add if not already in daily_summary for today
                if not any(h['date'] == today_str and h['project'] == ta['project'] for h in history):
                    history.append({'date': today_str, 'project': ta['project'], 'hours': ta['hours']})

                # Also persist today's data to daily_summary
                try:
                    captures = project_counts.get(ta['project'], 0)
                    db.execute(
                        "INSERT OR REPLACE INTO daily_summary (date, project, hours, captures) VALUES (?, ?, ?, ?)",
                        (today_str, ta['project'], ta['hours'], captures)
                    )
                except Exception:
                    pass
            db.commit()
        except Exception:
            pass
```

Update the return jsonify to include the new fields:

```python
        return jsonify({
            'status': status,
            'time_allocation': time_allocation,
            'neglected': neglected,
            'jc_activity': jc_activity,
            'handoffs': handoffs,
            'jc_questions': jc_questions,
            'history': history,
        })
```

- [ ] **Step 4: Verify syntax and commit**

```bash
cd server && python3 -c "import ast; ast.parse(open('context-receiver.py').read()); print('OK')"
git add server/context-receiver.py
git commit -m "feat: add daily_summary table, jc_questions endpoints, history + questions in dashboard"
```

---

## Task 3: Digest writes daily_summary rows

**Files:**
- Modify: `server/context-digest.py` — add daily_summary insert after project_last_seen update

- [ ] **Step 1: Add daily_summary population**

Read `server/context-digest.py`. Find where `update_project_last_seen()` is called (around line 355). After that call, add:

```python
    # Write daily_summary rows for each project this period
    try:
        today_str = datetime.now(timezone.utc).strftime('%Y-%m-%d')
        summary_db = get_db()
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
```

Note: Uses a separate `get_db()` call since the main `db` connection may or may not still be open at this point.

- [ ] **Step 2: Verify and commit**

```bash
cd server && python3 -c "import ast; ast.parse(open('context-digest.py').read()); print('OK')"
git add server/context-digest.py
git commit -m "feat: digest writes daily_summary rows per project"
```

---

## Task 4: Swift models — JCQuestion, DailyEntry, update DashboardData

**Files:**
- Create: `mac-helper/OpenClawHelper/Models/JCQuestion.swift`
- Create: `mac-helper/OpenClawHelper/Models/DailyEntry.swift`
- Modify: `mac-helper/OpenClawHelper/Models/DashboardData.swift`

- [ ] **Step 1: Create JCQuestion model**

Create `mac-helper/OpenClawHelper/Models/JCQuestion.swift`:

```swift
import Foundation

struct JCQuestion: Decodable, Identifiable {
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

- [ ] **Step 2: Create DailyEntry model**

Create `mac-helper/OpenClawHelper/Models/DailyEntry.swift`:

```swift
import Foundation

struct DailyEntry: Decodable, Identifiable {
    var id: String { "\(date)-\(project)" }
    let date: String
    let project: String
    let hours: Double
}
```

- [ ] **Step 3: Update DashboardData**

In `DashboardData.swift`, add two new properties to `DashboardData`:

```swift
let jcQuestions: [JCQuestion]
let history: [DailyEntry]
```

Add to the CodingKeys enum:

```swift
case jcQuestions = "jc_questions"
case history
```

Make both optional with defaults for backward compatibility. Use `init(from:)` or make them optional (`[JCQuestion]?`) and default to `[]` in the view model.

Actually, simplest approach — make them optional:

```swift
let jcQuestions: [JCQuestion]?
let history: [DailyEntry]?
```

- [ ] **Step 4: Register new files in Xcode project, build and commit**

Add JCQuestion.swift and DailyEntry.swift to the Xcode project (update project.pbxproj).

```bash
cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Release build 2>&1 | tail -3
git add mac-helper/
git commit -m "feat: add JCQuestion and DailyEntry models, update DashboardData"
```

---

## Task 5: NotificationService

**Files:**
- Create: `mac-helper/OpenClawHelper/Services/NotificationService.swift`

- [ ] **Step 1: Create the notification service**

```swift
import Foundation
import UserNotifications

final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // Show notification even when app is frontmost
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
```

- [ ] **Step 2: Request permission on app launch**

In `OpenClawHelperApp.swift`, add to the `init()` of `AppModel` or in the App struct's `init`:

```swift
NotificationService.shared.requestPermission()
```

- [ ] **Step 3: Register in Xcode, build and commit**

```bash
cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Release build 2>&1 | tail -3
git add mac-helper/
git commit -m "feat: add NotificationService for macOS notifications"
```

---

## Task 6: Notification detection in DashboardViewModel

**Files:**
- Modify: `mac-helper/OpenClawHelper/ViewModels/DashboardViewModel.swift`

- [ ] **Step 1: Add notification detection**

Read the file. Add properties and detection logic:

```swift
@Published var historyDays: Int = 7
private var previousHandoffStatuses: [Int: String] = [:]
private var lastNeglectNotifyDate: [String: String] = [:]  // project -> date string
```

Add a `checkForNotifications` method:

```swift
private func checkForNotifications(_ newData: DashboardData) {
    // 1. Handoff status changes
    for handoff in newData.handoffs {
        let prev = previousHandoffStatuses[handoff.id]
        if let prev = prev, prev != handoff.status,
           (handoff.status == "in-progress" || handoff.status == "done") {
            let verb = handoff.status == "done" ? "completed" : "started"
            NotificationService.shared.send(
                title: "JC \(verb): \(handoff.task)",
                body: handoff.project.capitalized
            )
        }
        previousHandoffStatuses[handoff.id] = handoff.status
    }

    // 2. Neglect alerts (once daily per project)
    let todayStr = ISO8601DateFormatter().string(from: Date()).prefix(10)
    for item in newData.neglected where item.days >= 7 {
        let lastNotified = lastNeglectNotifyDate[item.project]
        if lastNotified != String(todayStr) {
            NotificationService.shared.send(
                title: "\(item.project.capitalized) needs attention",
                body: "\(item.days) days since last activity"
            )
            lastNeglectNotifyDate[item.project] = String(todayStr)
        }
    }

    // 3. JC questions
    if let questions = newData.jcQuestions {
        for q in questions {
            NotificationService.shared.send(
                title: "JC asks about \(q.project ?? "general")",
                body: q.question
            )
            // Mark as seen
            let capturedRunner = runner
            let qid = q.id
            Task.detached {
                try? capturedRunner.runAction("mark-question-seen", "\(qid)")
            }
        }
    }
}
```

Call `checkForNotifications(decoded)` in `refreshDashboard()` right after decoding succeeds (inside the `await MainActor.run` block, after setting `self?.data = decoded`).

Also update `refreshDashboard()` to pass `historyDays` as a parameter. The helperctl `dashboard` command needs to accept and forward this. Simplest: have the view model call `runActionWithOutput("dashboard", "\(historyDays)")` and update helperctl to pass it as `?history_days=N` query parameter.

- [ ] **Step 2: Build and commit**

```bash
cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Release build 2>&1 | tail -3
git add mac-helper/OpenClawHelper/ViewModels/DashboardViewModel.swift
git commit -m "feat: add notification detection for handoffs, neglect, and JC questions"
```

---

## Task 7: Helperctl — mark-question-seen + dashboard history_days

**Files:**
- Modify: `mac-daemon/context-helperctl.sh`

- [ ] **Step 1: Add do_mark_question_seen function**

Add before the dispatch section:

```bash
do_mark_question_seen() {
  local qid="${1:-}"
  if [ -z "$qid" ]; then
    echo '{"error":"mark-question-seen requires <id>"}'
    exit 1
  fi

  local server_url=""
  if [ -f "$(cb_dir)/server-url" ]; then
    server_url=$(cat "$(cb_dir)/server-url" 2>/dev/null || echo "")
  fi
  if [ -z "$server_url" ]; then
    echo "{}"
    exit 0
  fi

  local question_url
  question_url=$(echo "$server_url" | sed "s|/context/push|/context/jc-question/$qid|")

  local auth_token=""
  auth_token=$(security find-generic-password -s "context-bridge" -a "token" -w 2>/dev/null || echo "")
  if [ -z "$auth_token" ]; then
    echo "{}"
    exit 0
  fi

  local curl_args=()
  local ca_cert="$(cb_dir)/server-ca.pem"
  if [[ "$question_url" == https://* ]] && [ -f "$ca_cert" ]; then
    curl_args+=(--cacert "$ca_cert")
  fi

  if [ ${#curl_args[@]} -gt 0 ]; then
    curl -sf -X PATCH \
      -H "Authorization: Bearer $auth_token" \
      -H "Content-Type: application/json" \
      -d '{"seen": true}' \
      --connect-timeout 5 --max-time 10 \
      "${curl_args[@]}" \
      "$question_url" 2>/dev/null || echo "{}"
  else
    curl -sf -X PATCH \
      -H "Authorization: Bearer $auth_token" \
      -H "Content-Type: application/json" \
      -d '{"seen": true}' \
      --connect-timeout 5 --max-time 10 \
      "$question_url" 2>/dev/null || echo "{}"
  fi
}
```

- [ ] **Step 2: Update do_fetch_dashboard to accept history_days**

In `do_fetch_dashboard()`, accept an optional first argument and append as query parameter:

```bash
do_fetch_dashboard() {
  local history_days="${1:-7}"
  # ... existing code ...
  # Change the dashboard_url line to:
  dashboard_url="$(echo "$server_url" | sed 's|/context/push|/context/dashboard|')?history_days=$history_days"
  # ... rest unchanged ...
}
```

- [ ] **Step 3: Add dispatch case**

```bash
mark-question-seen) do_mark_question_seen "$@" ;;
```

- [ ] **Step 4: Verify and commit**

```bash
bash -n mac-daemon/context-helperctl.sh
git add mac-daemon/context-helperctl.sh
git commit -m "feat: add mark-question-seen command, pass history_days to dashboard"
```

---

## Task 8: Historical view UI in DashboardTabView

**Files:**
- Modify: `mac-helper/OpenClawHelper/Views/Tabs/DashboardTabView.swift`

- [ ] **Step 1: Add history section to dashboardContent**

Read the file. Find the `dashboardContent` function. Add a new section after the `bottomPanels` call:

```swift
// History section
historySection(data)
```

- [ ] **Step 2: Implement historySection**

Add the function:

```swift
private func historySection(_ data: DashboardData) -> some View {
    VStack(alignment: .leading, spacing: 12) {
        HStack {
            Text("This Week")
                .font(.headline)
            Spacer()
            Picker("", selection: $viewModel.historyDays) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
        }

        let entries = data.history ?? []
        if entries.isEmpty {
            Text("No historical data yet")
                .foregroundStyle(.secondary)
                .font(.caption)
        } else {
            let grouped = Dictionary(grouping: entries, by: { $0.date })
            let sortedDates = grouped.keys.sorted(by: >)

            ForEach(Array(sortedDates.prefix(viewModel.historyDays)), id: \.self) { date in
                let dayEntries = grouped[date] ?? []
                let totalHours = dayEntries.reduce(0) { $0 + $1.hours }

                HStack(spacing: 8) {
                    Text(formatDayLabel(date))
                        .font(DarkUtilityGlass.monoCaption)
                        .frame(width: 36, alignment: .leading)

                    GeometryReader { geo in
                        HStack(spacing: 1) {
                            ForEach(dayEntries.sorted(by: { $0.hours > $1.hours })) { entry in
                                let fraction = totalHours > 0 ? entry.hours / totalHours : 0
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(projectColor(entry.project))
                                    .frame(width: max(geo.size.width * fraction, 2))
                            }
                        }
                    }
                    .frame(height: 12)

                    Text("\(totalHours, specifier: "%.1f")h")
                        .font(DarkUtilityGlass.monoCaption)
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
    }
    .padding()
    .glassCard()
}

private func formatDayLabel(_ dateStr: String) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    guard let date = formatter.date(from: dateStr) else { return dateStr }
    let dayFormatter = DateFormatter()
    dayFormatter.dateFormat = "EEE"
    return dayFormatter.string(from: date)
}
```

Note: `projectColor` already exists in the file.

- [ ] **Step 3: Build and commit**

```bash
cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Release build 2>&1 | tail -3
git add mac-helper/OpenClawHelper/Views/Tabs/DashboardTabView.swift
git commit -m "feat: add historical time view with stacked bars and day picker"
```

---

## Task 9: Build, deploy, and push

- [ ] **Step 1: Final build**

```bash
cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Release build 2>&1 | tail -3
```

- [ ] **Step 2: Install app**

```bash
osascript -e 'tell application "OpenClawHelper" to quit' 2>/dev/null
pkill -9 -x OpenClawHelper 2>/dev/null; sleep 1
rm -rf /Applications/OpenClawHelper.app
cp -R ~/Library/Developer/Xcode/DerivedData/OpenClawHelper-*/Build/Products/Release/OpenClawHelper.app /Applications/OpenClawHelper.app
open /Applications/OpenClawHelper.app
```

- [ ] **Step 3: Deploy helperctl**

```bash
cd /Users/jonassorensen/Desktop/Hobby/AI/openclaw-computer-vision
cp mac-daemon/context-helperctl.sh ~/.context-bridge/bin/context-helperctl.sh
```

- [ ] **Step 4: Push**

```bash
git push origin main
```
