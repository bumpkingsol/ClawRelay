#!/usr/bin/env python3
"""
Meeting Processor -- Post-meeting intelligence generation.

Triggered after final transcript arrives. Performs:
1. Claude Vision batch analysis on screenshots (expression classification)
2. Merge transcript + visual events + expression analysis into unified timeline
3. Generate meeting intelligence summary (markdown)
4. Match face embeddings to participant profiles
5. Update participant profiles
6. Pattern detection after 3+ meetings with same participant
"""

import os
import sys
import json
import base64
import logging
import argparse
from datetime import datetime, timezone
from pathlib import Path

from db_utils import get_db, DB_PATH
from security import (
    MEETING_SUMMARY_RETENTION_DAYS,
    is_external_meeting_processing_allowed,
    redact_text,
    safe_meeting_dir,
    summarize_transcript_segments,
    validate_meeting_id,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [meeting-processor] %(message)s",
)
logger = logging.getLogger(__name__)

MEETING_FRAMES_DIR = Path(
    os.environ.get("MEETING_FRAMES_DIR", str(Path(DB_PATH).parent / "meeting-frames"))
)

EXPRESSION_CONFIDENCE_THRESHOLD = 0.6

# Claude model for vision analysis
VISION_MODEL = os.environ.get("MEETING_VISION_MODEL", "claude-sonnet-4-20250514")
# Claude model for summary + pattern detection
SUMMARY_MODEL = os.environ.get("MEETING_SUMMARY_MODEL", "claude-sonnet-4-20250514")


def participant_text(value):
    try:
        participants = json.loads(value) if isinstance(value, str) else value
    except Exception:
        participants = value
    if isinstance(participants, list):
        cleaned = [str(item).strip() for item in participants if str(item).strip()]
        return ", ".join(cleaned) if cleaned else "Unknown"
    return redact_text(str(participants or "Unknown"), 200)


def get_anthropic_client():
    """Get Anthropic client. Returns None if API key not set."""
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        logger.warning("ANTHROPIC_API_KEY not set -- skipping Claude analysis")
        return None

    try:
        import anthropic

        return anthropic.Anthropic(api_key=api_key)
    except ImportError:
        logger.warning("anthropic package not installed -- skipping Claude analysis")
        return None


def load_meeting(meeting_id):
    """Load meeting session from database."""
    db = get_db()
    row = db.execute(
        "SELECT * FROM meeting_sessions WHERE id = ?", (meeting_id,)
    ).fetchone()
    db.close()
    return dict(row) if row else None


def load_frames(meeting_id):
    """Load screenshot file paths for a meeting."""
    if not validate_meeting_id(meeting_id):
        return []
    try:
        session_dir = safe_meeting_dir(MEETING_FRAMES_DIR, meeting_id)
    except ValueError:
        return []
    if not session_dir.exists():
        return []

    frames = sorted(session_dir.glob("*.png"))
    return frames


def analyze_frame_expression(client, frame_path):
    """Run Claude Vision on a single frame to classify expressions.

    Returns a list of participant observations.
    """
    if not client:
        return []

    try:
        with open(frame_path, "rb") as f:
            image_data = base64.standard_b64encode(f.read()).decode("utf-8")

        response = client.messages.create(
            model=VISION_MODEL,
            max_tokens=1024,
            messages=[
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "image",
                            "source": {
                                "type": "base64",
                                "media_type": "image/png",
                                "data": image_data,
                            },
                        },
                        {
                            "type": "text",
                            "text": (
                                "Analyze the people visible in this meeting screenshot. "
                                "For each person, classify their expression as one of: "
                                "neutral, concerned, interested, skeptical, confident, "
                                "uncomfortable, surprised, disengaged. "
                                "Also describe their body language briefly. "
                                "Return JSON array with objects containing: "
                                'position (e.g. "top-left"), expression, confidence (0-1), '
                                "body_language (string). "
                                "Only return the JSON array, no other text."
                            ),
                        },
                    ],
                }
            ],
        )

        result_text = response.content[0].text.strip()

        # Parse JSON, handling potential markdown code fences
        if result_text.startswith("```"):
            result_text = result_text.split("\n", 1)[1].rsplit("```", 1)[0].strip()

        observations = json.loads(result_text)
        return observations if isinstance(observations, list) else []

    except Exception:
        logger.exception(f"Failed to analyze frame {frame_path.name}")
        return []


def analyze_frames_streaming(client, meeting_id):
    """Run expression analysis on frames incrementally (streaming).

    Yields dict mapping frame filename to list of observations.
    Processes one frame at a time to keep memory usage constant.
    """
    try:
        session_dir = safe_meeting_dir(MEETING_FRAMES_DIR, meeting_id)
    except ValueError:
        return
    if not session_dir.exists():
        return

    for frame_path in sorted(session_dir.glob("*.png")):
        logger.info(f"Analyzing frame: {frame_path.name}")
        observations = analyze_frame_expression(client, frame_path)
        yield {frame_path.name: observations}


def batch_analyze_frames(client, frames):
    """Run expression analysis on a batch of frames.

    Returns dict mapping frame filename to list of observations.
    DEPRECATED: Use analyze_frames_streaming for large meetings.
    """
    results = {}
    for frame_path in frames:
        logger.info(f"Analyzing frame: {frame_path.name}")
        observations = analyze_frame_expression(client, frame_path)
        results[frame_path.name] = observations
    return results


def merge_timeline(transcript_json, visual_events_json, expression_results):
    """Merge transcript, visual events, and expression analysis into unified timeline.

    Returns a list of timeline events sorted by timestamp.
    """
    timeline = []

    # Add transcript segments
    if transcript_json:
        segments = (
            json.loads(transcript_json)
            if isinstance(transcript_json, str)
            else transcript_json
        )
        for seg in segments:
            timeline.append(
                {
                    "type": "transcript",
                    "timestamp": seg.get("timestamp", 0),
                    "speaker": seg.get("speaker", "unknown"),
                    "text": seg.get("text", ""),
                    "confidence": seg.get("confidence", 1.0),
                }
            )

    # Add visual events with expression analysis overlay
    if visual_events_json:
        events = (
            json.loads(visual_events_json)
            if isinstance(visual_events_json, str)
            else visual_events_json
        )
        for evt in events:
            entry = {
                "type": "visual",
                "timestamp": evt.get("timestamp", 0),
                "trigger": evt.get("trigger", ""),
                "participants": evt.get("participants", []),
            }

            # Overlay expression results if available for this frame
            frame_key = evt.get("frame_filename")
            if frame_key and frame_key in expression_results:
                observations = expression_results[frame_key]
                # Filter by confidence threshold
                entry["expression_analysis"] = [
                    obs
                    for obs in observations
                    if obs.get("confidence", 0) >= EXPRESSION_CONFIDENCE_THRESHOLD
                ]

            timeline.append(entry)

    # Sort by timestamp
    timeline.sort(key=lambda x: x.get("timestamp", 0))

    return timeline


def generate_summary(client, meeting, timeline):
    """Generate a meeting intelligence summary using Claude.

    Returns markdown string.
    """
    if not client:
        return _generate_basic_summary(meeting, timeline)

    transcript_parts = [
        f"[{e['timestamp']}s] {redact_text(str(e.get('speaker', '?')), 40)}: {redact_text(str(e.get('text', '')), 280)}"
        for e in timeline
        if e["type"] == "transcript"
    ]
    transcript_text = "\n".join(transcript_parts[:500])  # Cap at 500 segments

    expression_notes = []
    for e in timeline:
        if e["type"] == "visual" and e.get("expression_analysis"):
            for obs in e["expression_analysis"]:
                ts = e.get("timestamp", 0)
                minutes = int(ts // 60)
                seconds = int(ts % 60)
                expression_notes.append(
                    f"- {minutes:02d}:{seconds:02d} -- {obs.get('position', '?')}: "
                    f"{obs.get('expression', '?')} ({obs.get('confidence', 0):.2f}), "
                    f"{obs.get('body_language', '')}"
                )
    expression_text = (
        "\n".join(expression_notes)
        if expression_notes
        else "No visual analysis available."
    )

    participants_str = participant_text(meeting.get("participants", "Unknown"))
    app_name = meeting.get("app", "Unknown")
    started_at = meeting.get("started_at", "")
    ended_at = meeting.get("ended_at", "")
    duration = meeting.get("duration_seconds", 0)
    duration_min = duration // 60 if duration else 0

    prompt = f"""Analyze this meeting and generate a structured intelligence summary.

Meeting metadata:
- App: {app_name}
- Participants: {participants_str}
- Start: {started_at}
- End: {ended_at}
- Duration: {duration_min} minutes

Transcript:
{transcript_text}

Visual/Expression observations:
{expression_text}

Generate a markdown summary with these exact sections:
1. **Key Decisions** -- bullet list of decisions made
2. **Action Items** -- checkbox list with owner and deadline if mentioned
3. **Unresolved** -- topics discussed but not concluded
4. **Emotional Hotspots** -- significant expression/body language moments with timestamps (MM:SS format), only include observations with confidence >= 0.6
5. **Behavioural Notes** -- patterns observed about participants

Keep it concise and actionable. Use the participant names, not "speaker_1".
If the transcript is empty or too short, note that the meeting data was limited.
Return only the markdown content for these sections (no title header -- I will add that)."""

    try:
        response = client.messages.create(
            model=SUMMARY_MODEL,
            max_tokens=4096,
            messages=[{"role": "user", "content": prompt}],
        )
        body = response.content[0].text.strip()
    except Exception:
        logger.exception("Failed to generate summary via Claude")
        body = _generate_basic_summary_body(meeting, timeline)

    # Build full summary with header
    header = f"""# Meeting: {meeting.get("id", "Unknown")}
**Date:** {started_at[:10] if started_at else "Unknown"} {started_at[11:16] if len(started_at) > 16 else ""}-{ended_at[11:16] if len(ended_at) > 16 else ""} | **Duration:** {duration_min} min
**Participants:** {participants_str}
**App:** {app_name}

"""
    return header + body


def generate_policy_blocked_summary(meeting, timeline):
    summary = _generate_basic_summary(meeting, timeline).replace(
        "*(Claude API unavailable -- manual review needed)*",
        "*(External analysis skipped by policy -- local-only summary)*",
    )
    return summary + "\n\n## External Analysis\nexternal analysis skipped by policy.\n"


def _generate_basic_summary(meeting, timeline):
    """Generate a minimal summary without Claude API."""
    body = _generate_basic_summary_body(meeting, timeline)
    started_at = meeting.get("started_at", "")
    ended_at = meeting.get("ended_at", "")
    duration = meeting.get("duration_seconds", 0)
    duration_min = duration // 60 if duration else 0

    header = f"""# Meeting: {meeting.get("id", "Unknown")}
**Date:** {started_at[:10] if started_at else "Unknown"} | **Duration:** {duration_min} min
**Participants:** {participant_text(meeting.get("participants", "Unknown"))}
**App:** {meeting.get("app", "Unknown")}

"""
    return header + body


def _generate_basic_summary_body(meeting, timeline):
    """Generate basic summary body from timeline data."""
    transcript_count = sum(1 for e in timeline if e["type"] == "transcript")
    visual_count = sum(1 for e in timeline if e["type"] == "visual")

    lines = [
        "## Key Decisions",
        "*(Claude API unavailable -- manual review needed)*",
        "",
        "## Action Items",
        "*(Claude API unavailable -- manual review needed)*",
        "",
        f"## Stats",
        f"- Transcript segments: {transcript_count}",
        f"- Visual events: {visual_count}",
    ]
    return "\n".join(lines)


def match_face_embeddings(meeting_id, visual_events_json):
    """Match face embeddings from visual events to participant profiles.

    Creates new profiles for unknown faces.
    Returns dict mapping face_id to participant profile id.
    """
    if not visual_events_json:
        return {}

    events = (
        json.loads(visual_events_json)
        if isinstance(visual_events_json, str)
        else visual_events_json
    )

    db = get_db()
    profiles = db.execute(
        "SELECT id, face_embedding FROM participant_profiles"
    ).fetchall()

    # Build a map of known embeddings
    known = {}
    for p in profiles:
        if p["face_embedding"]:
            known[p["face_embedding"]] = p["id"]

    matches = {}
    new_faces = set()

    for evt in events:
        for participant in evt.get("participants", []):
            face_id = participant.get("face_id")
            embedding_hash = participant.get("face_embedding_hash")
            if face_id and embedding_hash:
                if embedding_hash in known:
                    matches[face_id] = known[embedding_hash]
                else:
                    new_faces.add((face_id, embedding_hash))

    # Create stub profiles for new faces
    for face_id, emb_hash in new_faces:
        profile_id = f"face_{emb_hash[:12]}"
        try:
            db.execute(
                """
                INSERT OR IGNORE INTO participant_profiles
                (id, display_name, face_embedding, meetings_observed, profile_json, last_updated)
                VALUES (?, ?, ?, 1, '{}', ?)
            """,
                (profile_id, face_id, emb_hash, datetime.now(timezone.utc).isoformat()),
            )
            matches[face_id] = profile_id
        except Exception:
            logger.exception(f"Failed to create profile for {face_id}")

    db.commit()
    db.close()

    return matches


def update_participant_profiles(meeting_id, participants_str):
    """Increment meetings_observed for participants in this meeting."""
    db = get_db()

    # Parse participants
    try:
        participants = (
            json.loads(participants_str)
            if isinstance(participants_str, str)
            else participants_str
        )
    except (json.JSONDecodeError, TypeError):
        participants = []

    if not isinstance(participants, list):
        db.close()
        return

    # Load meeting's ended_at to record as last_seen
    meeting_row = db.execute(
        "SELECT ended_at FROM meeting_sessions WHERE id = ?", (meeting_id,)
    ).fetchone()
    ended_at = (
        meeting_row["ended_at"]
        if meeting_row
        else datetime.now(timezone.utc).isoformat()
    )

    for name in participants:
        if not name:
            continue
        # Try to find by display_name
        row = db.execute(
            "SELECT id, meetings_observed FROM participant_profiles WHERE display_name = ?",
            (name,),
        ).fetchone()

        if row:
            db.execute(
                """
                UPDATE participant_profiles
                SET meetings_observed = meetings_observed + 1,
                    last_updated = ?,
                    last_seen = ?
                WHERE id = ?
            """,
                (datetime.now(timezone.utc).isoformat(), ended_at, row["id"]),
            )
        else:
            # Create new profile
            import hashlib

            profile_id = f"name_{hashlib.sha256(name.encode()).hexdigest()[:12]}"
            db.execute(
                """
                INSERT OR IGNORE INTO participant_profiles
                (id, display_name, meetings_observed, profile_json, last_updated, last_seen)
                VALUES (?, ?, 1, '{}', ?, ?)
            """,
                (profile_id, name, datetime.now(timezone.utc).isoformat(), ended_at),
            )

    db.commit()
    db.close()


def detect_patterns(client, participant_name):
    """Detect cross-meeting patterns for a participant with 3+ meetings.

    Uses Claude to analyze historical meeting summaries.
    Returns updated profile_json or None.
    """
    db = get_db()
    profile = db.execute(
        "SELECT * FROM participant_profiles WHERE display_name = ?", (participant_name,)
    ).fetchone()

    if not profile or profile["meetings_observed"] < 3:
        db.close()
        return None

    # Find all meetings with this participant.
    # Prefer indexed lookup via meeting_participants, fallback to legacy LIKE
    # for backward compatibility with old schemas.
    try:
        meetings = db.execute(
            """
            SELECT ms.id, ms.started_at, ms.summary_md, ms.participants
            FROM meeting_participants mp
            JOIN meeting_sessions ms ON ms.id = mp.meeting_id
            WHERE mp.participant_name = ?
              AND ms.summary_md IS NOT NULL
            ORDER BY ms.started_at DESC
            LIMIT 10
        """,
            (participant_name,),
        ).fetchall()
    except Exception:
        meetings = db.execute(
            """
            SELECT id, started_at, summary_md, participants
            FROM meeting_sessions
            WHERE participants LIKE ?
            AND summary_md IS NOT NULL
            ORDER BY started_at DESC
            LIMIT 10
        """,
            (f"%{participant_name}%",),
        ).fetchall()
    db.close()

    if len(meetings) < 3 or not client:
        return None

    summaries_text = "\n\n---\n\n".join(
        [
            f"Meeting: {m['id']} ({m['started_at']})\n{m['summary_md'][:2000]}"
            for m in meetings
        ]
    )

    prompt = f"""Analyze these {len(meetings)} meeting summaries involving {participant_name}.

{summaries_text}

Identify recurring patterns in {participant_name}'s behaviour:
- Decision-making style
- Emotional reactions to specific topics
- Authority/deference patterns
- Commitment reliability
- Stress triggers
- Engagement patterns

Return a JSON object with these keys:
- decision_style (string)
- money_reaction (string)
- authority_deference (string)
- commitment_signals (string)
- stress_triggers (list of strings)
- engagement_peak (string)
- reliability (string)

Only include patterns you have strong evidence for across multiple meetings.
Return only the JSON object, no other text."""

    try:
        response = client.messages.create(
            model=SUMMARY_MODEL,
            max_tokens=2048,
            messages=[{"role": "user", "content": prompt}],
        )
        result_text = response.content[0].text.strip()
        if result_text.startswith("```"):
            result_text = result_text.split("\n", 1)[1].rsplit("```", 1)[0].strip()

        patterns = json.loads(result_text)

        # Update profile
        db = get_db()
        profile_json = json.dumps(
            {
                "participant": participant_name,
                "meetings_observed": profile["meetings_observed"],
                "patterns": patterns,
                "last_updated": datetime.now(timezone.utc).isoformat(),
            }
        )
        db.execute(
            "UPDATE participant_profiles SET profile_json = ?, last_updated = ? WHERE display_name = ?",
            (profile_json, datetime.now(timezone.utc).isoformat(), participant_name),
        )
        db.commit()
        db.close()

        logger.info(f"Updated patterns for {participant_name}")
        return patterns

    except Exception:
        logger.exception(f"Failed to detect patterns for {participant_name}")
        return None


def process_meeting(meeting_id):
    """Full processing pipeline for a completed meeting."""
    logger.info(f"Processing meeting: {meeting_id}")
    if not validate_meeting_id(meeting_id):
        logger.error("Invalid meeting id: %s", meeting_id)
        return False

    # 1. Load meeting data
    meeting = load_meeting(meeting_id)
    if not meeting:
        logger.error(f"Meeting {meeting_id} not found in database")
        return False

    db = get_db()
    db.execute(
        "UPDATE meeting_sessions SET processing_status = ? WHERE id = ?",
        ("processing", meeting_id),
    )
    db.commit()
    db.close()

    try:
        # 2. Load frames
        frames = load_frames(meeting_id)
        logger.info(f"Found {len(frames)} frames for meeting {meeting_id}")

        if meeting.get("processing_status") == "awaiting_frames":
            logger.info("Meeting %s is still awaiting frame upload", meeting_id)
            db = get_db()
            db.execute(
                "UPDATE meeting_sessions SET processing_status = ? WHERE id = ?",
                ("awaiting_frames", meeting_id),
            )
            db.commit()
            db.close()
            return False

        # 3. Get Claude client
        external_processing_allowed = is_external_meeting_processing_allowed(
            meeting_id, bool(meeting.get("allow_external_processing"))
        )
        if not external_processing_allowed:
            logger.info("External analysis denied by policy for meeting %s", meeting_id)
        client = get_anthropic_client() if external_processing_allowed else None

        # 4. Run expression analysis on frames
        expression_results = {}
        if frames and client:
            expression_results = batch_analyze_frames(client, frames)
            logger.info(f"Analyzed {len(expression_results)} frames")

        # 5. Merge into unified timeline
        timeline = merge_timeline(
            meeting.get("transcript_json"),
            meeting.get("visual_events_json"),
            expression_results,
        )
        logger.info(f"Unified timeline: {len(timeline)} events")

        # 6. Generate summary
        summary_md = (
            generate_summary(client, meeting, timeline)
            if client
            else generate_policy_blocked_summary(meeting, timeline)
        )
        logger.info(f"Generated summary: {len(summary_md)} chars")

        # 7. Store summary
        db = get_db()
        db.execute(
            "UPDATE meeting_sessions SET summary_md = ?, processing_status = ? WHERE id = ?",
            (summary_md, "processed", meeting_id),
        )
        db.commit()
        db.close()

        # 8. Match face embeddings
        match_face_embeddings(meeting_id, meeting.get("visual_events_json"))

        # 9. Update participant profiles
        update_participant_profiles(meeting_id, meeting.get("participants"))

        # 10. Detect patterns (for participants with 3+ meetings)
        try:
            participants = (
                json.loads(meeting["participants"])
                if isinstance(meeting["participants"], str)
                else (meeting["participants"] or [])
            )
            if isinstance(participants, list):
                for name in participants:
                    detect_patterns(client, name)
        except (json.JSONDecodeError, TypeError):
            pass

        logger.info(f"Meeting {meeting_id} processing complete")
        return True
    except Exception:
        logger.exception("Meeting %s processing failed", meeting_id)
        db = get_db()
        db.execute(
            "UPDATE meeting_sessions SET processing_status = ? WHERE id = ?",
            ("failed", meeting_id),
        )
        db.commit()
        db.close()
        return False


def main():
    parser = argparse.ArgumentParser(description="Meeting Processor")
    parser.add_argument(
        "--meeting-id", required=True, help="Meeting session ID to process"
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="Print summary without saving"
    )
    args = parser.parse_args()

    success = process_meeting(args.meeting_id)
    if not success:
        sys.exit(1)


if __name__ == "__main__":
    main()
