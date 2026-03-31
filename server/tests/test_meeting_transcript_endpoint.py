"""Tests for GET /context/meetings/<id>/transcript endpoint."""
import json


class TestGetMeetingTranscript:
    def test_returns_transcript_and_events(self, client, auth_headers):
        from db_utils import get_db
        db = get_db()
        transcript = json.dumps([{"ts": "2026-03-31T09:01:00Z", "speaker": "Alice", "text": "Hello"}])
        visual = json.dumps([
            {"ts": "2026-03-31T09:02:00Z", "type": "slide_change", "description": "Title slide"},
            {"ts": "2026-03-31T09:03:00Z", "type": "expression", "expression_analysis": [
                {"expression": "concerned", "confidence": 0.85}
            ]},
        ])
        db.execute(
            "INSERT INTO meeting_sessions (id, started_at, ended_at, duration_seconds, app, participants, transcript_json, visual_events_json, summary_md) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            ("m1", "2026-03-31T09:00:00Z", "2026-03-31T09:30:00Z", 1800, "Zoom", '["Alice"]', transcript, visual, "Sum"),
        )
        db.commit()
        db.close()

        resp = client.get("/context/meetings/m1/transcript", headers=auth_headers)
        assert resp.status_code == 200
        data = resp.get_json()
        assert len(data["transcript"]) == 1
        assert data["transcript"][0]["speaker"] == "Alice"
        assert len(data["visual_events"]) == 2
        assert len(data["expression_analysis"]) == 1
        assert data["expression_analysis"][0]["expression"] == "concerned"

    def test_returns_404_for_nonexistent_meeting(self, client, auth_headers):
        resp = client.get("/context/meetings/nonexistent/transcript", headers=auth_headers)
        assert resp.status_code == 404

    def test_returns_purged_error_when_transcript_null(self, client, auth_headers):
        from db_utils import get_db
        db = get_db()
        db.execute(
            "INSERT INTO meeting_sessions (id, started_at, ended_at, duration_seconds, app, participants, summary_md) VALUES (?, ?, ?, ?, ?, ?, ?)",
            ("m2", "2026-03-31T09:00:00Z", "2026-03-31T09:30:00Z", 1800, "Zoom", '[]', "Sum"),
        )
        db.commit()
        db.close()

        resp = client.get("/context/meetings/m2/transcript", headers=auth_headers)
        assert resp.status_code == 200
        assert resp.get_json()["error"] == "purged"

    def test_unauthorized(self, client):
        resp = client.get("/context/meetings/m1/transcript")
        assert resp.status_code == 401
