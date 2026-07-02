# ok-hydromet-backup — BC PROVINCIAL leg (public AQUARIUS WebPortal CSV export).
# =====================================================================================
# NO credentials required. Uses the public per-dataset CSV export on the BC MoE AQUARIUS
# WebPortal (confirmed public by John Fraser / NHC, 2026-07-02):
#   GET bcmoe-prod.aquaticinformatics.net/Export/DataSet?DataSet=<Parameter>.<Label>@<MoeId>...
# Datasets come from data-raw/provincial_datasets.csv (expand as OBWB↔MoE id worksheet arrives).
# Pulls Q/H/Tw with grade + approval codes into the okhydromet schema, source='bc'.
# MODE=provincial. Env: AQ_DATERANGE (default 'Days7'; 'EntirePeriodOfRecord' for backfill).
# =====================================================================================
source("R/etl_common.R")
suppressMessages({library(httr2); library(dplyr)})

AQ_HOST     <- Sys.getenv("AQ_HOST", "https://bcmoe-prod.aquaticinformatics.net")
AQ_DATERANGE<- Sys.getenv("AQ_DATERANGE", "Days7")           # Days7 | Days30 | EntirePeriodOfRecord
REG_PATH    <- Sys.getenv("AQ_REGISTRY", "data-raw/provincial_datasets.csv")
COMMON <- "Calendar=CALENDARYEAR&Conversion=Instantaneous&IntervalPoints=PointsAsRecorded&ApprovalLevels=True&Qualifiers=True&Step=1&ExportFormat=csv&Compressed=false&RoundData=False&GradeCodes=True&InterpolationTypes=False&Timezone=0"

# AQUARIUS approval codes -> our approval_level vocabulary
appr_map <- function(x) dplyr::case_when(
  x == "1200" ~ "approved", x == "950" ~ "reviewed",
  x == "900"  ~ "in_review", x == "800" ~ "working", TRUE ~ "unspecified")

# Fetch + parse one dataset. Returns tibble(datetime_utc,value,grade_code,approval_level,qflag) or NULL.
fetch_dataset <- function(moe_id, parameter, label, unit_id) {
  url <- sprintf("%s/Export/DataSet?DataSet=%s.%s%%40%s&DateRange=%s&UnitID=%s&%s",
                 AQ_HOST, utils::URLencode(parameter), utils::URLencode(label),
                 moe_id, AQ_DATERANGE, unit_id, COMMON)
  body <- tryCatch(request(url) |> req_retry(max_tries = 3) |> req_timeout(180) |>
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

# ── connect (top-level bindings; see bad_weak_ptr note in etl_common.R) ───────
PG_ARGS <- pg_args(); con <- do.call(DBI::dbConnect, PG_ARGS); cat("[db] connected\n")
run_id <- dbGetQuery(con, "INSERT INTO okhydromet.pull_run(source,started_ts,status)
                           VALUES('bc-export', now(), 'running') RETURNING run_id")$run_id

reg <- utils::read.csv(REG_PATH, stringsAsFactors = FALSE)
cat("[bc] datasets in registry:", nrow(reg), " daterange:", AQ_DATERANGE, "\n")

total <- 0L
for (i in seq_len(nrow(reg))) {
  r <- reg[i, ]; suid <- paste0("BC-", r$moe_id)
  series_uid <- paste0(suid, "-", r$canon, "-instant-bc")
  d <- fetch_dataset(r$moe_id, r$parameter, r$label, r$unit_id)
  cat(sprintf("  %s %s(%s): %s rows\n", r$moe_id, r$canon, r$parameter, if (is.null(d)) 0 else nrow(d)))
  if (is.null(d) || !nrow(d)) next
  archive_raw(sprintf("bc/%s-%s", r$moe_id, r$canon), run_id, d)   # immutable raw landing

  dbExecute(con, "INSERT INTO okhydromet.station(station_uid,bc_aquarius_loc_id,name,operator,status,basin)
    VALUES($1,$2,$3,'BC','active','Okanagan')
    ON CONFLICT (station_uid) DO UPDATE SET bc_aquarius_loc_id=EXCLUDED.bc_aquarius_loc_id, name=EXCLUDED.name",
    params = list(suid, r$moe_id, r$name))
  dbExecute(con, "INSERT INTO okhydromet.series(series_uid,station_uid,parameter,units,interval,source_series_id)
    VALUES($1,$2,$3,$4,'instant',$5) ON CONFLICT (series_uid) DO NOTHING",
    params = list(series_uid, suid, r$canon, r$units, sprintf("%s.%s@%s", r$parameter, r$label, r$moe_id)))

  d$series_uid <- series_uid; d$pull_run_id <- run_id
  dbWriteTable(con, "tmp_bc", as.data.frame(d[, c("series_uid","datetime_utc","value","grade_code","approval_level","qflag","pull_run_id")]),
               temporary = TRUE, overwrite = TRUE)
  n <- dbExecute(con, "INSERT INTO okhydromet.observation
    (series_uid,datetime_utc,value,grade_code,approval_level,qualifier_flags,source,pull_run_id,ingest_ts)
    SELECT series_uid,datetime_utc,value, NULLIF(grade_code,''), NULLIF(approval_level,''),
      CASE WHEN qflag IS NULL OR qflag='' THEN NULL ELSE ARRAY[qflag] END,
      'bc', pull_run_id, now()
    FROM tmp_bc
    ON CONFLICT (series_uid,datetime_utc,source)
    DO UPDATE SET value=EXCLUDED.value, grade_code=EXCLUDED.grade_code,
      approval_level=EXCLUDED.approval_level, ingest_ts=now()")
  total <- total + n
}

dbExecute(con, "UPDATE okhydromet.pull_run SET finished_ts=now(), rows_in=$1, status='ok' WHERE run_id=$2",
          params = list(total, run_id))
cat("[provincial] datasets=", nrow(reg), " upserted_obs=", total, " run_id=", run_id, "\n")
