import json
import os
import sys
import pytest
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))


@pytest.fixture
def processor_db(tmp_path):
    """Set up a temp database with meeting tables."""
    db_path = str(tmp_path / 'test-processor.db')
    os.environ['CONTEXT_BRIDGE_DB'] = db_path
    os.environ['CONTEXT_BRIDGE_TOKEN'] = 'test-token'

    import importlib
    import db_utils
    importlib.reload(db_utils)

    db = db_utils.get_db(db_path)
    db.execute("""
        CREATE TABLE IF NOT EXISTS meeting_sessions (
            id TEXT PRIMARY KEY, started_at TEXT, ended_at TEXT,
            duration_seconds INTEGER, app TEXT, participants TEXT,
            transcript_json TEXT, visual_events_json TEXT,
            summary_md TEXT, raw_data_purge_at TEXT
        )
    """)
    db.execute("""
        CREATE TABLE IF NOT EXISTS participant_profiles (
            id TEXT PRIMARY KEY, display_name TEXT, face_embedding BLOB,
            meetings_observed INTEGER DEFAULT 0, profile_json TEXT,
            last_updated TEXT
        )
    """)
    db.commit()
    db.close()
    return db_path


@pytest.fixture
def frames_dir(tmp_path):
    """Set up temp frames directory."""
    d = tmp_path / 'meeting-frames'
    d.mkdir()
    os.environ['MEETING_FRAMES_DIR'] = str(d)
    return d


@pytest.fixture
def sample_meeting(processor_db):
    """Insert a sample meeting into the test DB."""
    import importlib
    import db_utils
    importlib.reload(db_utils)

    db = db_utils.get_db()
    db.execute("""
        INSERT INTO meeting_sessions
        (id, started_at, ended_at, duration_seconds, app, participants,
         transcript_json, visual_events_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    """, (
        'test-meeting-001',
        '2026-03-31T15:00:00Z',
        '2026-03-31T15:40:00Z',
        2400,
        'Zoom',
        json.dumps(['Jonas', 'David Rotman']),
        json.dumps([
            {'timestamp': 0, 'speaker': 'speaker_1', 'text': 'Hello David'},
            {'timestamp': 5, 'speaker': 'speaker_2', 'text': 'Hi Jonas, lets discuss pricing'},
            {'timestamp': 30, 'speaker': 'speaker_1', 'text': 'The total is $50,000'},
        ]),
        json.dumps([
            {
                'timestamp': 30,
                'type': 'visual',
                'trigger': 'keyword_price',
                'frame_filename': 'frame_030.png',
                'participants': [{'face_id': 'face_001', 'grid_position': 'top-right'}],
            },
        ]),
    ))
    db.commit()
    db.close()
    return 'test-meeting-001'


class TestMergeTimeline:
    """Tests for merge_timeline()."""

    def test_merge_transcript_only(self, processor_db, frames_dir):
        import importlib
        import meeting_processor
        importlib.reload(meeting_processor)

        transcript = [
            {'timestamp': 0, 'speaker': 'A', 'text': 'Hello'},
            {'timestamp': 5, 'speaker': 'B', 'text': 'Hi'},
        ]
        timeline = meeting_processor.merge_timeline(
            json.dumps(transcript), None, {}
        )
        assert len(timeline) == 2
        assert timeline[0]['type'] == 'transcript'
        assert timeline[0]['speaker'] == 'A'

    def test_merge_with_visual_events(self, processor_db, frames_dir):
        import importlib
        import meeting_processor
        importlib.reload(meeting_processor)

        transcript = [{'timestamp': 0, 'speaker': 'A', 'text': 'Hello'}]
        visual = [{'timestamp': 2, 'trigger': 'keyword', 'participants': []}]
        timeline = meeting_processor.merge_timeline(
            json.dumps(transcript), json.dumps(visual), {}
        )
        assert len(timeline) == 2
        assert timeline[0]['type'] == 'transcript'
        assert timeline[1]['type'] == 'visual'

    def test_merge_sorted_by_timestamp(self, processor_db, frames_dir):
        import importlib
        import meeting_processor
        importlib.reload(meeting_processor)

        transcript = [{'timestamp': 10, 'speaker': 'A', 'text': 'Late'}]
        visual = [{'timestamp': 2, 'trigger': 'early', 'participants': []}]
        timeline = meeting_processor.merge_timeline(
            json.dumps(transcript), json.dumps(visual), {}
        )
        assert timeline[0]['timestamp'] == 2
        assert timeline[1]['timestamp'] == 10

    def test_expression_filter_threshold(self, processor_db, frames_dir):
        import importlib
        import meeting_processor
        importlib.reload(meeting_processor)

        visual = [{
            'timestamp': 5,
            'trigger': 'test',
            'participants': [],
            'frame_filename': 'frame.png',
        }]
        expressions = {
            'frame.png': [
                {'position': 'top-left', 'expression': 'concerned', 'confidence': 0.8, 'body_language': 'leaning back'},
                {'position': 'top-right', 'expression': 'neutral', 'confidence': 0.4, 'body_language': 'still'},
            ]
        }
        timeline = meeting_processor.merge_timeline(
            None, json.dumps(visual), expressions
        )
        assert len(timeline) == 1
        analysis = timeline[0].get('expression_analysis', [])
        # Only the 0.8 confidence observation should be included
        assert len(analysis) == 1
        assert analysis[0]['expression'] == 'concerned'


class TestGenerateSummary:
    """Tests for summary generation."""

    def test_basic_summary_without_claude(self, processor_db, frames_dir, sample_meeting):
        import importlib
        import meeting_processor
        importlib.reload(meeting_processor)

        meeting = meeting_processor.load_meeting(sample_meeting)
        timeline = meeting_processor.merge_timeline(
            meeting['transcript_json'], meeting['visual_events_json'], {}
        )
        summary = meeting_processor.generate_summary(None, meeting, timeline)

        assert 'test-meeting-001' in summary
        assert 'Zoom' in summary
        assert 'Claude API unavailable' in summary


class TestUpdateProfiles:
    """Tests for participant profile updates."""

    def test_creates_new_profiles(self, processor_db, frames_dir):
        import importlib
        import meeting_processor
        importlib.reload(meeting_processor)

        meeting_processor.update_participant_profiles(
            'test-meeting', json.dumps(['Alice', 'Bob'])
        )

        import db_utils
        importlib.reload(db_utils)
        db = db_utils.get_db()
        profiles = db.execute("SELECT * FROM participant_profiles").fetchall()
        db.close()

        assert len(profiles) == 2
        names = {p['display_name'] for p in profiles}
        assert 'Alice' in names
        assert 'Bob' in names

    def test_increments_existing_profile(self, processor_db, frames_dir):
        import importlib
        import meeting_processor
        importlib.reload(meeting_processor)

        # First meeting
        meeting_processor.update_participant_profiles(
            'meeting-1', json.dumps(['Alice'])
        )
        # Second meeting
        meeting_processor.update_participant_profiles(
            'meeting-2', json.dumps(['Alice'])
        )

        import db_utils
        importlib.reload(db_utils)
        db = db_utils.get_db()
        profile = db.execute(
            "SELECT * FROM participant_profiles WHERE display_name = 'Alice'"
        ).fetchone()
        db.close()

        assert profile['meetings_observed'] == 2


class TestProcessMeeting:
    """Tests for the full processing pipeline."""

    def test_process_nonexistent_meeting(self, processor_db, frames_dir):
        import importlib
        import meeting_processor
        importlib.reload(meeting_processor)

        result = meeting_processor.process_meeting('nonexistent')
        assert result is False

    def test_process_meeting_without_claude(self, processor_db, frames_dir, sample_meeting):
        import importlib
        import meeting_processor
        importlib.reload(meeting_processor)

        # Process without ANTHROPIC_API_KEY (no Claude calls)
        os.environ.pop('ANTHROPIC_API_KEY', None)
        result = meeting_processor.process_meeting(sample_meeting)
        assert result is True

        # Check that summary was stored
        meeting = meeting_processor.load_meeting(sample_meeting)
        assert meeting['summary_md'] is not None
        assert 'test-meeting-001' in meeting['summary_md']

        # Check participant profiles were created
        import db_utils
        importlib.reload(db_utils)
        db = db_utils.get_db()
        profiles = db.execute("SELECT * FROM participant_profiles").fetchall()
        db.close()
        assert len(profiles) >= 1  # At least Jonas or David
