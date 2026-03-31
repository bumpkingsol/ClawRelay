# Context Bridge - Design Document

**Date:** 2026-03-27
**Status:** DESIGN (brainstormed with Jonas)
**Purpose:** Give JC real-time visibility into Jonas's work activity so autonomous actions don't duplicate or conflict with what Jonas is already doing.

---

## Problem Statement

JC has deep business context but zero operational visibility. He doesn't know what Jonas is working on right now, what's half-finished, or what was completed today. This leads to:
- Duplicated work (regenerating Cegid PDFs that already exist)
- Follow-up emails for conversations Jonas already handled
- Meeting prep for bus tickets
- Inability to work on "everything else" because he doesn't know what "this" is

## Design Principles

1. **Mac-only capture** - Jonas works exclusively on MacBook
2. **Server-to-server only** - no third-party services, no cloud storage, no external APIs
3. **Raw data is ephemeral** - purged after 48 hours
4. **Intelligence persists** - daily structured summaries survive indefinitely
5. **Security first** - filter passwords/API keys from terminal capture, encrypt at rest, HTTPS/SSH transit only

---

## Architecture

```
Jonas MacBook                          Hetzner Server (admin)
┌─────────────────┐                    ┌─────────────────────┐
│ Context Daemon   │───HTTPS/SSH──────>│ Context Receiver     │
│ (launchd)        │   every 2-3 min   │ (API endpoint)       │
│                  │                    │                      │
│ Captures:        │                    │ Stores:              │
│ - Active app     │                    │ - SQLite DB (raw)    │
│ - Window title   │                    │ - 48h retention      │
│ - URLs (Chrome)  │                    │                      │
│ - File paths     │                    │ JC reads DB          │
│ - Git branch     │                    │ before autonomous    │
│ - Terminal cmds  │                    │ actions              │
│ - Notifications  │                    │                      │
│                  │                    │ Daily Digest Job     │
│ Git hooks:       │                    │ - Process raw data   │
│ - post-commit    │                    │ - Open docs/slides   │
│   pushes diffs   │                    │ - Read git diffs     │
│                  │                    │ - Write summary      │
│                  │                    │ - Purge raw >48h     │
└─────────────────┘                    └─────────────────────┘
```

---

## Layer 1: Real-Time Activity Stream

### What Gets Captured (every 2-3 minutes)

| Signal | Method | Example |
|--------|--------|---------|
| Active app name | NSWorkspace / AppleScript | `Cursor`, `Chrome`, `Terminal` |
| Window title | Accessibility API / AppleScript | `notificationService.ts - prescrivia` |
| Chrome URLs | AppleScript on Chrome (requires Accessibility permission) | `https://docs.google.com/presentation/d/...` |
| File paths (editors) | Parse from window title string (Electron apps like Cursor show `filename - folder - Cursor`) | `notificationService.ts - prescrivia - Cursor` |
| Git branch | Shell: `git branch --show-current` in directory inferred from window title | `main`, `codex/launch-readiness` |
| Terminal commands | `.zshrc` PROMPT_COMMAND hook (NOT history tail - history only writes on shell exit) | `npm run build`, `git push` |
| macOS notifications | Notification center API | `Telegram: Nil Porras: Hey about the Cegid...` |
| Idle state | Screen lock / idle time via `ioreg` or CGEventSource | `idle_since: 2026-03-27T19:30:00Z` |

### Electron App File Path Strategy

Cursor, VS Code, and similar Electron editors don't expose file paths via AppleScript reliably. Instead:
- Parse the window title string, which typically shows: `filename - project_folder - Cursor`
- Infer the repo/project from the folder name
- For precise file paths: optionally watch `~/.config/Cursor/User/globalStorage/storage.json` for recently opened files
- Accept that window title parsing is 90% accurate, not 100%

### Terminal Command Capture Strategy

Shell history (`~/.zsh_history`) is written on shell exit, not per-command. Real-time capture requires a shell hook.

Add to `~/.zshrc`:
```bash
# Context Bridge - command logger
preexec() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|$(pwd)|$1" >> ~/.context-bridge-cmds.log
}
```

The daemon reads and flushes this log file on each capture cycle. Filtering happens before transmission (see filtering section below).

### macOS Permissions Required

The install script must prompt for or document:
1. **Accessibility permission** - required for window title and Chrome URL capture
2. **Notification access** - required for reading notification center
3. **Automation permission** - required for AppleScript to control Chrome/Cursor

These are one-time grants in System Preferences > Privacy & Security.

### What Gets Filtered OUT

- Password fields (any input type=password context)
- API keys / tokens in terminal output (regex filter for common patterns: `sk-`, `sb_`, `Bearer`, `token=`, etc.)
- Banking app content (filter by app name: Wise, Revolut, etc.)
- 1Password / Vaultwarden content

### Terminal Command Filtering

Capture command lines but redact:
- `export.*KEY=` → `export [REDACTED_KEY]`
- `curl.*-H.*Bearer` → `curl [REDACTED_AUTH]`
- Any line containing `password`, `secret`, `token` in assignment context

### WhatsApp Desktop

WhatsApp desktop app is a native macOS app. Capture approach:
- Window title shows active chat name: `WhatsApp - Nil Porras` or `WhatsApp - Lulu`
- Notification content (if enabled in macOS) gives message previews
- Cannot read full message history - only what surfaces via window title + notifications
- Accept this as partial visibility. If a critical WhatsApp conversation needs JC context, Jonas forwards to Telegram.

### Idle Detection

Detect when Jonas is away from the Mac to avoid misinterpreting stale window state as active work.

Method: `ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print $NF/1000000000; exit}'` returns seconds since last input event.

Rules:
- Idle > 5 minutes: mark as `idle` in stream, stop capturing window state
- Idle > 30 minutes: mark as `away`
- Screen locked (`CGSessionCopyCurrentDictionary` shows `CGSSessionScreenIsLocked`): mark as `locked`
- Resume from idle: capture immediately on first input

This prevents: "Jonas left Cursor open on Prescrivia and went to dinner, JC thinks he's still coding Prescrivia for 3 hours."

### Offline Handling

If the Mac can't reach the server (airplane mode, no wifi, VPN down):
- Capture continues writing to local SQLite DB on the Mac (`~/.context-bridge/local.db`)
- On each push attempt, if server unreachable, queue locally
- When connection restores, flush the local queue to server in chronological order
- Local queue max size: 10,000 rows (roughly 2-3 days). Oldest rows dropped if exceeded.

### Transport

- HTTPS POST to server endpoint
- Authenticated with strong pre-shared Bearer token (stored in macOS Keychain on Mac, `.env` on server)
- **No IP restriction** - Jonas is nomadic, IP changes constantly. Authentication via token is sufficient.
- Alternative: mutual TLS with client certificate for additional security
- Payload: JSON with timestamp, app, title, url, filepath, git_branch, terminal_cmd, notification, idle_state
- Endpoint: `https://<server-ip>:PORT/context/push`

### Storage

- SQLite database at `/home/admin/clawd/data/context-bridge.db`
- Single table: `activity_stream`
- Columns: `id`, `ts`, `app`, `window_title`, `url`, `file_path`, `git_branch`, `git_repo`, `terminal_cmd`, `notification_app`, `notification_text`, `idle_state`, `created_at`
- Index on `created_at` for time-range queries
- Purge job: delete rows older than 48 hours

---

## Layer 2: Daily Intelligence Digest

### Trigger

Runs three times daily (10:00, 16:00, 23:00 CET) as a cron job. Three times because Jonas context-switches frequently - twice daily would miss mid-day pivots.

### Model Budget

The digest job has two phases with different compute requirements:
1. **Mechanical extraction** (cheap): query DB, group by project, extract URLs/paths, fetch git diffs → MiniMax M2.7
2. **Synthesis** (reasoning): interpret what Jonas was doing, what's finished vs abandoned, what JC should pick up → Sonnet 4.6

Total estimated cost per digest run: ~$0.10-0.30. Three runs/day = ~$1/day max.

### Process

1. Query `activity_stream` for last 8 hours (overlapping windows to catch transitions)
2. Filter out idle/away periods
3. Group by project/workstream (inferred from app + file path + URL + repo)
4. For each Google Doc/Slides/Sheet URL found: open and read current content via `gog` tools
5. For each git repo with activity: read recent commit diffs via local clone
6. For each terminal session: understand what was being built/tested/deployed
7. Compare against previous digest to identify: new work, continued work, dropped work
8. Write structured daily summary

### Output Format

Saved to `memory/activity-digest/YYYY-MM-DD.md`:

```markdown
# Activity Digest - 2026-03-27

## Time Allocation
- Prescrivia: 4.2 hours (largest block)
- Sonopeace: 1.5 hours
- Legal/admin: 0.5 hours
- Other: 0.3 hours

## Prescrivia
- **Code:** Fixed notification handler for doctor approval flow (P0 #2)
- **Code:** Started clarification RPC refactor (P0 #6) - NOT FINISHED
  - Last file touched: `src/services/clarificationService.ts`
  - Branch: `codex/launch-readiness`, not pushed
- **Status:** 18/20 P0s remaining

## Sonopeace
- **Document:** Cost overview deck (Google Slides)
  - URL: [link]
  - Progress: ~80% complete
  - Missing: unit economics slide, payment terms slide
  - Last edited: 19:30

## Unfinished / Dropped
- Prescrivia P0 #6 clarification RPC: started, not completed
- No Leverwork activity today

## Signals
- WhatsApp: Active chat with Nil Porras (3 sessions, ~20 min total)
- No email activity detected
```

### How JC Uses This

Before any autonomous action, JC checks:
1. **Real-time stream** (what is Jonas doing RIGHT NOW?) → don't touch that workstream
2. **Latest digest** (what did Jonas do today/yesterday?) → pick up unfinished work or work on neglected areas
3. **Digest history** (what's been untouched for days?) → flag or act on abandoned tasks

---

## Layer 3: JC Status Visibility (Jonas → JC transparency)

### Telegram Group Updates

JC posts to the main Telegram group topic when:
- Starting a significant autonomous task: `🔧 Starting: Leverwork lead generation from Apollo`
- Completing something: `✅ Done: 25 qualified leads pulled, sequences drafted in Instantly`
- Hitting a blocker or question: `❓ Prescrivia P0 #6: clarification RPC has a version mismatch between v1/v2. Should I migrate to v2 or keep both?`

Format: one-line, emoji prefix, no essays.

Jonas reads when he wants, responds when he wants. No urgency implied.

### Handoff Command

For explicit task handoffs, Jonas can send a quick message:
```
/handoff prescrivia p0-6
```

JC interprets this as: "I'm done working on this, pick it up." JC acknowledges with a one-liner and takes over.

This is optional - JC should infer handoffs from the activity stream when possible (e.g., Jonas stopped touching Prescrivia 2 hours ago and switched to Sonopeace). But explicit handoffs remove ambiguity for critical tasks.

---

## Git Commit Hooks

### Installation

Add post-commit hooks to all repos on Jonas's Mac:
- `~/prescrivia/.git/hooks/post-commit`
- `~/jsvcapital/.git/hooks/post-commit`
- `~/leverwork/.git/hooks/post-commit`
- Any other active repos

### Hook Content

```bash
#!/bin/bash
# Context Bridge - post-commit hook
REPO=$(basename $(git rev-parse --show-toplevel))
BRANCH=$(git branch --show-current)
MSG=$(git log -1 --pretty=%s)
DIFF_STAT=$(git diff --stat HEAD~1 2>/dev/null || echo "initial commit")
AUTHOR=$(git log -1 --pretty=%an)

# Only capture Jonas's commits
if [[ "$AUTHOR" != *"Jonas"* && "$AUTHOR" != *"jonas"* && "$AUTHOR" != *"bumpkingsol"* ]]; then
  exit 0
fi

curl -sf -X POST "https://<server>/context/commit" \
  -H "Authorization: Bearer <shared-secret>" \
  -H "Content-Type: application/json" \
  -d "{
    \"repo\": \"$REPO\",
    \"branch\": \"$BRANCH\",
    \"message\": \"$MSG\",
    \"diff_stat\": \"$DIFF_STAT\",
    \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
  }" &>/dev/null &
```

---

## Security

### Data Classification

| Data | Sensitivity | Handling |
|------|------------|----------|
| App names / window titles | Low | Store, purge after 48h |
| URLs | Medium | Store, purge after 48h |
| File paths | Low | Store, purge after 48h |
| Terminal commands (filtered) | Medium | Store filtered only, purge after 48h |
| Git diffs | Low-Medium | Store in digest summaries |
| Google Doc content | Medium | Read for digest, don't store raw |
| Notification text | Medium-High | Store, purge after 48h |
| WhatsApp previews | High | Store window title only, notification preview if available, purge after 48h |

### Transport Security

- HTTPS with TLS 1.3 to server endpoint
- Authenticated with strong pre-shared Bearer token (stored in macOS Keychain on Mac side, `.env` on server side)
- **No IP allowlisting** - Jonas is nomadic, IP changes with every location/network. Token auth is the security boundary.
- Optional upgrade: mutual TLS with client certificate installed on Mac for defense-in-depth

### Storage Security

- SQLite DB file permissions: 600 (owner only)
- DB location: `/home/admin/clawd/data/` - not in git-tracked directory
- Encryption at rest: LUKS on server disk (already in place) or SQLCipher for DB-level encryption
- Digest summaries in `memory/activity-digest/`: same security as rest of memory corpus
- Git: add `/data/context-bridge.db` and `memory/activity-digest/` to `.gitignore`

### Access Control

- Only JC (the agent running on this server) reads the data
- No web UI, no external access, no API for querying from outside
- Server endpoint only accepts authenticated POST requests, no GET/read access from outside

---

## Implementation Components

### Mac Side (to build)

1. **`context-daemon.sh`** - Main capture script (bash + AppleScript)
2. **`com.openclaw.context-bridge.plist`** - launchd config for auto-start
3. **`context-filter.sh`** - Password/key filtering for terminal capture
4. **`install-hooks.sh`** - Git post-commit hook installer
5. **`install.sh`** - One-command installer for everything

### Server Side (to build)

1. **`context-receiver.py`** - HTTP endpoint that accepts pushes and writes to SQLite
2. **`context-digest.py`** - Processes raw stream into daily summaries
3. **`context-query.py`** - CLI tool for JC to query current state
4. **Cron job** - Runs digest twice daily (13:00 + 23:00 CET)
5. **Purge job** - Deletes raw data older than 48h

### Integration with JC

- Before any autonomous action: `python3 scripts/context-query.py --now` (what is Jonas doing?)
- Before starting work on a project: `python3 scripts/context-query.py --project prescrivia --since today` (has Jonas touched this?)
- Daily digest available at: `memory/activity-digest/YYYY-MM-DD.md`

---

## Rollout Plan

1. **Build server-side receiver + DB** (can do now)
2. **Build Mac-side daemon** (Jonas installs)
3. **Test with 24h of data** - verify capture quality, filtering, no leaks
4. **Build digest processor** - JC reads and produces first summary
5. **Wire into autonomous workflow** - JC checks context before acting
6. **Iterate** - adjust capture frequency, filtering, digest format based on real usage

---

## Success Criteria

- JC never duplicates work Jonas is actively doing
- JC picks up half-finished work without being asked
- JC works on neglected workstreams while Jonas focuses elsewhere
- Jonas can see what JC is doing with a glance at Telegram
- Zero security incidents with captured data

---

## Resolved Design Questions

1. ~~Should the digest run more than twice daily?~~ **Yes - three times daily** (10:00, 16:00, 23:00) due to frequent context-switching.
2. ~~Do we need a focus mode override?~~ **Yes - `/handoff` command** for explicit task transfers.
3. ~~Should JC activity also be tracked?~~ **Yes, via Telegram status updates** - not in the same DB, but visible to Jonas in the group chat.
4. ~~WhatsApp gap - acceptable?~~ **Accept for now.** Window titles + notification previews give partial visibility. Jonas forwards critical context to Telegram when needed.

## Remaining Open Questions

1. Should the digest also track patterns over time? (e.g., "Jonas hasn't touched Leverwork outreach in 5 days" - escalating signal)
2. Do we need a kill switch on the Mac side? (Quick way to pause capture for sensitive work like banking, personal calls)
3. Should JC proactively ask questions based on the digest? (e.g., "You started the clarification RPC yesterday but didn't finish - should I pick it up or are you continuing today?")
