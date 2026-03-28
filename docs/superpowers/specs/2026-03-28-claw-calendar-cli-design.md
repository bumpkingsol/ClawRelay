# claw-calendar CLI Design

**Date:** 2026-03-28
**Status:** Approved
**Goal:** Replace the JXA calendar query (which force-launches Calendar.app) with a native Swift CLI that uses EventKit to silently read calendar events.

## Problem

The daemon's calendar capture uses `osascript -l JavaScript` with `Application("Calendar")`, which launches Calendar.app every 2 minutes. This is wasteful and intrusive.

## Solution

A small Swift CLI binary (`claw-calendar`) that:
1. Queries EventKit for events happening now or starting in the next 2 hours
2. Redacts sensitive event titles using keywords passed via environment variable
3. Prints JSON to stdout and exits
4. Never launches Calendar.app

## Output Format

Same as the current daemon payload:
```json
[
  {"title": "Sprint Planning", "start": "2026-03-28T14:00:00Z", "end": "2026-03-28T14:30:00Z", "is_now": true},
  {"title": "[private event]", "start": "2026-03-28T16:00:00Z", "end": "2026-03-28T16:30:00Z", "is_now": false}
]
```

Empty calendar or no permission: `[]`

## Privacy

Reads the `SENSITIVE_TITLE_KEYWORDS` environment variable (newline-separated lowercase keywords). If any keyword appears in an event title (case-insensitive), the title is replaced with `[private event]`. No attendees, descriptions, or locations are ever included.

## EventKit Permission

First run triggers the macOS "wants to access your calendars" prompt. Once granted, subsequent runs are silent. If denied, the CLI prints `[]` and exits 0 (no error — graceful degradation).

## Daemon Integration

Replace the entire calendar section in `context-daemon.sh` (the `CALENDAR_ENABLED` check, JXA osascript block, and Python redaction block) with:

```bash
# --- Calendar Awareness (opt-in) ---
CALENDAR_EVENTS="[]"
CALENDAR_ENABLED=$(python3 -c "
import json
try:
    with open('$PRIVACY_RULES_FILE') as f:
        print('true' if json.load(f).get('calendar_enabled') else 'false')
except:
    print('false')
" 2>/dev/null || echo "false")

if [ "$CALENDAR_ENABLED" = "true" ]; then
  export SENSITIVE_TITLE_KEYWORDS
  CALENDAR_EVENTS=$("$CB_DIR/bin/claw-calendar" 2>/dev/null || echo "[]")
fi
```

## Files

- Create: `mac-helper/claw-calendar/main.swift` — the CLI tool (~60 lines)
- Modify: `mac-daemon/context-daemon.sh` — replace JXA block with `claw-calendar` call
- Modify: `mac-daemon/install.sh` — compile and install the binary to `~/.context-bridge/bin/claw-calendar`

## Build

```bash
swiftc -O -o claw-calendar mac-helper/claw-calendar/main.swift -framework EventKit -framework Foundation
```

Or as part of the Xcode project. The binary is ~200KB.

## Installation

The `install.sh` script compiles and copies:
```bash
swiftc -O -o "$HOME/.context-bridge/bin/claw-calendar" mac-helper/claw-calendar/main.swift -framework EventKit -framework Foundation
chmod +x "$HOME/.context-bridge/bin/claw-calendar"
```
