# Performance Remediation Plan (2026-04-22)

This plan translates the 2026-04-22 audit into concrete implementation work with acceptance criteria.

## Goals

1. Remove avoidable read amplification on helper-facing APIs.
2. Make retention/purge work predictable as tables grow.
3. Eliminate non-sargable participant history lookups.
4. Add production-grade measurements to detect regressions early.

## Workstream A — `/context/meetings` read-path optimization

### A1. Avoid loading full transcript bodies in meeting list

**Problem:** `/context/meetings` reads `transcript_json` only to derive `has_transcript`.

**Changes**
- Update `server/context-receiver.py` query in `get_meetings()`:
  - remove `transcript_json` from selected columns.
  - add `(transcript_json IS NOT NULL) AS has_transcript`.
- Use `r["has_transcript"]` for:
  - `has_transcript`
  - `purge_status` derivation.

**Acceptance criteria**
- API contract unchanged except internals (`has_transcript` and `purge_status` values preserved).
- Existing meeting-list tests pass.
- Synthetic benchmark shows lower SQL time for large meeting rows.

### A2. Add payload-size guardrail for future regressions

**Changes**
- Add a targeted test that inserts large `transcript_json` values and verifies list endpoint performance remains bounded by checking query shape (no direct transcript fetch).

**Acceptance criteria**
- Fails if `transcript_json` is reintroduced into meeting list SELECT.

---

## Workstream B — Retention and purge query scalability

### B1. Add index for summary purge

**Problem:** summary purge is currently a table scan.

**Changes**
- In `init_db()`, add:
  - `CREATE INDEX IF NOT EXISTS idx_meeting_summary_purge ON meeting_sessions(summary_purge_at)`.

**Acceptance criteria**
- Index exists on fresh and upgraded DBs.
- `EXPLAIN QUERY PLAN` for summary purge uses the index.

### B2. Add index for participant retention expression

**Problem:** retention uses `COALESCE(last_seen, last_updated)` and scans table.

**Changes**
- In `init_db()`, add expression index:
  - `CREATE INDEX IF NOT EXISTS idx_participant_last_activity ON participant_profiles(COALESCE(last_seen, last_updated))`.

**Acceptance criteria**
- Index exists on fresh and upgraded DBs.
- `EXPLAIN QUERY PLAN` for participant retention uses expression index.

### B3. Bound purge work per run (optional safety valve)

**Changes**
- If purge durations exceed budget in production, introduce chunked purge loops (`LIMIT` batches) to reduce lock duration.

**Acceptance criteria**
- No long write locks during purge windows.

---

## Workstream C — Participant lookup normalization for pattern detection

### C1. Introduce `meeting_participants` table

**Problem:** `LIKE '%name%'` in JSON/text participants field is non-sargable.

**Schema**
- New table:
  - `meeting_participants(meeting_id TEXT, participant_name TEXT, started_at TEXT)`
- Indexes:
  - `(participant_name, started_at DESC)`
  - `(meeting_id)`

### C2. Dual-write on ingest/update

**Changes**
- During meeting upsert (`/context/meeting/session` path), parse participants and upsert into `meeting_participants`.
- On meeting updates, clear+rebuild rows for that meeting id.

### C3. Migrate pattern detection query

**Changes**
- In `server/meeting_processor.py::detect_patterns()`, replace wildcard scan with indexed join via `meeting_participants`.

**Acceptance criteria**
- Functional parity of returned meeting set.
- Query plan avoids full-table scan on `meeting_sessions` for participant filtering.

---

## Workstream D — Measurement and regression detection

### D1. Add lightweight endpoint timing logs

**Changes**
- Instrument `/context/meetings`, `/context/participants`, and purge run sections with elapsed milliseconds and row counts.

**Acceptance criteria**
- Logs expose timing + cardinality fields required for p50/p95 rollups.

### D2. Add SQL plan smoke checks in tests

**Changes**
- Add unit-style checks around `EXPLAIN QUERY PLAN` for:
  - summary purge query
  - participant retention query
  - participant history lookup (post-normalization)

**Acceptance criteria**
- Tests fail on clear regressions to SCAN where indexed access is expected.

### D3. Ops runbook metrics

**Changes**
- Document exact commands for weekly checks:
  - endpoint p95
  - purge duration
  - DB file size growth
  - lock/busy timeout count

---

## Rollout Sequence (recommended)

1. **A1 + tests** (highest user-visible latency gain, low risk)
2. **B1 + B2** (small change set, low migration risk)
3. **D1** (observability before larger schema work)
4. **C1/C2/C3** (highest complexity, largest long-term gain)
5. **D2/D3** (guardrails and operationalization)

## Validation Commands

```bash
# Existing suites
pytest -q server/tests/test_meetings_list_endpoint.py
pytest -q server/tests/test_meeting_processor.py
pytest -q server/tests/test_participants_endpoint.py

# Synthetic snapshot benchmark
python3 server/scripts/perf_audit_snapshot.py
```

## Risks and Mitigations

- **Risk:** schema migration drift on existing deployments.
  - **Mitigation:** use `CREATE INDEX IF NOT EXISTS`; idempotent backfill steps.
- **Risk:** participant parsing edge cases during dual-write.
  - **Mitigation:** sanitize to string list and skip invalid entries.
- **Risk:** added logging noise.
  - **Mitigation:** structured one-line timing logs at INFO with concise fields.

## Definition of Done

- Meeting list path no longer fetches transcript body.
- Purge/retention queries use intended indexes.
- Pattern detection participant lookup no longer uses wildcard `LIKE` scans.
- Timing metrics available for endpoint and purge paths.
- Test coverage prevents regression of query shape/index usage.
