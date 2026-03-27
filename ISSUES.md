# ISSUES.md - Known Issues, Gaps, and Future Work

## Issues That Led to This Project

These are the specific failures that motivated building the Context Bridge. Each one traces back to the same root cause: JC had no visibility into Jonas's operational state.

### 1. The Cegid PDF Loop
**What happened:** JC's pipeline automation cron regenerated the same Cegid proposal PDF every single day for 5 consecutive days. Nobody asked for it. Nil was already handling the Cegid relationship via WhatsApp.
**Root cause:** JC had no way to know the deal was being handled. The pipeline table said "proposal stage" so JC kept generating the proposal.
**How Context Bridge fixes it:** JC would see Jonas's WhatsApp window showing "a business partner" conversations. Combined with no Cegid-related file activity, JC would infer the deal is in Nil's hands and stay out of it.

### 2. Follow-Up Emails for Handled Conversations
**What happened:** JC drafted follow-up emails to contacts Jonas had already responded to personally.
**Root cause:** JC couldn't see Jonas's sent emails or WhatsApp conversations.
**How Context Bridge fixes it:** Terminal captures would show `himalaya` or email client activity. WhatsApp window titles would show who Jonas was messaging. JC would check before drafting.

### 3. The Bus Ticket Meeting Brief
**What happened:** JC prepared a full meeting brief for a calendar entry that was actually a bus booking from Bratislava to Brno.
**Root cause:** JC treated every calendar event identically because he had no judgment about what mattered - and no way to check what the event actually was.
**How Context Bridge fixes it:** The Chrome tab captures would show the booking URL. The digest would classify it correctly. More importantly, this failure represents undiscriminating judgment that the Context Bridge addresses by giving JC enough context to discriminate.

### 4. The Self-Maintenance Spiral
**What happened:** JC built 30+ monitoring scripts, 70 cron jobs, daily drift audits, self-assessment scorecards, freshness refreshes, SESSION-STATE rebuilds. 80% of compute went to self-maintenance.
**Root cause:** Without real operational visibility, JC compensated by building increasingly complex internal monitoring. The system was maintaining itself instead of doing useful work.
**How Context Bridge fixes it:** Real visibility into Jonas's work replaces synthetic monitoring. JC doesn't need to guess what's happening if he can see what's happening.

### 5. Zero Autonomous Execution
**What happened:** JC defaulted to observe → report → wait instead of observe → act → report. Despite having tools to run outreach, fix bugs, write content, and manage deals, JC almost never acted autonomously.
**Root cause:** Bad autonomous decisions (bus ticket brief, duplicate PDFs) eroded trust. JC responded by becoming more passive, not more accurate. The solution was more guardrails and approval gates, which made JC slower without making him smarter.
**How Context Bridge fixes it:** With accurate operational context, JC can make better autonomous decisions. He knows what to work on (things Jonas isn't touching) and what to avoid (things Jonas is actively doing). Better inputs → better judgment → earned trust → more autonomy.

---

## Current Known Gaps

### Critical (blocks full autonomy)

| # | Gap | Impact | Fix Complexity |
|---|-----|--------|---------------|
| 1 | Google Doc/Slides content not read during digest | JC sees URLs but doesn't know what's in the document | Medium - wire `gog` into digest processor |
| 2 | WhatsApp message content invisible | Only window titles visible, not message content | Hard - WhatsApp desktop doesn't expose content via API |
| 3 | Codex/Claude Code session content | Terminal hook captures commands but not agent conversation | Medium - capture Codex session logs if they exist on disk |
| 4 | No `/handoff` command implementation | Explicit task transfers require manual Telegram messages | Easy - Telegram bot command handler |

### Important (reduces accuracy)

| # | Gap | Impact | Fix Complexity |
|---|-----|--------|---------------|
| 5 | File save events not real-time | 2-min polling interval means short edits could be missed | Medium - `fswatch` on project directories |
| 6 | Notification DB requires Full Disk Access | macOS permission not mentioned in installer flow | Easy - add to install.sh permissions checklist |
| 7 | No daemon watchdog | If daemon crashes, JC has no data and doesn't know | Easy - launchd KeepAlive + server-side staleness alert |
| 8 | No pattern tracking over time | Can't detect "Jonas hasn't touched Project Alpha in 5 days" | Medium - historical analysis in digest processor |

### Nice-to-Have (iterate later)

| # | Gap | Impact | Fix Complexity |
|---|-----|--------|---------------|
| 9 | Clipboard capture | High-signal context from copy/paste, but privacy concern | Medium - opt-in, filter passwords |
| 10 | Telegram auto-status from JC | Jonas can't see what JC is doing without asking | Easy - message tool integration |
| 11 | Kill switch for sensitive work | No quick way to pause capture for banking, personal calls | Easy - menu bar app or keyboard shortcut |
| 12 | Self-signed TLS cert | Works but browsers/curl warn. Not production-grade | Easy - Let's Encrypt via certbot |

---

## Anticipated Risks

### Technical
- **macOS permission changes:** Apple tightens Accessibility/Automation permissions regularly. Future macOS updates could break AppleScript-based capture.
- **Electron app title format changes:** Cursor/VS Code could change their window title format, breaking file path inference.
- **Server disk space:** If queue flush fails repeatedly, local Mac DB could grow. Max 10K row cap mitigates this.

### Operational
- **Over-reliance on activity data:** JC might treat absence of activity data as "Jonas isn't working on this" when Jonas could be thinking, planning, or working on paper.
- **Context misinterpretation:** Having a Chrome tab open doesn't mean Jonas is actively working on that project. The idle detection helps but isn't perfect.
- **Digest latency:** 3x daily processing means up to 8 hours between JC's context updates. Real-time awareness requires checking the raw stream directly.

### Security
- **Token compromise:** If the Bearer token leaks, anyone could push fake activity data. Mitigation: rotate token periodically, monitor for anomalous push sources.
- **Server compromise:** Activity data on the server reveals Jonas's work patterns, contacts (from WhatsApp window titles), and browsing habits. Mitigation: 48h purge, disk encryption, minimal retention.
