import json


class TestHandoffs:
    def test_helper_can_create_handoff(self, client, helper_headers):
        payload = {
            "project": "project-gamma",
            "task": "Ship the blocker fix",
            "message": "From helper UI",
            "priority": "high",
        }

        resp = client.post(
            "/context/handoff",
            data=json.dumps(payload),
            headers=helper_headers,
        )

        assert resp.status_code == 201
        data = resp.get_json()
        assert data["status"] == "ok"
        assert data["project"] == payload["project"]
        assert data["task"] == payload["task"]
        assert data["source"] == "helper"

    def test_daemon_cannot_create_handoff(self, client, daemon_headers):
        payload = {
            "project": "project-gamma",
            "task": "Should be forbidden",
        }

        resp = client.post(
            "/context/handoff",
            data=json.dumps(payload),
            headers=daemon_headers,
        )

        assert resp.status_code == 403


class TestJCWorkLog:
    def test_jc_work_log_returns_entries_when_table_exists(self, client, helper_headers):
        from db_utils import get_db

        db = get_db()
        db.execute(
            """
            CREATE TABLE IF NOT EXISTS jc_work_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                project TEXT,
                description TEXT,
                status TEXT,
                result TEXT,
                started_at TEXT,
                completed_at TEXT,
                duration_minutes INTEGER
            )
            """
        )
        db.execute(
            """
            INSERT INTO jc_work_log
            (project, description, status, result, started_at, completed_at, duration_minutes)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                "project-gamma",
                "Closed blocker",
                "done",
                "patched",
                "2026-04-02T10:00:00+00:00",
                "2026-04-02T10:15:00+00:00",
                15,
            ),
        )
        db.commit()
        db.close()

        resp = client.get("/context/jc-work-log", headers=helper_headers)

        assert resp.status_code == 200
        data = resp.get_json()
        assert data["total"] == 1
        assert data["entries"][0]["project"] == "project-gamma"
        assert data["entries"][0]["result"] == "patched"
