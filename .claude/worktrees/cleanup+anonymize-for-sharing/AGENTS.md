# AGENTS.md - For Non-Claude Agents

**If you're Codex, Gemini, GPT, Copilot, or any other agent working on this repo: read this file and CLAUDE.md.**

## Your Role

You are contributing to a system that enables an autonomous AI agent to have operational visibility into a human operator's computer activity. This is not a surveillance tool - it's a coordination mechanism between two operators (one human, one AI) who need shared context to work effectively without duplicating effort.

## What You Need to Know Before Writing Code

### The Daemon (Mac side)
- Runs on macOS via launchd, every 2 minutes
- Written in bash + AppleScript + Python (for JSON serialization)
- Must be lightweight - it runs constantly in the background
- Must fail silently on permission errors (don't crash, don't alert the user)
- Must handle offline gracefully (queue locally, flush when online)
- Captures metadata only (app names, window titles, URLs, file paths) - NOT screen content

### The Server (Linux side)
- Python 3 + Flask + SQLite
- Runs as a systemd service
- Receives pushes from the Mac daemon via HTTPS
- The digest processor is the brain - it interprets raw data into actionable intelligence
- The agent that consumes this data runs on the same server

### What the Operator Cares About
- **It works reliably.** A daemon that crashes or misses captures is worse than no daemon.
- **It's secure.** No data leaves the Mac→server pipeline. No third parties.
- **It's lightweight.** Shouldn't drain battery, spike CPU, or slow down the Mac.
- **It enables real autonomy.** The goal isn't data collection - it's enabling the agent to make good decisions without asking the operator first.

### What the Operator Does NOT Care About
- Pretty UIs or dashboards
- Comprehensive analytics
- Historical trends beyond what the digest captures
- Supporting multiple users or machines

## Coding Standards

- Bash scripts: `set -euo pipefail`, handle errors, fail gracefully
- Python: standard library where possible, minimal dependencies
- No node_modules, no complex build systems
- Comments explain WHY, not WHAT
- Test by running, not by writing test suites (this is infra, not a product)

## File Ownership

| Component | Primary Author | Notes |
|-----------|---------------|-------|
| `mac-daemon/*` | Any agent | Must test on actual macOS |
| `server/*` | Any agent | Can test on Linux server |
| `*.md` docs | The agent / the operator | Update when design changes |
| `DESIGN.md` | The agent + the operator | Canonical design decisions |

## Questions?

If something in the architecture doesn't make sense, read `PURPOSE.md` first. The design decisions all trace back to specific failures documented in `ISSUES.md`. If you're about to add a feature, check `ROADMAP.md` to see if it's planned and what phase it belongs to.

Don't add features that aren't in the roadmap without understanding why they're not there. Most missing features were deliberately deferred - not forgotten.
