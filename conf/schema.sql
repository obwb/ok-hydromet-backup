-- ok-hydromet-backup — PostgreSQL + PostGIS schema
-- Canonical sovereign backup of Okanagan hydrometric data (ONA + WSC + BC provincial).
-- Target: Cloud SQL for PostgreSQL 16, region northamerica-northeast1 (Montréal).
-- Captures values (Q/H/Tw) + full QAQC/grade lineage + rating lineage + station metadata + provenance.
--
-- Apply:  psql "$OKHYDROMET_URL" -f conf/schema.sql
-- Idempotent: safe to re-run.

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_trgm;   -- fuzzy/text search on station names & notes

CREATE SCHEMA IF NOT EXISTS okhydromet;
SET search_path = okhydromet, public;

-- ─────────────────────────────────────────────────────────────────────────────
-- Lookup / controlled vocabularies (decode authority codes)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS grade_code (
  grade_code   text PRIMARY KEY,              -- e.g. Aquarius A/B/C/E, or numeric grade
  authority    text NOT NULL,                 -- 'aquarius' | 'wsc'
  label        text,
  description  text
);

CREATE TABLE IF NOT EXISTS approval_level (
  approval_level text PRIMARY KEY,            -- 'working' | 'in_review' | 'approved' | 'unspecified'
  rank          int  NOT NULL,                -- precedence for reconciliation (higher = more authoritative)
  description   text
);

CREATE TABLE IF NOT EXISTS qualifier_code (
  qualifier_code text PRIMARY KEY,            -- WSC symbols: E,A,B,D,R,...  / Aquarius qualifiers
  authority      text NOT NULL,
  label          text,
  description    text
);

-- ─────────────────────────────────────────────────────────────────────────────
-- Stations (one row per physical gauge) — ID cross-walk + metadata
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS station (
  station_uid       text PRIMARY KEY,         -- our stable surrogate id
  wsc_id            text UNIQUE,              -- e.g. 08NM050
  bc_aquarius_loc_id text UNIQUE,             -- BC Aquarius location identifier
  ona_id            text,                     -- ONA internal id (if any)
  name              text NOT NULL,
  operator          text NOT NULL CHECK (operator IN ('ONA','WSC','BC','OTHER')),
  status            text CHECK (status IN ('active','discontinued','seasonal','unknown')),
  station_type      text,                     -- stream/lake/diversion/etc
  geom              geometry(Point,4326),
  lat               double precision,
  lon               double precision,
  elevation_m       double precision,
  gauge_datum       text,
  datum_notes       text,
  drainage_area_km2 double precision,
  regulation_status text CHECK (regulation_status IN ('natural','regulated','unknown')),
  basin             text,
  install_date      date,
  discontinue_date  date,
  telemetry_type    text,                     -- 'goes' | 'cellular' | 'manual' | ...
  goes_dcp_id       text,                     -- NESID for back-door B (GOES DCS decode)
  notes             text
);
CREATE INDEX IF NOT EXISTS station_geom_gix ON station USING gist (geom);
CREATE INDEX IF NOT EXISTS station_name_trgm ON station USING gin (name gin_trgm_ops);

-- ─────────────────────────────────────────────────────────────────────────────
-- Series (station × parameter × interval)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS series (
  series_uid          text PRIMARY KEY,
  station_uid         text NOT NULL REFERENCES station(station_uid),
  parameter           text NOT NULL CHECK (parameter IN ('Q','H','Tw','COND','OTHER')),  -- flow, stage, water temp, conductivity
  units               text NOT NULL,          -- m3/s, m, degC, uS/cm
  interval            text NOT NULL CHECK (interval IN ('instant','hourly','daily')),
  method              text,
  sensor_model        text,
  sensor_install_date date,
  time_zone           text DEFAULT 'UTC',
  source_series_id    text,                    -- upstream Aquarius/WSC series identifier
  UNIQUE (station_uid, parameter, interval, source_series_id)
);
CREATE INDEX IF NOT EXISTS series_station_ix ON series (station_uid);

-- ─────────────────────────────────────────────────────────────────────────────
-- Observations — append-only, every authority's version side-by-side
-- Partitioned by year on datetime_utc.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS observation (
  series_uid     text NOT NULL REFERENCES series(series_uid),
  datetime_utc   timestamptz NOT NULL,
  value          double precision,
  grade_code     text REFERENCES grade_code(grade_code),
  approval_level text REFERENCES approval_level(approval_level),
  qualifier_flags text[],
  estimate_flag  boolean DEFAULT false,
  ice_flag       boolean DEFAULT false,
  source         text NOT NULL CHECK (source IN ('wsc','bc','ona','goes')),
  pull_run_id    bigint,
  ingest_ts      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (series_uid, datetime_utc, source)
) PARTITION BY RANGE (datetime_utc);

-- Example partitions (extend via maintenance job / ETL). A DEFAULT partition catches the rest.
CREATE TABLE IF NOT EXISTS observation_default PARTITION OF observation DEFAULT;
-- e.g. CREATE TABLE observation_2025 PARTITION OF observation
--        FOR VALUES FROM ('2025-01-01Z') TO ('2026-01-01Z');

CREATE INDEX IF NOT EXISTS observation_series_time_ix ON observation (series_uid, datetime_utc);

-- Canonical de-duplicated authoritative series (approved > provisional; ONA-direct vs BC reconciled)
CREATE TABLE IF NOT EXISTS observation_canonical (
  series_uid          text NOT NULL REFERENCES series(series_uid),
  datetime_utc        timestamptz NOT NULL,
  value               double precision,
  grade_code          text REFERENCES grade_code(grade_code),
  approval_level      text REFERENCES approval_level(approval_level),
  authoritative_source text NOT NULL,
  last_reconciled_ts  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (series_uid, datetime_utc)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- QAQC lineage
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS correction_history (
  correction_id   bigserial PRIMARY KEY,
  series_uid      text NOT NULL REFERENCES series(series_uid),
  applied_from    timestamptz,
  applied_to      timestamptz,
  correction_type text,                       -- datum/drift/spike/gap/etc
  description     text,
  applied_by      text,
  applied_ts      timestamptz
);
CREATE INDEX IF NOT EXISTS correction_series_ix ON correction_history (series_uid);

-- ─────────────────────────────────────────────────────────────────────────────
-- Rating lineage (discharge Q derived from stage H)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS rating_curve (
  rating_uid     text PRIMARY KEY,
  station_uid    text NOT NULL REFERENCES station(station_uid),
  rating_version text,
  effective_from timestamptz,
  effective_to   timestamptz,
  equation_params jsonb,
  "offset"       double precision,
  notes          text
);
CREATE INDEX IF NOT EXISTS rating_station_ix ON rating_curve (station_uid);

CREATE TABLE IF NOT EXISTS discharge_measurement (
  measurement_uid     text PRIMARY KEY,
  station_uid         text NOT NULL REFERENCES station(station_uid),
  datetime_utc        timestamptz NOT NULL,
  measured_q          double precision,
  stage_h             double precision,
  method              text,
  party               text,
  quality             text,
  rating_deviation_pct double precision
);
CREATE INDEX IF NOT EXISTS measurement_station_ix ON discharge_measurement (station_uid);

-- ─────────────────────────────────────────────────────────────────────────────
-- Provenance & audit
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS pull_run (
  run_id      bigserial PRIMARY KEY,
  source      text NOT NULL,                  -- wsc/bc/ona/goes
  started_ts  timestamptz NOT NULL DEFAULT now(),
  finished_ts timestamptz,
  rows_in     bigint,
  status      text CHECK (status IN ('running','ok','partial','error')),
  error       text
);

CREATE TABLE IF NOT EXISTS audit_log (
  audit_id    bigserial PRIMARY KEY,
  run_ts      timestamptz NOT NULL DEFAULT now(),
  scope       text,                           -- weekly reconcile vs provincial
  stations_checked int,
  discrepancies   int,
  notes       text
);

CREATE TABLE IF NOT EXISTS audit_discrepancy (
  discrepancy_id bigserial PRIMARY KEY,
  audit_id    bigint REFERENCES audit_log(audit_id),
  series_uid  text REFERENCES series(series_uid),
  datetime_utc timestamptz,
  kind        text,                           -- 'gap' | 'value_mismatch' | 'grade_change'
  ours        double precision,
  theirs      double precision,
  action_taken text,                          -- 'backfilled' | 'updated' | 'flagged'
  detected_ts timestamptz NOT NULL DEFAULT now()
);

-- ─────────────────────────────────────────────────────────────────────────────
-- Seed controlled vocabularies (minimal; extend in ETL)
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO approval_level (approval_level, rank, description) VALUES
  ('approved',   30, 'QAQC complete, published as final/approved'),
  ('in_review',  20, 'Under QAQC review'),
  ('working',    10, 'Raw/provisional, no QAQC'),
  ('unspecified', 0, 'Source did not specify')
ON CONFLICT (approval_level) DO NOTHING;

INSERT INTO qualifier_code (qualifier_code, authority, label, description) VALUES
  ('E','wsc','estimate','Estimated value'),
  ('A','wsc','partial','Partial day'),
  ('B','wsc','ice','Ice conditions / backwater'),
  ('D','wsc','dry','Dry'),
  ('R','wsc','revised','Revised')
ON CONFLICT (qualifier_code) DO NOTHING;

-- AQUARIUS grade codes (BC provincial export legend)
INSERT INTO grade_code (grade_code, authority, label, description) VALUES
  ('-3','aquarius','GAP','Gap'),('-2','aquarius','UNUSABLE','Unusable'),
  ('-1','aquarius','UNSPECIFIED','Unspecified'),('0','aquarius','UNDEF','Undefined'),
  ('11','aquarius','POOR','Poor'),('21','aquarius','ESTIMATED','Estimated'),
  ('25','aquarius','BEST PRACTICE','Best practice'),('31','aquarius','GOOD','Good'),
  ('41','aquarius','VERYGOOD','Very good'),('51','aquarius','EXCELLENT','Excellent'),
  ('100','aquarius','RISC U','RISC unknown'),('121','aquarius','RISC E','RISC estimated'),
  ('125','aquarius','RISC BP','RISC best practice'),('131','aquarius','RISC C','RISC C'),
  ('141','aquarius','RISC B','RISC B'),('151','aquarius','RISC A','RISC A'),
  ('161','aquarius','RISC A/RS','RISC A rated structure')
ON CONFLICT (grade_code) DO NOTHING;
