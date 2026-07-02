#!/usr/bin/env Rscript
# ok-hydromet-backup — HYDAT full-history backfill (WSC leg)
# Loads the entire period-of-record daily discharge (Q) and daily level (H) for the
# 30 Okanagan (08NM) WSC stations from the local HYDAT SQLite into the project DuckDB.
# These are APPROVED/final daily means, stored as interval='daily' (distinct from the
# realtime interval='instant' series produced by R/firstcut_wsc.R).
#
# Run from project root:  Rscript R/backfill_hydat.R
suppressMessages({library(tidyhydat); library(dplyr); library(duckdb); library(DBI)})

DB <- "data/okhydromet.duckdb"
stopifnot(file.exists(DB))
con <- dbConnect(duckdb::duckdb(), DB)
on.exit(dbDisconnect(con, shutdown = TRUE))

stn <- read.csv("data-raw/wsc_okanagan_stations.csv", stringsAsFactors = FALSE)
ids <- stn$wsc_id

run_id  <- dbGetQuery(con, "SELECT nextval('hy.seq_run') AS r")$r[1]
started <- Sys.time()
dbExecute(con, "INSERT INTO hy.pull_run(run_id,source,started_ts,status) VALUES(?,?,?,?)",
          params = list(run_id, "wsc-hydat", format(started, "%Y-%m-%d %H:%M:%S"), "running"))

# ── enrich station metadata from HYDAT (drainage area, real coords, type) ────
dbExecute(con, "ALTER TABLE hy.station ADD COLUMN IF NOT EXISTS drainage_area_km2 DOUBLE")
dbExecute(con, "ALTER TABLE hy.station ADD COLUMN IF NOT EXISTS regulation_status TEXT")
meta <- suppressMessages(hy_stations(station_number = ids)) |>
  left_join(suppressMessages(hy_stn_regulation(station_number = ids)), by = "STATION_NUMBER")
for (i in seq_len(nrow(meta))) {
  dbExecute(con, "UPDATE hy.station SET drainage_area_km2=?, regulation_status=?,
    lat=COALESCE(?,lat), lon=COALESCE(?,lon) WHERE wsc_id=?",
    params = list(meta$DRAINAGE_AREA_GROSS[i],
                  if (isTRUE(meta$REGULATED[i])) "regulated" else if (!is.na(meta$REGULATED[i])) "natural" else NA,
                  meta$LATITUDE[i], meta$LONGITUDE[i], meta$STATION_NUMBER[i]))
}
message("Station metadata enriched: ", nrow(meta))

# ── pull full-history daily Q and H ──────────────────────────────────────────
message("Reading HYDAT daily flows + levels for ", length(ids), " stations ...")
q  <- suppressMessages(hy_daily_flows(station_number = ids))
h  <- suppressMessages(hy_daily_levels(station_number = ids))
message("  daily flow rows: ", nrow(q), " | daily level rows: ", nrow(h))

mk <- function(df, param, units) {
  df |> filter(!is.na(Value)) |>
    transmute(
      series_uid  = paste0("WSC-", STATION_NUMBER, "-", param, "-daily"),
      station_uid = paste0("WSC-", STATION_NUMBER),
      parameter   = param, units = units,
      datetime_utc = as.POSIXct(as.character(Date), tz = "UTC"),
      value = Value, qualifier_flags = as.character(Symbol))
}
long <- bind_rows(mk(q, "Q", "m3/s"), mk(h, "H", "m"))

# series (daily)
ser <- long |> distinct(series_uid, station_uid, parameter, units) |>
  mutate(interval = "daily", source_series_id = paste0(station_uid, ":", parameter, ":daily"))
dbExecute(con, "DELETE FROM hy.series WHERE series_uid LIKE 'WSC-%-daily'")
dbAppendTable(con, SQL("hy.series"),
  ser[, c("series_uid","station_uid","parameter","units","interval","source_series_id")])
message("Daily series loaded: ", nrow(ser))

# observations (approved daily means)
obs <- long |> transmute(series_uid, datetime_utc, value,
  grade_code = NA_character_, approval_level = "approved",
  qualifier_flags, source = "wsc", pull_run_id = run_id, ingest_ts = Sys.time())
dbExecute(con, "DELETE FROM hy.observation WHERE source='wsc' AND series_uid LIKE 'WSC-%-daily'")
dbAppendTable(con, SQL("hy.observation"), obs)
message("Daily observations loaded: ", nrow(obs))

dbExecute(con, "UPDATE hy.pull_run SET finished_ts=?, rows_in=?, status='ok' WHERE run_id=?",
          params = list(format(Sys.time(), "%Y-%m-%d %H:%M:%S"), nrow(obs), run_id))

# ── summary ──────────────────────────────────────────────────────────────────
cat("\n============ HYDAT BACKFILL SUMMARY (WSC / Okanagan 08NM) ============\n")
print(dbGetQuery(con, 'SELECT s.parameter, s.interval, COUNT(*) obs,
  COUNT(DISTINCT o.series_uid) n_series,
  CAST(MIN(datetime_utc) AS TIMESTAMP)::DATE AS "from",
  CAST(MAX(datetime_utc) AS TIMESTAMP)::DATE AS "to"
  FROM hy.observation o JOIN hy.series s USING(series_uid)
  GROUP BY s.parameter, s.interval ORDER BY s.parameter, s.interval'))
cat("\nLongest records (earliest start):\n")
print(dbGetQuery(con, 'SELECT o.series_uid,
  CAST(MIN(datetime_utc) AS TIMESTAMP)::DATE AS "from",
  CAST(MAX(datetime_utc) AS TIMESTAMP)::DATE AS "to"
  FROM hy.observation o JOIN hy.series s USING(series_uid)
  WHERE s.interval=''daily'' GROUP BY o.series_uid ORDER BY "from" LIMIT 8'))
cat("=====================================================================\n")
