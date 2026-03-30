# ISSUES.md - Known Issues, Gaps, and Future Work

## Issues That Led to This Project

These are the specific failures that motivated building the Context Bridge. Each one traces back to the same root cause: the agent had no visibility into the operator's operational state.

### 1. The Proposal PDF Loop
**What happened:** The agent's pipeline automation cron regenerated the same proposal PDF every single day for 5 consecutive days. Nobody asked for it. A business partner was already handling the relationship via WhatsApp.
**Root cause:** The agent had no way to know the deal was being handled. The pipeline table said "proposal stage" so the agent kept generating the proposal.
**How Context Bridge fixes it:** The agent would see the operator's WhatsApp window showing active conversations. Combined with no related file activity, the agent would infer the deal is being handled elsewhere and stay out of it.

### 2. Follow-Up Emails for Handled Conversations
**What happened:** The agent drafted follow-up emails to contacts the operator had already responded to personally.
**Root cause:** The agent couldn't see the operator's sent emails or WhatsApp conversations.
**How Context Bridge fixes it:** Terminal captures would show email client activity. WhatsApp window titles would show who the operator was messaging. The agent would check before drafting.

### 3. The Bus Ticket Meeting Brief
**What happened:** The agent prepared a full meeting brief for a calendar entry that was actually a bus booking.
**Root cause:** The agent treated every calendar event identically because it had no judgment about what mattered - and no way to check what the event actually was.
**How Context Bridge fixes it:** The Chrome tab captures would show the booking URL. The digest would classify it correctly. More importantly, this failure represents undiscriminating judgment that the Context Bridge addresses by giving the agent enough context to discriminate.

### 4. The Self-Maintenance Spiral
**What happened:** The agent built 30+ monitoring scripts, 70 cron jobs, daily drift audits, self-assessment scorecards, freshness refreshes, SESSION-STATE rebuilds. 80% of compute went to self-maintenance.
**Root cause:** Without real operational visibility, the agent compensated by building increasingly complex internal monitoring. The system was maintaining itself instead of doing useful work.
**How Context Bridge fixes it:** Real visibility into the operator's work replaces synthetic monitoring. The agent doesn't need to guess what's happening if it can see what's happening.

### 5. Zero Autonomous Execution
**What happened:** The agent defaulted to observe, report, wait instead of observe, act, report. Despite having tools to run outreach, fix bugs, write content, and manage deals, the agent almost never acted autonomously.
**Root cause:** Bad autonomous decisions (bus ticket brief, duplicate PDFs) eroded trust. The agent responded by becoming more passive, not more accurate. The solution was more guardrails and approval gates, which made the agent slower without making it smarter.
**How Context Bridge fixes it:** With accurate operational context, the agent can make better autonomous decisions. It knows what to work on (things the operator isn't touching) and what to avoid (things the operator is actively doing). Better inputs lead to better judgment, which leads to earned trust and more autonomy.

---

## Current Known Gaps

### Critical (blocks full autonomy)

| # | Gap | Impact | Fix Complexity |
|---|-----|--------|---------------|
| 1 | Google Doc/Slides content not read during digest | The agent sees URLs but doesn't know what's in the document | Medium - wire `gog` into digest processor |
| 2 | WhatsApp message content invisible | Only window titles visible, not message content | Hard - WhatsApp desktop doesn't expose content via API |
| 3 | Codex/Claude Code session content | Terminal hook captures commands but not agent conversation | Medium - capture Codex session logs if they exist on disk |
| 4 | No `/handoff` command implementation | Explicit task transfers require manual Telegram messages | Easy - Telegram bot command handler |

### Important (reduces accuracy)

| # | Gap | Impact | Fix Complexity |
|---|-----|--------|---------------|
| 5 | File save events not real-time | 2-min polling interval means short edits could be missed | Medium - `fswatch` on project directories |
| 6 | Notification DB requires Full Disk Access | macOS permission not mentioned in installer flow | Easy - add to install.sh permissions checklist |
| 7 | No daemon watchdog | If daemon crashes, the agent has no data and doesn't know | Easy - launchd KeepAlive + server-side staleness alert |
| 8 | No pattern tracking over time | Can't detect "the operator hasn't touched Project Alpha in 5 days" | Medium - historical analysis in digest processor |

### Nice-to-Have (iterate later)

| # | Gap | Impact | Fix Complexity |
|---|-----|--------|---------------|
| 9 | Clipboard capture | High-signal context from copy/paste, but privacy concern | Medium - opt-in, filter passwords |
| 10 | Telegram auto-status from the agent | The operator can't see what the agent is doing without asking | Easy - message tool integration |
| 11 | Kill switch for sensitive work | No quick way to pause capture for banking, personal calls | Easy - menu bar app or keyboard shortcut |
| 12 | Self-signed TLS cert | Works but browsers/curl warn. Not production-grade | Easy - Let's Encrypt via certbot |

---

## Anticipated Risks

### Technical
- **macOS permission changes:** Apple tightens Accessibility/Automation permissions regularly. Future macOS updates could break AppleScript-based capture.
- **Electron app title format changes:** Cursor/VS Code could change their window title format, breaking file path inference.
- **Server disk space:** If queue flush fails repeatedly, local Mac DB could grow. Max 10K row cap mitigates this.

### Operational
- **Over-reliance on activity data:** The agent might treat absence of activity data as "the operator isn't working on this" when the operator could be thinking, planning, or working on paper.
- **Context misinterpretation:** Having a Chrome tab open doesn't mean the operator is actively working on that project. The idle detection helps but isn't perfect.
- **Digest latency:** 3x daily processing means up to 8 hours between the agent's context updates. Real-time awareness requires checking the raw stream directly.

### Security
- **Token compromise:** If the Bearer token leaks, anyone could push fake activity data. Mitigation: rotate token periodically, monitor for anomalous push sources.
- **Server compromise:** Activity data on the server reveals the operator's work patterns, contacts (from WhatsApp window titles), and browsing habits. Mitigation: 48h purge, disk encryption, minimal retention.
