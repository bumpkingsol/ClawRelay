# WhatsApp Message Capture for ClawRelay

**Date:** 2026-03-30
**Status:** Draft
**Author:** Jonas + Claude (brainstorm)

## Problem

JC (the autonomous AI agent) has zero visibility into Jonas's WhatsApp conversations. WhatsApp is used for business decisions, action items, relationship context, and information sharing with partners and team members. Without this context, JC misses timeline changes, shared links, and collaborative decisions — leading to stale assumptions and duplicated effort.

## Solution

Integrate WhatsApp message capture into ClawRelay by forking the relevant parts of [wacli](https://github.com/steipete/wacli) (a Go CLI built on the `whatsmeow` library) into a purpose-built `claw-whatsapp` binary. This binary connects as a linked WhatsApp Web device, syncs messages in real-time, filters by a whitelist of contacts/groups, and writes captured messages to a buffer that the main daemon ships to the server.

## Architecture

```
claw-whatsapp (Go, persistent launchd service)
  ├─ whatsmeow: WhatsApp Web protocol, linked device
  ├─ Whitelist filter: discard non-matching messages at protocol level
  ├─ Output: ~/.context-bridge/whatsapp-buffer.jsonl
  └─ Health: ~/.context-bridge/whatsapp-health.json

context-daemon.sh (existing, every 2 min)
  ├─ Reads and flushes whatsapp-buffer.jsonl
  ├─ Includes whatsapp_messages in payload
  └─ Ships to server

context-receiver.py (existing, server)
  ├─ Stores whatsapp_messages in activity_stream
  └─ 48-hour purge (same as all raw data)

context-digest.py (existing, 3x daily)
  ├─ New WhatsApp section in digest
  ├─ Per-contact: topics, action items, links, frequency
  └─ Digest summaries persist permanently
```

### ClawRelay Distribution

```
ClawRelay.app        (Swift, menu bar UI)
context-daemon.sh    (Bash, main capture cycle)
claw-calendar        (Swift, EventKit CLI)
claw-whatsapp        (Go, whatsmeow)  ← new
```

## Components

### 1. `claw-whatsapp` Binary

A single Go binary wrapping `whatsmeow`. Three modes:

**`claw-whatsapp --auth`**
- Displays QR code in terminal for WhatsApp linking
- Stores session credentials in `~/.context-bridge/whatsapp-session/` (SQLite, same as wacli)
- One-time operation

**`claw-whatsapp --run`**
- Persistent sync mode, intended to run under launchd
- Registers a `whatsmeow` event handler for incoming/outgoing messages
- On each message event:
  1. Extract sender JID (e.g. `34612345678@s.whatsapp.net`) or group JID (e.g. `120363...@g.us`)
  2. Check against whitelist — discard immediately if no match
  3. Extract: sender, text, timestamp, message type (text/image/video/document/voice/reaction/reply)
  4. Append as JSON line to `~/.context-bridge/whatsapp-buffer.jsonl`
- Writes health status to `~/.context-bridge/whatsapp-health.json` every 30 seconds:
  ```json
  { "status": "syncing", "last_message_at": "2026-03-30T14:32:00Z", "uptime_seconds": 3600 }
  ```
- Honors pause and sensitive mode: checks `~/.context-bridge/pause-until` and `~/.context-bridge/sensitive-mode` every 30 seconds. When paused or in sensitive mode, stops writing to the buffer (messages are silently discarded, not queued — consistent with how sensitive mode suppresses all non-heartbeat data)
- No message sending capability — read-only by design (reduces ban risk surface)
- No media downloading — captures type + caption only
- No search, no CLI interface — single-purpose

**`claw-whatsapp --setup`**
- Interactive whitelist population helper (third mode of the same binary)
- Queries the whatsmeow session for recent chats (contacts and groups with recent activity)
- Displays a numbered list: display name + JID
- User picks which ones to whitelist
- Writes entries to `privacy-rules.json`
- After updating the whitelist, sends SIGHUP to the running `--run` process (via PID file at `~/.context-bridge/whatsapp.pid`) to trigger a hot reload

**`claw-whatsapp --check`**
- Reads `whatsapp-health.json` and prints human-readable status
- Useful for verifying setup: `claw-whatsapp --check` → "Syncing | Last message: 2 min ago | 3 whitelisted contacts"

**What we take from wacli:**
- `whatsmeow` integration and device registration
- Auth/QR code pairing flow
- Message event handling patterns
- SQLite session storage

**What we strip:**
- All send functionality
- Media downloading
- Search/CLI interface
- Group management commands
- Interactive terminal UI

### 2. Whitelist Configuration

Lives in `~/.context-bridge/privacy-rules.json` alongside existing privacy rules:

```json
{
  "whatsapp_whitelist": {
    "mode": "whitelist",
    "contacts": [
      { "id": "+34612345678", "label": "Nil Porras" },
      { "id": "+46701234567", "label": "Magnus (Leverwork)" },
      { "id": "group:120363012345678901@g.us", "label": "Prescrivia Team" }
    ]
  }
}
```

- `id`: stable identifier — phone number (with `+` prefix) for individuals, `group:<JID>` for groups
- `label`: human-readable name for digests and menu bar UI, never used for matching
- JID conversion: `"+34612345678"` matches `"34612345678@s.whatsapp.net"`, `"group:120363..."` matches `"120363...@g.us"`
- Whitelist is loaded on startup and reloaded on SIGHUP (no restart needed to add contacts)
- If no whitelist configured, WhatsApp capture is disabled (safe default)

### 3. Buffer Format

`~/.context-bridge/whatsapp-buffer.jsonl` — one JSON object per line:

```json
{"chat_id":"34612345678@s.whatsapp.net","chat_label":"Nil Porras","sender":"Nil","sender_jid":"34612345678@s.whatsapp.net","text":"Let's push the demo to Friday","ts":"2026-03-30T14:32:00Z","type":"text"}
{"chat_id":"34612345678@s.whatsapp.net","chat_label":"Nil Porras","sender":"Jonas","sender_jid":"self","text":"Works for me","ts":"2026-03-30T14:33:00Z","type":"text"}
{"chat_id":"120363012345678901@g.us","chat_label":"Prescrivia Team","sender":"Magnus","sender_jid":"46701234567@s.whatsapp.net","text":"PR merged, deploying now","ts":"2026-03-30T15:41:00Z","type":"text"}
{"chat_id":"120363012345678901@g.us","chat_label":"Prescrivia Team","sender":"Magnus","sender_jid":"46701234567@s.whatsapp.net","text":"","ts":"2026-03-30T15:42:00Z","type":"image","caption":"Staging screenshot"}
```

Fields:
- `chat_id`: JID of the chat (individual or group)
- `chat_label`: human-readable name from whitelist config
- `sender`: push name from WhatsApp (what the sender set as their display name). For Jonas's own messages, sender is `"self"`
- `sender_jid`: sender's JID, or `"self"` for Jonas's own messages
- `text`: message text content (empty string for media-only messages)
- `ts`: ISO 8601 timestamp
- `type`: `text`, `image`, `video`, `document`, `voice`, `reaction`, `reply`
- `caption`: (optional) caption for media messages
- `reply_to`: (optional) first 200 characters of the message being replied to, for context

### 4. Daemon Integration

`context-daemon.sh` changes:

**Buffer read uses atomic file rotation** to avoid race conditions with the persistent `claw-whatsapp` writer:
1. `mv whatsapp-buffer.jsonl whatsapp-buffer.jsonl.processing` (atomic rename)
2. Read all lines from `.processing` file
3. Include as `whatsapp_messages` field in the payload (flat JSON array — no grouping, same as `notifications` field)
4. Delete `.processing` file after successful send (or on next cycle if send failed)
5. If `mv` fails (file doesn't exist), there are no new messages — omit field

`claw-whatsapp` creates a new `whatsapp-buffer.jsonl` on its next write. This eliminates any window where messages could be lost between read and truncate.

Payload example:
```json
{
  "ts": "2026-03-30T14:34:00Z",
  "app": "Cursor",
  "whatsapp_messages": [
    { "chat_id": "34612345678@s.whatsapp.net", "chat_label": "Nil Porras", "sender": "Nil", "text": "Let's push the demo to Friday", "ts": "2026-03-30T14:32:00Z", "type": "text" },
    { "chat_id": "34612345678@s.whatsapp.net", "chat_label": "Nil Porras", "sender": "self", "text": "Works for me", "ts": "2026-03-30T14:33:00Z", "type": "text" },
    { "chat_id": "120363012345678901@g.us", "chat_label": "Prescrivia Team", "sender": "Magnus", "text": "PR merged", "ts": "2026-03-30T15:41:00Z", "type": "text" }
  ]
}
```

Messages are sent as a flat array (same format as the buffer). Grouping by chat is done server-side in the digest processor, not in the daemon.

### 5. Server Changes

**context-receiver.py:**
- `whatsapp_messages` is stored inside the existing `raw_payload` JSON column (which already stores the full sanitized payload as `json.dumps(sanitized)`). No schema migration needed — the receiver already preserves all payload fields in `raw_payload`.
- Same 48-hour purge as all raw data
- Suppress `whatsapp_messages` content from Flask debug/request logging (same treatment as clipboard)

**context-digest.py:**
- New `## WhatsApp Activity` section in digest output
- Mechanical extraction only (no LLM calls — consistent with existing digest architecture at $0/run):
  - Per whitelisted contact/group: message count, list of messages with sender and text
  - URLs extracted and listed separately
  - Timestamps of first and last message (communication window)
- Digest summaries persist permanently — raw messages purged at 48h

Example digest output:
```
## WhatsApp Activity

**Nil Porras** (+34612345678) — 12 messages, 09:14–16:33
- Nil: "Let's push the demo to Friday"
- Jonas: "Works for me"
- Nil: "Here's the updated deck" [link: docs.google.com/...]
- ... (10 more)

**Prescrivia Team** (group) — 8 messages, 15:30–15:55
- Magnus: "PR merged, deploying now"
- Magnus: [image] "Staging screenshot"
- Jonas: "Looks good, let's test notifications"
- ... (5 more)
```

JC interprets the raw messages during its own reasoning — the digest provides the data, JC provides the intelligence.

### 7. Helperctl Integration

`context-helperctl.sh` changes:
- `status_json()` gains a `whatsappLaunchdState` field (matching `daemonLaunchdState` and `watcherLaunchdState`)
- New action: `restart-whatsapp` — restarts the WhatsApp launchd service (matching existing `restart-watcher` action for fswatch)
- New action: `whatsapp-status` — reads `whatsapp-health.json` and returns structured status

### 8. Menu Bar Integration

ClawRelay.app additions under a **WhatsApp** submenu:

- **Status**: "Syncing" / "Degraded (notifications only)" / "Disconnected" / "Disabled"
  - Reads `~/.context-bridge/whatsapp-health.json`
- **Whitelist**: shows current contacts with labels and JIDs, each with remove option
- **Add Contact...**: runs `claw-whatsapp --setup` in a terminal window
- **Re-link WhatsApp**: runs `claw-whatsapp --auth` in a terminal window (for session re-pairing)
- **Last Message**: timestamp of most recent captured message

Status indicator on menu bar icon:
- Green dot: wacli syncing, healthy
- Yellow dot: wacli down, notification fallback active
- No dot: WhatsApp capture disabled

### 9. Fallback: Notification Capture

If `claw-whatsapp` is down (crashed, session expired, unlinked):

- ClawRelay falls back to existing notification capture for WhatsApp
- Notification previews provide incoming message awareness (degraded but nonzero)
- Window title capture continues as-is (active chat name)
- Menu bar shows "Degraded" status
- No code changes needed — this already works today

The main daemon checks `whatsapp-health.json` age. If stale (>5 min), it logs a warning and the menu bar reflects degraded status.

### 10. Launchd Configuration

`com.openclaw.context-bridge-whatsapp.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.openclaw.context-bridge-whatsapp</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/jonassorensen/.context-bridge/bin/claw-whatsapp</string>
        <string>--run</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>/tmp/claw-whatsapp.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/claw-whatsapp.log</string>
</dict>
</plist>
```

Notes:
- Binary installed to `~/.context-bridge/bin/` (consistent with other ClawRelay binaries, no sudo needed)
- `ThrottleInterval: 10` prevents rapid restart loops if the binary crashes on startup
- PATH matches the existing fswatch plist pattern

## Security Considerations

- **No send capability.** `claw-whatsapp` is read-only. The send functionality from wacli is stripped entirely, not just disabled. This reduces ban risk and eliminates the possibility of accidental message sending.
- **Whitelist enforced at protocol level.** Non-whitelisted messages are discarded in the event handler before touching disk. The buffer only contains whitelisted content.
- **Session credentials stored locally.** `~/.context-bridge/whatsapp-session/` with `600` permissions. Never transmitted to server.
- **48-hour raw purge.** Message content follows the same retention policy as all other raw data. Only digest summaries persist.
- **No media storage.** Media messages are logged as type + caption. No images, videos, or documents are downloaded or stored.
- **Tailscale-only transport.** WhatsApp message data travels from Mac to server over the existing Tailscale mesh network (HTTP over WireGuard tunnel), never over the public internet.
- **Ban risk acknowledged.** `whatsmeow` uses a reverse-engineered protocol. WhatsApp could detect and ban the linked device. Risk is low for passive read-only usage (widely used in bridges like mautrix-whatsapp), but nonzero. If banned, the linked device is simply removed — no impact on the primary phone app.

## One-Time Setup Flow

1. Build `claw-whatsapp`: `cd mac-daemon/claw-whatsapp && go build -tags sqlite_fts5 -o claw-whatsapp`
2. Install binary: `cp claw-whatsapp ~/.context-bridge/bin/`
3. Link WhatsApp: `claw-whatsapp --auth` → scan QR code from phone → Settings → Linked Devices
4. Add contacts to whitelist: `claw-whatsapp --setup` → pick from recent chats
5. Install launchd service: `cp com.openclaw.context-bridge-whatsapp.plist ~/Library/LaunchAgents/ && launchctl load ~/Library/LaunchAgents/com.openclaw.context-bridge-whatsapp.plist`
6. Verify: `claw-whatsapp --check` → "Syncing | Last message: 2 min ago | 3 whitelisted contacts"

`install.sh` will be updated to include steps 1-2 and 5 alongside the existing daemon/fswatch/helperctl installation. Steps 3-4 remain manual (require phone interaction).

## Limitations

- **Protocol risk.** WhatsApp could change the Web protocol and break whatsmeow. The library is actively maintained but there's inherent fragility in reverse-engineered protocols.
- **Linked device limits.** WhatsApp allows up to 4 linked devices. This uses one slot.
- **History backfill is best-effort.** WhatsApp may not return full history for older messages. The system captures from the moment of linking forward reliably.
- **No end-to-end encryption guarantee for stored data.** Messages are decrypted by whatsmeow for reading. The buffer file and server storage are not E2E encrypted (same security model as all other ClawRelay data — relies on filesystem permissions and network security).
- **Session can expire.** If the phone is offline for ~14 days, the linked device may be unlinked. Requires re-scanning QR code. Menu bar shows "Disconnected" status.
