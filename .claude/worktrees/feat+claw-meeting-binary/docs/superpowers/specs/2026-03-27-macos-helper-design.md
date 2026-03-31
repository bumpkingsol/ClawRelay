# OpenClaw macOS Helper Design

Date: 2026-03-27
Status: Approved for implementation planning
Owner: Jonas / OpenClaw

## 1. Purpose

OpenClaw needs a production-grade local control surface on Jonas's Mac for trust, privacy, repair, and operator confidence.

The helper is not a dashboard for curiosity. It is a native macOS utility that makes the Context Bridge safe and usable day to day by giving Jonas fast control over capture behavior, clear health visibility, and reliable repair flows when something breaks.

This design is explicitly local-first:
- it must remain useful when the server is offline
- it must prioritize privacy and operator trust over breadth
- it must sit on top of the current capture system instead of rewriting it in v1

## 2. Goals

### Primary goals

- Give Jonas one-click control over capture state from the macOS menu bar.
- Make privacy actions explicit, trustworthy, and fast.
- Detect missing permissions and broken local components and guide repair.
- Surface the health of the local capture pipeline without turning the helper into a noisy dashboard.
- Support simple handoff sending from the local device.

### Non-goals for v1

- Remote server administration
- Historical analytics or productivity views
- Rich browsing of raw captured activity in the main surface
- Rewriting the daemon or watcher into native code
- Multi-user or multi-machine support

## 3. Product principles

### Trust over feature count

If the helper says capture is paused, it must not keep silently accumulating new sensitive context in background logs. Privacy controls must reflect real behavior, not optimistic UI.

### Local-first

The helper should remain fully useful for local controls, diagnostics, and repair even if the receiver is unreachable.

### Minimal by default

The main surface should show state, health, and actions. Raw captured details belong behind explicit diagnostics affordances.

### Native utility, not web dashboard

The helper should feel like a serious system utility:
- fast
- quiet
- legible
- operational
- visually polished

### Production visual direction

The visual direction is `Dark Utility Glass`:
- darker, glassy, more control-surface-like
- clearly premium, but less soft or playful than the initial wireframe
- consistent with a security-sensitive operator tool

## 4. Recommended platform approach

### Chosen direction

Build a native SwiftUI menu bar app over the existing capture system.

### Why

- Best fit for macOS permissions and Settings repair flows
- Best fit for menu bar interaction and login-item behavior
- Lowest risk compared with a full native rewrite of the daemon
- Preserves the existing bash-based capture pipeline while improving trust and usability

### Rejected alternatives

#### Native app plus daemon rewrite

Too much architectural churn for v1. It risks destabilizing working capture while the product is still being hardened.

#### Web-wrapper helper

Poor fit for privacy permissions, menu bar behavior, and overall Mac utility quality.

## 5. Product shape

The helper has two primary surfaces:

### A. Menu bar popover

The menu bar popover is the fast path for operator trust and control.

It includes:
- current state badge
- quick pause / resume actions
- Sensitive Mode toggle
- Send Handoff action
- compact health strip
- top urgent issue, if any
- entry point to the full Control Center

This surface must be fast, calm, and low-friction.

### B. Control Center window

The Control Center is the deeper utility window for repair, diagnostics, and configuration.

It includes four tabs:
- `Overview`
- `Permissions`
- `Privacy`
- `Diagnostics`

This window is where richer detail lives. It is not the default interaction surface.

## 6. State model

The helper should model the system through four top-level states:

### Active

Tracking is running normally. Local components are healthy enough for expected operation.

### Paused

Tracking is intentionally paused by the operator, with a clear timer or explicit indefinite pause until resume.

### Sensitive

Tracking is intentionally reduced because of privacy mode or a sensitive-app rule.

### Needs Attention

Something important requires repair or review:
- permission missing
- daemon stopped
- watcher failed
- local queue growing unexpectedly
- auth missing
- endpoint unreachable

These states should drive the menu bar icon, top copy, and available quick actions.

## 7. v1 feature scope

### Menu bar popover

- state badge: Active / Paused / Sensitive / Needs Attention
- quick actions:
  - Pause 15m
  - Pause 1h
  - Pause until tomorrow
  - Resume
  - Toggle Sensitive Mode
  - Send Handoff
- compact health strip:
  - last capture time
  - local queue depth
  - watcher health
  - top alert
- `Open Control Center`

### Control Center: Overview

- current state summary
- launchd status for main daemon and watcher
- last successful capture time
- queue summary
- recent health-event timeline
- current local config summary

### Control Center: Permissions

For each permission:
- Accessibility
- Automation
- Full Disk Access

Show:
- status
- why it matters
- impact of missing permission
- repair action
- re-check action after repair

### Control Center: Privacy

- pause configuration
- Sensitive Mode
- sensitive-app rule management
- quiet windows / privacy-focused temporary modes
- local purge actions
- privacy explanation copy

### Control Center: Diagnostics

- recent local errors
- last push attempt summary
- queue inspector
- config paths
- reinstall / repair actions
- restart actions for daemon and watcher

### Explicit v1 actions

- pause / resume tracking
- toggle Sensitive Mode
- manage sensitive-app rules
- open appropriate macOS Settings repair locations
- restart daemon
- restart fswatch watcher
- re-check permission and local health state
- send handoff
- purge local helper data on explicit request

## 8. Privacy and trust semantics

This is the most important behavioral contract in the app.

### Pause must mean capture pause, not just upload pause

When the operator pauses tracking, the system should stop generating new local context wherever feasible, not merely stop sending it to the server.

This applies to:
- daemon capture cycle
- file watcher logging
- git hook sending
- shell command logging where controllable through shared state checks

If any producer cannot yet respect pause, the helper must not silently claim full pause. It should instead show a degraded message such as:

`Paused, but shell command logging still active locally`

The UI must never over-promise privacy.

### Sensitive Mode

Sensitive Mode is different from Pause:
- the system remains operational
- capture becomes minimal and privacy-biased
- app/window-specific sensitive rules should reduce capture to the lowest safe signal

### Raw context visibility

Raw captured details should not appear in the main popover.

Diagnostics may show limited raw detail when the operator explicitly opens that area, but the default UX should stay summary-first.

## 9. Architecture

### 9.1 Major components

#### Menu Bar App

Native SwiftUI/AppKit shell responsible for:
- menu bar item
- popover
- Control Center window
- onboarding
- repair flows
- state presentation

#### Local Control Layer

A native service layer that reads and interprets:
- launchd status
- local logs
- local SQLite queue
- permission state
- Keychain token presence
- local config files in `~/.context-bridge/`

#### Bridge Adapter

A narrow boundary that performs controlled actions against the existing system:
- pause / resume
- toggle Sensitive Mode
- update privacy rules
- restart / reload local services
- send handoff
- run diagnostics

#### Existing Capture System

The current bash daemon, fswatch watcher, git hooks, local queue DB, and server receiver remain in place beneath the helper.

### 9.2 Key architectural rule

The helper does not absorb capture logic in v1.

It observes and controls the current system through a narrow contract. This keeps the helper focused, lowers migration risk, and preserves current reliability while still enabling a native operator experience.

## 10. Shared local contract

To safely control the existing bash system from a native app, the helper and scripts should share explicit local state files under `~/.context-bridge/`.

Recommended contract:

- `pause-until`
  - timestamp or sentinel for indefinite pause
- `sensitive-mode`
  - boolean / timestamped state file
- `privacy-rules.json`
  - sensitive-app rules and future privacy settings
- `handoff-outbox/`
  - optional local queue for handoff actions if server is unreachable
- `helper-state.json`
  - helper-owned cached derived state for UI startup speed

The app writes intentional control state.
The scripts read that state and adjust behavior.

This keeps the integration explicit, inspectable, and easy to debug.

## 11. Permission model

The app should implement `detect + guide + repair`, not promise impossible automatic permission control.

### Accessibility

Can be checked using native trust APIs and linked into Settings guidance.

### Automation

Automation is harder to read reliably in a clean, non-disruptive way. The helper may need to classify it as:
- granted
- missing
- needs verification

### Full Disk Access

Full Disk Access may also require a best-effort classification, based on known path access behavior and repair heuristics.

### UI behavior

Each permission should have:
- a state label
- explanation of impact
- `Open Settings`
- `Check Again`

The app should avoid fake certainty where macOS does not provide exact programmatic visibility.

## 12. Data and persistence

### App-owned state

Native local storage for:
- window/UI preferences
- last-opened tab
- non-sensitive convenience settings

### Shared operational state

Stored as explicit files in `~/.context-bridge/` so the helper and existing scripts can cooperate.

### Secrets

Keep secrets in Keychain where already supported.

The helper must not invent a second credential store for tokens.

## 13. Handoff behavior

The helper should support a fast handoff flow:
- open quick handoff sheet from the menu bar
- enter project / task / optional note
- send immediately if online
- queue locally if needed
- show delivery state clearly

The handoff flow should feel like a native operator shortcut, not a form-heavy mini app.

## 14. Error handling

### Missing auth token

State should become `Needs Attention`.
UI should explain that capture cannot authenticate and offer repair guidance.

### Daemon stopped

Show impact clearly and offer restart.

### Watcher stopped

Show reduced-capture warning, not total-failure language.

### Server unreachable

For v1 local-first scope, this should not block most of the app.
The helper should continue working locally and explain:
- whether queueing is active
- whether handoffs are queued
- whether recent pushes succeeded

### Permission missing

Show what capability is broken and link directly into repair.

### Unknown or inconsistent state

Prefer honest degraded states over fake confidence.

## 15. Security considerations

- No new long-lived secrets outside Keychain
- No remote control plane in v1
- Sensitive actions require clear intent
- Raw activity details hidden by default
- Local purge actions must be explicit
- The helper should never weaken the hardened auth boundary already established on the server and hooks

## 16. Verification strategy

This repo tests by running, not by building broad test suites. The helper should be verified primarily through manual operational checks on macOS.

### Required verification scenarios

- fresh install / first launch
- Accessibility missing
- Automation missing
- Full Disk Access missing
- daemon stopped
- watcher stopped
- queue growing while server unreachable
- pause 15m
- pause until tomorrow
- resume
- Sensitive Mode on / off
- handoff send success
- handoff queue on network failure
- local purge

### Verification evidence

Each action should be validated through observable local state:
- launchd status
- config file state
- queue depth changes
- visible banner / badge state
- repaired permission state after re-check

## 17. Rollout plan

### Phase 1: App shell + read-only health

- menu bar item
- popover
- Control Center window shell
- local state reading
- launchd health
- queue health

### Phase 2: Operator controls

- pause / resume
- Sensitive Mode
- restart actions
- handoff sending

### Phase 3: Permission repair + privacy management

- permission checks
- Settings deep links
- privacy rules UI
- local purge actions

### Phase 4: Production polish

- dark utility-glass visual refinement
- better copy
- onboarding and recovery flows
- degraded-state edge cases

## 18. Open implementation questions

- Best native strategy for classifying Automation and Full Disk Access without misleading certainty
- Exact shared-state file formats and versioning
- Whether handoff queueing should be helper-owned or script-owned
- Whether pause should stop producers directly or be enforced entirely through shared state checks

None of these block implementation planning. They are plan-level and build-level questions, not product-shape questions.

## 19. Recommendation

Proceed with a local-first native macOS menu bar helper that controls the current system through a narrow shared-state contract.

If the first version does only four things extremely well, they should be:
- trustworthy pause / resume
- clear permission repair
- accurate local health reporting
- fast handoff sending

That combination will do more for real production usability than a broader but shallower dashboard.
