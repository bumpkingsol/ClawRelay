# Performance Regression Audit (2026-04-22)

## Scope

Audit focus was server-side read/write paths introduced or expanded by meeting intelligence work:

- `/context/meetings` read path
- participant profile retention purge path
- summary purge path
- cross-meeting pattern lookup path

## Measurement Environment

- Date: **2026-04-22**
- Runtime: Python 3 (stdlib only)
- DB: SQLite in-memory synthetic workloads
- Limitation: Flask is not installed in this container, so endpoint-level latency could not be measured directly.

## Measured Findings

### 1) `/context/meetings` likely regressed due to large payload reads

Current query selects full `transcript_json` for every row, only to compute `has_transcript`.

Synthetic benchmark (5,000 meetings; transcript payload ~16 KB each):

- Query selecting `transcript_json`: **~0.40590s** avg
- Query deriving `has_transcript` in SQL without selecting body: **~0.03380s** avg

Estimated impact in this synthetic setup: ~12x faster when transcript bodies are not fetched.

### 2) Participant profile retention currently does table scan

Retention filter uses `COALESCE(last_seen, last_updated) < ?`.

`EXPLAIN QUERY PLAN` currently shows:

- `SCAN participant_profiles`

Adding an expression index changes plan to:

- `SEARCH participant_profiles USING INDEX idx_profiles_last_activity (<expr><?)`

Observed timing change in-memory was small, but plan quality improves and should matter with disk-backed larger datasets.

### 3) Summary purge currently does table scan

`EXPLAIN QUERY PLAN` for summary purge update currently shows full scan:

- `SCAN meeting_sessions`

No index currently exists for `summary_purge_at`, even though raw purge already has one (`idx_meeting_purge` on `raw_data_purge_at`).

### 4) Cross-meeting participant pattern lookup is non-sargable

`meeting_processor.detect_patterns()` uses:

- `WHERE participants LIKE '%{name}%' ORDER BY started_at DESC LIMIT 10`

`EXPLAIN QUERY PLAN` under synthetic load shows full table scan + temp B-tree sort.

This path will degrade as `meeting_sessions` grows.

## Highest-Leverage Fixes (Prioritized)

1. **Stop selecting `transcript_json` in `/context/meetings`.**
   - Use `(transcript_json IS NOT NULL) AS has_transcript` in SQL and return that boolean.
   - Expected payoff: high latency and I/O reduction on UI polling path.

2. **Add index on `meeting_sessions(summary_purge_at)`.**
   - Aligns summary purge path with existing raw purge indexing.
   - Expected payoff: lower background purge cost as data grows.

3. **Add expression index for participant retention cutoff.**
   - `CREATE INDEX ... ON participant_profiles(COALESCE(last_seen, last_updated))`
   - Expected payoff: predictable retention runtime under growth.

4. **Normalize meeting participants into join table for pattern lookup.**
   - Add `meeting_participants(meeting_id, participant_name, started_at)` with indexes.
   - Replace wildcard `LIKE` scan with indexed lookup.
   - Expected payoff: major scalability improvement for pattern detection.

## Uncertainty & What to Measure Next

Because Flask was unavailable here, endpoint-level p50/p95/p99 latency and serialization overhead were not measured directly.

Next measurements to run in staging/production:

1. Endpoint tracing for `/context/meetings` and `/context/participants`:
   - p50/p95/p99 latency
   - SQL time vs JSON serialization time
   - payload size distribution
2. Purge job timing and rows touched per run:
   - wall-clock duration
   - lock contention / busy timeout occurrences
3. Pattern detection runtime by meeting count:
   - time spent in participant lookup query
   - number of scanned rows vs returned rows

## Repro Script

A synthetic benchmark script was added:

- `server/scripts/perf_audit_snapshot.py`

Run with:

```bash
python3 server/scripts/perf_audit_snapshot.py
```
