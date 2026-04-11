# Production Gap Audit
**Date**: 2026-04-12
**Codebase**: ClawRelay - real-time Mac activity bridge, helper app, and meeting capture pipeline for an autonomous agent
**Scope**: Full audit of active runtime paths in `server/`, `mac-daemon/`, `mac-helper/OpenClawHelper/`, and `mac-helper/claw-meeting/Sources/`. Prioritized current user-facing flows, recent/high-churn files, and meeting/handoff/control-plane paths. Excluded `.claude/worktrees/`, test files, generated caches, assets, and third-party dependencies.
**Stack**: Bash + AppleScript, Python 3 + Flask + SQLite/SQLCipher, SwiftUI/macOS app, Swift package (`ClawMeeting`), Go (`claw-whatsapp`)
**Mode**: Full

## Executive Summary
ClawRelay is close on the server/auth/privacy fundamentals, but the helper and meeting subsystems still contain several user-facing broken promises. The highest-risk gaps are in meeting capture: a crashed worker can leave the app showing a false "recording" state, accepting a meeting can fail with no explanation, and declining one Chrome meeting can suppress all future Meet auto-detection until Chrome quits.

The second class of issues is operator trust: the helper app can claim permissions are healthy when the daemon still cannot capture Chrome URLs, and privacy controls in the helper silently swallow failures. These are the kinds of failures that pass tests but create immediate confusion in production.

## Critical Findings
No verified Critical findings.

## High Severity

### Meeting Worker Crash Leaves a False "Recording" State
- **Location**: `mac-helper/OpenClawHelper/Services/MeetingWorkerManager.swift:27`, `mac-helper/OpenClawHelper/Services/MeetingWorkerManager.swift:86`
- **What happens**: During a meeting, if the `claw-meeting` worker exits non-zero, the monitor path tries to restart it while `isRunning` is still `true`. `startWorker()` immediately returns because of its `guard !isRunning`, so the restart never happens. The helper keeps its in-memory `isRunning` state, the session manager stays in `.recording`, and the operator keeps seeing a live recording UI even though capture has stopped.
- **Why it matters**: This is silent data loss in a core flow. The operator thinks the meeting is being captured, but no more transcript/audio/frame work is happening.
- **Confidence**: High - traced full execution path from worker start, to monitor exit, to failed restart condition.
- **How to verify**: Start a meeting, then kill the `claw-meeting` process or force it to exit non-zero. The helper should keep showing a recording session and elapsed time while no new meeting artifacts are produced.
- **Recommended fix**: Clear `isRunning`/`process`/`workerPid` before attempting restart, or add a dedicated restart path that bypasses the guard. Surface restart attempts and terminal failure to the UI.
- **Evidence**:
  - `startWorker()` refuses to run if `isRunning` is already `true`.
  - `startMonitoring()` calls `startWorker()` on non-zero exit without clearing that state first.

### Declining One Google Meet Can Disable Auto-Detection for the Rest of the Day
- **Location**: `mac-helper/OpenClawHelper/Services/MeetingDetectorService.swift:164`, `mac-helper/OpenClawHelper/Services/MeetingDetectorService.swift:178`, `mac-helper/OpenClawHelper/Services/MeetingDetectorService.swift:190`
- **What happens**: If the operator declines one detected meeting, `suppressedUntilAppCloses` is set to `true`. For Google Meet, the suppression is only cleared when `com.google.Chrome` terminates. Because the operator uses Chrome continuously, later Meet sessions can stop triggering detection until Chrome quits.
- **Why it matters**: A single false positive or deliberate decline can silently disable the advertised automatic meeting capture flow for all subsequent Meet sessions.
- **Confidence**: High - traced the decline notification through suppression and reset conditions.
- **How to verify**: Decline a Google Meet prompt, keep Chrome running, join another Meet later, and observe that no new consent prompt appears.
- **Recommended fix**: Suppress only the current meeting instance for a bounded interval, or clear suppression when the active Meet signal disappears instead of waiting for all Chrome termination.
- **Evidence**:
  - Detection short-circuits while `suppressedUntilAppCloses` is `true`.
  - The reset condition listens for Chrome termination, not "this meeting ended."

### Accepting a Meeting Can Fail Back to Idle With No Explanation
- **Location**: `mac-helper/OpenClawHelper/Services/MeetingSessionManager.swift:77`
- **What happens**: After the operator accepts recording, `beginPreparing()` tries to launch `claw-meeting`. Any launch failure drops into `catch { transitionToIdle() }`. The UI does not keep an error state, show a notification, or explain why the accepted meeting never started recording.
- **Why it matters**: The operator performed the intended recovery action, but the system quietly reverts to idle and captures nothing. This is especially likely on fresh installs where the meeting binary failed to build or lost execute permissions.
- **Confidence**: High - traced the post-consent path and verified the failure branch has no surfaced state.
- **How to verify**: Remove execute permission from `~/.context-bridge/bin/claw-meeting` or rename the binary, accept a detected meeting, and observe the helper return to idle with no visible explanation.
- **Recommended fix**: Store a visible meeting startup error state, route it to the overlay/control center, and offer an immediate retry/repair action.
- **Evidence**:
  - `beginPreparing()` is the only path after consent.
  - The failure branch only calls `transitionToIdle()`.

## Medium Severity

### Permissions Tab Can Report Automation as Healthy Even When Chrome URL Capture Is Broken
- **Location**: `mac-helper/OpenClawHelper/Services/PermissionService.swift:43`, `mac-daemon/context-daemon.sh:447`, `mac-daemon/install.sh:220`
- **What happens**: The daemon's Chrome capture uses Apple Events from the daemon context to `Google Chrome`. The installer explicitly tells the operator to allow `Terminal -> Google Chrome`. The helper app's Automation check does not test that path; it only runs `tell application "System Events" to return name of first process`, then reports "System Events automation available".
- **Why it matters**: The repair UI can say Automation is granted while the daemon still cannot read Chrome URLs or tabs. The operator gets a false green light in the main diagnostics surface for one of the system's highest-signal capture features.
- **Confidence**: Medium-High - verified the probe does not match the daemon's real AppleScript dependency.
- **How to verify**: Deny the daemon's Chrome automation permission while allowing the helper app/System Events probe to succeed, then compare empty Chrome URL capture with a "granted" Automation row in the helper.
- **Recommended fix**: Probe the exact daemon action through `context-helperctl.sh` or a daemon-owned status endpoint, not a helper-local `System Events` script.
- **Evidence**:
  - Daemon capture calls `tell application "Google Chrome"`.
  - Installer documents `Terminal -> Google Chrome`.
  - Helper check never talks to Chrome.

### Privacy Controls Swallow Failures Instead of Warning the Operator
- **Location**: `mac-helper/OpenClawHelper/ViewModels/ControlCenterViewModel.swift:92`, `mac-helper/OpenClawHelper/ViewModels/MenuBarViewModel.swift:87`, `mac-helper/OpenClawHelper/Views/QuickActionsGrid.swift:38`
- **What happens**: Pause, resume, sensitive mode, and local purge all use `try? runner.runAction(...)`. If the helper CLI is missing, tokens are unavailable, or the action fails, the UI drops the error and only refreshes state. In the popover path there is no error banner at all.
- **Why it matters**: These are privacy and trust controls. A failed pause/purge is materially worse than a normal UI bug because the operator may believe capture has stopped or local data has been deleted when it has not.
- **Confidence**: High - verified the error values are discarded in both control-center and menu-bar control paths.
- **How to verify**: Break `context-helperctl.sh` or remove the helper token, then click Pause or toggle Sensitive Mode from the UI. The action will fail without any explicit warning.
- **Recommended fix**: Replace `try?` with surfaced `BridgeCommandError` handling and only show control success after the refreshed state confirms the change.
- **Evidence**:
  - Every privacy control action drops thrown errors.
  - The quick-action UI binds directly to those no-error action methods.

### Quick Handoffs in the Menu Bar Fail Invisibly
- **Location**: `mac-helper/OpenClawHelper/ViewModels/MenuBarViewModel.swift:122`, `mac-helper/OpenClawHelper/Views/MenuBarPopoverView.swift:128`
- **What happens**: The menu bar quick-handoff path records `handoffError` when submission fails, but the popover never renders that error. The only visible state change in that area is a transient "Sent" success label on success.
- **Why it matters**: This is the fastest handoff path the operator is likely to use. When the helper/server is unavailable, the operator gets no actionable feedback that the handoff was not accepted.
- **Confidence**: High - verified the error is stored in the view model and never consumed by the view.
- **How to verify**: Disconnect the helper from the server or invalidate the helper token, then send a quick handoff from the popover. No error text is shown.
- **Recommended fix**: Render `handoffError` inline in the popover, or route it into a toast/notification so the operator knows the handoff did not go through.
- **Evidence**:
  - `MenuBarViewModel` sets `handoffError` on failure.
  - `MenuBarPopoverView` renders success state only.

## Low Severity
No verified Low-severity findings worth reporting separately.

## Claimed vs. Actual Capability Matrix
| Capability (from docs/README) | Status | Notes |
|-------------------------------|--------|-------|
| Real-time activity capture from Mac daemon | Working | Core receiver/auth/storage flow is coherent and well-contained. |
| Chrome URL and tab capture | Partial | Capture path exists, but the helper's permission diagnostics can misreport readiness. |
| Pause / Sensitive / purge controls from helper app | Partial | Controls exist, but failures are not surfaced reliably. |
| Automatic meeting detection and recording | Partial | Works on the happy path, but decline suppression and startup/crash handling break realistic usage. |
| Meeting history and summaries in helper app | Partial | Meeting sessions are listed, but failed processing/startup paths can degrade silently. |
| Explicit handoffs to the agent | Partial | Full handoff tab handles errors; the popover quick path does not. |
| Scoped auth and protected API surface | Working | `require_clients()` is consistently applied to the public endpoints I audited. |
| Encrypted-at-rest server DB | Working | Server startup validates SQLCipher availability and fails closed unless explicitly overridden for non-production use. |

## Positive Observations
- The server-side auth model is disciplined: scoped tokens are resolved centrally and endpoint access is explicit via `require_clients(...)`.
- The SQLite encryption path is fail-closed in production mode, which is aligned with the repo's security claims.
- Meeting storage uses `validate_meeting_id()` and `safe_meeting_dir()` to prevent path traversal and unsafe frame writes.
- Sensitive meeting sessions correctly zero out transcript/visual payloads before storage and block external processing.
- The helper/control-plane separation is clean: the Swift app is a controller over shell/runtime state, not an ad hoc second capture implementation.

## Methodology
- Reviewed product intent and claimed capabilities from `README.md`, `CLAUDE.md`, `PURPOSE.md`, `DESIGN.md`, `ROADMAP.md`, `ISSUES.md`, and `ARCHITECTURE.md`.
- Used git-history signals to prioritize recently unstable and high-churn areas; `server/context-receiver.py`, `mac-daemon/context-daemon.sh`, and helper meeting/control code were the main hotspots.
- Ran broad sweeps for silent-failure, UX black-hole, integration, security, and observability patterns across the active runtime paths.
- Deep-verified each reported finding by tracing the execution path in code rather than relying on pattern matches alone.
- Did not perform live macOS runtime reproduction in this environment, so findings are based on code-path verification rather than local UI execution.
