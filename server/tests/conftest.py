import os
import sys
import pytest

# Add server directory to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

os.environ['CONTEXT_BRIDGE_TOKEN'] = 'test-token-12345'


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
def auth_headers():
    """Standard auth headers for testing."""
    return {
        'Authorization': 'Bearer test-token-12345',
        'Content-Type': 'application/json',
    }
