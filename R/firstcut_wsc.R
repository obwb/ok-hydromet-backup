#!/usr/bin/env Rscript
# ok-hydromet-backup — FIRST CUT (WSC leg)
# Scrape Okanagan (08NM) WSC realtime hydrometric data (water level H, discharge Q)
# from the ECCC GeoMet OGC API and populate a local DuckDB built on the project schema.
# (BC provincial Aquarius leg is auth-gated — see docs/ACCESS_NOTES.md.)
#
# Run from project root:  Rscript R/firstcut_wsc.R
suppressMessages({library(httr2); library(jsonlite); library(dplyr); library(duckdb); library(DBI)})

DB <- "data/okhydromet.duckdb"
dir.create("data", showWarnings = FALSE)
API <- "https://api.weather.gc.ca/collections/hydrometric-realtime/items"

con <- dbConnect(duckdb::duckdb(), DB)
on.exit(dbDisconnect(con, shutdown = TRUE))

# ── schema (DuckDB-compatible subset of conf/schema.sql) ─────────────────────
dbExecute(con, "CREATE SCHEMA IF NOT EXISTS hy")
dbExecute(con, "CREATE TABLE IF NOT EXISTS hy.station (
  station_uid TEXT PRIMARY KEY, wsc_id TEXT, bc_aquarius_loc_id TEXT, ona_id TEXT,
  name TEXT, operator TEXT, status TEXT, lat DOUBLE, lon DOUBLE, basin TEXT,
  telemetry_type TEXT, goes_dcp_id TEXT)")
dbExecute(con, "CREATE TABLE IF NOT EXISTS hy.series (
  series_uid TEXT PRIMARY KEY, station_uid TEXT, parameter TEXT, units TEXT,
  interval TEXT, source_series_id TEXT)")
dbExecute(con, "CREATE TABLE IF NOT EXISTS hy.observation (
  series_uid TEXT, datetime_utc TIMESTAMPTZ, value DOUBLE, grade_code TEXT,
  approval_level TEXT, qualifier_flags TEXT, source TEXT, pull_run_id BIGINT,
  ingest_ts TIMESTAMPTZ DEFAULT now())")
dbExecute(con, "CREATE SEQUENCE IF NOT EXISTS hy.seq_run START 1")
dbExecute(con, "CREATE TABLE IF NOT EXISTS hy.pull_run (
  run_id BIGINT, source TEXT, started_ts TIMESTAMPTZ, finished_ts TIMESTAMPTZ,
  rows_in BIGINT, status TEXT, error TEXT)")

run_id  <- dbGetQuery(con, "SELECT nextval('hy.seq_run') AS r")$r[1]
started <- Sys.time()
dbExecute(con, "INSERT INTO hy.pull_run(run_id,source,started_ts,status) VALUES(?,?,?,?)",
          params = list(run_id, "wsc", format(started, "%Y-%m-%d %H:%M:%S"), "running"))

# ── stations (from seed produced by R/pull_wsc_stations.R) ───────────────────
stn <- read.csv("data-raw/wsc_okanagan_stations.csv", stringsAsFactors = FALSE)
dbExecute(con, "DELETE FROM hy.station WHERE operator='WSC'")
dbAppendTable(con, SQL("hy.station"),
  stn[, c("station_uid","wsc_id","bc_aquarius_loc_id","ona_id","name","operator",
          "status","lat","lon","basin","telemetry_type","goes_dcp_id")])
message("Stations loaded: ", nrow(stn))

# ── fetch realtime items for one station (paginated) ─────────────────────────
fetch_station <- function(sn) {
  offset <- 0L; lim <- 10000L; out <- list()
  repeat {
    resp <- request(API) |>
      req_url_query(STATION_NUMBER = sn, limit = lim, offset = offset, f = "json") |>
      req_retry(max_tries = 3) |> req_timeout(60) |> req_perform()
    fc <- resp_body_json(resp, simplifyVector = FALSE)
    n <- length(fc$features); if (n == 0) break
    out[[length(out) + 1L]] <- fc$features
    if (n < lim) break
    offset <- offset + lim
  }
  feats <- do.call(c, out)
  if (length(feats) == 0) return(NULL)
  p <- lapply(feats, `[[`, "properties")
  gv <- function(k) vapply(p, function(x) { v <- x[[k]]; if (is.null(v)) NA else v }, numeric(1))
  gc <- function(k) vapply(p, function(x) { v <- x[[k]]; if (is.null(v)) NA_character_ else as.character(v) }, character(1))
  tibble(STATION_NUMBER = sn,
         DATETIME = gc("DATETIME"),
         LEVEL = gv("LEVEL"), DISCHARGE = gv("DISCHARGE"),
         LEVEL_SYM = gc("LEVEL_SYMBOL_EN"), DISCHARGE_SYM = gc("DISCHARGE_SYMBOL_EN"))
}

message("Fetching realtime for ", nrow(stn), " stations from GeoMet OGC API ...")
raw <- lapply(stn$wsc_id, function(sn) { r <- tryCatch(fetch_station(sn), error = function(e) NULL)
  message(sprintf("  %s: %s rows", sn, if (is.null(r)) 0 else nrow(r))); r })
raw <- bind_rows(raw)

# ── reshape LEVEL/DISCHARGE -> long observations (H / Q) ──────────────────────
to_obs <- function(df, col, sym, param, units) {
  df |> filter(!is.na(.data[[col]])) |>
    transmute(series_uid = paste0("WSC-", STATION_NUMBER, "-", param, "-instant"),
              station_uid = paste0("WSC-", STATION_NUMBER),
              parameter = param, units = units,
              datetime_utc = as.POSIXct(DATETIME, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
              value = .data[[col]], qualifier_flags = .data[[sym]])
}
long <- bind_rows(
  to_obs(raw, "LEVEL", "LEVEL_SYM", "H", "m"),
  to_obs(raw, "DISCHARGE", "DISCHARGE_SYM", "Q", "m3/s"))

# series
ser <- long |> distinct(series_uid, station_uid, parameter, units) |>
  mutate(interval = "instant", source_series_id = paste0(station_uid, ":", parameter))
dbExecute(con, "DELETE FROM hy.series WHERE station_uid LIKE 'WSC-%'")
dbAppendTable(con, SQL("hy.series"),
  ser[, c("series_uid","station_uid","parameter","units","interval","source_series_id")])
message("Series loaded: ", nrow(ser))

# observations
obs <- long |> transmute(series_uid, datetime_utc, value,
  grade_code = NA_character_, approval_level = "working",
  qualifier_flags, source = "wsc", pull_run_id = run_id, ingest_ts = Sys.time())
dbExecute(con, "DELETE FROM hy.observation WHERE source='wsc'")
dbAppendTable(con, SQL("hy.observation"), obs)
message("Observations loaded: ", nrow(obs))

dbExecute(con, "UPDATE hy.pull_run SET finished_ts=?, rows_in=?, status='ok' WHERE run_id=?",
          params = list(format(Sys.time(), "%Y-%m-%d %H:%M:%S"), nrow(obs), run_id))

# ── summary ──────────────────────────────────────────────────────────────────
cat("\n================ FIRST CUT SUMMARY (WSC / Okanagan 08NM) ================\n")
print(dbGetQuery(con, "SELECT s.parameter, COUNT(*) obs, COUNT(DISTINCT o.series_uid) series,
  MIN(datetime_utc) first_obs, MAX(datetime_utc) last_obs
  FROM hy.observation o JOIN hy.series s USING(series_uid)
  GROUP BY s.parameter ORDER BY s.parameter"))
cat("\n")
print(dbGetQuery(con, "SELECT COUNT(DISTINCT station_uid) stations_total,
  (SELECT COUNT(DISTINCT station_uid) FROM hy.series WHERE station_uid LIKE 'WSC-%') stations_with_series
  FROM hy.station"))
cat("DB: ", DB, "\n=========================================================================\n")
