# App Switch Tracker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace snapshot-based activity capture with continuous app switch tracking so time allocation and project detection are accurate regardless of what's frontmost at the 2-minute capture mark.

**Architecture:** ClawRelay listens for `NSWorkspace.didActivateApplicationNotification`, logs each switch with timestamp/app/title to `~/.context-bridge/app-switches.jsonl`. The daemon reads this file every 2 minutes, computes time-per-app, picks the dominant app, and sends enriched data. Falls back to snapshot if no switch log exists.

**Tech Stack:** SwiftUI/AppKit (ClawRelay), Bash + Python inline (daemon)

**Spec:** `docs/superpowers/specs/2026-03-28-app-switch-tracker-design.md`

---

## File Structure

**New files:**
- `mac-helper/OpenClawHelper/Services/AppSwitchTracker.swift` — NSWorkspace listener + JSONL writer

**Modified files:**
- `mac-helper/OpenClawHelper/AppModel.swift` — start tracker on init
- `mac-daemon/context-daemon.sh` — read switch log, aggregate, replace snapshot

---

## Task 1: AppSwitchTracker service

**Files:**
- Create: `mac-helper/OpenClawHelper/Services/AppSwitchTracker.swift`
- Modify: `mac-helper/OpenClawHelper/AppModel.swift`

- [ ] **Step 1: Create AppSwitchTracker.swift**

```swift
import AppKit
import Foundation

final class AppSwitchTracker {
    static let shared = AppSwitchTracker()

    private let logPath: String
    private let pausePath: String
    private let dateFormatter: ISO8601DateFormatter

    private init() {
        let home = NSHomeDirectory()
        logPath = "\(home)/.context-bridge/app-switches.jsonl"
        pausePath = "\(home)/.context-bridge/pause-until"
        dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
    }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func appDidActivate(_ notification: Notification) {
        guard !isPaused() else { return }

        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let appName = app.localizedName else { return }

        // Capture window title via AppleScript
        let title = captureWindowTitle(appName)

        let entry: [String: Any] = [
            "ts": dateFormatter.string(from: Date()),
            "app": appName,
            "title": title,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              let line = String(data: data, encoding: .utf8) else { return }

        appendLine(line)
    }

    private func captureWindowTitle(_ appName: String) -> String {
        let script = "tell application \"System Events\" to get name of front window of application process \"\(appName)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }

    private func appendLine(_ line: String) {
        let fileURL = URL(fileURLWithPath: logPath)

        // Create file if missing
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }

        // Append
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        handle.seekToEndOfFile()
        handle.write((line + "\n").data(using: .utf8)!)
        handle.closeFile()

        // Prune entries older than 5 minutes
        pruneOldEntries()
    }

    private func pruneOldEntries() {
        guard let content = try? String(contentsOfFile: logPath, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let cutoff = Date().addingTimeInterval(-300) // 5 minutes ago

        let kept = lines.filter { line in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tsStr = obj["ts"] as? String,
                  let ts = ISO8601DateFormatter().date(from: tsStr) else {
                return false
            }
            return ts > cutoff
        }

        let newContent = kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")
        try? newContent.write(toFile: logPath, atomically: true, encoding: .utf8)
    }

    private func isPaused() -> Bool {
        guard let content = try? String(contentsOfFile: pausePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        if content == "indefinite" { return true }
        guard let until = TimeInterval(content) else { return false }
        return Date().timeIntervalSince1970 < until
    }
}
```

- [ ] **Step 2: Start tracker in AppModel**

In `AppModel.swift`, add after `NotificationService.shared.requestPermission()`:

```swift
AppSwitchTracker.shared.start()
```

- [ ] **Step 3: Register in Xcode project, build and commit**

Add AppSwitchTracker.swift to project.pbxproj (PBXBuildFile, PBXFileReference, Services group, Sources build phase).

```bash
cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Release build 2>&1 | tail -3
git add mac-helper/
git commit -m "feat: add AppSwitchTracker — logs every foreground app change to JSONL"
```

---

## Task 2: Daemon reads switch log and aggregates

**Files:**
- Modify: `mac-daemon/context-daemon.sh` (lines 340-345 for snapshot capture, lines 412-424 for background editor)

- [ ] **Step 1: Add switch log aggregation**

Read `mac-daemon/context-daemon.sh`. Find the section that captures ACTIVE_APP and WINDOW_TITLE (around lines 340-343):

```bash
# --- Active App + Window Title ---
ACTIVE_APP=$(osascript -e '...' ...)
WINDOW_TITLE=$(osascript -e '...' ...)
```

Replace that section (from the `# --- Active App + Window Title ---` comment through the sensitive app/title check, INCLUDING the background editor context section) with:

```bash
# --- Active App + Window Title (switch log or snapshot) ---
SWITCH_LOG="$CB_DIR/app-switches.jsonl"
SWITCH_RESULT=""

if [ -f "$SWITCH_LOG" ] && [ -s "$SWITCH_LOG" ]; then
  # Read switch log and aggregate time per app
  SWITCH_RESULT=$(python3 -c "
import json, sys, os
from datetime import datetime, timezone

log_path = sys.argv[1]
lines = []
try:
    with open(log_path) as f:
        lines = [json.loads(l) for l in f if l.strip()]
except:
    pass

if not lines:
    print(json.dumps({'fallback': True}))
    sys.exit(0)

app_times = {}
all_titles = []
for i, entry in enumerate(lines):
    try:
        ts = datetime.fromisoformat(entry['ts'].replace('Z', '+00:00'))
    except:
        continue
    if i + 1 < len(lines):
        try:
            next_ts = datetime.fromisoformat(lines[i+1]['ts'].replace('Z', '+00:00'))
            duration = (next_ts - ts).total_seconds()
        except:
            duration = 0
    else:
        duration = (datetime.now(timezone.utc) - ts).total_seconds()
    duration = min(max(duration, 0), 300)
    app = entry.get('app', 'unknown')
    app_times[app] = app_times.get(app, 0) + duration
    title = entry.get('title', '')
    if title:
        all_titles.append(title)

if not app_times:
    print(json.dumps({'fallback': True}))
    sys.exit(0)

dominant = max(app_times, key=app_times.get)
dominant_title = ''
for entry in reversed(lines):
    if entry.get('app') == dominant:
        dominant_title = entry.get('title', '')
        break

unique_titles = list(set(all_titles))
print(json.dumps({
    'app': dominant,
    'title': dominant_title,
    'all_titles': unique_titles,
}))
" "$SWITCH_LOG" 2>/dev/null || echo '{"fallback": true}')

  # Truncate the log after reading
  > "$SWITCH_LOG"
fi

# Parse result or fall back to snapshot
FALLBACK=$(echo "$SWITCH_RESULT" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('fallback',''))" 2>/dev/null || echo "true")

if [ "$FALLBACK" = "True" ] || [ "$FALLBACK" = "true" ] || [ -z "$SWITCH_RESULT" ]; then
  # Snapshot fallback — same as before
  ACTIVE_APP=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || echo "unknown")
  WINDOW_TITLE=$(osascript -e 'tell application "System Events" to get name of front window of first application process whose frontmost is true' 2>/dev/null || echo "")
else
  # Use aggregated data
  ACTIVE_APP=$(echo "$SWITCH_RESULT" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('app','unknown'))" 2>/dev/null || echo "unknown")
  DOMINANT_TITLE=$(echo "$SWITCH_RESULT" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('title',''))" 2>/dev/null || echo "")
  ALL_TITLES=$(echo "$SWITCH_RESULT" | python3 -c "import json,sys; print(' '.join(json.loads(sys.stdin.read()).get('all_titles',[])))" 2>/dev/null || echo "")
  WINDOW_TITLE="$DOMINANT_TITLE"
  if [ -n "$ALL_TITLES" ]; then
    WINDOW_TITLE="$DOMINANT_TITLE [also: $ALL_TITLES]"
  fi
fi

# --- Sensitive app or title: blank out entirely ---
if is_sensitive_app "$ACTIVE_APP" || is_sensitive_title "$WINDOW_TITLE"; then
  PAYLOAD=$(build_minimal_payload "active" "${idle_seconds:-0}")
  send_payload "$PAYLOAD" || true
  exit 0
fi
```

- [ ] **Step 2: Remove the old background editor context section**

The background editor section (around lines 412-424) that we added earlier is no longer needed — the switch log already captures every editor visit. Find and remove:

```bash
# --- Background editor context (capture even when not frontmost) ---
EDITOR_PROJECTS=""
if [[ "$ACTIVE_APP" != "Code" && ... ]]; then
  ...
fi
```

Also remove the corresponding section near the exports that appends editor projects to WINDOW_TITLE:

```bash
# Append background editor context to window title for project matching
if [ -n "$EDITOR_PROJECTS" ]; then
  WINDOW_TITLE="${WINDOW_TITLE} [bg: ${EDITOR_PROJECTS}]"
fi
```

- [ ] **Step 3: Verify syntax**

```bash
bash -n mac-daemon/context-daemon.sh && echo "OK"
```

- [ ] **Step 4: Deploy and commit**

```bash
cp mac-daemon/context-daemon.sh ~/.context-bridge/bin/context-bridge-daemon.sh
git add mac-daemon/context-daemon.sh
git commit -m "feat: daemon reads app switch log for accurate time-weighted capture"
```

---

## Task 3: Build, deploy, and push

- [ ] **Step 1: Build**

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

- [ ] **Step 3: Verify switch log is being written**

Switch between a few apps, then:

```bash
cat ~/.context-bridge/app-switches.jsonl
```

Expected: JSONL entries with ts, app, title for each app you switched to.

- [ ] **Step 4: Trigger a daemon capture and check**

```bash
bash ~/.context-bridge/bin/context-bridge-daemon.sh
cat ~/.context-bridge/app-switches.jsonl  # should be empty (truncated)
```

- [ ] **Step 5: Push**

```bash
git push origin main
```
