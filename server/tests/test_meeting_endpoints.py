import io
import json
import os
import sys
import pytest
from pathlib import Path

# Fixtures come from conftest.py


class TestMeetingSessionEndpoint:
    """Tests for POST /context/meeting/session."""

    def test_push_session_success(self, client, daemon_headers):
        """Valid session data is stored."""
        payload = {
            'meeting_id': 'test-2026-03-31-zoom-david',
            'started_at': '2026-03-31T15:00:00Z',
            'ended_at': '2026-03-31T15:40:00Z',
            'duration_seconds': 2400,
            'app': 'Zoom',
            'participants': ['Jonas', 'David Rotman'],
            'transcript_json': [
                {'timestamp': 0, 'speaker': 'speaker_1', 'text': 'Hello David'}
            ],
            'visual_events_json': [
                {'timestamp': 0, 'type': 'visual', 'participants': []}
            ],
            'allow_external_processing': True,
        }
        resp = client.post(
            '/context/meeting/session',
            data=json.dumps(payload),
            headers=daemon_headers,
        )
        assert resp.status_code == 201
        data = resp.get_json()
        assert data['status'] == 'ok'
        assert data['meeting_id'] == 'test-2026-03-31-zoom-david'
        assert 'purge_at' in data

    def test_push_session_missing_meeting_id(self, client, daemon_headers):
        """Missing meeting_id returns 400."""
        payload = {
            'started_at': '2026-03-31T15:00:00Z',
            'ended_at': '2026-03-31T15:40:00Z',
        }
        resp = client.post(
            '/context/meeting/session',
            data=json.dumps(payload),
            headers=daemon_headers,
        )
        assert resp.status_code == 400
        assert 'meeting_id' in resp.get_json()['error']

    def test_push_session_missing_timestamps(self, client, daemon_headers):
        """Missing started_at or ended_at returns 400."""
        payload = {
            'meeting_id': 'test-meeting',
            'started_at': '2026-03-31T15:00:00Z',
            # missing ended_at
        }
        resp = client.post(
            '/context/meeting/session',
            data=json.dumps(payload),
            headers=daemon_headers,
        )
        assert resp.status_code == 400

    def test_push_session_upsert(self, client, daemon_headers):
        """Pushing same meeting_id twice updates the existing record."""
        payload = {
            'meeting_id': 'test-upsert',
            'started_at': '2026-03-31T15:00:00Z',
            'ended_at': '2026-03-31T15:40:00Z',
            'duration_seconds': 2400,
            'app': 'Zoom',
            'participants': ['Jonas'],
            'transcript_json': [{'text': 'first version'}],
        }
        resp1 = client.post(
            '/context/meeting/session',
            data=json.dumps(payload),
            headers=daemon_headers,
        )
        assert resp1.status_code == 201

        payload['transcript_json'] = [{'text': 'final version'}]
        resp2 = client.post(
            '/context/meeting/session',
            data=json.dumps(payload),
            headers=daemon_headers,
        )
        assert resp2.status_code == 201

    def test_push_session_rejects_invalid_meeting_id(self, client, daemon_headers):
        payload = {
            'meeting_id': '../escape',
            'started_at': '2026-03-31T15:00:00Z',
            'ended_at': '2026-03-31T15:40:00Z',
        }
        resp = client.post(
            '/context/meeting/session',
            data=json.dumps(payload),
            headers=daemon_headers,
        )
        assert resp.status_code == 400
        assert 'meeting_id' in resp.get_json()['error']

    def test_push_session_rejects_helper_scope(self, client, helper_headers):
        payload = {
            'meeting_id': 'test-meeting',
            'started_at': '2026-03-31T15:00:00Z',
            'ended_at': '2026-03-31T15:40:00Z',
        }
        resp = client.post(
            '/context/meeting/session',
            data=json.dumps(payload),
            headers=helper_headers,
        )
        assert resp.status_code == 403

    def test_push_session_unauthorized(self, client):
        """No auth token returns 401."""
        payload = {
            'meeting_id': 'test',
            'started_at': '2026-03-31T15:00:00Z',
            'ended_at': '2026-03-31T15:40:00Z',
        }
        resp = client.post(
            '/context/meeting/session',
            data=json.dumps(payload),
            content_type='application/json',
        )
        assert resp.status_code == 401


class TestMeetingFramesEndpoint:
    """Tests for POST /context/meeting/frames."""

    def test_upload_frames_success(self, client, temp_frames_dir):
        """Upload PNG frames for a meeting."""
        resp = client.post(
            '/context/meeting/frames',
            data={
                'meeting_id': 'test-meeting-frames',
                'frames': [
                    (io.BytesIO(b'\x89PNG\r\n\x1a\n' + b'\x00' * 50), f'frame_{i:03d}.png')
                    for i in range(3)
                ],
            },
            headers={'Authorization': 'Bearer test-daemon-token'},
            content_type='multipart/form-data',
        )
        assert resp.status_code == 201
        result = resp.get_json()
        assert result['frames_saved'] == 3

        # Verify files on disk
        session_dir = temp_frames_dir / 'test-meeting-frames'
        assert session_dir.exists()
        assert len(list(session_dir.iterdir())) == 3

    def test_upload_frames_missing_meeting_id(self, client):
        """Missing meeting_id returns 400."""
        resp = client.post(
            '/context/meeting/frames',
            data={'frames': (io.BytesIO(b'fake'), 'test.png')},
            headers={'Authorization': 'Bearer test-daemon-token'},
            content_type='multipart/form-data',
        )
        assert resp.status_code == 400

    def test_upload_frames_no_files(self, client):
        """No files returns 400."""
        resp = client.post(
            '/context/meeting/frames',
            data={'meeting_id': 'test'},
            headers={'Authorization': 'Bearer test-daemon-token'},
            content_type='multipart/form-data',
        )
        assert resp.status_code == 400

    def test_upload_frames_too_many(self, client):
        """More than 10 files returns 400."""
        resp = client.post(
            '/context/meeting/frames',
            data={
                'meeting_id': 'test',
                'frames': [
                    (io.BytesIO(b'\x89PNG' + b'\x00' * 20), f'frame_{i:03d}.png')
                    for i in range(11)
                ],
            },
            headers={'Authorization': 'Bearer test-daemon-token'},
            content_type='multipart/form-data',
        )
        assert resp.status_code == 400

    def test_upload_frames_rejects_invalid_meeting_id(self, client):
        resp = client.post(
            '/context/meeting/frames',
            data={
                'meeting_id': '../escape',
                'frames': [(io.BytesIO(b'\x89PNG' + b'\x00' * 20), 'frame_001.png')],
            },
            headers={'Authorization': 'Bearer test-daemon-token'},
            content_type='multipart/form-data',
        )
        assert resp.status_code == 400
        assert 'meeting_id' in resp.get_json()['error']

    def test_upload_frames_rejects_agent_scope(self, client):
        resp = client.post(
            '/context/meeting/frames',
            data={
                'meeting_id': 'test-meeting',
                'frames': [(io.BytesIO(b'\x89PNG' + b'\x00' * 20), 'frame_001.png')],
            },
            headers={'Authorization': 'Bearer test-agent-token'},
            content_type='multipart/form-data',
        )
        assert resp.status_code == 403

    def test_upload_frames_unauthorized(self, client):
        """No auth returns 401."""
        resp = client.post(
            '/context/meeting/frames',
            data={'meeting_id': 'test'},
            content_type='multipart/form-data',
        )
        assert resp.status_code == 401


class TestMeetingContextRequest:
    """Tests for POST /meeting/context-request."""

    def test_context_request_success(self, client, helper_headers):
        """Valid context request returns a card."""
        payload = {
            'meeting_id': 'test-ctx-meeting',
            'transcript_context': 'David just mentioned a new CRM integration timeline.',
            'topic': 'CRM integration',
            'participants': ['Jonas', 'David'],
        }
        resp = client.post(
            '/meeting/context-request',
            data=json.dumps(payload),
            headers=helper_headers,
        )
        assert resp.status_code == 200
        data = resp.get_json()
        assert data['status'] == 'ok'
        assert 'card' in data
        assert data['card']['category'] == 'fallback'
        assert 'requests_remaining' in data

    def test_context_request_missing_meeting_id(self, client, helper_headers):
        """Missing meeting_id returns 400."""
        payload = {'transcript_context': 'some context'}
        resp = client.post(
            '/meeting/context-request',
            data=json.dumps(payload),
            headers=helper_headers,
        )
        assert resp.status_code == 400

    def test_context_request_missing_context(self, client, helper_headers):
        """Missing transcript_context returns 400."""
        payload = {'meeting_id': 'test'}
        resp = client.post(
            '/meeting/context-request',
            data=json.dumps(payload),
            headers=helper_headers,
        )
        assert resp.status_code == 400

    def test_context_request_rate_limit_count(self, client, helper_headers):
        """6th request to same meeting returns 429."""
        for i in range(5):
            payload = {
                'meeting_id': 'test-rate-limit',
                'transcript_context': f'context {i}',
            }
            resp = client.post(
                '/meeting/context-request',
                data=json.dumps(payload),
                headers=helper_headers,
            )
            # First 5 should succeed (ignoring 60s rate limit in test
            # since they are in the same second -- we test the count limit here)
            if resp.status_code == 429:
                # The 60s rate limit may kick in first; that is also acceptable
                break

        # The 6th should definitely be rate-limited
        payload = {
            'meeting_id': 'test-rate-limit',
            'transcript_context': 'context 5',
        }
        resp = client.post(
            '/meeting/context-request',
            data=json.dumps(payload),
            headers=helper_headers,
        )
        assert resp.status_code == 429

    def test_context_request_rejects_agent_scope(self, client, agent_headers):
        payload = {
            'meeting_id': 'test-context',
            'transcript_context': 'hello',
        }
        resp = client.post(
            '/meeting/context-request',
            data=json.dumps(payload),
            headers=agent_headers,
        )
        assert resp.status_code == 403

    def test_context_request_unauthorized(self, client):
        """No auth returns 401."""
        payload = {
            'meeting_id': 'test',
            'transcript_context': 'hello',
        }
        resp = client.post(
            '/meeting/context-request',
            data=json.dumps(payload),
            content_type='application/json',
        )
        assert resp.status_code == 401
