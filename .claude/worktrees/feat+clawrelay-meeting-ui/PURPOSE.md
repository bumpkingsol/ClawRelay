# PURPOSE.md - Why This Exists

## The Problem

Jean-Claude (JC) is an autonomous AI agent operating as COO for Jonas's portfolio of companies. JC has deep business context - legal disputes, deal pipelines, product status, entity structures - but **zero visibility into what Jonas is actually doing at any given moment.**

This blind spot caused a cascade of failures:

### Specific Failures This Solves

1. **Duplicated work.** JC regenerated the same Cegid proposal PDF 5 days in a row because he didn't know Nil was already handling it via WhatsApp conversations JC couldn't see.

2. **Follow-up emails for handled conversations.** JC would draft follow-up emails for contacts Jonas had already responded to, because JC couldn't see Jonas's sent emails or WhatsApp messages.

3. **Meeting prep for irrelevant events.** JC prepared a full meeting brief for what turned out to be a bus ticket from Bratislava to Brno. He treated every calendar event equally because he had no judgment about what mattered - and no context about what it actually was.

4. **Inability to work on "everything else."** When Jonas is coding Prescrivia, JC should be working on Leverwork outreach. When Jonas is preparing a Sonopeace deck, JC should be fixing Prescrivia P0 bugs. But JC had no way to know what Jonas was working on, so he either duplicated Jonas's work or did nothing useful.

5. **Picking up half-finished work.** Jonas would start a task, get pulled to something else, and the first task would sit unfinished. JC had no way to detect this pattern and pick up the dropped thread.

6. **Self-maintenance spiral.** Without real operational visibility, JC built increasingly complex monitoring systems to try to compensate. 30+ scripts, 70 cron jobs, daily drift audits, self-assessment scorecards. The system was maintaining itself instead of doing useful work. 80% of compute went to self-maintenance, 20% to actual value.

### The Root Cause

JC has the **strategic context** of a COO but the **operational visibility** of someone who only reads the newspaper. He knows the goals, the priorities, the people. He doesn't know what happened in the last 4 hours.

A human COO sits in the same office. They see their CEO working on a deck. They overhear phone calls. They notice when something gets abandoned on a desk. JC has none of this ambient awareness.

## The Solution

A lightweight daemon on Jonas's MacBook that captures his work activity and pushes it to JC's server. JC processes this raw stream into structured intelligence that informs autonomous decisions.

**The daemon captures what Jonas is doing. JC decides what to do about it.**

### What This Enables

- **Complementary work.** Jonas works on Prescrivia → JC works on Leverwork. No duplication, no gaps.
- **Picking up dropped threads.** Jonas starts a task Monday, doesn't touch it by Wednesday → JC either finishes it or asks if priorities changed.
- **Context-aware autonomy.** JC doesn't prep meeting briefs for bus tickets because he can see the window title and URL of what Jonas is actually doing.
- **Reduced noise.** No more daily briefings about things that haven't changed. JC knows what changed because he watched it happen.
- **Mutual visibility.** Jonas sees what JC is working on via Telegram status updates. JC sees what Jonas is working on via the activity stream. Two operators, one shared picture.

## What This Is NOT

- Not surveillance. Jonas owns the data, the server, and the kill switch.
- Not screen recording. It captures metadata (app names, window titles, URLs, file paths) not screen content.
- Not a productivity tracker. It doesn't measure or judge how Jonas spends time. It gives JC operational context.
- Not a replacement for communication. Jonas still tells JC about strategic decisions, priority changes, and context that can't be inferred from screen activity. This fills the gap for everything else.

## Success Criteria

1. JC never duplicates work Jonas is actively doing.
2. JC picks up half-finished work without being asked.
3. JC works on neglected workstreams while Jonas focuses elsewhere.
4. The daily self-maintenance spiral is replaced by real operational intelligence.
5. Zero security incidents with captured data.
