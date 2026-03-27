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
- [ ] **Server-side setup and running**
- [ ] **Mac-side installation and testing**
- [ ] **First real data flowing**

## Phase 2: Integration
**Goal:** JC makes better autonomous decisions using the data.

- [ ] JC checks `context-query.py now` before any autonomous action
- [ ] JC checks `context-query.py project <name>` before working on any project
- [ ] Digest comparison: detect started-but-abandoned work across days
- [ ] JC Telegram status updates when starting/completing autonomous work
- [ ] Watchdog cron alerting JC if daemon goes stale
- [ ] Handoff processing: JC reads pending handoffs and acts

## Phase 3: Autonomy
**Goal:** JC operates as a true second operator.

- [ ] JC autonomously picks up abandoned work without being asked
- [ ] JC autonomously shifts focus based on what Jonas is NOT doing
- [ ] JC provides end-of-day summary: "You did X, I did Y, Z is still open"
- [ ] Feedback loop: Jonas rates JC's autonomous actions, JC adjusts
- [ ] Pattern tracking: "X hasn't been touched in N days" escalating signals
- [ ] Let's Encrypt TLS upgrade
