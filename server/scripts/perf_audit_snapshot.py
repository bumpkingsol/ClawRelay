#!/usr/bin/env python3
"""Quick synthetic performance snapshot for ClawRelay server paths.

This script is intentionally dependency-light (stdlib only) so it can run in
restricted environments.
"""

import json
import sqlite3
import time


def bench(cursor, query, args=(), n=20):
    start = time.perf_counter()
    for _ in range(n):
        cursor.execute(query, args).fetchall()
    return (time.perf_counter() - start) / n


def main():
    con = sqlite3.connect(":memory:")
    cur = con.cursor()

    cur.execute(
        """
        CREATE TABLE meeting_sessions (
            id TEXT PRIMARY KEY,
            started_at TEXT,
            ended_at TEXT,
            duration_seconds INTEGER,
            app TEXT,
            participants TEXT,
            transcript_json TEXT,
            summary_md TEXT,
            processing_status TEXT,
            frames_expected INTEGER,
            frames_uploaded INTEGER,
            raw_data_purge_at TEXT,
            summary_purge_at TEXT
        )
    """
    )
    cur.execute("CREATE INDEX idx_meeting_started ON meeting_sessions(started_at)")
    cur.execute("CREATE INDEX idx_meeting_purge ON meeting_sessions(raw_data_purge_at)")

    cur.execute(
        """
        CREATE TABLE participant_profiles (
            id TEXT PRIMARY KEY,
            display_name TEXT,
            meetings_observed INTEGER,
            profile_json TEXT,
            last_updated TEXT,
            last_seen TEXT
        )
    """
    )

    participants = json.dumps(["Alice", "Bob"])
    transcript = json.dumps([{"t": i, "text": "x" * 200} for i in range(80)])

    cur.executemany(
        """
        INSERT INTO meeting_sessions
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """,
        [
            (
                f"m{i}",
                f"2026-04-{(i % 28) + 1:02d}T12:00:00+00:00",
                None,
                1800,
                "Zoom",
                participants,
                transcript,
                "summary",
                "done",
                20,
                20,
                "2026-04-20T00:00:00Z",
                "2026-04-20T00:00:00Z",
            )
            for i in range(5000)
        ],
    )

    cur.executemany(
        "INSERT INTO participant_profiles VALUES (?, ?, ?, ?, ?, ?)",
        [
            (
                f"p{i}",
                f"Person {i}",
                i % 8,
                "{}",
                "2026-04-01T00:00:00Z",
                "2026-04-01T00:00:00Z" if i % 2 == 0 else None,
            )
            for i in range(100000)
        ],
    )
    con.commit()

    cutoff = "2026-03-25T00:00:00+00:00"
    with_transcript = """
        SELECT id, started_at, ended_at, duration_seconds, app,
               participants, summary_md, transcript_json,
               processing_status, frames_expected, frames_uploaded
        FROM meeting_sessions
        WHERE started_at >= ?
        ORDER BY started_at DESC
    """
    without_transcript = """
        SELECT id, started_at, ended_at, duration_seconds, app,
               participants, summary_md,
               processing_status, frames_expected, frames_uploaded,
               (transcript_json IS NOT NULL) AS has_transcript
        FROM meeting_sessions
        WHERE started_at >= ?
        ORDER BY started_at DESC
    """

    profile_retention = """
        SELECT COUNT(*)
        FROM participant_profiles
        WHERE COALESCE(last_seen, last_updated) IS NOT NULL
          AND COALESCE(last_seen, last_updated) < ?
    """

    summary_purge = """
        UPDATE meeting_sessions
        SET summary_md = NULL
        WHERE summary_purge_at IS NOT NULL
          AND summary_purge_at < ?
          AND summary_md IS NOT NULL
    """

    print("=== Query timings (seconds, lower is better) ===")
    print(f"meetings_query_with_transcript: {bench(cur, with_transcript, (cutoff,)):0.5f}")
    print(
        f"meetings_query_without_transcript: {bench(cur, without_transcript, (cutoff,)):0.5f}"
    )
    print(
        f"participant_profile_retention_scan: {bench(cur, profile_retention, ('2026-04-15T00:00:00Z',), n=10):0.5f}"
    )

    print("\n=== Query plans ===")
    print(
        "participant_profile_retention:",
        cur.execute(
            "EXPLAIN QUERY PLAN " + profile_retention,
            ("2026-04-15T00:00:00Z",),
        ).fetchall(),
    )
    print(
        "summary_purge:",
        cur.execute(
            "EXPLAIN QUERY PLAN " + summary_purge,
            ("2026-04-25T00:00:00Z",),
        ).fetchall(),
    )


if __name__ == "__main__":
    main()
