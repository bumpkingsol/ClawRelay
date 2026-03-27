# ROADMAP.md - Build Phases

## Phase 1: Core (Current)
**Goal:** Raw capture working end-to-end.

- [x] Mac daemon captures: app, window title, Chrome URLs (all tabs), file paths, git state, terminal commands, idle state
- [x] Server receiver stores in SQLite with 48h purge
- [x] Auth via Bearer token
- [x] Offline queue on Mac with flush-on-reconnect
- [x] Health endpoint with staleness detection
- [x] systemd service for persistent receiver
- [x] Self-signed TLS
- [x] Git post-commit hooks
- [x] Digest processor (structured daily summaries)
- [x] Query CLI (now, today, project, gaps)
- [ ] **Server-side setup and running**
- [ ] **Mac-side installation and testing**
- [ ] **First real data flowing**

## Phase 2: Intelligence
**Goal:** JC makes better autonomous decisions using the data.

- [ ] Wire `gog` into digest processor to read Google Docs/Slides/Sheets content
- [ ] JC checks `context-query.py now` before any autonomous action
- [ ] JC checks `context-query.py project <name>` before working on any project
- [ ] Digest comparison: detect started-but-abandoned work across days
- [ ] `/handoff` command via Telegram
- [ ] JC Telegram status updates when starting/completing autonomous work

## Phase 3: Refinement
**Goal:** Higher fidelity capture and smarter processing.

- [ ] `fswatch` for real-time file change detection
- [ ] Codex/Claude Code session log capture
- [ ] Pattern tracking: "X hasn't been touched in N days" escalating alerts
- [ ] Let's Encrypt TLS upgrade
- [ ] Daemon watchdog with server-side staleness alerting
- [ ] Kill switch (menu bar toggle to pause capture)
- [ ] macOS permissions automation in installer

## Phase 4: Full Autonomy
**Goal:** JC operates as a true second operator.

- [ ] JC autonomously picks up abandoned work without being asked
- [ ] JC autonomously shifts focus based on what Jonas is NOT doing
- [ ] JC provides end-of-day summary: "You did X, I did Y, Z is still open"
- [ ] Feedback loop: Jonas rates JC's autonomous actions, JC adjusts
- [ ] WhatsApp content integration (if technically feasible)
