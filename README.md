<p align="center">
  <img src="assets/openclaw-icon.svg" width="80" height="80" alt="OpenClaw">
</p>

# OpenClaw Context Bridge

Real-time activity monitoring bridge between a Mac and an autonomous AI agent. Captures what you're working on and pushes it to your agent's server, so the agent can coordinate autonomously without duplicating your work.

## Architecture

```
┌──────────────┐           ┌──────────────────┐       ┌──────────────┐
│  ClawRelay   │ controls  │  Mac Daemon       │ HTTPS │  Server      │
│  (menu bar)  │─────────>│  (every 2 min)    │──────>│  (Flask)     │
│  + handoffs  │          │  captures context  │       │  SQLite      │
└──────────────┘           └──────────────────┘       └──────┬───────┘
                                                             │ reads
                                                        ┌────┴───────┐
                                                        │  AI Agent  │
                                                        │  (JC)      │
                                                        └────────────┘
```

## What It Captures

| Signal | Detail |
|--------|--------|
| Active app + window title | Which app is frontmost, what's in the title bar |
| Chrome tabs | Active URL + all open tab URLs and titles |
| Git state | Current repo, branch, recent commits |
| Terminal commands | Last 10 commands (secrets redacted) |
| File changes | Real-time fswatch events per project |
| AI agent sessions | Active Claude/Codex sessions and tasks |
| Meeting/call detection | Camera + mic state, call app identification |
| Focus/DND mode | macOS Focus mode detection |
| Calendar events | Upcoming events from Calendar.app (opt-in) |
| Idle state | Active, idle, away, or locked |
| Notifications | Recent macOS notifications (requires Full Disk Access) |
| WhatsApp context | Active chat name (not message content) |

**Privacy filtering:** Banks, password managers, crypto wallets, login pages, and sensitive window titles are automatically blanked out. Configurable via `~/.context-bridge/privacy-rules.json`.

## Components

### ClawRelay (`mac-helper/`)

Native SwiftUI menu bar app (macOS 14+). Controls the daemon, manages privacy, and handles task handoffs.

**Menu Bar Popover:**
- Live tracking state (Active / Paused / Sensitive / Needs Attention)
- Health strip: queue depth, daemon status, watcher status
- Quick actions: Pause 15m, Pause 1h, Until Tomorrow, Sensitive Mode
- Quick handoff: project dropdown + task field for fast delegation to AI agent

**Control Center (5 tabs):**
- **Overview** - State cards, service health, restart buttons
- **Permissions** - Accessibility, Automation, Full Disk Access with repair links
- **Privacy** - Pause presets, Sensitive Mode, local data purge
- **Handoffs** - Full compose form (project, task, details, priority) + bidirectional status history (pending / in-progress / done)
- **Diagnostics** - Error logs, config paths, repair actions

#### Install
```bash
# Build from source
cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Release build
cp -R ~/Library/Developer/Xcode/DerivedData/OpenClawHelper-*/Build/Products/Release/OpenClawHelper.app /Applications/
```

### Mac Daemon (`mac-daemon/`)
- `context-daemon.sh` - Main capture script (runs every 2 min via launchd)
- `context-helperctl.sh` - Control CLI (status, pause, resume, sensitive, restart, queue-handoff, list-handoffs, privacy-rules)
- `context-common.sh` - Shared path helpers and state readers
- `context-shell-hook.zsh` - Shell command logger
- `fswatch-projects.sh` - File change watcher
- `install.sh` - One-command installer

```bash
bash mac-daemon/install.sh https://YOUR_SERVER:7890/context/push /path/to/server-ca.pem
```

### Server (`server/`)
- `context-receiver.py` - Flask endpoint accepting pushes, handoffs, and status updates
- `context-digest.py` - Processes raw stream into structured summaries (3x daily)
- `context-query.py` - CLI for querying state (`status`, `today`, `project`, `gaps`, `since`, `neglected`)
- `config.py` - Shared project list and constants
- `db_utils.py` - Encrypted DB connections (SQLCipher when available, fallback to sqlite3)
- `staleness-watchdog.sh` - Cron script to detect daemon disconnection

```bash
bash server/setup-server.sh  # generates TLS certs, installs systemd service
```

### Digest Output

The digest processor runs 3x daily and produces structured markdown summaries:

- Time allocation per project (hours + percentages)
- Cross-digest comparison (new / continued / dropped work)
- Project neglect tracker (days since last activity)
- Focus level per hour (focused / multitasking / scattered)
- Terminal commands, file changes, Chrome tabs
- Communication context (WhatsApp), AI agent sessions, notifications
- Calendar events

The AI agent reads these digests to decide what to work on autonomously.

### API Endpoints

| Method | Endpoint | Purpose |
|--------|----------|---------|
| POST | `/context/push` | Receive activity capture from daemon |
| POST | `/context/commit` | Receive git commit data |
| POST | `/context/handoff` | Receive task handoff |
| GET | `/context/handoffs` | List recent handoffs with status |
| PATCH | `/context/handoffs/<id>` | Update handoff status (agent marks done) |
| GET | `/context/health` | Health check with capture status |

All endpoints require Bearer token auth.

## Security

- **Transport:** HTTPS with self-signed cert pinning (over Tailscale WireGuard tunnel)
- **Auth:** Bearer token (macOS Keychain on client, `.env` on server), HMAC-constant comparison
- **Data at rest:** SQLCipher AES-256 encryption (when installed), 600 file permissions
- **Retention:** Raw data purged after 48h, only digest summaries persist
- **Privacy:** 40+ sensitive apps, 48 URL patterns, and 8 title keywords auto-filtered
- **Systemd hardening:** NoNewPrivileges, ProtectSystem=strict, PrivateTmp, UMask=0077
- **No third-party services** - data flows Mac to server only

#### Privacy Controls

| Mode | Effect | Use case |
|------|--------|----------|
| **Pause** | Stops all local context generation | Personal time, sensitive meetings |
| **Sensitive** | Reduces to heartbeat payloads; shell/git still flow | Confidential work |
| **Auto-filter** | Banks, password managers, login pages blanked automatically | Always active |

## Documentation

- [Architecture](ARCHITECTURE.md) - Full system design
- [Design](DESIGN.md) - Technical decisions from the original brainstorm
- [JC Integration Guide](docs/jc-integration-guide.md) - Pre-action check pattern for the AI agent
- [Server Deployment Checklist](docs/server-deployment-checklist.md) - VPS setup steps
