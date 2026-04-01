"""Security hardening tests for scoped auth, health signals, and provider defaults."""
import json
import os


class TestScopedAuthAndHealth:
    def test_health_uses_helper_scope(self, client, helper_headers):
        resp = client.get("/context/health", headers=helper_headers)
        assert resp.status_code == 200
        data = resp.get_json()
        assert "db_encrypted" in data
        assert "retention_backlog" in data
        assert "auth_mode" in data

    def test_health_rejects_daemon_scope(self, client, daemon_headers):
        resp = client.get("/context/health", headers=daemon_headers)
        assert resp.status_code == 403


class TestProviderDefaults:
    def test_meeting_session_defaults_external_processing_to_false(self, client, daemon_headers):
        payload = {
            "meeting_id": "meeting-default-deny",
            "started_at": "2026-03-31T15:00:00Z",
            "ended_at": "2026-03-31T15:40:00Z",
            "transcript_json": [{"timestamp": 0, "speaker": "speaker_1", "text": "hi"}],
        }
        resp = client.post(
            "/context/meeting/session",
            data=json.dumps(payload),
            headers=daemon_headers,
        )
        assert resp.status_code == 201

        from db_utils import get_db

        db = get_db()
        meeting = db.execute(
            "SELECT allow_external_processing FROM meeting_sessions WHERE id = ?",
            ("meeting-default-deny",),
        ).fetchone()
        db.close()

        assert meeting["allow_external_processing"] == 0

    def test_meeting_processor_skips_provider_when_external_processing_not_allowed(
        self, processor_db, frames_dir, sample_meeting
    ):
        import importlib
        import meeting_processor

        os.environ["ANTHROPIC_API_KEY"] = "test-api-key"
        importlib.reload(meeting_processor)

        calls = []

        class FakeMessages:
            def create(self, **kwargs):
                calls.append(kwargs)
                return None

        class FakeClient:
            messages = FakeMessages()

        original = meeting_processor.get_anthropic_client
        meeting_processor.get_anthropic_client = lambda: FakeClient()
        try:
            result = meeting_processor.process_meeting(sample_meeting)
        finally:
            meeting_processor.get_anthropic_client = original

        assert result is True
        assert calls == []

        meeting = meeting_processor.load_meeting(sample_meeting)
        assert "external analysis skipped by policy" in meeting["summary_md"].lower()
