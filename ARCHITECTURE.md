# ARCHITECTURE.md - System Design

## Overview

The Context Bridge has four layers:

```
┌─────────────────────────────────────────────────────┐
│                    LAYER 4                           │
│              macOS Helper (Local Operator)           │
│    SwiftUI menu bar app: observe, control, repair   │
│    Talks to daemon via context-helperctl.sh          │
└─────────────────────────┬───────────────────────────┘
                          │ controls
┌─────────────────────────┴───────────────────────────┐
│                    LAYER 3                           │
│              Mutual Visibility                       │
│    Jonas sees JC's work via Telegram                 │
│    JC sees Jonas's work via activity stream          │
└─────────────────────────┬───────────────────────────┘
                          │ reads
┌─────────────────────────┴───────────────────────────┐
│                    LAYER 2                           │
│              Intelligence (Digest)                   │
│    Processes raw stream into structured summaries    │
│    Opens Google Docs, reads git diffs                │
│    Detects: finished, in-progress, abandoned work    │
│    Runs 3x daily (10:00, 16:00, 23:00 CET)         │
└─────────────────────────┬───────────────────────────┘
                          │ reads
┌─────────────────────────┴───────────────────────────┐
│                    LAYER 1                           │
│              Raw Activity Stream                     │
│    Mac daemon → HTTPS → Server → SQLite             │
│    Every 2 minutes, 48-hour retention               │
└─────────────────────────────────────────────────────┘
```

## Layer 4: macOS Helper (Local Operator)

Native SwiftUI menu bar app that observes, controls, and repairs the local capture pipeline.

- **MenuBarExtra with popover**: status, quick actions (pause/resume/sensitive), health strip
- **Control Center window**: Overview, Permissions, Privacy, Diagnostics tabs
- Communicates with the daemon via `context-helperctl.sh` (JSON over Process)
- Reads logs, queue state, and permission status directly from the filesystem
- Never captures data itself - it observes and controls the bash-based pipeline

### Pause vs Sensitive

| Mode | What happens | Use when |
|------|-------------|----------|
| **Pause** | Stops all local context generation. No shell commands, file changes, or window info is captured. The daemon does nothing until resumed. | You want complete privacy. Personal calls, sensitive meetings, off-the-clock hours. |
| **Sensitive** | Keeps the system operational but reduces capture to minimal heartbeat payloads. Shell commands and git commits still flow; window titles and URLs are suppressed. | You're working on something confidential but still want JC to know you're active on a project. |

Both modes can be activated from the menu bar popover or the Privacy tab in the Control Center.

## Layer 1: Raw Activity Stream

### Source: Mac Daemon (`mac-daemon/context-daemon.sh`)

A bash script running every 2 minutes via macOS `launchd`. Captures:

| Signal | Method | Notes |
|--------|--------|-------|
| Active app | AppleScript + NSWorkspace | e.g. `Cursor`, `Chrome`, `Terminal` |
| Window title | AppleScript Accessibility API | e.g. `notificationService.ts - project-gamma - Cursor` |
| Chrome URLs | AppleScript on Chrome (all tabs) | Active tab URL + all open tab URLs |
| File paths | Parsed from editor window titles | Electron apps show `file - folder - app` |
| Git branch | `git branch --show-current` | Inferred from active editor directory |
| Terminal commands | `.zshrc` preexec hook | Filtered for passwords/keys before transmission |
| Notifications | macOS Notification Center DB | Requires Full Disk Access permission |
| Idle state | `ioreg` HIDIdleTime + screen lock | Prevents stale window misinterpretation |

### Browser Coverage

Chrome only. Jonas does not use Safari or other browsers.

### Transport

```
Mac daemon → HTTPS POST → Server receiver
             Bearer token auth (macOS Keychain → .env)
             JSON payload per capture
             Self-signed TLS (upgradeable to Let's Encrypt)
```

No IP allowlisting - Jonas is nomadic, changes networks frequently. Security is token-based.

### Offline Handling

If the server is unreachable:
- Captures queue in local SQLite on Mac (`~/.context-bridge/local.db`)
- Queue flushes when connection restores
- Max 10,000 queued rows (~2-3 days), oldest dropped if exceeded

### Storage: Server SQLite

```
/home/user/clawrelay/data/context-bridge.db

Tables:
  activity_stream  - raw captures (purged after 48h)
  commits          - git commit data from hooks (purged after 48h)

Indexes:
  idx_activity_created  - for time-range queries
  idx_activity_ts       - for chronological ordering
```

File permissions: `600` (owner only). Not in any git-tracked directory.

### Idle Detection

| State | Condition | Behavior |
|-------|-----------|----------|
| `active` | Idle < 5 min | Full capture |
| `idle` | Idle 5-30 min | Minimal payload (state only) |
| `away` | Idle > 30 min | Minimal payload |
| `locked` | Screen locked | Minimal payload |

Prevents: "Jonas left Cursor open on Project Gamma and went to dinner → JC thinks he's still coding for 3 hours."

## Layer 2: Intelligence (Digest Processor)

### Source: `server/context-digest.py`

Runs 3x daily as a cron job. Transforms raw captures into structured operational summaries.

### Process

1. **Extract** - Query raw stream for last 8 hours
2. **Classify** - Group captures by project (keyword matching against known project identifiers)
3. **Enrich** - For each Google Doc/Slides/Sheet URL found: JC reads content via `gog` CLI tools (NOT the daemon)
4. **Enrich** - For each git repo with activity: read recent commit diffs from local clones
5. **Compare** - Diff against previous digest to detect: new work, continued work, dropped work
6. **Synthesize** - Write structured markdown summary

### Output

Saved to `memory/activity-digest/YYYY-MM-DD-HH.md` with a `latest.md` symlink.

```markdown
# Activity Digest - 2026-03-27 (23:00)

## Time Allocation
- project-gamma: ~4.2h (65%)
- project-delta: ~1.5h (23%)
- other: ~0.8h (12%)

## Project Gamma
*~4.2h | 14:00 → 19:30*
Files touched: notificationService.ts, clarificationService.ts
Branches: codex/launch-readiness
Commits: [2] Fixed doctor approval notification, Started RPC refactor

## Not Touched This Period
- ⚠️ project-alpha
- ⚠️ project-beta
```

### Model Budget

| Phase | Model | Cost/run |
|-------|-------|----------|
| Mechanical extraction | MiniMax M2.7 | ~$0.02 |
| Google Doc reading | `gog` CLI (no model) | $0 |
| Synthesis | Sonnet 4.6 | ~$0.10-0.25 |
| **Total per digest** | | **~$0.15-0.30** |
| **Daily (3 runs)** | | **~$0.50-1.00** |

### Project Classification

Known projects and their keyword identifiers:

| Project | Keywords |
|---------|----------|
| project-gamma | `project-gamma` |
| project-alpha | `project-alpha` |
| project-delta | `project-delta` |
| project-beta | `project-beta`, `jsvcapital` |
| aeoa | `aeoa`, `aeoa-studio` |
| openclaw | `openclaw`, `clawd` |
| nilsy | `nilsy` |
| legal | `mcol`, `sehaj`, `azika`, `sorna`, `rohu` |

## Layer 3: Mutual Visibility

### Jonas → JC (this system)

Activity stream + digests give JC real-time and historical visibility into Jonas's work.

### JC → Jonas (Telegram)

JC posts one-line status updates to the Telegram group when:
- Starting autonomous work: `🔧 Starting: Project Alpha lead gen from Apollo`
- Completing work: `✅ Done: 25 leads pulled, sequences in Instantly`
- Hitting a blocker: `❓ Project Gamma P0 #6: v1/v2 mismatch - should I migrate?`

### Handoff Protocol

Explicit task transfer via Telegram message:
```
/handoff project-gamma p0-6
```

JC acknowledges and takes over. Optional - JC should also infer handoffs from activity patterns (e.g., Jonas stopped touching a project 2+ hours ago).

## Git Commit Hooks

Post-commit hooks installed on all repos on Jonas's Mac. On each commit:
- Extracts: repo name, branch, commit message, diff stat
- Filters: only Jonas's commits (by author name)
- Pushes to server: `POST /context/commit`
- Runs async (background) - doesn't slow down git

## Security Model

### Data Flow

```
Jonas MacBook → (HTTPS + Bearer token) → Hetzner Server
                                          ↓
                                     SQLite (600 perms)
                                          ↓
                                     JC reads via Python
                                          ↓
                                     Anthropic API (inference)
```

No third-party services. No cloud storage. No external APIs except Anthropic (same trust boundary as all other JC operations).

### Sensitive Data Filtering

**Filtered before transmission (on Mac):**
- `export.*KEY=`, `Bearer`, `token=` → `[REDACTED]`
- `sk-*`, `sb_*` patterns → `[REDACTED_KEY]`
- `password`, `secret` in assignment context → `[REDACTED]`

**Filtered by app name (not captured):**
- Banking apps: Wise, Revolut
- Password managers: 1Password, Vaultwarden

**Not captured at all:**
- Screen content / pixels
- Keystroke logging
- Clipboard content (future consideration)
- Audio / microphone

### Data Retention

| Data Type | Retention | Location |
|-----------|-----------|----------|
| Raw activity stream | 48 hours | SQLite DB |
| Raw commit data | 48 hours | SQLite DB |
| Digest summaries | Permanent | `memory/activity-digest/` |
| Local queue (Mac) | Until flushed | `~/.context-bridge/local.db` |

### Permissions Required (macOS)

| Permission | Why | One-time |
|-----------|-----|----------|
| Accessibility | Window title, Chrome URL capture | Yes |
| Automation | AppleScript control of Chrome | Yes |
| Full Disk Access | Notification center DB (optional) | Yes |

## API Endpoints

| Endpoint | Method | Auth | Purpose |
|----------|--------|------|---------|
| `/context/push` | POST | Bearer | Receive activity captures |
| `/context/commit` | POST | Bearer | Receive git commit data |
| `/context/health` | GET | Bearer | Health check + capture staleness |

## File Structure

```
openclaw-computer-vision/
├── README.md
├── PURPOSE.md              ← Why this exists
├── ARCHITECTURE.md         ← This file
├── DESIGN.md               ← Detailed design decisions
├── mac-daemon/
│   ├── context-daemon.sh   ← Main capture script
│   ├── context-helperctl.sh ← Control contract for helper app
│   ├── context-common.sh   ← Shared functions
│   ├── install.sh          ← Mac installer
│   └── com.openclaw.context-bridge.plist  ← launchd config
├── mac-helper/
│   └── OpenClawHelper.xcodeproj  ← Layer 4 SwiftUI app
│       └── OpenClawHelper/
│           ├── Models/      ← BridgeSnapshot, PermissionStatus, HandoffDraft
│           ├── ViewModels/  ← MenuBarViewModel, ControlCenterViewModel
│           ├── Views/       ← MenuBarPopover, ControlCenter, tab views
│           ├── Services/    ← BridgeCommandRunner, PermissionService
│           └── Theme/       ← DarkUtilityGlass visual system
├── server/
│   ├── context-receiver.py ← HTTP endpoint + SQLite
│   ├── context-digest.py   ← Layer 2 intelligence
│   ├── context-query.py    ← CLI query tool
│   ├── context-bridge.service  ← systemd unit
│   ├── setup-server.sh     ← Server installer
│   └── requirements.txt
└── scripts/
    └── install-hooks.sh    ← Git hook installer
```
