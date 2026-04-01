"""Tests for GET /context/meetings endpoint."""
import json
from datetime import datetime, timedelta, timezone


class TestGetMeetings:
    def test_returns_empty_list_when_no_meetings(self, client, helper_headers):
        resp = client.get("/context/meetings", headers=helper_headers)
        assert resp.status_code == 200
        data = resp.get_json()
        assert data["meetings"] == []

    def test_returns_meetings_sorted_by_started_at_desc(self, client, helper_headers):
        from db_utils import get_db
        db = get_db()
        db.execute(
            "INSERT INTO meeting_sessions (id, started_at, ended_at, duration_seconds, app, participants, transcript_json, summary_md) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            ("m1", "2026-03-30T09:00:00Z", "2026-03-30T09:30:00Z", 1800, "Zoom", '["Alice"]', '[]', "Summary 1"),
        )
        db.execute(
            "INSERT INTO meeting_sessions (id, started_at, ended_at, duration_seconds, app, participants, transcript_json, summary_md) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            ("m2", "2026-03-31T10:00:00Z", "2026-03-31T10:45:00Z", 2700, "Google Meet", '["Bob"]', None, "Summary 2"),
        )
        db.commit()
        db.close()

        resp = client.get("/context/meetings", headers=helper_headers)
        assert resp.status_code == 200
        meetings = resp.get_json()["meetings"]
        assert len(meetings) == 2
        assert meetings[0]["id"] == "m2"
        assert meetings[1]["id"] == "m1"

    def test_has_transcript_derived_field(self, client, helper_headers):
        from db_utils import get_db
        db = get_db()
        db.execute(
            "INSERT INTO meeting_sessions (id, started_at, ended_at, duration_seconds, app, participants, transcript_json, summary_md) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            ("m1", "2026-03-31T09:00:00Z", "2026-03-31T09:30:00Z", 1800, "Zoom", '["Alice"]', '[{"text":"hi"}]', "Sum"),
        )
        db.execute(
            "INSERT INTO meeting_sessions (id, started_at, ended_at, duration_seconds, app, participants, summary_md) VALUES (?, ?, ?, ?, ?, ?, ?)",
            ("m2", "2026-03-31T10:00:00Z", "2026-03-31T10:30:00Z", 1800, "Zoom", '["Bob"]', "Sum2"),
        )
        db.commit()
        db.close()

        resp = client.get("/context/meetings", headers=helper_headers)
        meetings = resp.get_json()["meetings"]
        m1 = next(m for m in meetings if m["id"] == "m1")
        m2 = next(m for m in meetings if m["id"] == "m2")
        assert m1["has_transcript"] is True
        assert m1["purge_status"] == "live"
        assert m2["has_transcript"] is False
        assert m2["purge_status"] == "summary_only"

    def test_unauthorized(self, client):
        resp = client.get("/context/meetings")
        assert resp.status_code == 401

    def test_participants_parsed_from_json(self, client, helper_headers):
        from db_utils import get_db
        db = get_db()
        db.execute(
            "INSERT INTO meeting_sessions (id, started_at, ended_at, duration_seconds, app, participants, summary_md) VALUES (?, ?, ?, ?, ?, ?, ?)",
            ("m1", "2026-03-31T09:00:00Z", "2026-03-31T09:30:00Z", 1800, "Zoom", '["Alice", "Bob"]', "Sum"),
        )
        db.commit()
        db.close()

        resp = client.get("/context/meetings", headers=helper_headers)
        m = resp.get_json()["meetings"][0]
        assert m["participants"] == ["Alice", "Bob"]

    def test_rejects_daemon_scope(self, client, daemon_headers):
        resp = client.get("/context/meetings", headers=daemon_headers)
        assert resp.status_code == 403
