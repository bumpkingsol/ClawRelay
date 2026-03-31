# ROADMAP.md - Build Phases

## Phase 1: Core ✅
**Goal:** Raw capture working end-to-end.

- [x] Mac daemon captures: app, window title, Chrome URLs (all tabs), file paths, git state, terminal commands, idle state
- [x] Clipboard capture with change detection + password filtering
- [x] File change events via fswatch on project directories
- [x] Codex/Claude Code session detection (active sessions + process check)
- [x] WhatsApp Desktop context (window title = active chat name)
- [x] Notification capture with Full Disk Access support + fallback paths
- [x] Server receiver stores in SQLite with 48h purge
- [x] Auth via Bearer token
- [x] Offline queue on Mac with flush-on-reconnect
- [x] Health endpoint with staleness detection
- [x] systemd service for persistent receiver
- [x] Self-signed TLS
- [x] Git post-commit hooks
- [x] Digest processor with Google Doc reading via `gog`
- [x] Query CLI (now, today, project, gaps)
- [x] `/handoff` API endpoint
- [x] Daemon watchdog script
- [x] fswatch file watcher as separate launchd service
- [x] Installer handles all components + permissions guidance
- [x] **Server-side setup and running**
- [x] **Mac-side installation and testing**
- [x] **First real data flowing**

## Phase 2: Integration ✅ (enhancement work complete)
**Goal:** The agent makes better autonomous decisions using the data.

- [x] The agent checks `context-query.py now` before any autonomous action — covered by `status` command
- [x] The agent checks `context-query.py project <name>` before working on any project
- [x] Digest comparison: detect started-but-abandoned work across days — cross-digest comparison added to digest processor
- [x] The agent posts Telegram status updates when starting/completing autonomous work — documented in integration guide
- [x] Watchdog cron alerting the agent if daemon goes stale — `server/staleness-watchdog.sh` + `daemon_stale` field in `status` output
- [x] Handoff processing: the agent reads pending handoffs and acts — `/handoff` endpoint and `status` output include handoff queue
- [x] Pre-action decision rules documented — `docs/jc-integration-guide.md`
- [x] `neglected` and `since` query commands for autonomous project selection

## Phase 3: Autonomy
**Goal:** The agent operates as a true second operator.
*Note: Phase 3 items build on the Phase 2 integration foundation now in place.*

- [ ] The agent autonomously picks up abandoned work without being asked
- [ ] The agent autonomously shifts focus based on what the operator is NOT doing
- [ ] The agent provides end-of-day summary: "You did X, I did Y, Z is still open"
- [ ] Feedback loop: the operator rates the agent's autonomous actions, the agent adjusts
- [ ] Pattern tracking: "X hasn't been touched in N days" escalating signals
- [ ] Let's Encrypt TLS upgrade
