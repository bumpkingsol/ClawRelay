# Meetings Tab & Live Sidebar — Design Spec

**Date:** 2026-03-31
**Status:** Approved
**Scope:** New Control Center Meetings tab + live meeting sidebar panel + consent gate + 3 new server endpoints

---

## Problem

The ClawRelay meeting infrastructure is ~85% complete — audio/visual capture (claw-meeting binary), server processing (meeting_processor.py), briefing cache, and overlay notifications all exist. But there's no centralized UI for meeting intelligence. The Control Center has no Meetings tab, there's no persistent sidebar for live meetings, and there's no consent gate before recording starts.

## Solution

Three new UI surfaces and three new server endpoints:

1. **Consent Gate** — Prompt before auto-detected meetings begin recording
2. **Meeting Sidebar** — Live intelligence panel anchored to the meeting app window
3. **Meetings Tab** — 7th tab in the Control Center for live monitoring and meeting history

---

## 1. Consent Gate

### Trigger
`MeetingDetectorService` detects mic activation + Zoom/Google Meet running.

### Flow
1. Auto-detect triggers a confirmation prompt (macOS alert or menu bar dialog)
2. Prompt: **"Record this meeting?"** with **Accept** and **Decline** buttons
3. **Accept** → full recording pipeline starts (claw-meeting spawns, sidebar opens)
4. **Decline** → meeting is ignored; detection pauses until the meeting app window closes
5. **No response within 15 seconds** → treated as Decline (safe default)
6. **Manual start** (`meeting-start` command) → no prompt; intent is explicit

### Integration with Meeting Lifecycle

Consent adds a new `.awaitingConsent` case to `MeetingLifecycleState`, between `idle` and `preparing`:

1. `MeetingDetectorService` triggers → state transitions to `.awaitingConsent`
2. A macOS `NSAlert` (or menu bar dialog) is presented
3. A 15-second `Task.sleep` timeout runs concurrently
4. **Accept** → transition to `.preparing` → normal pipeline
5. **Decline or timeout** → transition back to `.idle`; detection suppressed until the meeting app's main window closes (tracked via `NSWorkspace.didTerminateApplicationNotification` or window close observation)

`MeetingSessionManager.beginPreparing()` currently has `guard state == .idle` — this changes to `guard state == .awaitingConsent`.

### Rationale
Some meetings are private. The user must explicitly consent to recording for each auto-detected meeting. Manual starts bypass the prompt because the user has already expressed intent.

### Concurrent Meetings
Only one meeting at a time is supported. If a second meeting is detected while one is recording, it is silently ignored. The existing `guard state == .idle` / `.awaitingConsent` check enforces this.

---

## 2. Meeting Sidebar (Live Surface)

### Physical Properties
- **Type:** NSPanel with `.nonactivatingPanel` style mask (doesn't steal focus from Zoom/Meet)
- **Width:** ~300px, non-resizable
- **Position:** Anchored to the right edge of the meeting app window, same height
- **Window tracking:** Polls `CGWindowListCopyWindowInfo` on a 1-second timer to get the meeting app's main window frame (external app windows cannot be observed via `NSWindow` notifications). Falls back to right-edge-of-screen positioning if the meeting window frame cannot be determined (e.g., window closes but meeting continues, or app goes to a non-standard state).
- **Full-screen:** If meeting app goes full-screen, sidebar overlays from the right edge

### Layout (Top to Bottom)

#### Header (fixed)
- Recording indicator (red dot) + "Recording" label
- Elapsed time counter (MM:SS)
- Meeting app name + meeting title (if available)

#### Participants Section
- Participant avatars (initials) with one-line behavioral insight
- For scheduled meetings: populated from briefing package immediately
- For ad-hoc meetings: shows "detecting..." placeholder, fills within ~30 seconds from transcript/vision analysis

#### Intelligence Cards Section (scrollable, main area)
Cards persist in the sidebar (no auto-dismiss). New cards slide in at the top with subtle animation.

Four card types, color-coded:
| Type | Color | Purpose |
|------|-------|---------|
| Talking Point | Purple (#8b5cf6) | Pre-loaded points from briefing |
| Context | Blue (#58a6ff) | Relevant history pulled from agent memory |
| Suggestion | Green (#3fb950) | Reactive recommendations triggered by transcript keywords |
| Warning | Amber (#d29922) | Alerts (stress triggers, sensitive topics) |

**Card type mapping:** The existing `BriefingCard` model uses `category` (behavioural, data, context) and `priority` (high, medium, low). Add a new `cardType` enum field to the card model: `.talkingPoint`, `.context`, `.suggestion`, `.warning`. The briefing loader maps existing categories: `context` → `.context`, `behavioural` → `.warning`, `data` → `.talkingPoint`. Reactive cards generated from keyword matches default to `.suggestion`.

#### Transcript Ticker (fixed bottom)
- Rolling ~30 seconds of live transcript
- Speaker-colored text
- Pinned to bottom of sidebar, always visible
- Dark background to visually separate from cards

### Layered Content Strategy

The sidebar fills progressively — never empty, even for ad-hoc meetings:

| Layer | Timing | Content |
|-------|--------|---------|
| Layer 1 | Instant | Briefing cards if available, otherwise "Listening..." with transcript ticker |
| Layer 2 | Within ~30s | Participants identified from audio/vision; profiles loaded |
| Layer 3 | Ongoing | Reactive cards as transcript keywords match agent memory |

### Lifecycle
- **Spawns** when meeting recording starts (after consent)
- **Dismisses** when meeting ends (auto-detect or manual stop)
- User can toggle sidebar visibility via the Meetings Tab "Toggle Sidebar" button or the popover's existing sidebar button during recording

---

## 3. Meetings Tab (Control Center)

7th tab in the Control Center sidebar, positioned after Dashboard (2nd position). SF Symbol: `mic.and.signal.meter`.

### Adaptive Layout

The tab switches between two modes based on meeting state:

#### Live Mode (meeting active)

**Recording Banner** (top, prominent):
- Red recording indicator + meeting title
- Elapsed time, app name, participant count
- Controls: "Toggle Sidebar" button, "Stop" button (red)
- Stats row: transcript segment count, screenshot count, cards fired, briefing loaded status

**Recent Meetings List** (below, dimmed):
- Same as idle mode but visually de-emphasized
- Provides continuity — user can still reference past meetings while in one

#### Idle Mode (no active meeting)

**Stats Strip** (top, 4 cards in a row):
| Card | Content |
|------|---------|
| This Week | Meeting count |
| Total Hours | Sum of durations, average per meeting |
| Top Participant | Most frequently seen person |
| Pattern | Most notable behavioral pattern detected |

Stats are computed client-side from the `GET /context/meetings` and `GET /context/participants` responses — no separate stats endpoint needed.

**Sub-Navigation:** Two sub-tabs — **Meetings** and **People**

##### Meetings Sub-Tab

Chronological list of meetings (last 7 days, configurable). Each row shows:
- Meeting title — derived from the first line/sentence of `summary_md` if available, otherwise formatted from the meeting ID (e.g., `2026-03-31-153000-zoom` → "Zoom, Mar 31 3:30 PM")
- Date/time, app, duration
- Participant avatars (initials)
- Status badge:
  - **"Summary ready"** (green) — processing complete
  - **"Processing"** (blue) — meeting_processor running
  - **"Raw purged"** (gray) — past 48h, only summary remains

**Expanded row** (click to expand):
- Full summary text (summary_md from server)
- Action buttons: "View transcript" (if within purge window). Expression timeline is deferred to a future iteration.

##### People Sub-Tab

Participant profiles sorted by meeting frequency. Each row shows:
- Avatar (initials, colored), display name
- Meeting count, last seen date
- One-line behavioral summary

**Expanded profile** (click to expand) — 4-quadrant detail:
| Quadrant | Content |
|----------|---------|
| Decision Style | How this person makes decisions |
| Stress Triggers | Topics/situations that cause pushback |
| Framing Advice | How to present ideas to this person |
| Recent Pattern | Notable trend from recent meetings |

---

## 4. Server Endpoints

Three new endpoints, all using the existing `verify_auth` Bearer token pattern.

### GET /context/meetings

Returns meeting history list.

**Query parameters:**
- `days` — Number of days of history (default: 7, max: 30)

**Response:**
```json
{
  "meetings": [
    {
      "id": "meeting-id",
      "started_at": "2026-03-31T09:00:00Z",
      "ended_at": "2026-03-31T09:34:00Z",
      "duration_seconds": 2040,
      "app": "Zoom",
      "participants": ["Maria Kim", "Tom Park"],
      "summary_md": "Reviewed sprint velocity...",
      "has_transcript": true,
      "purge_status": "live"
    }
  ]
}
```

**Derived fields:**
- `has_transcript`: `transcript_json IS NOT NULL` (direct column check)
- `purge_status`: Based on actual data state, not the schedule:
  - `"live"` — `transcript_json IS NOT NULL` (raw data still present)
  - `"summary_only"` — `transcript_json IS NULL` (purge has run, only `summary_md` remains)

Sorted by `started_at` descending.

### GET /context/participants

Returns participant profiles.

**Response:**
```json
{
  "participants": [
    {
      "id": "participant-id",
      "display_name": "Maria Kim",
      "meetings_observed": 8,
      "last_seen": "2026-03-31T09:34:00Z",
      "profile": {
        "decision_style": "Data-first. Wants numbers before commitments.",
        "stress_triggers": "Vague timelines, unquantified risks.",
        "money_reaction": "Conservative — needs ROI data before budget commits.",
        "authority_deference": "Defers to data, not hierarchy.",
        "commitment_signals": "Uses 'I can commit to...' when ready.",
        "engagement_peak": "Most engaged during technical deep-dives.",
        "reliability": "High — follows through on action items."
      }
    }
  ]
}
```

**Schema alignment:** The `profile` object maps directly to `profile_json` stored by `meeting_processor.py`. The database stores: `decision_style`, `money_reaction`, `authority_deference`, `commitment_signals`, `stress_triggers`, `engagement_peak`, `reliability`. The endpoint returns these fields as-is.

**`last_seen` derivation:** The `participant_profiles` table has `last_updated` but not `last_seen`. The endpoint derives `last_seen` by adding a `last_seen` column to `participant_profiles`, updated by `meeting_processor.py` when it processes a meeting containing that participant (set to the meeting's `ended_at`).

**UI mapping:** The People sub-tab's 4-quadrant expanded view maps the stored profile fields to display labels:
| Display Quadrant | Source Fields |
|-----------------|---------------|
| Decision Style | `decision_style` + `authority_deference` |
| Stress Triggers | `stress_triggers` + `money_reaction` |
| Engagement | `engagement_peak` + `commitment_signals` |
| Reliability | `reliability` |

Sorted by `meetings_observed` descending.

### GET /context/meetings/<id>/transcript

Returns full transcript and analysis for a single meeting.

**Response:**
```json
{
  "transcript": [
    { "ts": "2026-03-31T09:01:12Z", "speaker": "Maria Kim", "text": "..." }
  ],
  "visual_events": [
    { "ts": "2026-03-31T09:05:00Z", "type": "slide_change", "description": "..." }
  ],
  "expression_analysis": [
    { "ts": "2026-03-31T09:12:30Z", "expression": "concerned", "confidence": 0.82 }
  ]
}
```

**Note:** `expression_analysis` is extracted from within `visual_events_json` entries that contain an `expression_analysis` sub-array. The endpoint flattens these into a top-level array — there is no separate database column for expression data.

Returns 404 if meeting not found. Returns `{ "error": "purged" }` if `transcript_json IS NULL` (raw data has been purged).

---

## 5. Architecture

### Shared ViewModel

`MeetingViewModel` is the single source of truth for both the sidebar and the Meetings tab. Both surfaces bind to the same published properties.

```
                Control Center                Meeting Sidebar
                ┌─────────────┐              ┌──────────────┐
                │ Meetings Tab │              │ NSPanel      │
                └──────┬──────┘              └──────┬───────┘
                       │                            │
                ┌──────┴────────────────────────────┴───────┐
                │         MeetingViewModel (shared)          │
                │  @Published state, transcript, cards,      │
                │  participants, meetingHistory, profiles     │
                └──────┬────────────────────────────┬───────┘
                       │                            │
          ┌────────────┴───────┐        ┌──────────┴────────┐
          │ MeetingSessionMgr  │        │ BriefingCacheSvc  │
          │ (exists)           │        │ (exists)          │
          └────────────────────┘        └───────────────────┘
                       │
          ┌────────────┴───────┐
          │ helperctl commands │
          │ + server endpoints │
          └────────────────────┘
```

### Data Flow

**Meeting starts:**
1. `MeetingDetectorService` detects mic + meeting app → consent prompt
2. User accepts → `MeetingSessionManager` transitions to `recording`
3. `MeetingViewModel` publishes state change
4. Meetings tab switches to Live Mode
5. Sidebar NSPanel spawns, anchors to meeting window
6. Layered fill begins (briefing → participants → reactive cards)

**During meeting:**
- `BriefingCacheService` watches `meeting-buffer.jsonl` for keyword matches
- Matched cards appear in sidebar Intelligence section
- Transcript ticker updates every few seconds
- Meetings tab live banner updates counters

**Meeting ends:**
- Sidebar dismisses
- Meetings tab transitions to Idle Mode
- `meeting-sync.sh` pushes final data to server
- `meeting_processor.py` runs async
- Meeting row appears in history with "Processing" badge → "Summary ready"

**Reviewing history:**
- Meetings sub-tab calls `GET /context/meetings?days=7` on tab load
- Expanding a row calls `GET /context/meetings/<id>/transcript` if within purge window
- People sub-tab calls `GET /context/participants`
- Both cached locally and refreshed on tab switch

### Sidebar Window Management
- NSPanel with `.nonactivatingPanel` style mask
- Observes meeting window frame changes
- `sidebar.frame.origin.x = meetingWindow.frame.maxX`
- Matches meeting window height
- If meeting window goes full-screen, overlays from right edge

---

## 6. What Already Exists (Reuse)

| Component | Status | Action |
|-----------|--------|--------|
| `MeetingDetectorService` | Complete | Add consent prompt before starting |
| `MeetingSessionManager` | Complete | Wire to shared MeetingViewModel |
| `MeetingViewModel` | Exists (basic) | Extend with history, profiles, sidebar state |
| `MeetingOverlayPanel` | Complete | Adapt pattern for sidebar (different layout) |
| `BriefingCacheService` | Complete | No changes needed |
| `NotificationCardView` | Complete | Adapt card styling for sidebar (persistent, not auto-dismiss) |
| `MeetingStatusView` | Complete (popover) | Keep as-is; Meetings tab is separate |
| `MeetingSidebarView` | Started | Rewrite to match this spec |
| `meeting_processor.py` | Complete | No changes needed |
| `meeting-sync.sh` | Complete | No changes needed |
| Server meeting endpoints | 3 exist | Add 3 new read endpoints |
| `ControlCenterViewModel` | Complete | Add `.meetings` to tab enum |

---

## 7. Out of Scope

- Calendar integration for pre-meeting briefing scheduling (future)
- Multi-monitor sidebar positioning (handle single monitor first)
- Meeting recording playback (audio never leaves the Mac)
- Editing/deleting meeting records from the UI
- Export/share meeting summaries
- Expression timeline visualization (deferred to future iteration)
- Concurrent meeting support (one meeting at a time)
