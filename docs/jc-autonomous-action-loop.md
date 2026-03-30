# Agent Autonomous Action Loop — Implementation Notes

These are recommendations for wiring the agent to actively use the context bridge data before every autonomous action.

## The Core Loop

Every agent cron job should follow this pattern:

```
1. Check context     →  python3 context-query.py status
2. Decide what to do →  Apply decision rules
3. Execute           →  Do the work
4. Report            →  Update handoff status, post to Telegram
```

## Pre-Action Check

Before any autonomous action, the agent runs:

```bash
python3 /home/user/clawrelay/openclaw-computer-vision/server/context-query.py status
```

This returns:
```
current_app: Cursor
current_project: project-gamma
idle_state: active
in_call: false
focus_mode: null
focus_level: focused
time_on_current_project_today: 3.2h
daemon_stale: false
last_activity: 2026-03-28T14:32:00Z
```

## Decision Rules

| Condition | Action |
|-----------|--------|
| `current_project` matches what the agent wants to work on | **Don't.** Pick a different project. |
| `in_call: True` | **Don't send Telegram.** Wait until call ends. |
| `focus_mode` is non-null | **Don't interrupt.** The operator is in deep work. |
| `focus_level: focused` | Only interrupt for urgent items. |
| `focus_level: scattered` | Good time to take things off the operator's plate. |
| `idle_state: away` or `locked` | Safe to work autonomously. Don't expect input. |
| `daemon_stale: True` | **Be conservative.** No recent data — operating blind. |

## Project Selection

```bash
python3 /home/user/clawrelay/openclaw-computer-vision/server/context-query.py neglected
```

Returns:
```
project-beta: 6 days
project-alpha: 3 days
project-delta: 1 day
project-gamma: 0 days (active now)
```

Pick the project with highest inactivity that has pending work. Cross-reference with handoffs:

```bash
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:7890/context/handoffs | python3 -m json.tool
```

Pending handoffs with `priority: urgent` or `priority: high` take precedence over neglect-based selection.

## Abandoned Work Detection

```bash
python3 /home/user/clawrelay/openclaw-computer-vision/server/context-query.py since 8
```

If something shows as "Dropped" that was active in the previous period, consider asking the operator via Telegram:

> "You were working on [X] earlier but stopped — should I pick it up or are you continuing later?"

Only ask once per dropped item. Track asked items to avoid nagging.

## After Completing Work

1. If working on a handoff, update its status:
```bash
curl -X PATCH http://localhost:7890/context/handoffs/<id> \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"status": "done"}'
```

2. Post a summary to Telegram with what was done and any follow-up needed.

## End-of-Day Summary

At ~22:00 CET, the agent generates a daily wrap-up posted to Telegram:

```
Daily Summary — 2026-03-28

The operator worked on:
- project-gamma: 4.2h (branch: feature/notifications)
- project-alpha: 1.5h

The agent worked on:
- project-beta: reviewed PR #42, merged
- project-delta: fixed deploy script (handoff from operator)

Still open:
- project-alpha: auth migration started but not finished
- project-beta: tax residency research (handoff pending)

Neglected:
- aeoa: 12 days since last activity
```

This requires the agent to track its own work log alongside the digest data.

## Escalating Neglect Signals

The `neglected` command shows days since last activity, but the agent should escalate its response based on duration:

| Days inactive | Agent behavior |
|---------------|-------------|
| 1-2 days | Note it, no action needed |
| 3-5 days | Mention in end-of-day summary |
| 6-10 days | Proactively check if there's pending work to pick up |
| 10+ days | Flag to the operator via Telegram: "X hasn't been touched in N days — is this intentional?" |

## Implementation Approach

These behaviors should be wired into the agent's existing cron infrastructure:

1. **Before every cron action:** Add a `status` check as preamble
2. **Project selection cron (e.g., hourly):** Run `neglected` + check handoffs, pick work
3. **End-of-day cron (22:00 CET):** Generate and post the daily summary
4. **Escalation check (daily):** Scan neglect data and trigger Telegram messages for 10+ day items

The context bridge provides the data. The agent's own logic decides what to do with it.
