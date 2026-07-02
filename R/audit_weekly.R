# ok-hydromet-backup — WEEKLY audit & reconciliation.
# 1) Re-pull last 35 days of WSC realtime and upsert (catches late revisions).
# 2) Coverage audit: flag any day in the last 30 with zero realtime obs per instant series.
# 3) [STUB] provincial (BC Aquarius) comparison — enabled once credentials/ONA tee exist.
source("R/etl_common.R")

# Connect at top level (see etl_common.R / etl_daily.R re: bad_weak_ptr).
PG_ARGS <- pg_args()
con <- do.call(DBI::dbConnect, PG_ARGS)
cat("[db] connected\n")
ids <- dbGetQuery(con, "SELECT wsc_id FROM okhydromet.station
                        WHERE operator='WSC' AND wsc_id IS NOT NULL ORDER BY wsc_id")$wsc_id
run_id <- dbGetQuery(con, "INSERT INTO okhydromet.pull_run(source,started_ts,status)
                           VALUES('wsc-audit', now(), 'running') RETURNING run_id")$run_id

# 1) revision-catch re-pull
raw  <- geomet_realtime(ids, since = Sys.time() - 35 * 86400)
long <- if (nrow(raw)) reshape_obs(raw) else raw
upserted <- if (nrow(long)) upsert_wsc(con, long, run_id) else 0L

# 2) coverage audit -> audit_log + audit_discrepancy
audit_id <- dbGetQuery(con, "INSERT INTO okhydromet.audit_log(scope,notes)
  VALUES('weekly wsc coverage','realtime 30d gap scan') RETURNING audit_id")$audit_id
gaps <- dbExecute(con, "
  INSERT INTO okhydromet.audit_discrepancy(audit_id, series_uid, datetime_utc, kind, detected_ts)
  WITH days AS (SELECT generate_series((now()-interval '30 days')::date, now()::date, interval '1 day')::date d),
       ser  AS (SELECT series_uid FROM okhydromet.series WHERE interval='instant'),
       present AS (SELECT series_uid, datetime_utc::date d
                   FROM okhydromet.observation
                   WHERE source='wsc' AND datetime_utc > now()-interval '30 days'
                   GROUP BY 1,2)
  SELECT $1, s.series_uid, d.d::timestamptz, 'gap', now()
  FROM ser s CROSS JOIN days d
  LEFT JOIN present p ON p.series_uid=s.series_uid AND p.d=d.d
  WHERE p.series_uid IS NULL", params = list(audit_id))

dbExecute(con, "UPDATE okhydromet.audit_log SET stations_checked=$1, discrepancies=$2 WHERE audit_id=$3",
          params = list(length(ids), gaps, audit_id))
dbExecute(con, "UPDATE okhydromet.pull_run SET finished_ts=now(), rows_in=$1, status='ok' WHERE run_id=$2",
          params = list(upserted, run_id))
cat("[weekly] stations=", length(ids), " reupserted=", upserted,
    " coverage_gaps=", gaps, " audit_id=", audit_id, "\n")
