import os
import sys
import json
import pytest

# Add server directory to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

os.environ['CONTEXT_BRIDGE_DAEMON_WRITE_TOKEN'] = 'test-daemon-token'
os.environ['CONTEXT_BRIDGE_HELPER_TOKEN'] = 'test-helper-token'
os.environ['CONTEXT_BRIDGE_AGENT_TOKEN'] = 'test-agent-token'
os.environ['CONTEXT_BRIDGE_ALLOW_PLAINTEXT_DB_FOR_TESTS'] = 'true'
os.environ['CONTEXT_BRIDGE_REQUIRE_SQLCIPHER'] = 'false'


@pytest.fixture
def temp_db(tmp_path):
    """Create a temporary database for testing."""
    db_path = str(tmp_path / 'test.db')
    os.environ['CONTEXT_BRIDGE_DB'] = db_path
    return db_path


@pytest.fixture
def temp_frames_dir(tmp_path):
    """Create a temporary frames directory."""
    frames_dir = tmp_path / 'meeting-frames'
    frames_dir.mkdir()
    os.environ['MEETING_FRAMES_DIR'] = str(frames_dir)
    return frames_dir


@pytest.fixture
def processor_db(tmp_path):
    """Set up a temp database with meeting tables for processor tests."""
    db_path = str(tmp_path / 'test-processor.db')
    os.environ['CONTEXT_BRIDGE_DB'] = db_path

    import importlib
    import db_utils
    importlib.reload(db_utils)

    db = db_utils.get_db(db_path)
    db.execute("""
        CREATE TABLE IF NOT EXISTS meeting_sessions (
            id TEXT PRIMARY KEY, started_at TEXT, ended_at TEXT,
            duration_seconds INTEGER, app TEXT, participants TEXT,
            transcript_json TEXT, visual_events_json TEXT,
            summary_md TEXT, raw_data_purge_at TEXT,
            allow_external_processing INTEGER DEFAULT 0,
            summary_purge_at TEXT
        )
    """)
    db.execute("""
        CREATE TABLE IF NOT EXISTS participant_profiles (
            id TEXT PRIMARY KEY, display_name TEXT, face_embedding BLOB,
            meetings_observed INTEGER DEFAULT 0, profile_json TEXT,
            last_updated TEXT, last_seen TEXT
        )
    """)
    db.commit()
    db.close()
    return db_path


@pytest.fixture
def frames_dir(tmp_path):
    """Set up temp frames directory for processor tests."""
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
         transcript_json, visual_events_json, allow_external_processing)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        0,
    ))
    db.commit()
    db.close()
    return 'test-meeting-001'


@pytest.fixture
def app(temp_db, temp_frames_dir):
    """Create a test Flask app with fresh database."""
    # Re-import to pick up new env vars
    import importlib
    import db_utils
    importlib.reload(db_utils)

    # Flask app import workaround for hyphenated filename
    if 'context_receiver' in sys.modules:
        del sys.modules['context_receiver']

    import importlib.util
    spec = importlib.util.spec_from_file_location(
        'context_receiver',
        os.path.join(os.path.dirname(__file__), '..', 'context-receiver.py')
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    mod.app.config['TESTING'] = True
    return mod.app


@pytest.fixture
def client(app):
    """Create a test client."""
    return app.test_client()


@pytest.fixture
def daemon_headers():
    """Daemon write auth headers."""
    return {
        'Authorization': 'Bearer test-daemon-token',
        'Content-Type': 'application/json',
    }


@pytest.fixture
def helper_headers():
    """Helper auth headers."""
    return {
        'Authorization': 'Bearer test-helper-token',
        'Content-Type': 'application/json',
    }


@pytest.fixture
def agent_headers():
    """Agent auth headers."""
    return {
        'Authorization': 'Bearer test-agent-token',
        'Content-Type': 'application/json',
    }
