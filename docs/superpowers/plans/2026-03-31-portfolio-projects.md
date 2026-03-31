# Portfolio Projects Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hardcoded `portfolioProjects` array in `MenuBarViewModel` with live data from the server's new `portfolio_projects` table.

**Architecture:** Server provides `GET /context/projects` endpoint. The Mac shell script curls it (same pattern as `do_fetch_dashboard`). The ViewModel decodes and stores it. Popover picker reads from the `@Published` property.

**Tech Stack:** Python/SQLite (server), Bash/curl (shell script), Swift/SwiftUI (Mac)

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `server/context-receiver.py` | Modify | Add migration + `GET /context/projects` endpoint |
| `~/.context-bridge/bin/context-helperctl.sh` | Modify | Add `do_fetch_projects` + `projects` dispatch |
| `mac-helper/.../ViewModels/MenuBarViewModel.swift` | Modify | Replace static array with `@Published`, add fetch |

---

### Task 1: Server — Migration + Endpoint

**Files:**
- Modify: `server/context-receiver.py`

The migration adds the table if it doesn't exist. The endpoint returns all project names sorted alphabetically as JSON.

- [ ] **Step 1: Add migration and `GET /context/projects` endpoint**

Find `init_db()` in `context-receiver.py`. Add the `portfolio_projects` table creation to the existing `CREATE TABLE IF NOT EXISTS` block.

Then find the Flask route section and add:

```python
@app.route("/context/projects", methods=["GET"])
def get_projects():
    token = request.headers.get("Authorization", "").replace("Bearer ", "").strip()
    expected = os.environ.get("CONTEXT_BRIDGE_TOKEN", "").strip()
    if not expected or token != expected:
        return jsonify({"error": "Unauthorized"}), 401

    try:
        db = get_db()
        rows = db.execute(
            "SELECT name FROM portfolio_projects ORDER BY name ASC"
        ).fetchall()
        return jsonify({"projects": [r["name"] for r in rows]})
    except Exception as e:
        return jsonify({"error": str(e)}), 500
```

Add the route AFTER the existing `/context/health` route (around line 85).

- [ ] **Step 2: Test the endpoint**

```bash
cd /Users/jonassorensen/Desktop/Hobby/AI/clawrelay/server
CONTEXT_BRIDGE_TOKEN=dev-token python3 context-receiver.py &
sleep 2
curl -s -H "Authorization: Bearer dev-token" http://localhost:7890/context/projects
# Expected: {"projects": []}  (empty since no projects yet)
curl -s -H "Authorization: Bearer wrong" http://localhost:7890/context/projects
# Expected: {"error": "Unauthorized"}
kill %1
```

- [ ] **Step 3: Commit**

```bash
git add server/context-receiver.py
git commit -m "feat(server): add GET /context/projects endpoint with portfolio_projects table"
```

---

### Task 2: Shell Script — Fetch Projects

**Files:**
- Modify: `~/.context-bridge/bin/context-helperctl.sh`

Add `do_fetch_projects` following `do_fetch_dashboard` exactly. Insert it right before `# ---------------------------------------------------------------------------` (Main dispatch).

- [ ] **Step 1: Add `do_fetch_projects` function and dispatch case**

Add before the `cmd="${1:-}"` line:

```bash
# ---------------------------------------------------------------------------
# fetch-projects  – fetch portfolio projects from the server
# ---------------------------------------------------------------------------
do_fetch_projects() {
  local server_url=""
  if [ -f "$(cb_dir)/server-url" ]; then
    server_url=$(cat "$(cb_dir)/server-url" 2>/dev/null || echo "")
  fi
  if [ -z "$server_url" ]; then
    echo '{}'
    exit 0
  fi

  local projects_url
  projects_url=$(echo "$server_url" | sed 's|/context/push|/context/projects|')

  local auth_token=""
  auth_token=$(security find-generic-password -s "context-bridge" -a "token" -w 2>/dev/null || echo "")
  if [ -z "$auth_token" ]; then
    echo '{}'
    exit 0
  fi

  local curl_args=()
  local ca_cert="$(cb_dir)/server-ca.pem"
  if [[ "$projects_url" == https://* ]] && [ -f "$ca_cert" ]; then
    curl_args+=(--cacert "$ca_cert")
  fi

  local response
  if [ ${#curl_args[@]} -gt 0 ]; then
    response=$(curl -sf \
      -H "Authorization: Bearer $auth_token" \
      --connect-timeout 5 --max-time 10 \
      "${curl_args[@]}" \
      "$projects_url" 2>/dev/null || echo '{}')
  else
    response=$(curl -sf \
      -H "Authorization: Bearer $auth_token" \
      --connect-timeout 5 --max-time 10 \
      "$projects_url" 2>/dev/null || echo '{}')
  fi

  echo "$response"
}
```

Then add `fetch-projects) do_fetch_projects ;;` to the dispatch case. Add it between `dashboard)` and `mark-question-seen)` in alphabetical order under the existing dispatch entries.

- [ ] **Step 2: Test the shell script locally**

```bash
# Test with no server-url configured (should return {})
~/.context-bridge/bin/context-helperctl.sh fetch-projects
# Expected: {}

# Update server-url first if you want to test with a live server:
# echo "http://localhost:7890/context/push" > ~/.context-bridge/server-url
# CONTEXT_BRIDGE_TOKEN=dev-token python3 server/context-receiver.py &
# ~/.context-bridge/bin/context-helperctl.sh fetch-projects
# Expected: {"projects": []}
# kill %1
```

- [ ] **Step 3: Commit**

```bash
git add mac-helper/.context-bridge/bin/context-helperctl.sh
git commit -m "feat(mac): add fetch-projects shell command for portfolio project list"
```

**Note:** The script lives at `~/.context-bridge/bin/context-helperctl.sh`. The repo has a copy at `mac-helper/.context-bridge/bin/context-helperctl.sh` — edit both, or check where the canonical copy lives first with `ls ~/.context-bridge/bin/` on your Mac.

---

### Task 3: Mac ViewModel — Replace Static Array

**Files:**
- Modify: `mac-helper/OpenClawHelper/ViewModels/MenuBarViewModel.swift`

Replace the `static let portfolioProjects` with a `@Published` property and fetch it in `refresh()`.

- [ ] **Step 1: Replace static array with @Published property**

Change:
```swift
static let portfolioProjects = ["project-gamma", "project-alpha", "project-beta", "project-delta", "openclaw"]
```
To:
```swift
@Published var portfolioProjects: [String] = []
```

- [ ] **Step 2: Add fetch call in `refresh()`**

In the `refresh()` function (line 21-25), add `fetchPortfolioProjects()` to the list:
```swift
func refresh() {
    snapshot = runner.fetchStatus()
    fetchDashboard()
    fetchPortfolioProjects()
    refreshWhatsApp()
}
```

- [ ] **Step 3: Add `fetchPortfolioProjects()` method**

Add after `fetchDashboard()` (around line 59):
```swift
func fetchPortfolioProjects() {
    let capturedRunner = runner
    Task.detached {
        do {
            let raw = try capturedRunner.runActionWithOutput("fetch-projects")
            let decoded = try JSONDecoder().decode(ProjectsResponse.self, from: raw)
            await MainActor.run { [weak self] in
                self?.portfolioProjects = decoded.projects.sorted()
            }
        } catch {
            // Silently fail — keep current list
        }
    }
}
```

- [ ] **Step 4: Add response struct**

Add after the `MenuBarViewModel` class closing brace (at the bottom of the file, after line 100):

```swift
private struct ProjectsResponse: Codable {
    let projects: [String]
}
```

- [ ] **Step 5: Build to verify**

```bash
xcodebuild -scheme OpenClawHelper -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add mac-helper/OpenClawHelper/ViewModels/MenuBarViewModel.swift
git commit -m "feat(popover): fetch portfolio projects from server instead of static array"
```

---

### Task 4: Smoke Test (Manual)

No code changes. Verify end-to-end after all three tasks are done.

- [ ] **Step 1: Insert a test project into the DB**

```bash
sqlite3 ~/.context-bridge/data/context-bridge.db \
  "INSERT OR IGNORE INTO portfolio_projects (name) VALUES ('test-project');"
```

- [ ] **Step 2: Verify the endpoint returns it**

```bash
curl -s -H "Authorization: Bearer $CONTEXT_BRIDGE_TOKEN" \
  http://localhost:7890/context/projects
# Expected: {"projects": ["test-project"]}
```

- [ ] **Step 3: Verify the shell script returns it**

```bash
~/.context-bridge/bin/context-helperctl.sh fetch-projects
# Expected: {"projects": ["test-project"]}
```

- [ ] **Step 4: Open the app, verify picker shows "Test-project"**

Clean up:
```bash
sqlite3 ~/.context-bridge/data/context-bridge.db \
  "DELETE FROM portfolio_projects WHERE name = 'test-project';"
```
