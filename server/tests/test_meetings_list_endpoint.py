"""Tests for GET /context/meetings endpoint."""
import json
from datetime import datetime, timedelta, timezone


class TestGetMeetings:
    def _recent_iso(self, days_ago: int, hour: int, minute: int = 0):
        dt = datetime.now(timezone.utc) - timedelta(days=days_ago)
        dt = dt.replace(hour=hour, minute=minute, second=0, microsecond=0)
        return dt.isoformat().replace("+00:00", "Z")

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
            ("m1", self._recent_iso(2, 9), self._recent_iso(2, 9, 30), 1800, "Zoom", '["Alice"]', '[]', "Summary 1"),
        )
        db.execute(
            "INSERT INTO meeting_sessions (id, started_at, ended_at, duration_seconds, app, participants, transcript_json, summary_md) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            ("m2", self._recent_iso(1, 10), self._recent_iso(1, 10, 45), 2700, "Google Meet", '["Bob"]', None, "Summary 2"),
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
            "INSERT INTO meeting_sessions (id, started_at, ended_at, duration_seconds, app, participants, transcript_json, summary_md, processing_status, frames_expected, frames_uploaded) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            ("m1", self._recent_iso(2, 9), self._recent_iso(2, 9, 30), 1800, "Zoom", '["Alice"]', '[{"text":"hi"}]', "Sum", "processed", 2, 2),
        )
        db.execute(
            "INSERT INTO meeting_sessions (id, started_at, ended_at, duration_seconds, app, participants, summary_md, processing_status, frames_expected, frames_uploaded) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            ("m2", self._recent_iso(1, 10), self._recent_iso(1, 10, 30), 1800, "Zoom", '["Bob"]', "Sum2", "ready", 4, 0),
        )
        db.commit()
        db.close()

        resp = client.get("/context/meetings", headers=helper_headers)
        meetings = resp.get_json()["meetings"]
        m1 = next(m for m in meetings if m["id"] == "m1")
        m2 = next(m for m in meetings if m["id"] == "m2")
        assert m1["has_transcript"] is True
        assert m1["purge_status"] == "live"
        assert m1["processing_status"] == "processed"
        assert m1["frames_expected"] == 2
        assert m1["frames_uploaded"] == 2
        assert m2["has_transcript"] is False
        assert m2["purge_status"] == "summary_only"
        assert m2["processing_status"] == "ready"
        assert m2["frames_expected"] == 4
        assert m2["frames_uploaded"] == 0

    def test_unauthorized(self, client):
        resp = client.get("/context/meetings")
        assert resp.status_code == 401

    def test_participants_parsed_from_json(self, client, helper_headers):
        from db_utils import get_db
        db = get_db()
        db.execute(
            "INSERT INTO meeting_sessions (id, started_at, ended_at, duration_seconds, app, participants, summary_md) VALUES (?, ?, ?, ?, ?, ?, ?)",
            ("m1", self._recent_iso(2, 9), self._recent_iso(2, 9, 30), 1800, "Zoom", '["Alice", "Bob"]', "Sum"),
        )
        db.commit()
        db.close()

        resp = client.get("/context/meetings", headers=helper_headers)
        m = resp.get_json()["meetings"][0]
        assert m["participants"] == ["Alice", "Bob"]

    def test_rejects_daemon_scope(self, client, daemon_headers):
        resp = client.get("/context/meetings", headers=daemon_headers)
        assert resp.status_code == 403

    def test_returns_processing_metadata_for_incomplete_meetings(self, client, helper_headers):
        from db_utils import get_db
        db = get_db()
        db.execute(
            """
            INSERT INTO meeting_sessions
            (id, started_at, ended_at, duration_seconds, app, participants, summary_md,
             transcript_json, processing_status, frames_expected, frames_uploaded)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                "m-awaiting",
                self._recent_iso(1, 11),
                self._recent_iso(1, 11, 30),
                1800,
                "Zoom",
                '["Alice"]',
                None,
                None,
                "awaiting_frames",
                6,
                2,
            ),
        )
        db.commit()
        db.close()

        resp = client.get("/context/meetings", headers=helper_headers)
        assert resp.status_code == 200
        meeting = next(m for m in resp.get_json()["meetings"] if m["id"] == "m-awaiting")
        assert meeting["processing_status"] == "awaiting_frames"
        assert meeting["frames_expected"] == 6
        assert meeting["frames_uploaded"] == 2
        assert meeting["summary_md"] is None
