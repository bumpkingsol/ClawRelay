"""Tests for GET /context/participants endpoint."""
import json


class TestGetParticipants:
    def test_returns_empty_list_when_no_profiles(self, client, helper_headers):
        resp = client.get("/context/participants", headers=helper_headers)
        assert resp.status_code == 200
        assert resp.get_json()["participants"] == []

    def test_returns_profiles_sorted_by_meetings_observed(self, client, helper_headers):
        from db_utils import get_db
        db = get_db()
        db.execute(
            "INSERT INTO participant_profiles (id, display_name, meetings_observed, profile_json, last_updated, last_seen) VALUES (?, ?, ?, ?, ?, ?)",
            ("p1", "Alice", 3, '{"decision_style": "data-first"}', "2026-03-31T09:00:00Z", "2026-03-31T09:00:00Z"),
        )
        db.execute(
            "INSERT INTO participant_profiles (id, display_name, meetings_observed, profile_json, last_updated, last_seen) VALUES (?, ?, ?, ?, ?, ?)",
            ("p2", "Bob", 8, '{"decision_style": "consensus"}', "2026-03-31T10:00:00Z", "2026-03-31T10:00:00Z"),
        )
        db.commit()
        db.close()

        resp = client.get("/context/participants", headers=helper_headers)
        participants = resp.get_json()["participants"]
        assert len(participants) == 2
        assert participants[0]["display_name"] == "Bob"
        assert participants[1]["display_name"] == "Alice"

    def test_profile_json_parsed(self, client, helper_headers):
        from db_utils import get_db
        db = get_db()
        profile = json.dumps({"decision_style": "data-first", "stress_triggers": "vague timelines"})
        db.execute(
            "INSERT INTO participant_profiles (id, display_name, meetings_observed, profile_json, last_updated, last_seen) VALUES (?, ?, ?, ?, ?, ?)",
            ("p1", "Alice", 5, profile, "2026-03-31T09:00:00Z", "2026-03-31T09:00:00Z"),
        )
        db.commit()
        db.close()

        resp = client.get("/context/participants", headers=helper_headers)
        p = resp.get_json()["participants"][0]
        assert p["profile"]["decision_style"] == "data-first"
        assert p["last_seen"] == "2026-03-31T09:00:00Z"

    def test_unauthorized(self, client):
        resp = client.get("/context/participants")
        assert resp.status_code == 401

    def test_rejects_daemon_scope(self, client, daemon_headers):
        resp = client.get("/context/participants", headers=daemon_headers)
        assert resp.status_code == 403
