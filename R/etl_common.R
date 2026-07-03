# ok-hydromet-backup — shared ETL helpers (Cloud Run job)
# Connects to Cloud SQL Postgres (unix socket in Cloud Run; TCP+SSL locally),
# pulls WSC realtime from the ECCC GeoMet OGC API, and upserts idempotently.
suppressMessages({library(httr2); library(jsonlite); library(DBI); library(RPostgres); library(dplyr)})

# Build dbConnect() argument list (including a fresh driver). The CALLER must
# create the connection at top level and keep BOTH the returned args (which holds
# the driver) and the connection as live bindings for the whole run — on Linux the
# RPostgres connection is only usable while the driver binding stays in the running
# frame; returning a connection out of a helper triggers "bad_weak_ptr". See PG_CONNECT.
pg_args <- function() {
  host <- Sys.getenv("DB_HOST", "127.0.0.1")
  args <- list(RPostgres::Postgres(),
               dbname   = Sys.getenv("DB_NAME", "okhydromet"),
               user     = Sys.getenv("DB_USER", "okhydromet_app"),
               password = Sys.getenv("DB_PASS"),
               host     = host)
  if (!startsWith(host, "/")) {                       # TCP (local): require SSL
    args$port    <- as.integer(Sys.getenv("DB_PORT", "5432"))
    args$sslmode <- Sys.getenv("DB_SSLMODE", "require")
    for (k in c("sslrootcert", "sslcert", "sslkey")) {  # client-cert TLS if provided
      v <- Sys.getenv(toupper(paste0("DB_", k))); if (nzchar(v)) args[[k]] <- v
    }
  }
  args
}

# Each ETL script connects at top level with:
#   PG_ARGS <- pg_args(); con <- do.call(DBI::dbConnect, PG_ARGS)
# keeping PG_ARGS (the driver) a live top-level binding for the whole run.

# ── GCS raw landing (immutable append-only archive of each pull) ─────────────
gcs_token <- function() {
  t <- tryCatch(request("http://metadata.google.internal/computeMetadata/v1/instance/service-account/default/token") |>
                  req_headers(`Metadata-Flavor` = "Google") |> req_timeout(10) |>
                  req_perform() |> resp_body_json(),
                error = function(e) { message("[gcs] metadata token error: ", conditionMessage(e)); NULL })
  if (!is.null(t$access_token) && nzchar(t$access_token)) return(t$access_token)  # Cloud Run / GCE
  tok <- tryCatch(system("gcloud auth print-access-token", intern = TRUE, ignore.stderr = TRUE),
                  error = function(e) character(0))               # local fallback
  if (length(tok) && nzchar(tok[1])) tok[1] else NA_character_
}

gcs_put <- function(object, body, content_type = "text/csv", bucket = Sys.getenv("RAW_BUCKET", "")) {
  if (!nzchar(bucket)) return(invisible(FALSE))                   # archiving disabled
  tok <- gcs_token(); if (is.na(tok)) { message("[gcs] no token; skip archive"); return(invisible(FALSE)) }
  url <- sprintf("https://storage.googleapis.com/upload/storage/v1/b/%s/o?uploadType=media&name=%s",
                 bucket, utils::URLencode(object, reserved = TRUE))
  ok <- tryCatch({
    request(url) |> req_headers(Authorization = paste("Bearer", tok), `Content-Type` = content_type) |>
      req_body_raw(if (is.character(body)) charToRaw(paste(body, collapse = "\n")) else body) |>
      req_timeout(120) |> req_perform(); TRUE
  }, error = function(e) { message("[gcs] put failed: ", conditionMessage(e)); FALSE })
  if (ok) message("[gcs] archived gs://", bucket, "/", object)
  invisible(ok)
}

# Archive a data frame or raw text body -> {source}/{yyyy}/{mm}/{dd}/{source}-run{n}.{ext}
# Prefers a mounted GCS volume (RAW_MOUNT, e.g. /raw on Cloud Run); falls back to the
# Cloud Storage API (RAW_BUCKET + metadata token). No-op if neither is configured.
archive_raw <- function(source, run_id, x, ext = "csv") {
  rel <- sprintf("%s/%s/%s-run%s.%s", source, format(Sys.time(), "%Y/%m/%d"), source, run_id, ext)
  write_body <- function(path) if (is.data.frame(x)) utils::write.csv(x, path, row.names = FALSE)
                               else writeLines(as.character(x), path)
  mount <- Sys.getenv("RAW_MOUNT", "")
  if (nzchar(mount)) {                                          # gcsfuse volume (preferred)
    p <- file.path(mount, rel); dir.create(dirname(p), recursive = TRUE, showWarnings = FALSE)
    ok <- tryCatch({ write_body(p); TRUE }, error = function(e) { message("[gcs] mount write failed: ", conditionMessage(e)); FALSE })
    if (ok) message("[gcs] archived ", p)
    return(invisible(ok))
  }
  if (nzchar(Sys.getenv("RAW_BUCKET", ""))) {                   # API fallback
    tf <- tempfile(); on.exit(unlink(tf), add = TRUE); write_body(tf)
    return(gcs_put(rel, readChar(tf, file.info(tf)$size, useBytes = TRUE)))
  }
  invisible(FALSE)
}

# Pull hydrometric-realtime for a set of WSC station numbers, optionally since a POSIXct.
geomet_realtime <- function(station_ids, since = NULL) {
  base <- "https://api.weather.gc.ca/collections/hydrometric-realtime/items"
  fetch1 <- function(sn) {
    off <- 0L; lim <- 10000L; acc <- list()
    repeat {
      q <- list(STATION_NUMBER = sn, limit = lim, offset = off, f = "json")
      if (!is.null(since)) q$datetime <- paste0(format(since, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"), "/..")
      fc <- request(base) |> req_url_query(!!!q) |> req_retry(max_tries = 3) |>
            req_timeout(60) |> req_perform() |> resp_body_json(simplifyVector = FALSE)
      n <- length(fc$features); if (n == 0) break
      acc[[length(acc) + 1L]] <- fc$features
      if (n < lim) break; off <- off + lim
    }
    feats <- do.call(c, acc); if (!length(feats)) return(NULL)
    p  <- lapply(feats, `[[`, "properties")
    gv <- function(k) vapply(p, function(x) { v <- x[[k]]; if (is.null(v)) NA else v }, numeric(1))
    gc <- function(k) vapply(p, function(x) { v <- x[[k]]; if (is.null(v)) NA_character_ else as.character(v) }, character(1))
    tibble(STATION_NUMBER = sn, DATETIME = gc("DATETIME"),
           LEVEL = gv("LEVEL"), DISCHARGE = gv("DISCHARGE"),
           LEVEL_SYM = gc("LEVEL_SYMBOL_EN"), DISCHARGE_SYM = gc("DISCHARGE_SYMBOL_EN"))
  }
  bind_rows(lapply(station_ids, function(sn) tryCatch(fetch1(sn), error = function(e) NULL)))
}

reshape_obs <- function(raw) {
  to <- function(col, sym, param, units) raw |> filter(!is.na(.data[[col]])) |>
    transmute(series_uid  = paste0("WSC-", STATION_NUMBER, "-", param, "-instant"),
              station_uid = paste0("WSC-", STATION_NUMBER), parameter = param, units = units,
              datetime_utc = as.POSIXct(DATETIME, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
              value = .data[[col]], qflag = .data[[sym]])
  bind_rows(to("LEVEL", "LEVEL_SYM", "H", "m"), to("DISCHARGE", "DISCHARGE_SYM", "Q", "m3/s"))
}

# Idempotent upsert of instant WSC series + observations. Returns rows affected.
upsert_wsc <- function(con, long, run_id) {
  ser <- long |> distinct(series_uid, station_uid, parameter, units) |>
    mutate(interval = "instant", source_series_id = paste0(station_uid, ":", parameter))
  dbWriteTable(con, "tmp_series", as.data.frame(ser), temporary = TRUE, overwrite = TRUE)
  dbExecute(con, "INSERT INTO okhydromet.series
    (series_uid,station_uid,parameter,units,interval,source_series_id)
    SELECT series_uid,station_uid,parameter,units,interval,source_series_id FROM tmp_series
    ON CONFLICT (series_uid) DO NOTHING")

  obs <- long |> transmute(series_uid, datetime_utc, value, qflag,
                           source = "wsc", pull_run_id = run_id)
  dbWriteTable(con, "tmp_obs", as.data.frame(obs), temporary = TRUE, overwrite = TRUE)
  dbExecute(con, "INSERT INTO okhydromet.observation
    (series_uid,datetime_utc,value,qualifier_flags,approval_level,source,pull_run_id,ingest_ts)
    SELECT series_uid,datetime_utc,value,
      CASE WHEN qflag IS NULL OR qflag='' THEN NULL ELSE ARRAY[qflag] END,
      'working','wsc',pull_run_id, now()
    FROM tmp_obs
    ON CONFLICT (series_uid,datetime_utc,source)
    DO UPDATE SET value=EXCLUDED.value, qualifier_flags=EXCLUDED.qualifier_flags, ingest_ts=now()")
}
