# Production Gap Audit
**Date**: 2026-04-02
**Codebase**: ClawRelay - real-time activity bridge between the operator's Mac and an autonomous AI agent
**Scope**: Full tracked codebase audit, prioritizing core operator flows, server ingest/query paths, helper control paths, and the meeting pipeline. Excluded `.claude/worktrees`, generated build artifacts, release zips, and other non-source assets.
**Stack**: Bash, AppleScript, Python 3, Flask, SQLite/SQLCipher, SwiftUI/AppKit, Swift Package Manager, Go
**Mode**: Full

## Executive Summary
The core idea is sound, but the current build is not production-ready for the flows it explicitly advertises. The most serious gaps are not unit-test style defects; they are broken operator promises: helper-created handoffs never reach the server, Sensitive mode does not actually protect meeting transcripts, and the meeting pipeline can silently declare sessions complete while dropping the visual side of the record.

Outside those release blockers, the control plane still has several misleading "healthy" states: stale-monitoring can fail exactly when the daemon is down, meeting sessions arrive without enough metadata to power the People/meeting-intelligence surfaces, and some helper/API surfaces degrade to empty UI or 500s instead of actionable errors.

## Critical Findings

### Helper-App Handoffs Never Reach JC
- **Location**: [mac-daemon/context-helperctl.sh](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/mac-daemon/context-helperctl.sh#L298), [mac-daemon/context-daemon.sh](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/mac-daemon/context-daemon.sh#L72), [server/context-receiver.py](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/server/context-receiver.py#L580), [mac-helper/OpenClawHelper/ViewModels/MenuBarViewModel.swift](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/mac-helper/OpenClawHelper/ViewModels/MenuBarViewModel.swift#L126), [mac-helper/OpenClawHelper/ViewModels/HandoffsTabViewModel.swift](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/mac-helper/OpenClawHelper/ViewModels/HandoffsTabViewModel.swift#L20)
- **What happens**: The operator submits a handoff in the menu bar or Handoffs tab and gets an immediate local success confirmation, but the handoff is only written to `~/.context-bridge/handoff-outbox/`. The daemon later flushes that outbox using the daemon write token, while `/context/handoff` only accepts the `agent` scope. The server rejects the request, the handoff never becomes visible to JC, and the operator is left believing the transfer succeeded.
- **Why it matters**: Explicit handoff is one of the repo's core advertised coordination mechanisms. In its current state the feature is effectively non-functional for the actual helper-app path.
- **Confidence**: High - traced full path from SwiftUI submit action to shell outbox write, daemon delivery, and server auth gate.
- **How to verify**: Queue a handoff from the helper UI, inspect `~/.context-bridge/handoff-outbox/*.json`, then call `GET /context/handoffs` with a valid helper token. The handoff will not appear unless it is posted with the agent-scoped token instead of the daemon token.
- **Recommended fix**: Align the auth contract. Either allow `helper` and/or `daemon` to create handoffs, or move handoff posting out of the daemon flush path and have the helper call a route that accepts the helper token. Do not show "sent" UI until the server has acknowledged receipt.
- **Evidence**: `do_queue_handoff()` only writes JSON locally; `flush_handoff_outbox()` posts with `Authorization: Bearer $AUTH_TOKEN`; `/context/handoff` is decorated with `@require_clients("agent")`.

### Sensitive Mode Still Uploads Confidential Meeting Transcripts
- **Location**: [mac-helper/claw-meeting/Sources/ClawMeeting/Session/MeetingRecorder.swift](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/mac-helper/claw-meeting/Sources/ClawMeeting/Session/MeetingRecorder.swift#L172), [mac-helper/claw-meeting/Sources/ClawMeeting/Session/MeetingRecorder.swift](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/mac-helper/claw-meeting/Sources/ClawMeeting/Session/MeetingRecorder.swift#L184), [mac-helper/claw-meeting/Sources/ClawMeeting/Session/MeetingRecorder.swift](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/mac-helper/claw-meeting/Sources/ClawMeeting/Session/MeetingRecorder.swift#L299), [mac-helper/claw-meeting/Sources/ClawMeeting/Session/MeetingRecorder.swift](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/mac-helper/claw-meeting/Sources/ClawMeeting/Session/MeetingRecorder.swift#L321), [mac-daemon/meeting-sync.sh](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/mac-daemon/meeting-sync.sh#L124)
- **What happens**: During a confidential meeting, switching ClawRelay into Sensitive mode stops screenshots and suppresses live transcript writes, but audio capture continues. At finalization the worker still batch-transcribes the full `audio.wav`, writes `transcript.json`, and `meeting-sync.sh` uploads that transcript to the server.
- **Why it matters**: This is a broken privacy promise, not just a UX issue. A user taking Sensitive mode seriously during a confidential segment would still leak the conversation to the server/agent path after the meeting ends.
- **Confidence**: High - traced the Sensitive-mode state transition, transcript suppression branch, finalize path, and sync upload path.
- **How to verify**: Start a meeting, enable Sensitive mode mid-call, then stop the meeting. Inspect the session directory for `transcript.json` and confirm that `meeting-sync.sh` includes it in the session payload.
- **Recommended fix**: Define and enforce one privacy contract for meetings. If Sensitive mode means "no meeting content leaves the Mac," stop or redact batch transcription and avoid uploading buffered transcript/audio-derived content for any sensitive interval.
- **Evidence**: `checkPauseSensitive()` explicitly keeps audio capture running in Sensitive mode; `handleTranscriptSegment()` only suppresses live writes; `finalize()` still runs batch transcription over the full audio file; `meeting-sync.sh` prefers the final transcript file when present.

## High Severity

### Meeting Sessions Can Be Marked Synced While Visual Intelligence Is Lost Forever
- **Location**: [mac-daemon/meeting-sync.sh](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/mac-daemon/meeting-sync.sh#L152), [server/context-receiver.py](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/server/context-receiver.py#L1138), [server/context-receiver.py](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/server/context-receiver.py#L1162), [server/meeting_processor.py](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/server/meeting_processor.py#L615), [mac-daemon/meeting-sync.sh](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/mac-daemon/meeting-sync.sh#L175)
- **What happens**: The session JSON is uploaded first and immediately triggers `meeting_processor.py`. Frames are uploaded afterward. If frame upload fails, the script only prints a warning, still touches `.synced`, and the daemon will skip that meeting on future sync passes. The final meeting record looks complete but permanently lacks screenshot-driven expression/body-language analysis.
- **Why it matters**: This silently undermines the meeting intelligence feature in a realistic failure mode: transient network trouble during a large frame upload.
- **Confidence**: High - traced the processing order and the sync success marker logic.
- **How to verify**: Force `/context/meeting/frames` to fail during sync, then rerun the daemon. The session remains `.synced`, the processor has already run, and no retry path repopulates the missing visual data.
- **Recommended fix**: Treat session and frame upload as one transactional sync unit, or track independent sync stages. Do not mark a session fully synced until the frame upload stage has succeeded or been explicitly waived.
- **Evidence**: `meeting_processor.py` is launched in `/context/meeting/session` before `/context/meeting/frames` runs; frame upload failures are warnings only; `.synced` is written unconditionally afterward.

### Daemon Staleness Monitoring Fails on the Outage Path
- **Location**: [server/staleness-watchdog.sh](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/server/staleness-watchdog.sh#L19), [server/staleness-watchdog.sh](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/server/staleness-watchdog.sh#L41), [server/watchdog.py](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/server/watchdog.py#L22), [QUICKSTART.md](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/QUICKSTART.md#L307)
- **What happens**: The shell watchdog uses `row[0]` against dict-style DB rows, falls into the `"9999"` fallback, and on the actual stale branch expands an unset `LATEST` variable under `set -u`, aborting before it can write `/tmp/context-bridge-stale`. Separately, the older `watchdog.py` path still documented in Quickstart opens the production DB with plain `sqlite3`, which is incompatible with the encrypted SQLCipher path.
- **Why it matters**: The operator loses the very signal that should tell them the daemon stopped sending data. This is a reliability blind spot in the core pipeline.
- **Confidence**: High - verified the `LATEST` crash path directly and traced the DB-access mismatch in code/docs.
- **How to verify**: Run the stale branch of `staleness-watchdog.sh`; it exits with `LATEST: unbound variable`. Then point `watchdog.py` at an encrypted production DB and observe the failure to read it.
- **Recommended fix**: Make `staleness-watchdog.sh` use named dict access and remove the unset variable reference. Retire or update `watchdog.py` so docs and runtime both use the same SQLCipher-aware implementation.
- **Evidence**: The stale branch references `$LATEST` without ever assigning it. Local reproduction of the branch fails with `LATEST: unbound variable`.

### Meeting Sessions Arrive Without Enough Metadata to Power the Meetings and People Surfaces
- **Location**: [mac-helper/claw-meeting/Sources/ClawMeeting/Session/MeetingRecorder.swift](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/mac-helper/claw-meeting/Sources/ClawMeeting/Session/MeetingRecorder.swift#L399), [mac-daemon/meeting-sync.sh](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/mac-daemon/meeting-sync.sh#L59), [mac-daemon/meeting-sync.sh](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/mac-daemon/meeting-sync.sh#L130), [server/context-receiver.py](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/server/context-receiver.py#L1054), [server/meeting_processor.py](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/server/meeting_processor.py#L620)
- **What happens**: `session-state.json` only records timestamps and counters. The sync script expects keys like `call_app` and `allow_external_processing` that are never written, and it hardcodes `participants` to an empty string in the payload. The server persists exactly that. As a result, meetings reach the backend with missing app identity, no participant list, and external-processing consent defaulting false.
- **Why it matters**: This breaks the claimed end-to-end meeting intelligence flow. The history view loses identity/context, participant profiles do not build from session metadata, and external analysis remains disabled even when the operator intended to allow it.
- **Confidence**: High - traced recorder output, sync payload construction, and server persistence.
- **How to verify**: Record a meeting and inspect `session-state.json`, the outbound sync payload, and the corresponding row in `meeting_sessions`.
- **Recommended fix**: Define a real meeting-session contract and keep the writer and sync reader in lockstep. The session state should include app, participants, consent, and any other fields the server depends on.
- **Evidence**: `writeSessionState()` omits `call_app`, `participants`, and `allow_external_processing`; `meeting-sync.sh` reads the missing keys and still builds the payload; the server stores those blank values without remediation.

## Medium Severity

### `/context/jc-work-log` Will 500 Once the Table Exists
- **Location**: [server/context-receiver.py](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/server/context-receiver.py#L973)
- **What happens**: The endpoint uses dict-style DB rows everywhere except for `"result": r[4]`. Once a `jc_work_log` table actually exists, that numeric index raises and the endpoint falls into the 500 handler.
- **Why it matters**: The helper/agent loses visibility into JC's work log exactly when the feature starts being used.
- **Confidence**: High - direct code-path verification against the dict row factory used by `get_db()`.
- **How to verify**: Create a `jc_work_log` table with one row and request `/context/jc-work-log`.
- **Recommended fix**: Replace the numeric index with a named field and add an endpoint test that exercises the non-empty table case.
- **Evidence**: `get_db()` installs a dict row factory; the endpoint then mixes `r.get(...)` with `r[4]`.

### The Transcript Button Is Shipped but Still a No-Op
- **Location**: [mac-helper/OpenClawHelper/Views/Tabs/MeetingRowView.swift](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/mac-helper/OpenClawHelper/Views/Tabs/MeetingRowView.swift#L47), [server/context-receiver.py](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/server/context-receiver.py#L915)
- **What happens**: The Meetings UI offers a `View transcript` button when the server says transcript data exists, but the click handler is still `TODO: fetch transcript`.
- **Why it matters**: This is a direct user-facing broken promise on a visible surface, not hidden technical debt.
- **Confidence**: High - traced the visible button and the empty action body.
- **How to verify**: Open a meeting row with `hasTranscript = true` and click the button.
- **Recommended fix**: Either wire it to the existing transcript endpoint or hide the control until the flow is implemented.
- **Evidence**: The server already exposes `GET /context/meetings/<meeting_id>/transcript`; the UI never calls it.

### Helper Fetch Failures Collapse Into Empty-State UI
- **Location**: [mac-daemon/context-helperctl.sh](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/mac-daemon/context-helperctl.sh#L338), [mac-daemon/context-helperctl.sh](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/mac-daemon/context-helperctl.sh#L386), [mac-helper/OpenClawHelper/ViewModels/MeetingViewModel.swift](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/mac-helper/OpenClawHelper/ViewModels/MeetingViewModel.swift#L121), [mac-helper/OpenClawHelper/ViewModels/HandoffsTabViewModel.swift](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/mac-helper/OpenClawHelper/ViewModels/HandoffsTabViewModel.swift#L47), [mac-helper/OpenClawHelper/ViewModels/DashboardViewModel.swift](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/mac-helper/OpenClawHelper/ViewModels/DashboardViewModel.swift#L17)
- **What happens**: Missing server URL, missing helper token, TLS/auth failures, and curl failures often return `[]` or `{}` from the shell layer. The Swift side largely swallows the resulting decode/transport errors. The operator is shown stale data or honest-looking empty states like "No meetings recorded yet" or "No handoffs yet" instead of a connectivity/auth problem.
- **Why it matters**: It erodes operator trust and makes incident diagnosis slower because failure and emptiness are rendered identically.
- **Confidence**: High - traced helper shell fallbacks and the silent Swift error handling paths.
- **How to verify**: Remove the helper token or break the TLS trust file, then open the Meetings or Handoffs surfaces.
- **Recommended fix**: Preserve explicit transport/auth errors through the shell boundary and render them distinctly from true empty states.
- **Evidence**: `do_list_handoffs()` and `do_fetch_dashboard()` emit success-shaped empty payloads on configuration/curl failure; view models often keep existing state or show empty UI without surfacing the real cause.

## Low Severity

### Documented Auth Setup No Longer Matches Runtime Requirements
- **Location**: [QUICKSTART.md](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/QUICKSTART.md#L47), [server/context-receiver.py](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/server/context-receiver.py#L1679), [server/start.sh](/Users/jonassorensen/Desktop/Hobby/AI/clawrelay/server/start.sh)
- **What happens**: Quickstart still refers to a single `CONTEXT_BRIDGE_TOKEN`-style setup in places, while the receiver now requires three scoped tokens (`daemon`, `helper`, `agent`).
- **Why it matters**: Fresh installs can fail or be misconfigured before the operator even reaches runtime verification.
- **Confidence**: High - doc/runtime mismatch is explicit.
- **How to verify**: Follow Quickstart literally on a clean server and compare the generated env layout to `configure_app()`.
- **Recommended fix**: Update all setup and troubleshooting docs to the scoped-token model and remove stale single-token examples.
- **Evidence**: `configure_app()` hard-fails on missing scoped auth env vars.

## Claimed vs. Actual Capability Matrix
| Capability (from docs/README) | Status | Notes |
|-------------------------------|--------|-------|
| Real-time Mac activity capture with offline queue | Working | Core capture/queue path exists and looks broadly coherent. |
| Explicit operator handoffs from the helper app | Broken | Helper writes local outbox, but daemon-flushed delivery is rejected by server auth. |
| Sensitive mode for confidential work | Partial | Main daemon suppresses normal activity payloads, but meeting transcripts still upload after Sensitive-mode segments. |
| Dashboard / handoff / meetings helper UI | Partial | Surfaces exist, but connectivity/auth failures often degrade to empty states or stale data. |
| Meeting summaries with transcript + visual intelligence | Partial | Session upload works, but visual analysis can be lost permanently if frames arrive late or upload fails. |
| Meeting participant / People intelligence | Partial | Sessions arrive without enough metadata, and downstream profile/pattern flows are incomplete/brittle. |
| Transcript viewing in the helper app | Broken | UI control is present but not implemented. |
| Daemon staleness monitoring | Broken | Watchdog path fails on actual stale conditions; legacy documented path is not production-compatible. |

## Positive Observations
- The server-side auth model has moved toward better separation with scoped daemon/helper/agent tokens instead of a single shared secret.
- Input hardening is present in several important places: `validate_meeting_id()`, `safe_meeting_dir()`, bounded frame counts, request-size limits, and TLS CA pinning support on the Mac side.
- The main activity ingest path does make a credible effort to respect privacy defaults: clipboard content is nulled server-side, sensitive apps/URLs/titles are filtered Mac-side, and raw retention/purge logic is present.

## Methodology
I read the repo intent docs (`README.md`, `CLAUDE.md`, `PURPOSE.md`, `ROADMAP.md`, `ISSUES.md`, `ARCHITECTURE.md`), mapped the stack and entry points, checked git churn over the last three months, and then audited the full tracked source tree with emphasis on the highest-risk runtime paths: `mac-daemon/context-daemon.sh`, `mac-daemon/context-helperctl.sh`, `mac-daemon/meeting-sync.sh`, `server/context-receiver.py`, `server/context-digest.py`, `server/context-query.py`, `server/watchdog.py`, `server/staleness-watchdog.sh`, `mac-helper/OpenClawHelper/*`, and `mac-helper/claw-meeting/*`.

I also used parallel subagent sweeps for silent failures, incomplete implementations, integration gaps, UX/security/observability gaps, and then personally re-read and verified the Critical and High findings against the actual execution paths. I excluded `.claude/worktrees`, generated build output, archives, and vendor-like artifacts from the audit body.
