# ClawRelay Meeting Intelligence — Design Spec

**Date:** 2026-03-31
**Status:** Draft
**Author:** Jonas + Claude (brainstorm)

## Problem

JC has zero visibility into Jonas's meetings. All meeting context arrives after the fact — filtered through memory, mood, and whatever Jonas remembers to share. By the time context reaches JC, the nuance is gone: no access to what was said, no read on how people reacted, no understanding of tone or body language.

## Solution

A ClawRelay extension that captures audio and visual data from meetings, processes them locally, feeds structured intelligence to JC, and surfaces real-time briefing cards during calls. Three layers working together: audio transcription, visual/behavioural analysis, and a live suggestion overlay powered by JC's pre-loaded briefing packages.

## Architecture Docs Update Required

ARCHITECTURE.md currently states "Audio / microphone" and "Screen content / pixels" are "Not captured at all." Meeting mode explicitly lifts these constraints. When this feature ships, ARCHITECTURE.md must be updated to reframe those as default-mode constraints:

> **Default mode:** No audio, microphone, or screen pixel capture.
> **Meeting mode:** Captures system audio, microphone input, and periodic screen captures. All audio processing is local — only text transcripts leave the Mac. Screenshots are pushed to the server for batch analysis, then purged after 48h.

## Architecture

```
ClawRelay.app (existing SwiftUI menu bar app)
  ├─ Meeting mode toggle (menu bar + auto-detect)
  ├─ MeetingDetector (CoreAudio device listener + NSWorkspace)
  ├─ OverlayPanel (NSPanel, sharingType = .none)
  │   ├─ Notification cards (slide-in, auto-dismiss)
  │   └─ Sidebar mode (toggle for full briefing view)
  ├─ BriefingCache (pre-loaded from JC, local keyword matching)
  └─ Spawns/manages claw-meeting worker

claw-meeting (Swift binary, spawned by ClawRelay during meetings)
  ├─ FluidAudio: SystemAudioCapture + MicCapture
  ├─ FluidAudio: Parakeet TDT streaming transcription + VAD
  ├─ FluidAudio: Speaker diarisation (LS-EEND streaming)
  ├─ Screen capture (CGWindowListCreateImage at intervals)
  ├─ Apple Vision: face detection, landmarks, body pose
  ├─ Face tracking (ArcFace embeddings via CoreML)
  ├─ Output: ~/.context-bridge/meeting-buffer.jsonl
  └─ Output: ~/.context-bridge/meeting-session/<id>/

context-daemon.sh (existing, every 2 min)
  ├─ Reads and flushes meeting-buffer.jsonl
  └─ Ships meeting data to server via Tailscale

Server (existing, extended)
  ├─ context-receiver.py: stores meeting data
  ├─ meeting-processor.py: Claude Vision batch analysis
  ├─ context-digest.py: meeting section in digests
  └─ Participant profiles (SQLite, persistent)
```

### Data Flow During a Meeting

1. `claw-meeting` captures audio + screenshots continuously
2. Live transcript segments write to `meeting-buffer.jsonl` every few seconds
3. ClawRelay watches the buffer, matches keywords against pre-loaded briefing, surfaces notification cards
4. `context-daemon.sh` picks up buffer every 2 min, ships to server
5. Post-meeting: `claw-meeting` runs high-quality Parakeet batch transcription on the full recording
6. Server receives final transcript + screenshots, runs Claude Vision expression analysis

## Meeting Lifecycle

```
idle
  │
  ├─ auto-detect (mic active 5s + Zoom/Meet running)
  ├─ manual start (menu bar button)
  ▼
preparing
  │  Spawn claw-meeting worker
  │  Request briefing from JC
  │  Load cached briefing if available
  │  Worker loads FluidAudio models
  ▼
recording
  │  Audio capture active
  │  Live transcript streaming
  │  Screenshots at intervals
  │  Notification cards active
  │  Sidebar available on toggle
  │
  ├─ auto-detect (mic silent 60s + app closed)
  ├─ manual stop (menu bar button)
  ▼
finalizing
  │  Stop audio capture
  │  Run Parakeet batch on full recording
  │  Run diarisation on full recording
  │  Push final transcript + screenshots to server
  │  Server runs Claude Vision expression analysis
  │  Kill claw-meeting worker
  ▼
idle
```

### Auto-Detection

Adapted from OpenOats' `MeetingDetector`:

- Listens to CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere` on all input devices
- When mic goes active, 5-second debounce, then scans `NSWorkspace.runningApplications` for:
  - `us.zoom.xos` (Zoom)
  - Chrome with "meet.google.com" in window title (Google Meet)
- When mic goes silent for 60 seconds AND the meeting app is no longer foregrounded: trigger stop
- If the user manually started, auto-stop is disabled. Only manual stop works. Prevents cutting off a meeting because someone muted for a minute.
- Manual override always wins.
- Auto-detection verifies active call state, not just app running:
  - Zoom: check for window title containing "Zoom Meeting" (not lobby/settings)
  - Google Meet: check for "meet.google.com" in active Chrome tab URL (already captured by daemon)

### Pause & Sensitive Mode

`claw-meeting` checks `~/.context-bridge/pause-until` and `~/.context-bridge/sensitive-mode` every 10 seconds during recording:

| Mode | Behaviour |
|---|---|
| **Pause** | Immediately stops all capture. Audio recording stops, screenshots stop, overlay dismissed. Session enters a `paused` state. Resumes when pause lifts. Raw audio has a gap. |
| **Sensitive** | Audio capture continues (for transcript continuity) but transcript segments are not written to `meeting-buffer.jsonl`. Screenshots stop. Overlay cards stop. When sensitive mode lifts, capture resumes normally. The gap in the buffer is logged. |

If pause is activated during finalizing, finalization completes (it's processing already-captured data, not capturing new data).

## Audio Pipeline

### During the Meeting (Live Streaming)

- System audio captured via Core Audio HAL process tap (from OpenOats' `SystemAudioCapture`)
- Microphone captured via AVAudioEngine input tap (from OpenOats' `MicCapture`)
- FluidAudio mixes and resamples to 16kHz mono
- Parakeet TDT streaming transcription in ~2s chunks with 10s left context
- LS-EEND streaming speaker diarisation (up to 10 speakers)
- Raw audio saved as WAV to `~/.context-bridge/meeting-session/<id>/audio.wav`
- Live transcript segments written to `meeting-buffer.jsonl`

### Post-Meeting (Batch, High Quality)

- Parakeet TDT batch transcription on full audio (better WER than streaming, ~2% improvement)
- Pyannote batch diarisation (more accurate than LS-EEND streaming)
- Merge into final timestamped, speaker-labelled transcript
- Final transcript replaces the rough streaming version on the server
- Audio file retained locally only — never pushed to server

**Finalization timing:** A 40-minute meeting produces ~75MB of WAV audio. Batch Parakeet transcription at 110x realtime takes ~22 seconds. Diarisation adds ~30 seconds. Total finalization: under 2 minutes for a typical meeting.

**Edge cases during finalization:**
- New meeting starts during finalization: finalization continues in background, new session starts independently
- Mac sleeps during finalization: resumes on wake (claw-meeting worker stays alive)
- Finalization can be cancelled from menu bar (discards batch results, keeps the streaming transcript already on server)

### Model: FluidAudio + Parakeet TDT 0.6b v3

- 600M parameters, runs on Apple Neural Engine via CoreML
- 110x realtime on M4 Pro (fastest local ASR by 5-10x over alternatives)
- 25 European languages including English, Danish, Slovak, German, Spanish
- CC BY 4.0 license (fully commercial)
- Word-level and segment-level timestamps
- Automatic punctuation and capitalisation

FluidAudio also provides VAD (Silero) and speaker diarisation (Pyannote CoreML + LS-EEND streaming) in the same Swift package. Single dependency for the entire audio pipeline.

### Why Not WhisperKit

WhisperKit was considered (used by OpenOats). Parakeet via FluidAudio wins on:
- Speed: 110x vs ~9x realtime on Apple Silicon
- English WER: 6.32% vs ~7.4% average
- Diarisation included in same SDK (WhisperKit has none)
- All five target languages supported

### Transcript Segment Format

```json
{
  "type": "transcript",
  "meeting_id": "2026-03-31-zoom-david-sonopeace",
  "timestamp": 124.5,
  "speaker": "speaker_1",
  "text": "So I looked at the numbers last night and I have some concerns.",
  "confidence": 0.91,
  "words": [
    {"word": "So", "start": 124.5, "end": 124.8},
    {"word": "I", "start": 124.85, "end": 124.92}
  ],
  "is_final": true
}
```

## Visual Pipeline

### During the Meeting (On-Device)

Screen capture via `CGWindowListCreateImage`:
- Periodic: every 30 seconds baseline
- Event-triggered: increase to every 5 seconds when:
  - Keyword detected in transcript (price, deadline, concern)
  - Long silence (>5 seconds)
  - Speaker change after a question

Per frame, Apple Vision runs on-device:
1. `VNDetectFaceRectanglesRequest` — face bounding boxes
2. `VNDetectFaceLandmarksRequest` — 76-point landmark constellation
3. `VNDetectHumanBodyPose3DRequest` — 17 joints in 3D (macOS 14+)
4. ArcFace embeddings (ONNX → CoreML) — face re-ID across frames
5. Geometric expression signals — mouth open, brow position, gaze direction, head tilt

Screenshots saved to `~/.context-bridge/meeting-session/<id>/frames/`.

### Post-Meeting (Server-Side, Claude Vision Batch)

Server receives screenshots, runs Claude Vision API (~$0.01-0.05 per frame):
- Classifies expressions: neutral, concerned, interested, skeptical, confident, uncomfortable, surprised, disengaged
- Describes body language: posture, hand position, gaze direction
- Notes behaviours: looking at phone, multitasking, nodding

Results merged with transcript timeline to produce emotional hotspot annotations ("At 2:04, when Jonas mentioned $50K, David shifted from neutral to uncomfortable and leaned back").

### Why LLM for Expression Analysis

ARKit's 52 blend shapes (the gold standard for expression detection) are iOS only — not available on macOS. On-device options are limited to geometric analysis of Vision landmarks (~80-85% accuracy for basic signals). For nuanced categories like "skeptical" or "disengaged", multimodal LLMs are the best option:

| Model | Accuracy (7 emotions) |
|---|---|
| GPT-4o | 86% |
| Gemini 2.0 | 84% |
| Claude 3.5 Sonnet | 74% |

Batch post-meeting processing makes latency and cost acceptable. Expression classifications include a confidence score (0-1). Meeting summaries qualify emotional hotspot statements with confidence: "David likely uncomfortable (0.78 confidence) when $50K mentioned." Observations below 0.6 confidence are omitted from summaries.

### Visual Event Format

```json
{
  "type": "visual",
  "meeting_id": "2026-03-31-zoom-david-sonopeace",
  "timestamp": 124.5,
  "aligned_transcript_segment": 31,
  "trigger": "keyword_price",
  "participants": [
    {
      "face_id": "face_001",
      "grid_position": "top-right",
      "face_embedding_hash": "a3f8c2...",
      "mouth_open": true,
      "gaze": "at_camera",
      "head_tilt": -3.2,
      "body_lean": "forward",
      "landmarks_summary": {
        "brow_raised": false,
        "brow_furrowed": true,
        "mouth_openness": 0.42
      }
    }
  ]
}
```

## Live Suggestion Overlay

### Pre-Meeting: Briefing Package

JC reads the calendar event, knows attendees and topic, searches memory corpus, entity data, participant profiles, deal history, WhatsApp threads, and meeting history. Generates a structured briefing package and pushes to ClawRelay via Tailscale HTTP. Cached at `~/.context-bridge/meeting-briefing/<meeting_id>.json`.

```json
{
  "meeting_id": "2026-03-31-zoom-david-sonopeace",
  "attendees": ["david_rotman", "liz_chen"],
  "topic": "Sonopeace Q2 pricing",
  "cards": [
    {
      "trigger_keywords": ["cash flow", "budget", "afford", "expensive"],
      "title": "David + cash flow",
      "body": "David panicked at similar numbers in January. Recovered in 48hrs. Anouk's one-pager resolved it. Don't offer concessions yet.",
      "priority": "high",
      "category": "behavioural"
    },
    {
      "trigger_keywords": ["break even", "breakeven", "ROI", "payback"],
      "title": "Break-even numbers",
      "body": "18 months at 500 units. He's seen this before. Reference the deck from Feb 12.",
      "priority": "medium",
      "category": "data"
    }
  ],
  "participant_profiles": {
    "david_rotman": {
      "decision_style": "needs_time_to_process",
      "stress_triggers": ["large_numbers", "timeline_pressure"],
      "framing_advice": "Phased numbers, not lump sums"
    }
  },
  "talking_points": [
    "Confirm Q3 vs Q4 timeline preference",
    "Get commitment on pilot scope"
  ]
}
```

### During the Meeting: Local Keyword Matching

1. Live transcript segment arrives from `meeting-buffer.jsonl`
2. ClawRelay matches keywords against card `trigger_keywords` (case-insensitive, partial match)
3. Deduplication: same card won't fire twice within 5 minutes
4. Match found → notification card surfaces instantly (sub-100ms, pure local matching)

95% of suggestions are instant (local match). Zero server round-trips.

### Fallback for Novel Situations (~5%)

When the transcript contains a significant topic not in any card's trigger keywords:
1. ClawRelay pings JC via Tailscale HTTP: `POST /meeting/context-request`
2. JC searches memory, generates a card, pushes back (~3 second round-trip)
3. Card surfaces as a notification

Rate limited to maximum 5 fallback requests per meeting, minimum 60 seconds between requests. Prevents flooding JC during meetings with many unexpected topics.

### Notification Cards (Default)

```
┌─────────────────────────────────┐
│ 💡 David + cash flow            │
│                                 │
│ Panicked at similar numbers in  │
│ January. Recovered in 48hrs.    │
│ Don't offer concessions yet.    │
│                          8s ━━░ │
└─────────────────────────────────┘
```

- `NSPanel` with `sharingType = .none` (invisible to screen share)
- Dark glass aesthetic (matching ClawRelay's `DarkUtilityGlass` theme)
- Slides in from top-right
- Auto-dismisses after 8 seconds (countdown bar)
- Click → pins the card, stops countdown
- Drag to sidebar area → opens sidebar with full context

### Sidebar (Optional Toggle)

Full-height panel docked to the right side of the screen. Shows:
- All briefing cards (triggered and untriggered)
- Participant profiles
- Talking points checklist
- Live transcript scroll

Also `NSPanel` with `sharingType = .none`. Toggle via menu bar or keyboard shortcut.

## Server-Side Processing

### New API Endpoints

| Endpoint | Method | Purpose |
|---|---|---|
| `/context/meeting/session` | POST | Receive final transcript + metadata |
| `/context/meeting/frames` | POST | Receive screenshots for analysis (multipart/form-data, batch of up to 10 PNGs per request, max 50MB) |
| `/meeting/context-request` | POST | Live fallback card requests from ClawRelay |

### Meeting Processor (`meeting-processor.py`)

Triggered when final transcript arrives:
1. Run Claude Vision batch analysis on screenshots
2. Merge transcript + visual events + expression analysis into unified timeline
3. Generate meeting intelligence summary (markdown)
4. Match face embeddings to existing participant profiles (or create new)
5. Update participant profiles with new behavioural observations
6. If participant has 3+ meetings observed: run Claude to detect cross-meeting patterns

### Meeting Intelligence Summary

```markdown
# Meeting: Sonopeace Q2 Pricing
**Date:** 2026-03-31 15:00-15:40 | **Duration:** 40 min
**Participants:** Jonas, David Rotman, Liz Chen
**App:** Zoom

## Key Decisions
- Agreed to phased pricing: $15K/quarter instead of $50K upfront
- Pilot scope: 200 units (down from 500)

## Action Items
- [ ] Jonas: Send revised pricing deck by Thursday
- [ ] David: Confirm budget approval with board by April 7
- [ ] Liz: Share Q3 launch timeline doc

## Unresolved
- Q3 vs Q4 launch date — David still hesitant
- Integration with their existing CRM not discussed

## Emotional Hotspots
- **02:04** — David uncomfortable when $50K mentioned (leaned back, furrowed brow)
- **12:30** — David visibly relieved at phased pricing suggestion
- **28:15** — Liz disengaged during technical discussion (looking off-camera)

## Behavioural Notes
- David's pattern held: initial anxiety at big numbers, recovery when phased
- Liz deferred to David on pricing (consistent with profile)
- David more engaged than last 2 meetings
```

### Database Schema

```sql
CREATE TABLE participant_profiles (
    id TEXT PRIMARY KEY,
    display_name TEXT,
    face_embedding BLOB,
    meetings_observed INTEGER,
    profile_json TEXT,
    last_updated TEXT
);

CREATE INDEX idx_participant_display_name ON participant_profiles(display_name);

CREATE TABLE meeting_sessions (
    id TEXT PRIMARY KEY,
    started_at TEXT,
    ended_at TEXT,
    duration_seconds INTEGER,
    app TEXT,
    participants TEXT,
    transcript_json TEXT,
    visual_events_json TEXT,
    summary_md TEXT,
    raw_data_purge_at TEXT
);

CREATE INDEX idx_meeting_started ON meeting_sessions(started_at);
CREATE INDEX idx_meeting_purge ON meeting_sessions(raw_data_purge_at);
```

### Digest Integration

`context-digest.py` extended with a "Meetings" section:

```markdown
## Meetings
- **15:00-15:40** Sonopeace Q2 Pricing (Zoom, David + Liz)
  Agreed phased pricing. 3 action items. David's cash flow pattern held.
  Full summary: meeting_sessions/2026-03-31-zoom-david-sonopeace
```

## Participant Profiles (Cross-Meeting)

Over time, the system builds profiles for each meeting participant:

```json
{
  "participant": "david_rotman",
  "meetings_observed": 8,
  "patterns": {
    "decision_style": "needs_time_to_process",
    "money_reaction": "initial_anxiety_then_recovery",
    "authority_deference": "defers_to_liz_on_strategy",
    "commitment_signals": "verbal_yes_but_delays_action",
    "stress_triggers": ["large_numbers", "timeline_pressure", "technical_detail"],
    "engagement_peak": "when_discussing_product_impact",
    "reliability": "follows_through_after_48h_delay"
  },
  "last_updated": "2026-03-31"
}
```

JC uses these profiles to:
- Predict reactions before a meeting
- Suggest framing strategies ("David responds better to phased numbers, not lump sums")
- Flag behavioural deviations ("David was unusually quiet today — something changed")
- Identify the real decision-maker vs the stated one

Profile updates require 3+ meetings with a participant before pattern detection runs.

## Integration with ClawRelay

### New Files in mac-helper/

```
mac-helper/ClawRelay/
├─ Services/
│   ├─ MeetingDetectorService.swift
│   ├─ MeetingSessionManager.swift
│   ├─ BriefingCacheService.swift
│   └─ MeetingWorkerManager.swift
├─ Models/
│   ├─ MeetingState.swift
│   ├─ BriefingPackage.swift
│   └─ MeetingNotification.swift
├─ Views/
│   ├─ MeetingStatusView.swift
│   ├─ MeetingOverlayPanel.swift
│   ├─ NotificationCardView.swift
│   └─ MeetingSidebarView.swift
└─ ViewModels/
    └─ MeetingViewModel.swift
```

### New Binary: claw-meeting

```
mac-helper/claw-meeting/
├─ main.swift
├─ AudioCapture/
│   ├─ SystemAudioCapture.swift
│   └─ MicCapture.swift
├─ Transcription/
│   └─ FluidTranscriber.swift
├─ Visual/
│   ├─ ScreenCapture.swift
│   ├─ FaceAnalyzer.swift
│   └─ FaceTracker.swift
├─ Session/
│   └─ MeetingRecorder.swift
└─ Output/
    └─ BufferWriter.swift
```

### Menu Bar Integration

New "Meeting" section in the menu bar popover:
- When idle: shows "Meeting: idle" + [Start Meeting] button
- When recording: shows "Meeting: Recording" + elapsed time + [Stop] + [Sidebar] buttons
- Meeting mode toggle accessible from menu bar at all times

### Permissions (New)

| Permission | Why | Existing? |
|---|---|---|
| Accessibility | Window titles, Chrome URLs | Already granted |
| Screen Recording | System audio capture + screenshots | New |
| Microphone | Mic input during meetings | New |

Both new permissions are requested on first meeting start, not at app install.

### Model Download

FluidAudio models (~1.2GB for Parakeet TDT) download on first meeting start, not at app install. Cached in `~/Library/Application Support/ClawRelay/models/`.

**Failure handling:**
- Download progress shown in menu bar ("Downloading models... 45%")
- If download fails: meeting start is blocked, error shown in menu bar, user can retry
- If insufficient disk space: warning shown with required space
- Partial downloads resume from where they left off (HTTP range requests)
- Models are verified via checksum after download

### Worker Process Management

ClawRelay spawns `claw-meeting` via `Process` (Foundation). The worker lifecycle:
- ClawRelay starts the worker when entering `preparing` state
- Worker writes PID to `~/.context-bridge/meeting-worker.pid`
- ClawRelay monitors the process — if it crashes during recording, restart it (audio has a gap but session continues)
- If ClawRelay itself crashes while `claw-meeting` is running: on next launch, ClawRelay checks for the PID file, reattaches to the orphaned worker or kills it
- Worker communicates back to ClawRelay via `meeting-buffer.jsonl` (file watching) and a local Unix domain socket for control messages (stop, pause, status)

### helperctl Integration

`context-helperctl.sh` extended with meeting status:

```json
{
  "meeting": {
    "state": "recording",
    "meeting_id": "2026-03-31-zoom-david-sonopeace",
    "elapsed_seconds": 724,
    "worker_pid": 12345,
    "transcript_segments": 48,
    "screenshots_taken": 24,
    "briefing_loaded": true,
    "cards_surfaced": 3
  }
}
```

New actions: `meeting-start`, `meeting-stop`, `meeting-status`.

### Distribution

```
ClawRelay.app/
├─ Contents/
│   ├─ MacOS/
│   │   ├─ ClawRelay
│   │   ├─ claw-calendar
│   │   ├─ claw-whatsapp
│   │   └─ claw-meeting          ← new
│   └─ Resources/
│       └─ models/
│           └─ (FluidAudio downloads on first use)
```

## Privacy & Consent

- All audio processing is local. No audio leaves the Mac.
- Raw audio stays on Mac. Only transcripts and structured metadata go to server.
- Screenshots pushed to server for Claude Vision analysis, then purged after 48h. Only structured text output persists.
- Face embeddings are biometric identifiers used for participant re-identification across meetings. Stored as numeric vectors on the server. Note: under GDPR and similar regulations, face embeddings constitute biometric data. The per-meeting consent covers Jonas's awareness; participants are not individually consented. This is acceptable for Jonas's personal business use but would need a consent mechanism if deployed for others.
- Per-meeting consent acknowledgement on start (configurable — can be disabled for internal team calls).
- Kill switch: any meeting can be marked "off the record" which skips all capture.
- Comply with two-party consent requirements where applicable.
- Overlay panel invisible to screen share (`NSPanel.sharingType = .none`).

## Data Retention

| Data | Location | Retention |
|---|---|---|
| Raw audio (WAV) | Mac only | 30 days, then auto-deleted (configurable) |
| Screenshots (PNG) | Mac + server | Mac: 30 days auto-delete. Server: 48h |
| Raw transcript JSON | Server | 48h |
| Visual events JSON | Server | 48h |
| Meeting summary (markdown) | Server | Permanent |
| Participant profiles | Server | Permanent |

## Tech Stack

| Component | Technology | Runs On |
|---|---|---|
| Audio capture (system + mic) | Core Audio HAL process tap + AVAudioEngine | Mac |
| Audio transcription | FluidAudio + Parakeet TDT 0.6b v3 (CoreML/ANE) | Mac |
| Speaker diarisation | FluidAudio (LS-EEND streaming + Pyannote batch) | Mac |
| VAD | FluidAudio (Silero) | Mac |
| Meeting detection | CoreAudio device listener + NSWorkspace | Mac |
| Screen capture | CGWindowListCreateImage | Mac |
| Face detection + landmarks | Apple Vision framework | Mac |
| Body pose | Apple Vision VNDetectHumanBodyPose3DRequest | Mac |
| Face re-ID | ArcFace/InsightFace (ONNX → CoreML) | Mac |
| Expression analysis | Claude Vision API (batch, post-meeting) | Server |
| Overlay panel | NSPanel + sharingType = .none | Mac |
| Data transport | ClawRelay (existing Tailscale tunnel) | Mac → Server |
| Meeting DB | SQLite (alongside context-bridge.db) | Server |
| Profile storage | SQLite | Server |
| AI analysis | Claude Opus / Sonnet | Server |

## OpenOats Reuse

OpenOats (MIT licensed) provides tested implementations of:

| Component | OpenOats Source | Adaptation Needed |
|---|---|---|
| System audio capture | `SystemAudioCapture.swift` | Minimal — swap output to FluidAudio |
| Mic capture | `MicCapture.swift` | Minimal — swap output to FluidAudio |
| Meeting detection | `MeetingDetector.swift` | Filter to Zoom + Google Meet only |
| Overlay panel | `OverlayPanel.swift` | Restyle to DarkUtilityGlass theme |
| Session state machine | `MeetingState` enum + `AppCoordinator` | Adapt to ClawRelay lifecycle |
| Invisible window technique | `NSPanel.sharingType = .none` | Direct reuse |

Discarded from OpenOats:
- Ollama/OpenRouter LLM layer (replaced by JC on server)
- Knowledge base RAG system (replaced by JC's pre-loaded briefings)
- WhisperKit transcription (replaced by FluidAudio + Parakeet)
- Voyage AI embeddings (not needed)
- Sparkle auto-updater, LaunchAtLogin

## Open Source Strategy

**What's open:**
- Audio capture + FluidAudio/Parakeet integration
- Visual capture + Apple Vision face detection framework
- Meeting session manager and lifecycle
- Structured output format specification
- Integration protocol (not OpenClaw-specific)

**What stays private:**
- Psychological profiling prompts
- Participant profiles and meeting data
- JC-specific briefing generation logic
