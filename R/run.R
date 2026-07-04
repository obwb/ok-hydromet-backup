# ok-hydromet-backup — Cloud Run job entrypoint. Dispatches on MODE env var.
mode <- Sys.getenv("MODE", "daily")
cat("MODE =", mode, "\n")
ok <- tryCatch({
  if (mode == "daily")      source("R/etl_daily.R") else
  if (mode == "weekly")     source("R/audit_weekly.R") else
  if (mode == "provincial") source("R/etl_provincial.R") else   # INACTIVE until AQ creds
  if (mode == "gw")         source("R/etl_gw.R") else           # BC groundwater (PGOWN wells)
    stop("unknown MODE: ", mode)
  TRUE
}, error = function(e) { cat("FATAL:", conditionMessage(e), "\n"); FALSE })
if (!isTRUE(ok)) quit(status = 1)
