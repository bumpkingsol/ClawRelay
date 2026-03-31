<p align="center">
  <img src="assets/openclaw-icon.svg" width="80" height="80" alt="OpenClaw">
</p>

# ClawRelay

Real-time activity bridge between a Mac and an autonomous AI agent. Tracks what you're working on, surfaces operational intelligence, and lets you hand off tasks — so your agent can coordinate autonomously without duplicating your work.

## Architecture

```
┌──────────────────┐          ┌──────────────────┐  Tailscale  ┌──────────────┐
│  ClawRelay       │ controls │  Mac Daemon       │    HTTP     │  Server      │
│  (menu bar app)  │────────>│  (every 2 min)    │───────────>│  (Flask)     │
│  dashboard +     │          │  captures context  │             │  SQLite      │
│  handoffs +      │          │  reads switch log  │             │  (SQLCipher) │
│  notifications   │          └──────────────────┘             └──────┬───────┘
└──────────────────┘                                                  │ reads
                                                                 ┌────┴───────┐
                                                                 │  AI Agent  │
                                                                 │  (JC)      │
                                                                 └────────────┘
```

## What It Captures

| Signal | Detail |
|--------|--------|
| App switch tracking | Continuous foreground app monitoring via NSWorkspace (not just snapshots) |
| Window titles | Every app's window title at switch time — enables accurate project detection |
| Chrome tabs | Active URL + all open tab URLs and titles |
| Git state | Current repo, branch, recent commits |
| Terminal commands | Last 10 commands (secrets redacted) |
| File changes | Real-time fswatch events per project |
| AI agent sessions | Active Claude/Codex sessions and tasks |
| Meeting/call detection | Camera + mic state, call app identification |
| Focus/DND mode | macOS Focus mode detection |
| Calendar events | Upcoming events via native EventKit CLI (opt-in, never launches Calendar.app) |
| Idle state | Active, idle, away, or locked |
| Notifications | Recent macOS notifications (requires Full Disk Access) |
| WhatsApp context | Active chat name (not message content) |

**Privacy filtering:** 40+ sensitive apps, 48 URL patterns, and 8 title keywords are automatically blanked out. Banks, password managers, crypto wallets, and login pages send zero data. Configurable via `~/.context-bridge/privacy-rules.json`.

## ClawRelay App (`mac-helper/`)

Native SwiftUI menu bar app (macOS 14+). Your operations dashboard + daemon control panel.

**Menu Bar Popover:**
- Live tracking state (Active / Paused / Sensitive / Needs Attention)
- Dashboard summary: current project, time today, agent status, focus level
- Health strip: queue depth, daemon status, watcher status
- Quick actions: Pause 15m, Pause 1h, Until Tomorrow, Sensitive Mode
- Quick handoff: project dropdown + task field for fast delegation

**Control Center (6 tabs):**
- **Dashboard** - Status cards (current project, focus level, agent activity), time allocation bars, project neglect alerts, handoff status, historical view (7/30 days with stacked bars)
- **Overview** - Service health, restart buttons
- **Permissions** - Accessibility, Automation, Full Disk Access with repair links
- **Privacy** - Pause presets, Sensitive Mode, local data purge
- **Handoffs** - Full compose form (project, task, details, priority) + bidirectional status history (pending / in-progress / done)
- **Diagnostics** - Error logs, config paths, repair actions

**Notifications:**
- Agent handoff updates (started / completed)
- Project neglect alerts (7+ days, once daily)
- Agent questions requiring your input

**App Switch Tracker:**
- Listens to `NSWorkspace.didActivateApplicationNotification` continuously
- Logs every foreground change with timestamp + window title to JSONL
- Daemon reads the log every 2 min and computes time-weighted activity
- Replaces snapshot-based capture with accurate per-app time tracking

#### Install
```bash
# Build from source
cd mac-helper && xcodebuild -scheme OpenClawHelper -configuration Release build
cp -R ~/Library/Developer/Xcode/DerivedData/OpenClawHelper-*/Build/Products/Release/OpenClawHelper.app /Applications/
```

## Mac Daemon (`mac-daemon/`)

- `context-daemon.sh` - Main capture script (runs every 2 min via launchd)
- `context-helperctl.sh` - Control CLI (status, pause, resume, sensitive, restart, queue-handoff, list-handoffs, dashboard, mark-question-seen, meeting-status, meeting-start, meeting-stop)
- `context-common.sh` - Shared path helpers and state readers
- `context-shell-hook.zsh` - Shell command logger
- `fswatch-projects.sh` - File change watcher
- `install.sh` - One-command installer

```bash
bash mac-daemon/install.sh http://TAILSCALE_IP:7890/context/push
```

**Calendar CLI** (`mac-helper/claw-calendar/`): Native Swift binary using EventKit. Queries calendar silently without launching Calendar.app.

**Meeting Recorder** (`mac-helper/claw-meeting/`): Swift package for real-time meeting capture — system + mic audio with 16 kHz mixing, live transcription via FluidAudio, screen capture with face analysis (Vision framework), speaker diarisation, and session management via Unix domain socket. Pushes frames and session data to the server for processing.

## Server (`server/`)

- `context-receiver.py` - Flask endpoint accepting pushes, handoffs, questions, meeting data, and dashboard queries
- `context-digest.py` - Processes raw stream into structured summaries (3x daily), includes meeting sections
- `context-query.py` - CLI for querying state (`status`, `today`, `project`, `gaps`, `since`, `neglected`)
- `meeting_processor.py` - Meeting intelligence: Claude Vision expression analysis, timeline merge, participant profiles, summary generation
- `config.py` - Shared project list and constants
- `db_utils.py` - Encrypted DB connections (SQLCipher when available, fallback to sqlite3)
- `watchdog.py` - Daemon health checker
- `staleness-watchdog.sh` - Cron script to detect daemon disconnection
- `wsgi.py` / `start.sh` - Production startup via Gunicorn

```bash
bash server/setup-server.sh  # installs systemd service
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

### API Endpoints

| Method | Endpoint | Purpose |
|--------|----------|---------|
| POST | `/context/push` | Receive activity capture from daemon |
| POST | `/context/commit` | Receive git commit data |
| POST | `/context/handoff` | Receive task handoff |
| GET | `/context/handoffs` | List recent handoffs with status |
| PATCH | `/context/handoffs/<id>` | Update handoff status (agent marks done) |
| GET | `/context/dashboard` | Combined dashboard data (status, time, neglect, agent activity, handoffs, history) |
| GET | `/context/health` | Health check with capture status |
| GET | `/context/jc-work-log` | Agent's own work activity log |
| POST | `/context/jc-question` | Agent posts a question for the user |
| PATCH | `/context/jc-question/<id>` | Mark question as seen |
| POST | `/context/meeting/session` | Push meeting session metadata (start/end, participants) |
| POST | `/context/meeting/frames` | Upload meeting screen captures for expression analysis |
| POST | `/meeting/context-request` | Agent requests real-time meeting context (rate-limited) |

All endpoints require Bearer token auth.

## Security

- **Transport:** HTTP over Tailscale WireGuard tunnel (encrypted at the network layer, no TLS certs needed)
- **Auth:** Bearer token (macOS Keychain on client, `.env` on server), HMAC-constant comparison
- **Data at rest:** SQLCipher AES-256 encryption (key derived from auth token via PBKDF2), 600 file permissions
- **Retention:** Raw data purged after 48h, daily summaries persist for historical view
- **Privacy:** 40+ sensitive apps, 48 URL patterns, and 8 title keywords auto-filtered
- **Systemd hardening:** NoNewPrivileges, ProtectSystem=strict, PrivateTmp, UMask=0077
- **Token rotation:** `bash server/setup-server.sh rotate-token`
- **No third-party services** - data flows Mac to server only, no public IP exposed

#### Privacy Controls

| Mode | Effect | Use case |
|------|--------|----------|
| **Pause** | Stops all local context generation | Personal time, sensitive meetings |
| **Sensitive** | Reduces to heartbeat payloads; shell/git still flow | Confidential work |
| **Auto-filter** | Banks, password managers, login pages blanked automatically | Always active |

## Documentation

- [Quickstart](QUICKSTART.md) - Complete setup guide (server + Mac)
- [Architecture](ARCHITECTURE.md) - Full system design
- [Design](DESIGN.md) - Technical decisions from the original brainstorm
- [Purpose](PURPOSE.md) - Why this exists, specific failures it solves
- [Roadmap](ROADMAP.md) - Build phases and status
- [Issues](ISSUES.md) - Known gaps and anticipated risks
- [Agent Integration Guide](docs/jc-integration-guide.md) - Pre-action check pattern for the agent
- [Autonomous Action Loop](docs/jc-autonomous-action-loop.md) - Decision rules, project selection, end-of-day summary
- [Server Deployment Checklist](docs/server-deployment-checklist.md) - VPS setup steps
