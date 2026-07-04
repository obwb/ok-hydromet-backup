-- ok-hydromet-backup migration: dashboard performance after the groundwater backfill.
-- Context: the GW backfill roughly doubled okhydromet.observation (2.8M -> 6.5M rows),
-- which pushed the dashboard's full-table aggregates past the read role's 30s
-- statement_timeout (60-day ingest histogram ~35s, coverage-by-parameter ~34s) -> the
-- queries were killed and every DB-driven widget went blank.
--
-- Fix: an index on ingest_ts (the "observations ingested — last 60 days" chart filters on
-- it) plus a one-time VACUUM ANALYZE (fresh stats + visibility map so the per-series counts
-- use index-only scans). After this: count(*) ~2s, histogram ~8s, coverage ~15s — all under
-- the 30s ceiling, so the timeout stays at its safe 30s (not weakened).
--
-- Idempotent. Run once. (Applied to prod 2026-07-04.)

-- index on ingest_ts (parent table -> propagates to partitions)
CREATE INDEX IF NOT EXISTS observation_ingest_ix ON okhydromet.observation (ingest_ts);

-- refresh planner stats + visibility map after the bulk load (cannot run in a txn block)
VACUUM (ANALYZE) okhydromet.observation;
