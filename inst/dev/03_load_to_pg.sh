#!/usr/bin/env bash
# ok-hydromet-backup — load local DuckDB (WSC first cut + HYDAT backfill) into Cloud SQL.
# Exports station/series/observation/pull_run from DuckDB to CSV (UTC), then \copy into Postgres.
#   bash inst/dev/03_load_to_pg.sh
set -euo pipefail
export PATH="/opt/homebrew/opt/libpq/bin:$PATH"

PROJECT="${PROJECT:-okanagan-hydrology-project}"
INSTIP="${INSTIP:-$(gcloud sql instances describe okhydromet-pg --project=$PROJECT --format='value(ipAddresses[0].ipAddress)')}"
PW="$(gcloud secrets versions access latest --secret=okhydromet-db-pw --project=$PROJECT)"
CONN="host=$INSTIP port=5432 dbname=okhydromet user=okhydromet_app sslmode=require"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "== export DuckDB -> CSV (UTC) =="
Rscript -e '
suppressMessages({library(duckdb);library(DBI)})
con <- dbConnect(duckdb::duckdb(), "data/okhydromet.duckdb")
d <- commandArgs(TRUE)[1]
dbExecute(con, sprintf("COPY (SELECT station_uid,wsc_id,bc_aquarius_loc_id,ona_id,name,operator,status,lat,lon,drainage_area_km2,regulation_status,basin,telemetry_type,goes_dcp_id FROM hy.station) TO \047%s/station.csv\047 (HEADER,DELIMITER \047,\047)", d))
dbExecute(con, sprintf("COPY (SELECT series_uid,station_uid,parameter,units,interval,source_series_id FROM hy.series) TO \047%s/series.csv\047 (HEADER,DELIMITER \047,\047)", d))
dbExecute(con, sprintf("COPY (SELECT run_id,source,started_ts,finished_ts,rows_in,status,error FROM hy.pull_run) TO \047%s/pull_run.csv\047 (HEADER,DELIMITER \047,\047)", d))
dbExecute(con, sprintf("COPY (SELECT series_uid, CAST(datetime_utc AS VARCHAR) AS datetime_utc, value, grade_code, approval_level, qualifier_flags, source, pull_run_id FROM hy.observation) TO \047%s/observation.csv\047 (HEADER,DELIMITER \047,\047)", d))
dbDisconnect(con, shutdown=TRUE)
' "$TMP"
wc -l "$TMP"/*.csv

echo "== load into Postgres =="
PGPASSWORD="$PW" psql "$CONN" -v ON_ERROR_STOP=1 -q <<SQL
SET timezone='UTC';
-- metadata + lookups first (FKs)
\copy okhydromet.pull_run (run_id,source,started_ts,finished_ts,rows_in,status,error) FROM '$TMP/pull_run.csv' CSV HEADER
\copy okhydromet.station (station_uid,wsc_id,bc_aquarius_loc_id,ona_id,name,operator,status,lat,lon,drainage_area_km2,regulation_status,basin,telemetry_type,goes_dcp_id) FROM '$TMP/station.csv' CSV HEADER
UPDATE okhydromet.station SET geom = ST_SetSRID(ST_MakePoint(lon,lat),4326) WHERE lon IS NOT NULL AND geom IS NULL;
\copy okhydromet.series (series_uid,station_uid,parameter,units,interval,source_series_id) FROM '$TMP/series.csv' CSV HEADER
-- observations via staging (qualifier_flags text -> text[])
CREATE TEMP TABLE obs_stage (series_uid text, datetime_utc timestamptz, value double precision,
  grade_code text, approval_level text, qualifier_flags text, source text, pull_run_id bigint);
\copy obs_stage FROM '$TMP/observation.csv' CSV HEADER
INSERT INTO okhydromet.observation
  (series_uid,datetime_utc,value,grade_code,approval_level,qualifier_flags,source,pull_run_id)
SELECT series_uid,datetime_utc,value,
  NULLIF(grade_code,'') ,
  NULLIF(approval_level,''),
  CASE WHEN qualifier_flags IS NULL OR qualifier_flags='' THEN NULL ELSE ARRAY[qualifier_flags] END,
  source, pull_run_id
FROM obs_stage
ON CONFLICT DO NOTHING;
-- advance serial sequences past bulk-loaded explicit ids (else new INSERTs collide)
SELECT setval(pg_get_serial_sequence('okhydromet.pull_run','run_id'),
              COALESCE((SELECT max(run_id) FROM okhydromet.pull_run),1));
SQL

echo "== verify =="
PGPASSWORD="$PW" psql "$CONN" -c "SELECT
  (SELECT count(*) FROM okhydromet.station)  AS stations,
  (SELECT count(*) FROM okhydromet.series)   AS series,
  (SELECT count(*) FROM okhydromet.observation) AS observations;"
PGPASSWORD="$PW" psql "$CONN" -c "SELECT s.parameter, s.interval, count(*) obs,
  min(datetime_utc)::date AS from_dt, max(datetime_utc)::date AS to_dt
  FROM okhydromet.observation o JOIN okhydromet.series s USING(series_uid)
  GROUP BY 1,2 ORDER BY 1,2;"
