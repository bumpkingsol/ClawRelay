# PURPOSE.md - Why This Exists

## The Problem

The agent is an autonomous AI operating as an assistant for the operator's portfolio of companies. The agent has deep business context - legal disputes, deal pipelines, product status, entity structures - but **zero visibility into what the operator is actually doing at any given moment.**

This blind spot caused a cascade of failures:

### Specific Failures This Solves

1. **Duplicated work.** The agent regenerated the same proposal PDF 5 days in a row because it didn't know a business partner was already handling it via WhatsApp conversations the agent couldn't see.

2. **Follow-up emails for handled conversations.** The agent would draft follow-up emails for contacts the operator had already responded to, because the agent couldn't see the operator's sent emails or WhatsApp messages.

3. **Meeting prep for irrelevant events.** The agent prepared a full meeting brief for what turned out to be a bus ticket. It treated every calendar event equally because it had no judgment about what mattered - and no context about what it actually was.

4. **Inability to work on "everything else."** When the operator is coding Project Gamma, the agent should be working on Project Alpha outreach. When the operator is preparing a Project Delta deck, the agent should be fixing Project Gamma P0 bugs. But the agent had no way to know what the operator was working on, so it either duplicated the operator's work or did nothing useful.

5. **Picking up half-finished work.** The operator would start a task, get pulled to something else, and the first task would sit unfinished. The agent had no way to detect this pattern and pick up the dropped thread.

6. **Self-maintenance spiral.** Without real operational visibility, the agent built increasingly complex monitoring systems to try to compensate. 30+ scripts, 70 cron jobs, daily drift audits, self-assessment scorecards. The system was maintaining itself instead of doing useful work. 80% of compute went to self-maintenance, 20% to actual value.

### The Root Cause

The agent has the **strategic context** of an assistant but the **operational visibility** of someone who only reads the newspaper. It knows the goals, the priorities, the people. It doesn't know what happened in the last 4 hours.

A human assistant sits in the same office. They see their colleague working on a deck. They overhear phone calls. They notice when something gets abandoned on a desk. The agent has none of this ambient awareness.

## The Solution

A lightweight daemon on the operator's MacBook that captures their work activity and pushes it to the agent's server. The agent processes this raw stream into structured intelligence that informs autonomous decisions.

**The daemon captures what the operator is doing. The agent decides what to do about it.**

### What This Enables

- **Complementary work.** The operator works on Project Gamma, the agent works on Project Alpha. No duplication, no gaps.
- **Picking up dropped threads.** The operator starts a task Monday, doesn't touch it by Wednesday, the agent either finishes it or asks if priorities changed.
- **Context-aware autonomy.** The agent doesn't prep meeting briefs for bus tickets because it can see the window title and URL of what the operator is actually doing.
- **Reduced noise.** No more daily briefings about things that haven't changed. The agent knows what changed because it watched it happen.
- **Mutual visibility.** The operator sees what the agent is working on via Telegram status updates. The agent sees what the operator is working on via the activity stream. Two operators, one shared picture.

## What This Is NOT

- Not surveillance. The operator owns the data, the server, and the kill switch.
- Not screen recording. It captures metadata (app names, window titles, URLs, file paths) not screen content.
- Not a productivity tracker. It doesn't measure or judge how the operator spends time. It gives the agent operational context.
- Not a replacement for communication. The operator still tells the agent about strategic decisions, priority changes, and context that can't be inferred from screen activity. This fills the gap for everything else.

## Success Criteria

1. The agent never duplicates work the operator is actively doing.
2. The agent picks up half-finished work without being asked.
3. The agent works on neglected workstreams while the operator focuses elsewhere.
4. The daily self-maintenance spiral is replaced by real operational intelligence.
5. Zero security incidents with captured data.
