#!/usr/bin/env Rscript
# Deploy the monitoring dashboard to obwb.shinyapps.io.
# DB connection is sent as secure environment variables (read-only user).
# Env expected (set by the shell wrapper from Secret Manager):
#   DB_HOST DB_PORT DB_NAME DB_USER DB_PASS DB_SSLMODE DB_PUBLIC_HOST
library(rsconnect)
rsconnect::deployApp(
  appDir    = "dashboard",
  appName   = "ok-hydromet-backup",
  appTitle  = "Okanagan Hydrometric Backup",
  account   = "obwb", server = "shinyapps.io",
  # shinyapps.io can't set env vars — creds come from bundled dashboard/db_config.R
  forceUpdate = TRUE, launch.browser = FALSE, logLevel = "normal"
)
