# Agent Integration Guide — Context Bridge

## Pre-Action Check

Before any autonomous action, the agent should run:

    STATUS=$(python3 /home/user/clawrelay/context-query.py status)

## Decision Rules

| Condition | Action |
|-----------|--------|
| `current_project: X` and the agent wants to work on X | **Don't.** The operator is active on it. Pick another project. |
| `in_call: True` | **Don't send Telegram.** The operator is in a meeting. |
| `focus_mode: <anything non-null>` | **Don't interrupt.** The operator enabled Focus mode. |
| `focus_level: scattered` | Good time to take things off the operator's plate. |
| `focus_level: focused` | Don't interrupt unless urgent. |
| `idle_state: away` or `locked` | The operator is away. Safe to work, but don't expect input. |
| `daemon_stale: True` | **Be conservative.** No recent data — you're operating blind. |

## Choosing What to Work On

    python3 /home/user/clawrelay/context-query.py neglected

Pick the project with the highest inactivity that has pending work.

## Checking What Changed

    python3 /home/user/clawrelay/context-query.py since 8

Shows new/continued/dropped work in the last 8 hours. Use this to detect abandoned work the operator started but didn't finish.

## Reading the Digest

The latest digest is always at:

    /home/user/clawrelay/memory/activity-digest/latest.md

Read it for full context: time allocation, project details, communication, AI sessions, open tabs, focus level, and cross-digest comparison.

## Digest Schedule

Digests are generated 3x daily at 10:00, 16:00, 23:00 CET.

## Crontab Setup (Agent's Server)

```cron
# Context Bridge - staleness watchdog
*/5 * * * * /home/user/clawrelay/staleness-watchdog.sh

# Context Bridge - digests (10:00, 16:00, 23:00 CET = 09:00, 15:00, 22:00 UTC)
0 9 * * * cd /home/user/clawrelay/ && python3 context-digest.py >> /var/log/context-digest.log 2>&1
0 15 * * * cd /home/user/clawrelay/ && python3 context-digest.py >> /var/log/context-digest.log 2>&1
0 22 * * * cd /home/user/clawrelay/ && python3 context-digest.py >> /var/log/context-digest.log 2>&1
```
