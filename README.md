# OpenClaw Context Bridge

Real-time activity monitoring from Jonas's Mac → JC's server. Gives JC operational visibility into what Jonas is working on so autonomous actions don't duplicate or conflict.

## Architecture

```
┌─────────────────┐           ┌──────────────────┐       ┌──────────┐
│  macOS Helper    │ controls  │  Mac Daemon       │ HTTPS │  Server  │
│  (menu bar app)  │─────────>│  (every 2 min)    │──────>│  (Flask) │
│  observe/repair  │          │  captures context  │       │  SQLite  │
└─────────────────┘           └──────────────────┘       └────┬─────┘
                                                              │ reads
                                                         ┌────┴─────┐
                                                         │  JC (AI) │
                                                         │  agent   │
                                                         └──────────┘
```

## Components

### Mac Side (`mac-daemon/`)
- `context-daemon.sh` - Main capture script (runs every 2 min via launchd)
- `context-helperctl.sh` - Control CLI for the helper app (10 JSON commands: status, pause, resume, sensitive, restart-daemon, restart-watcher, purge-local, queue-handoff, privacy-rules)
- `context-common.sh` - Shared path helpers and pause/sensitive state readers
- `context-shell-hook.zsh` - Shell command logger (respects pause state)
- `fswatch-projects.sh` - File change watcher (respects pause state)
- `install.sh` - One-command installer (user-owned scripts at `~/.context-bridge/bin/`)

### macOS Helper App (`mac-helper/`)

Native SwiftUI menu bar app (macOS 14+) that observes, controls, and repairs the local capture pipeline. Sits in the menu bar - no Dock icon.

**Menu Bar Popover:**
- Live tracking state (Active / Paused / Sensitive / Needs Attention)
- Health strip: queue depth, daemon status, watcher status
- Quick actions: Pause 15m, Pause 1h, Until Tomorrow, Resume, Sensitive Mode toggle

**Control Center Window (4 tabs):**
- **Overview** - State cards, service health, restart buttons
- **Permissions** - Accessibility, Automation, Full Disk Access detection with "Open Settings" repair links
- **Privacy** - Pause presets, Sensitive Mode, handoff composer, local data purge
- **Diagnostics** - Error logs, config paths, repair actions

**How it works:**
- Communicates with the daemon via `context-helperctl.sh` (JSON over `Process`)
- Reads `~/.context-bridge/` for queue state, logs, and pause files
- Never captures data itself - it only observes and controls the bash pipeline
- Polls every 5 seconds when the popover or Control Center is open

#### Requirements
- macOS 14.0+ (Sonoma or later)

#### Install (pre-built)
1. Download `OpenClawHelper-v0.1.0.zip` from [Releases](https://github.com/clawrelay-org/openclaw-computer-vision/releases)
2. Unzip and move `OpenClawHelper.app` to `/Applications`
3. First launch: right-click the app > **Open** (required for unsigned apps)

#### Build from source
```bash
# Command line
bash scripts/build-release.sh
open mac-helper/build/Build/Products/Release/OpenClawHelper.app

# Or open in Xcode (requires Xcode 15+)
open mac-helper/OpenClawHelper.xcodeproj  # then Cmd+R
```

#### Privacy Controls
| Mode | Effect | Use case |
|------|--------|----------|
| **Pause** | Stops all local context generation entirely | Personal time, sensitive meetings |
| **Sensitive** | Reduces capture to heartbeat payloads; shell/git still flow | Confidential work where you want JC to know you're active |

### Server Side (`server/`)
- `context-receiver.py` - HTTP endpoint accepting pushes
- `context-digest.py` - Processes raw stream into daily summaries
- `context-query.py` - CLI for querying current state

### Shared
- `scripts/install-hooks.sh` - Git post-commit hook installer

## Setup

### Server
```bash
cd server && pip install -r requirements.txt
CONTEXT_BRIDGE_TOKEN=dev-token python context-receiver.py  # starts on port 7890
```

### Mac
```bash
bash mac-daemon/install.sh https://YOUR_SERVER:7890/context/push /path/to/context-bridge.pem
```

## Security
- Transport: HTTPS with Bearer token auth
- Storage: SQLite, 600 permissions, purged after 48h
- No third-party services, no cloud storage
- Raw data ephemeral, only digests persist

## Design Doc
See [design document](https://github.com/clawrelay-org/openclaw-computer-vision/blob/main/DESIGN.md)
