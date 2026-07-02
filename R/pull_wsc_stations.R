#!/usr/bin/env Rscript
# ok-hydromet-backup — pull the live WSC Okanagan station list (sub-basin 08NM)
# into the `station` registry seed format. Reproducible; no HYDAT download required
# (uses the ECCC realtime station network list).
#
# Run:  Rscript R/pull_wsc_stations.R
# Out:  data-raw/wsc_okanagan_stations.csv
suppressMessages({library(tidyhydat); library(dplyr); library(readr)})

st <- realtime_stations(prov_terr_state_loc = "BC") |>
  filter(grepl("^08NM", STATION_NUMBER)) |>          # 08NM = Okanagan River basin
  arrange(STATION_NUMBER)

reg <- tibble(
  station_uid        = paste0("WSC-", st$STATION_NUMBER),
  wsc_id             = st$STATION_NUMBER,
  bc_aquarius_loc_id = NA_character_,
  ona_id             = NA_character_,
  name               = st$STATION_NAME,
  operator           = "WSC",
  status             = "active",
  lat                = st$LATITUDE,
  lon                = st$LONGITUDE,
  basin              = "Okanagan",
  telemetry_type     = NA_character_,
  goes_dcp_id        = NA_character_
)

out <- file.path("data-raw", "wsc_okanagan_stations.csv")
dir.create("data-raw", showWarnings = FALSE)
write_csv(reg, out)
cat("Wrote", nrow(reg), "WSC Okanagan stations ->", out, "\n")
print(reg, n = Inf)
