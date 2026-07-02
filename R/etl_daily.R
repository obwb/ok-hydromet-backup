# ok-hydromet-backup — DAILY incremental ETL (WSC realtime leg).
# Pulls the last ~3 days of realtime H/Q from GeoMet and upserts into Cloud SQL.
source("R/etl_common.R")

# Connect at top level — PG_ARGS (driver) must stay a live binding for the whole
# run, else RPostgres throws "bad_weak_ptr" on Linux (see etl_common.R).
PG_ARGS <- pg_args()
con <- do.call(DBI::dbConnect, PG_ARGS)
cat("[db] connected\n")
ids <- dbGetQuery(con, "SELECT wsc_id FROM okhydromet.station
                        WHERE operator='WSC' AND wsc_id IS NOT NULL ORDER BY wsc_id")$wsc_id
run_id <- dbGetQuery(con, "INSERT INTO okhydromet.pull_run(source,started_ts,status)
                           VALUES('wsc-daily', now(), 'running') RETURNING run_id")$run_id

raw  <- geomet_realtime(ids, since = Sys.time() - 3 * 86400)
long <- if (nrow(raw)) reshape_obs(raw) else raw
n    <- if (nrow(long)) upsert_wsc(con, long, run_id) else 0L

dbExecute(con, "UPDATE okhydromet.pull_run SET finished_ts=now(), rows_in=$1, status='ok'
                WHERE run_id=$2", params = list(n, run_id))
cat("[daily] stations=", length(ids), " upserted_obs=", n, " run_id=", run_id, "\n")
