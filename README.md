# OpenClaw Context Bridge

Real-time activity monitoring from Jonas's Mac → JC's server. Gives JC operational visibility into what Jonas is working on so autonomous actions don't duplicate or conflict.

## Architecture

```
MacBook (daemon)  ──HTTPS──>  Server (receiver)  ──>  JC (agent)
  captures every              stores in SQLite         reads before
  2-3 minutes                 purges after 48h         any autonomous
                              digests persist           action
```

## Components

### Mac Side (`mac-daemon/`)
- `context-daemon.sh` - Main capture script (launchd)
- `context-helperctl.sh` - Control contract for the helper app (JSON over Process)
- `install.sh` - One-command installer
- `com.openclaw.context-bridge.plist` - launchd config

### macOS Helper App (`mac-helper/`)

Native SwiftUI menu bar app that observes, controls, and repairs the local capture pipeline. Lives in the system tray and provides:

- **Menu bar popover**: live status, health strip, quick actions (pause/resume/sensitive)
- **Control Center window**: Overview, Permissions, Privacy, Diagnostics tabs
- Reads `~/.context-bridge/` for queue state, logs, and pause files
- Communicates with the daemon via `context-helperctl.sh` (JSON over Process)
- Never captures data itself - it only observes and controls the bash-based pipeline

#### Build and Run
```bash
# Command line
xcodebuild -project mac-helper/OpenClawHelper.xcodeproj -scheme OpenClawHelper -destination 'platform=macOS' build
open mac-helper/build/Build/Products/Debug/OpenClawHelper.app

# Or open in Xcode
open mac-helper/OpenClawHelper.xcodeproj  # then Cmd+R
```

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
