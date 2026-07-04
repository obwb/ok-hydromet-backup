-- ok-hydromet-backup migration: enable the BC groundwater (SGWL / PGOWN) leg.
-- Run once against the okhydromet DB BEFORE the first MODE=gw load.
-- Idempotent + transactional: safe to re-run.
--
-- 1. series.parameter CHECK must allow 'GW' (was Q/H/Tw/COND/OTHER; inline unnamed
--    CHECK is auto-named series_parameter_check by Postgres).
-- 2. grade_code lookup must include codes '1' and '2' — present in real well data
--    (e.g. OW035, OW180) but absent from the seeded Aquarius legend, so the
--    observation.grade_code FK would reject those rows otherwise.
-- 3. approval_level: add 'reviewed' (AQUARIUS 950) defensively. Not seen in the
--    current GW pull (only 800/900/1200), but appr_map() emits it, so seed it so a
--    future REVIEWED point can never break the observation.approval_level FK.

BEGIN;

SET LOCAL search_path TO okhydromet, public;

-- 1. widen series.parameter to include groundwater level ('GW')
ALTER TABLE okhydromet.series DROP CONSTRAINT IF EXISTS series_parameter_check;
ALTER TABLE okhydromet.series
  ADD CONSTRAINT series_parameter_check
  CHECK (parameter IN ('Q','H','Tw','COND','GW','OTHER'));

-- 2. grade codes seen in groundwater data but missing from the seeded legend
INSERT INTO okhydromet.grade_code (grade_code, authority, label, description) VALUES
  ('1','aquarius','GRADE 1','Numeric grade 1 (not in the published Aquarius legend)'),
  ('2','aquarius','GRADE 2','Numeric grade 2 (not in the published Aquarius legend)')
ON CONFLICT (grade_code) DO NOTHING;

-- 3. defensive: 'reviewed' approval level (AQUARIUS 950)
INSERT INTO okhydromet.approval_level (approval_level, rank, description) VALUES
  ('reviewed', 25, 'QAQC reviewed (AQUARIUS 950), not yet final/approved')
ON CONFLICT (approval_level) DO NOTHING;

COMMIT;
