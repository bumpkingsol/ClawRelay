# CLAUDE.md - Agent Onboarding

**Read this first if you're an AI agent working on this codebase.**

## What This Is

A real-time activity monitoring bridge between the operator's MacBook and their autonomous AI agent. It gives the agent operational visibility into what the operator is working on so the agent can make better autonomous decisions.

**Read these in order:**
1. `PURPOSE.md` - Why this exists and what failures it solves
2. `ARCHITECTURE.md` - Full system design, all three layers
3. `ISSUES.md` - Known gaps, anticipated risks
4. `ROADMAP.md` - Build phases and what's done vs pending
5. `DESIGN.md` - Detailed technical decisions from the original brainstorm

## Critical Context

### The People
- **The operator** - Works exclusively on a MacBook. Nomadic (IP changes constantly). Uses Chrome only. Switches contexts frequently throughout the day.
- **The agent** - Autonomous AI agent running on a VPS (Ubuntu). Operates as an autonomous assistant across the operator's project portfolio. The agent is the primary consumer of the data this system produces.

### The Problem in One Sentence
The agent has deep business knowledge but zero visibility into what the operator is doing right now, which causes duplicated work, wasted effort, and an inability to act autonomously on the right things.

### The Solution in One Sentence
A Mac daemon captures the operator's activity (apps, windows, URLs, git, terminal) and pushes it to the agent's server, where it's processed into operational intelligence that informs the agent's autonomous decisions.

## Architecture Quick Reference

```
Mac Daemon (every 2 min) → HTTPS + Bearer token → Server Receiver → SQLite (48h retention)
                                                                          ↓
                                                              Digest Processor (3x daily)
                                                                          ↓
                                                              Structured summaries (permanent)
                                                                          ↓
                                                              Agent reads before autonomous actions
```

## Development Rules

### Security is Non-Negotiable
- **No third-party services.** Data flows Mac → VPS only. No cloud storage, no external APIs, no analytics.
- **No credentials in code.** Auth tokens in macOS Keychain (Mac side) and `.env` (server side).
- **Filter sensitive data before transmission.** Passwords, API keys, banking app content never leave the Mac.
- **48-hour purge on raw data.** Only digest summaries persist.

### The Daemon Runs on macOS
- Must work on macOS (Apple Silicon, latest macOS)
- Uses AppleScript for window/app capture - this requires Accessibility permission
- Uses `launchd` (not cron) for scheduling
- Must handle offline gracefully (local queue, flush on reconnect)
- Must detect idle/locked state to avoid misinterpreting stale windows

### The Server Runs on Linux (Ubuntu)
- Python 3, Flask, SQLite
- systemd service for persistence
- The agent reads the database directly via Python scripts
- The digest processor is the intelligence layer - it interprets raw data, not just stores it

### Chrome Only
The operator uses Chrome exclusively. Do not build support for Safari, Firefox, Arc, or any other browser. If this changes, the operator will say so.

### The Daemon Does NOT Read Documents
The daemon captures URLs. The agent reads the actual Google Docs/Slides/Sheets content during digest processing using the `gog` CLI tool on the server. The daemon is lightweight and fast - it captures metadata, not content.

### Capture Quality > Feature Count
A reliable 2-minute capture cycle that accurately reflects what the operator is doing is worth more than fancy features that break. If something is fragile (like notification DB access), make it optional and fail silently.

## Testing

### Manual Testing (Mac daemon)
```bash
# Run one capture cycle manually
bash mac-daemon/context-daemon.sh

# Check local queue
sqlite3 ~/.context-bridge/local.db "SELECT COUNT(*) FROM queue;"

# Check logs
tail -f /tmp/context-bridge.log
```

### Manual Testing (Server)
```bash
# Start receiver
cd server && CONTEXT_BRIDGE_TOKEN=dev-token python3 context-receiver.py

# Check health
curl -H "Authorization: Bearer dev-token" http://localhost:7890/context/health

# Query current state
python3 server/context-query.py now
python3 server/context-query.py today
python3 server/context-query.py gaps --days 3

# Run digest
python3 server/context-digest.py --dry-run
```

### Simulating a Push (for testing without Mac)
```bash
curl -X POST http://localhost:7890/context/push \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "ts": "2026-03-27T20:00:00Z",
    "app": "Cursor",
    "window_title": "notificationService.ts - project-gamma - Cursor",
    "url": "",
    "file_path": "project-gamma",
    "git_repo": "project-gamma",
    "git_branch": "codex/launch-readiness",
    "idle_state": "active",
    "idle_seconds": 0
  }'
```

## Common Pitfalls

1. **AppleScript permissions.** If the daemon silently fails, it's almost always a missing Accessibility or Automation permission in System Preferences.

2. **Electron window title parsing.** Cursor/VS Code change their title format between versions. The daemon parses `file - folder - AppName` but separators vary (` - `, ` — `, ` | `). Handle all variants.

3. **Shell history vs preexec.** `.zsh_history` only writes on shell exit, not per-command. The `preexec` hook in `.zshrc` is the correct approach for real-time terminal capture.

4. **SQLite concurrent access.** The receiver writes while the digest processor reads. WAL mode is enabled for this reason. Don't switch to default journal mode.

5. **macOS notification DB path.** Changes between macOS versions. Currently at `~/Library/Group Containers/group.com.apple.usernoted/db2/db`. May require Full Disk Access. Make this optional - don't crash if unavailable.

## What Success Looks Like

When this system is working correctly:
- The agent knows what the operator is working on within 2 minutes
- The agent never duplicates the operator's active work
- The agent picks up abandoned tasks without being asked
- The agent works on neglected projects while the operator focuses elsewhere
- The daily self-maintenance overhead drops to near zero
- The operator can see what the agent is doing via Telegram status updates
