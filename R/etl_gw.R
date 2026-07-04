# ok-hydromet-backup — BC PROVINCIAL GROUNDWATER leg (public AQUARIUS WebPortal CSV export).
# =====================================================================================
# NO credentials required. Mirrors R/etl_provincial.R but for PGOWN observation wells:
#   GET bcmoe-prod.aquaticinformatics.net/Export/DataSet?DataSet=SGWL.Working@<OWid>...
# Parameter code = SGWL (Static Ground Water Level), label = Working, UnitID 306 = metres.
# Column layout is identical to the surface-water export (skip 5 metadata lines, header row 6).
# Confirmed public by John Fraser / NHC (2026-07-03). Datasets come from
# data-raw/provincial_gw_datasets.csv. Upserts SGWL as parameter 'GW', source='bc'.
#
# MODE=gw. Env:
#   AQ_DATERANGE  (default 'Days30'; 'EntirePeriodOfRecord' for full backfill)
#   AQ_GW_REGISTRY(default data-raw/provincial_gw_datasets.csv)
#   GW_DRYRUN=1   parse + report per-well row counts WITHOUT connecting to / writing the DB
#
# NOTE (datum): SGWL here reads as DEPTH BELOW GROUND SURFACE in metres (a rising value =
#   a declining water table). Confirm before plotting trends / labelling the y-axis.
# =====================================================================================
source("R/etl_common.R")
suppressMessages({library(httr2); library(dplyr)})

AQ_HOST      <- Sys.getenv("AQ_HOST", "https://bcmoe-prod.aquaticinformatics.net")
AQ_DATERANGE <- Sys.getenv("AQ_DATERANGE", "Days30")          # Days7 | Days30 | EntirePeriodOfRecord
REG_PATH     <- Sys.getenv("AQ_GW_REGISTRY", "data-raw/provincial_gw_datasets.csv")
DRYRUN       <- nzchar(Sys.getenv("GW_DRYRUN", ""))
COMMON <- "Calendar=CALENDARYEAR&Conversion=Instantaneous&IntervalPoints=PointsAsRecorded&ApprovalLevels=True&Qualifiers=True&Step=1&ExportFormat=csv&Compressed=false&RoundData=False&GradeCodes=True&InterpolationTypes=False&Timezone=0"

# AQUARIUS approval codes -> our approval_level vocabulary (same map as etl_provincial.R)
appr_map <- function(x) dplyr::case_when(
  x == "1200" ~ "approved", x == "950" ~ "reviewed",
  x == "900"  ~ "in_review", x == "800" ~ "working", TRUE ~ "unspecified")

# Fetch + parse one dataset. Returns tibble(datetime_utc,value,grade_code,approval_level,qflag) or NULL.
fetch_dataset <- function(moe_id, parameter, label, unit_id) {
  url <- sprintf("%s/Export/DataSet?DataSet=%s.%s%%40%s&DateRange=%s&UnitID=%s&%s",
                 AQ_HOST, utils::URLencode(parameter), utils::URLencode(label),
                 moe_id, AQ_DATERANGE, unit_id, COMMON)
  body <- tryCatch(request(url) |> req_retry(max_tries = 3) |> req_timeout(300) |>
                     req_perform() |> resp_body_string(), error = function(e) NULL)
  if (is.null(body)) return(NULL)
  df <- tryCatch(utils::read.csv(text = body, skip = 5, header = TRUE,
                                 stringsAsFactors = FALSE, check.names = FALSE),
                 error = function(e) NULL)
  if (is.null(df) || nrow(df) == 0 || ncol(df) < 4) return(NULL)   # empty template => dataset absent
  tibble(datetime_utc   = as.POSIXct(df[[1]], format = "%Y-%m-%d %H:%M:%S", tz = "UTC"),
         value          = suppressWarnings(as.numeric(df[[2]])),
         grade_code     = as.character(df[[3]]),
         approval_level = appr_map(as.character(df[[4]])),
         qflag          = if (ncol(df) >= 5) as.character(df[[5]]) else NA_character_) |>
    filter(!is.na(datetime_utc), !is.na(value))
}

reg <- utils::read.csv(REG_PATH, stringsAsFactors = FALSE)
cat("[gw] wells in registry:", nrow(reg), " daterange:", AQ_DATERANGE,
    if (DRYRUN) " (DRY RUN — no DB writes)\n" else "\n")

# ── DRY RUN: fetch + parse every well, report counts, never touch the DB ──────
if (DRYRUN) {
  total <- 0L
  for (i in seq_len(nrow(reg))) {
    r <- reg[i, ]
    d <- fetch_dataset(r$moe_id, r$parameter, r$label, r$unit_id)
    n <- if (is.null(d)) 0L else nrow(d)
    rng <- if (n) sprintf("%s .. %s", min(d$datetime_utc), max(d$datetime_utc)) else "-"
    cat(sprintf("  %-7s %-42s %8d rows  %s\n", r$moe_id, substr(r$name, 1, 42), n, rng))
    total <- total + n
  }
  cat("[gw] DRY RUN total obs that WOULD load:", total, "\n")
  quit(status = 0)
}

# ── connect (top-level bindings; see bad_weak_ptr note in etl_common.R) ───────
PG_ARGS <- pg_args(); con <- do.call(DBI::dbConnect, PG_ARGS); cat("[db] connected\n")
run_id <- dbGetQuery(con, "INSERT INTO okhydromet.pull_run(source,started_ts,status)
                           VALUES('gw-export', now(), 'running') RETURNING run_id")$run_id

total <- 0L
for (i in seq_len(nrow(reg))) {
  r <- reg[i, ]; suid <- paste0("BC-", r$moe_id)
  series_uid <- paste0(suid, "-", r$canon, "-instant-bc")
  d <- fetch_dataset(r$moe_id, r$parameter, r$label, r$unit_id)
  cat(sprintf("  %s %s(%s): %s rows\n", r$moe_id, r$canon, r$parameter, if (is.null(d)) 0 else nrow(d)))
  if (is.null(d) || !nrow(d)) next
  archive_raw(sprintf("gw/%s-%s", r$moe_id, r$canon), run_id, d)   # immutable raw landing

  dbExecute(con, "INSERT INTO okhydromet.station
      (station_uid,bc_aquarius_loc_id,name,operator,status,station_type,basin,lat,lon,geom)
    VALUES($1,$2,$3,'BC','active','groundwater_well','Okanagan',$4::double precision,$5::double precision,
      CASE WHEN $4::double precision IS NULL OR $5::double precision IS NULL THEN NULL
           ELSE ST_SetSRID(ST_MakePoint($5::double precision,$4::double precision),4326) END)
    ON CONFLICT (station_uid) DO UPDATE SET bc_aquarius_loc_id=EXCLUDED.bc_aquarius_loc_id,
      name=EXCLUDED.name, station_type=EXCLUDED.station_type,
      lat=EXCLUDED.lat, lon=EXCLUDED.lon, geom=EXCLUDED.geom",
    params = list(suid, r$moe_id, r$name,
                  if (is.null(r$lat) || is.na(r$lat)) NA else as.numeric(r$lat),
                  if (is.null(r$lon) || is.na(r$lon)) NA else as.numeric(r$lon)))
  dbExecute(con, "INSERT INTO okhydromet.series(series_uid,station_uid,parameter,units,interval,source_series_id)
    VALUES($1,$2,$3,$4,'instant',$5) ON CONFLICT (series_uid) DO NOTHING",
    params = list(series_uid, suid, r$canon, r$units, sprintf("%s.%s@%s", r$parameter, r$label, r$moe_id)))

  d$series_uid <- series_uid; d$pull_run_id <- run_id
  dbWriteTable(con, "tmp_gw", as.data.frame(d[, c("series_uid","datetime_utc","value","grade_code","approval_level","qflag","pull_run_id")]),
               temporary = TRUE, overwrite = TRUE)
  n <- dbExecute(con, "INSERT INTO okhydromet.observation
    (series_uid,datetime_utc,value,grade_code,approval_level,qualifier_flags,source,pull_run_id,ingest_ts)
    SELECT series_uid,datetime_utc,value, NULLIF(grade_code,''), NULLIF(approval_level,''),
      CASE WHEN qflag IS NULL OR qflag='' THEN NULL ELSE ARRAY[qflag] END,
      'bc', pull_run_id, now()
    FROM tmp_gw
    ON CONFLICT (series_uid,datetime_utc,source)
    DO UPDATE SET value=EXCLUDED.value, grade_code=EXCLUDED.grade_code,
      approval_level=EXCLUDED.approval_level, ingest_ts=now()")
  total <- total + n
}

dbExecute(con, "UPDATE okhydromet.pull_run SET finished_ts=now(), rows_in=$1, status='ok' WHERE run_id=$2",
          params = list(total, run_id))
cat("[gw] wells=", nrow(reg), " upserted_obs=", total, " run_id=", run_id, "\n")
