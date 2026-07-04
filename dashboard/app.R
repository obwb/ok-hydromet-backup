# ok-hydromet-backup — database monitoring dashboard
# Live view of the okhydromet Cloud SQL (Postgres/PostGIS) backup DB: what's in it,
# freshness, pipeline health, key statistics, and read-only data sharing.
#
# Env: DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS[, DB_SSLMODE]
# Run locally:  Rscript -e 'shiny::runApp("dashboard", port=7788)'
suppressMessages({
  library(shiny); library(bslib); library(pool); library(RPostgres); library(DBI)
  library(DT); library(leaflet); library(dplyr); library(ggplot2); library(plotly); library(scales)
})

# DB connection config: env vars (local/Cloud Run) or a bundled, git-ignored
# db_config.R (shinyapps.io, which can't set env vars). Read-only SELECT user.
if (file.exists("db_config.R")) source("db_config.R", local = TRUE)

# ── DB pool (holds the driver → avoids RPostgres bad_weak_ptr) ────────────────
.host <- Sys.getenv("DB_HOST", "127.0.0.1")
.args <- list(drv = RPostgres::Postgres(), dbname = Sys.getenv("DB_NAME", "okhydromet"),
              user = Sys.getenv("DB_USER", "okhydromet_app"), password = Sys.getenv("DB_PASS"),
              host = .host, minSize = 1, maxSize = 5)
if (!startsWith(.host, "/")) {
  .args$port <- as.integer(Sys.getenv("DB_PORT", "5432"))
  .args$sslmode <- Sys.getenv("DB_SSLMODE", "require")
  for (k in c("sslrootcert", "sslcert", "sslkey")) {          # client-cert TLS if provided
    v <- Sys.getenv(toupper(paste0("DB_", k)))
    if (nzchar(v)) .args[[k]] <- v
  }
}
pool <- do.call(dbPool, .args)
onStop(function() poolClose(pool))
# RPostgres returns counts as integer64, which breaks format(big.mark) and ggplot's
# round_any. Coerce integer64 columns to numeric at the source.
Q <- function(sql) {
  d <- dbGetQuery(pool, sql)
  for (nm in names(d)) if (inherits(d[[nm]], "integer64")) d[[nm]] <- as.numeric(d[[nm]])
  d
}
Q1 <- function(sql) { v <- Q(sql)[[1]]; if (length(v)) v[1] else NA }

OK_TEAL <- "#0b6b6b"
theme <- bs_theme(version = 5, primary = OK_TEAL, base_font = font_google("Inter"),
                  heading_font = font_google("Inter"))

# ── UI ───────────────────────────────────────────────────────────────────────
ui <- page_navbar(
  title = "Okanagan Hydrometric Backup", theme = theme, fillable = FALSE,
  header = tags$head(tags$style(HTML(sprintf(
    ".value-box{min-height:118px}.navbar-brand{font-weight:700}
     a{color:%s}.freshbar{height:8px;border-radius:4px}
     .navbar{position:sticky;top:0;z-index:1030;background:#fff;border-bottom:1px solid #e4eded}", OK_TEAL)))),

  # ---- Dashboard ----
  nav_panel(
    "Dashboard", icon = icon("gauge-high"),
    div(class = "d-flex justify-content-between align-items-center mb-2",
        h4("Database at a glance", class = "mt-2"),
        div(textOutput("updated_at", inline = TRUE),
            actionButton("refresh", "Refresh", icon = icon("rotate"), class = "btn-sm btn-outline-secondary ms-2"))),
    layout_columns(
      fill = FALSE, col_widths = c(3,3,3,3),
      value_box("Observations", textOutput("kpi_obs"), showcase = icon("water"), theme = "primary"),
      value_box("Stations", textOutput("kpi_stn"), showcase = icon("map-location-dot")),
      value_box("Time series", textOutput("kpi_series"), showcase = icon("wave-square")),
      value_box("Latest reading", textOutput("kpi_latest"), showcase = icon("clock"))),
    layout_columns(
      col_widths = c(7, 5),
      card(card_header("Observations ingested — last 60 days"), full_screen = TRUE,
           plotlyOutput("plot_recent", height = 300)),
      card(card_header("Data freshness by source"), uiOutput("freshness"))),
    card(card_header("Coverage by parameter"), full_screen = TRUE,
         plotlyOutput("plot_coverage", height = 260))),

  # ---- Data Summary ----
  nav_panel(
    "Data Summary", icon = icon("table-list"),
    layout_columns(
      col_widths = c(5, 7),
      card(card_header("What's in the database"), htmlOutput("summary_text")),
      card(card_header("Coverage detail"), DTOutput("tbl_coverage"))),
    card(card_header("Data availability — source, record count & date range"), full_screen = TRUE,
         plotlyOutput("plot_timeline", height = 360)),
    card(card_header("Station map — colour = data freshness"), full_screen = TRUE,
         leafletOutput("map", height = 420)),
    card(card_header("Stations"), full_screen = TRUE, DTOutput("tbl_stations"))),

  # ---- Groundwater ----
  nav_panel(
    "Groundwater", icon = icon("droplet"),
    div(class = "d-flex justify-content-between align-items-center mb-2",
        h4("BC provincial groundwater observation wells (PGOWN)", class = "mt-2"),
        downloadButton("dl_gw", "Well summary (CSV)", class = "btn-sm btn-primary")),
    layout_columns(
      fill = FALSE, col_widths = c(3,3,3,3),
      value_box("Wells", textOutput("gw_n"), showcase = icon("droplet"), theme = "primary"),
      value_box("Water-level readings", textOutput("gw_pts"), showcase = icon("database")),
      value_box("QAQC approved", textOutput("gw_appr"), showcase = icon("clipboard-check")),
      value_box("Record spans", textOutput("gw_span"), showcase = icon("clock"))),
    layout_columns(
      col_widths = c(6, 6),
      card(card_header("Well locations — colour = data freshness"), full_screen = TRUE,
           leafletOutput("gw_map", height = 460)),
      card(card_header("Wells — record span, readings & QAQC"), full_screen = TRUE,
           DTOutput("gw_table"))),
    tags$small(class = "text-muted",
      "Static ground-water level (SGWL), metres — public AQUARIUS export from the BC provincial ",
      "groundwater observation well network (PGOWN). Historical series are largely QAQC-approved; ",
      "recent telemetry is provisional (working).")),

  # ---- ONA Audit ----
  nav_panel(
    "ONA Audit", icon = icon("clipboard-check"),
    div(class = "d-flex justify-content-between align-items-center mb-2",
        h4("ONA / provincial monitoring network — audit & project status", class = "mt-2"),
        downloadButton("dl_ona_audit", "Download audit report (CSV)", class = "btn-sm btn-primary")),
    layout_columns(
      fill = FALSE, col_widths = c(3,3,3,3),
      value_box("ONA stations", textOutput("ona_n"), showcase = icon("location-dot"), theme = "primary"),
      value_box("Data points", textOutput("ona_pts"), showcase = icon("database")),
      value_box("QAQC reviewed/approved", textOutput("ona_qaqc"), showcase = icon("clipboard-check")),
      value_box("Most recent reading", textOutput("ona_latest"), showcase = icon("clock"))),
    layout_columns(
      col_widths = c(8, 4),
      card(card_header("QAQC status by station — approval level of collected points"), full_screen = TRUE,
           plotlyOutput("ona_qaqc_plot", height = 620)),
      card(card_header("Project status"), uiOutput("ona_status_summary"))),
    card(card_header("Station audit — data points, record span, QAQC & freshness"), full_screen = TRUE,
         DTOutput("ona_table")),

    h5("By year", class = "mt-4 mb-2 text-secondary"),
    card(card_header("Station reporting history — data points by station × year"), full_screen = TRUE,
         plotlyOutput("ona_heatmap", height = 580)),
    card(card_header("Network activity by year"), full_screen = TRUE,
      layout_columns(
        col_widths = c(6, 6),
        plotlyOutput("ona_year_plot", height = 360),
        DTOutput("ona_year_table")),
      tags$small(class = "text-muted",
        "* Field visits are estimated from the data record — telemetry gaps > 1 day ",
        "(interruption → service visit → data resumes), de-duplicated per station-day. ",
        "A proxy for maintenance/service events, not confirmed visits. ",
        "Rating-curve status and QAQC approval await ingestion of AQUARIUS rating/approved-series data."))),

  # ---- Pipeline Health ----
  nav_panel(
    "Pipeline Health", icon = icon("heart-pulse"),
    layout_columns(col_widths = c(4,4,4),
      value_box("Last successful run", textOutput("kpi_lastrun"), showcase = icon("circle-check"), theme = "success"),
      value_box("Runs (30 d)", textOutput("kpi_runs"), showcase = icon("arrows-rotate")),
      value_box("Open discrepancies", textOutput("kpi_disc"), showcase = icon("triangle-exclamation"))),
    card(card_header("Recent ingestion runs (pull_run)"), full_screen = TRUE, DTOutput("tbl_runs")),
    card(card_header("Weekly audit log"), full_screen = TRUE, DTOutput("tbl_audit"))),

  # ---- Data Access (read-only sharing) ----
  nav_panel(
    "Data Access", icon = icon("share-nodes"),
    card(card_header("Download data (read-only, open)"),
      p("Direct CSV exports of the current database contents — free to share and reuse ",
        "(source: OBWB / Water Survey of Canada; provincial data as available)."),
      div(class = "d-flex flex-wrap gap-2",
        downloadButton("dl_stations", "Stations (CSV)", class = "btn-primary"),
        downloadButton("dl_coverage", "Coverage summary (CSV)", class = "btn-primary"),
        downloadButton("dl_latest", "Latest reading per series (CSV)", class = "btn-primary"),
        downloadButton("dl_daily", "Daily means — full record (CSV)", class = "btn-outline-primary"))),
    card(card_header("Programmatic read-only access"),
      htmlOutput("access_info"))),

  # ---- About ----
  nav_panel(
    "About", icon = icon("circle-info"), htmlOutput("about")),
  nav_spacer(),
  nav_item(tags$span(class = "navbar-text small", "Sovereign backup · GCP Montréal"))
)

# ── Server ───────────────────────────────────────────────────────────────────
server <- function(input, output, session) {

  bump <- reactiveVal(0)
  observeEvent(input$refresh, bump(bump() + 1))
  refresh <- reactive({ bump(); invalidateLater(5 * 60 * 1000); Sys.time() })

  stats <- reactive({ refresh(); list(
    obs    = Q1("SELECT count(*) FROM okhydromet.observation"),
    stn    = Q1("SELECT count(*) FROM okhydromet.station"),
    series = Q1("SELECT count(*) FROM okhydromet.series"),
    params = Q1("SELECT count(DISTINCT parameter) FROM okhydromet.series"),
    latest = Q1("SELECT max(datetime_utc) FROM okhydromet.observation"),
    lastrun= Q1("SELECT max(finished_ts) FROM okhydromet.pull_run WHERE status='ok'"),
    runs30 = Q1("SELECT count(*) FROM okhydromet.pull_run WHERE started_ts > now()-interval '30 days'"),
    disc   = Q1("SELECT count(*) FROM okhydromet.audit_discrepancy WHERE action_taken IS NULL")
  )})

  fmt <- function(x) format(as.numeric(x), big.mark = ",", scientific = FALSE, trim = TRUE)
  output$updated_at <- renderText(paste("Loaded", format(refresh(), "%Y-%m-%d %H:%M")))
  output$kpi_obs    <- renderText(fmt(stats()$obs))
  output$kpi_stn    <- renderText(fmt(stats()$stn))
  output$kpi_series <- renderText(fmt(stats()$series))
  output$kpi_latest <- renderText(format(as.POSIXct(stats()$latest), "%Y-%m-%d %H:%M", tz = "UTC"))
  output$kpi_lastrun<- renderText(ifelse(is.na(stats()$lastrun), "—", format(as.POSIXct(stats()$lastrun), "%Y-%m-%d %H:%M")))
  output$kpi_runs   <- renderText(fmt(stats()$runs30))
  output$kpi_disc   <- renderText(fmt(stats()$disc))

  # recent ingest volume
  output$plot_recent <- renderPlotly({
    refresh()
    d <- Q("SELECT date_trunc('day', datetime_utc)::date AS d, count(*) n
            FROM okhydromet.observation WHERE datetime_utc > now()-interval '60 days'
            GROUP BY 1 ORDER BY 1")
    validate(need(nrow(d) > 0, "No recent observations"))
    p <- ggplot(d, aes(d, n)) + geom_col(fill = OK_TEAL) +
      scale_y_continuous(labels = comma) + labs(x = NULL, y = NULL) +
      theme_minimal(base_size = 12)
    ggplotly(p) |> layout(margin = list(l = 60, b = 40)) |> config(displayModeBar = FALSE)
  })

  # coverage by parameter
  cov <- reactive({ refresh(); Q(
    "SELECT s.parameter, s.interval, o.source, count(*) obs,
            count(DISTINCT o.series_uid) series,
            min(datetime_utc)::date first_obs, max(datetime_utc)::date last_obs
     FROM okhydromet.observation o JOIN okhydromet.series s USING(series_uid)
     GROUP BY 1,2,3 ORDER BY 1,2,3") })

  output$plot_coverage <- renderPlotly({
    d <- cov() |> group_by(parameter) |> summarise(obs = sum(obs), .groups = "drop")
    lbl <- c(Q = "Discharge", H = "Stage", Tw = "Water temp", COND = "Conductivity", GW = "Groundwater")
    d$label <- ifelse(d$parameter %in% names(lbl), lbl[d$parameter], d$parameter)
    p <- ggplot(d, aes(x = obs, y = reorder(label, obs), fill = label)) + geom_col() +
      scale_x_continuous(labels = comma) +
      labs(x = "observations", y = NULL) + guides(fill = "none") + theme_minimal(base_size = 12)
    ggplotly(p) |> layout(margin = list(l = 100)) |> config(displayModeBar = FALSE)
  })

  output$freshness <- renderUI({
    refresh()
    d <- Q("SELECT CASE WHEN s.parameter='GW' THEN 'BC groundwater'
                        WHEN o.source='bc'    THEN 'BC surface'
                        ELSE upper(o.source) END AS source,
              round(extract(epoch FROM now()-max(o.datetime_utc))/3600.0, 1) AS hours,
              max(o.datetime_utc) AS latest
            FROM okhydromet.observation o JOIN okhydromet.series s USING(series_uid)
            GROUP BY 1 ORDER BY 1")
    if (!nrow(d)) return("No data")
    lapply(seq_len(nrow(d)), function(i) {
      h <- d$hours[i]; stale <- h > 48
      col <- if (h <= 26) "#1a9850" else if (h <= 48) "#f0a202" else "#d73027"
      div(class = "mb-3",
        div(class = "d-flex justify-content-between",
            tags$b(toupper(d$source[i])),
            tags$span(sprintf("%.0f h ago%s", h, if (stale) " ⚠" else ""))),
        div(class = "freshbar", style = sprintf("background:%s", col)),
        tags$small(class = "text-muted", format(as.POSIXct(d$latest[i]), "%Y-%m-%d %H:%M UTC")))
    })
  })

  output$summary_text <- renderUI({
    s <- stats(); refresh()
    por <- Q("SELECT min(datetime_utc)::date a, max(datetime_utc)::date b
              FROM okhydromet.observation o JOIN okhydromet.series sr USING(series_uid)
              WHERE sr.interval='daily'")
    HTML(sprintf(
      "<ul class='mb-0'>
        <li><b>%s observations</b> across <b>%s time series</b> at <b>%s stations</b></li>
        <li>Parameters: discharge, stage, groundwater level; water temperature as available</li>
        <li>Daily record spans <b>%s → %s</b></li>
        <li>Sources: Water Survey of Canada (federal); BC provincial as available</li>
        <li>Updated daily; weekly reconciliation audit</li>
       </ul>", fmt(s$obs), fmt(s$series), fmt(s$stn),
      ifelse(nrow(por), as.character(por$a), "—"), ifelse(nrow(por), as.character(por$b), "—")))
  })

  output$tbl_coverage <- renderDT(datatable(cov(), rownames = FALSE, options = list(pageLength = 8, dom = "tp")) |>
    formatRound("obs", digits = 0, mark = ","))

  # data-availability timeline: one bar per source × parameter × interval,
  # spanning first→last observation, labelled with the record count.
  output$plot_timeline <- renderPlotly({
    d <- cov()
    validate(need(nrow(d) > 0, "No data"))
    plbl <- c(Q = "Discharge", H = "Stage", Tw = "Water temp", COND = "Conductivity", GW = "Groundwater")
    d$param <- ifelse(d$parameter %in% names(plbl), plbl[d$parameter], d$parameter)
    d$row <- sprintf("%s · %s (%s)", toupper(d$source), d$param, d$interval)
    d$first_obs <- as.Date(d$first_obs); d$last_obs <- as.Date(d$last_obs)
    span <- as.numeric(max(d$last_obs) - min(d$first_obs))
    p <- ggplot(d, aes(y = reorder(row, first_obs), color = toupper(source),
                       text = sprintf("%s\n%s → %s\n%s records",
                                      row, first_obs, last_obs, comma(obs)))) +
      geom_segment(aes(x = first_obs, xend = last_obs, yend = row), linewidth = 5, lineend = "round") +
      geom_text(aes(x = last_obs, label = comma(obs)), hjust = -0.15, size = 3, color = "grey30") +
      scale_x_date(expand = expansion(mult = c(0.02, 0.14))) +
      labs(x = NULL, y = NULL, color = "Source") + theme_minimal(base_size = 12)
    ggplotly(p, tooltip = "text") |> layout(margin = list(l = 210)) |> config(displayModeBar = FALSE)
  })

  station_tbl <- reactive({ refresh(); Q(
    "SELECT st.station_uid, st.wsc_id, st.name, st.operator, st.drainage_area_km2,
            st.lat, st.lon, count(o.*) obs, max(o.datetime_utc) latest
     FROM okhydromet.station st
     LEFT JOIN okhydromet.series s ON s.station_uid=st.station_uid
     LEFT JOIN okhydromet.observation o ON o.series_uid=s.series_uid
     GROUP BY 1,2,3,4,5,6,7 ORDER BY st.name") })

  output$tbl_stations <- renderDT(datatable(
    station_tbl() |> mutate(latest = format(as.POSIXct(latest), "%Y-%m-%d")),
    rownames = FALSE, filter = "top", options = list(pageLength = 10)))

  output$map <- renderLeaflet({
    d <- station_tbl() |> filter(!is.na(lat), !is.na(lon))
    d$hrs <- as.numeric(difftime(Sys.time(), d$latest, units = "hours"))
    pal <- function(h) ifelse(is.na(h), "#999", ifelse(h <= 26, "#1a9850", ifelse(h <= 48, "#f0a202", "#d73027")))
    leaflet(d) |> addProviderTiles(providers$CartoDB.Positron) |>
      addCircleMarkers(~lon, ~lat, radius = 6, color = ~pal(hrs), fillOpacity = 0.85, stroke = FALSE,
        popup = ~sprintf("<b>%s</b><br>%s | %s<br>obs: %s<br>latest: %s",
                         name, station_uid, operator, format(obs, big.mark=","),
                         format(as.POSIXct(latest), "%Y-%m-%d %H:%M"))) |>
      addLegend("bottomright", colors = c("#1a9850","#f0a202","#d73027","#999"),
                labels = c("< 26 h","26–48 h","> 48 h","no data"), title = "Freshness")
  })

  output$tbl_runs <- renderDT(datatable(
    Q("SELECT run_id, source, status, rows_in,
         started_ts::timestamp(0) started, finished_ts::timestamp(0) finished
       FROM okhydromet.pull_run ORDER BY run_id DESC LIMIT 50"),
    rownames = FALSE, options = list(pageLength = 10)) |> formatRound("rows_in", digits = 0, mark = ","))

  output$tbl_audit <- renderDT(datatable(
    Q("SELECT audit_id, scope, stations_checked, discrepancies, run_ts::timestamp(0) run_ts
       FROM okhydromet.audit_log ORDER BY audit_id DESC LIMIT 25"),
    rownames = FALSE, options = list(pageLength = 5, dom = "tp")))

  # ---- ONA / provincial audit ----
  ona <- reactive({ refresh(); Q("
    SELECT st.bc_aquarius_loc_id AS moe_id, st.name,
      count(DISTINCT s.series_uid) series,
      string_agg(DISTINCT s.parameter, ', ' ORDER BY s.parameter) params,
      count(o.*) points,
      min(o.datetime_utc)::date first_obs, max(o.datetime_utc)::date last_obs,
      round(100.0*count(*) FILTER (WHERE o.approval_level IN ('approved','reviewed'))
            / NULLIF(count(o.*),0), 1) pct_qaqc,
      round(extract(epoch FROM now()-max(o.datetime_utc))/86400.0)::int days_stale
    FROM okhydromet.station st
    JOIN okhydromet.series s ON s.station_uid=st.station_uid
    JOIN okhydromet.observation o ON o.series_uid=s.series_uid AND o.source='bc'
    WHERE st.operator='BC' AND st.station_type IS DISTINCT FROM 'groundwater_well'
    GROUP BY 1,2 ORDER BY st.name") })

  output$ona_n   <- renderText(nrow(ona()))
  output$ona_pts <- renderText(fmt(sum(ona()$points)))
  output$ona_qaqc <- renderText({ d <- ona(); if (!nrow(d)) return("—")
    paste0(round(100*sum(d$points*ifelse(is.na(d$pct_qaqc),0,d$pct_qaqc)/100)/sum(d$points),1), "%") })
  output$ona_latest <- renderText({ d <- ona(); if (nrow(d)) format(max(as.Date(d$last_obs)),"%Y-%m-%d") else "—" })

  output$ona_qaqc_plot <- renderPlotly({
    d <- Q("SELECT st.name, COALESCE(o.approval_level,'unspecified') approval, count(*) n
            FROM okhydromet.station st
            JOIN okhydromet.series s ON s.station_uid=st.station_uid
            JOIN okhydromet.observation o ON o.series_uid=s.series_uid AND o.source='bc'
            WHERE st.operator='BC' AND st.station_type IS DISTINCT FROM 'groundwater_well'
            GROUP BY 1,2")
    validate(need(nrow(d) > 0, "No ONA/provincial data loaded yet"))
    lv <- c("working","in_review","reviewed","approved","unspecified")
    d$approval <- factor(d$approval, levels = lv)
    cols <- c(working="#bdbdbd", in_review="#f0a202", reviewed="#4a90d9", approved="#1a9850", unspecified="#e6e6e6")
    p <- ggplot(d, aes(y = reorder(name, n, sum), x = n, fill = approval)) + geom_col() +
      scale_fill_manual(values = cols, drop = FALSE) + scale_x_continuous(labels = comma) +
      labs(x = "data points", y = NULL, fill = "Approval") +
      theme_minimal(base_size = 12) + theme(axis.text.y = element_text(size = 11))
    ggplotly(p) |> layout(margin = list(l = 250)) |> config(displayModeBar = FALSE)
  })

  ona_audit <- reactive({
    d <- ona(); if (!nrow(d)) return(d)
    d$qaqc_status <- ifelse(is.na(d$pct_qaqc) | d$pct_qaqc < 10, "Provisional (working)",
                     ifelse(d$pct_qaqc < 90, "Partially reviewed", "Approved"))
    d$freshness <- ifelse(d$days_stale <= 2, "Current", ifelse(d$days_stale <= 14, "Recent", "Stale"))
    d
  })

  output$ona_status_summary <- renderUI({
    d <- ona_audit(); validate(need(nrow(d) > 0, "No data yet"))
    HTML(sprintf("<ul class='mb-0'>
      <li><b>%d</b> stations reporting</li>
      <li><b>%s</b> parameter-series</li>
      <li><b>%d</b> stations <span style='color:#777'>provisional</span> (not yet QAQC-approved)</li>
      <li><b>%d</b> stations <span style='color:#d73027'>stale</span> (&gt;14 d)</li>
      <li>Record spans <b>%s → %s</b></li></ul>",
      nrow(d), sum(d$series), sum(d$qaqc_status == "Provisional (working)"),
      sum(d$freshness == "Stale"), as.character(min(as.Date(d$first_obs))), as.character(max(as.Date(d$last_obs)))))
  })

  output$ona_table <- renderDT(datatable(
    ona_audit()[, c("moe_id","name","params","series","points","first_obs","last_obs","pct_qaqc","days_stale","qaqc_status","freshness")],
    rownames = FALSE, filter = "top",
    colnames = c("MoE ID","Station","Parameters","Series","Data points","First","Last","% QAQC","Days stale","QAQC status","Freshness"),
    options = list(pageLength = 15)) |> formatRound("points", digits = 0, mark = ","))

  output$dl_ona_audit <- downloadHandler(
    filename = function() sprintf("ona_station_audit_%s.csv", Sys.Date()),
    content = function(f) write.csv(ona_audit(), f, row.names = FALSE))
  outputOptions(output, "dl_ona_audit", suspendWhenHidden = FALSE)

  # ---- ONA by-year summary ----
  ona_year <- reactive({ refresh(); Q("
    WITH obs AS (
      SELECT st.station_uid, o.datetime_utc,
        o.datetime_utc - lag(o.datetime_utc) OVER (PARTITION BY o.series_uid ORDER BY o.datetime_utc) gap
      FROM okhydromet.observation o JOIN okhydromet.series s USING(series_uid)
      JOIN okhydromet.station st USING(station_uid)
      WHERE o.source='bc' AND st.station_type IS DISTINCT FROM 'groundwater_well'),
    py AS (SELECT extract(year FROM datetime_utc)::int yr, count(DISTINCT station_uid) stations,
                  count(*) points FROM obs GROUP BY 1),
    vd AS (SELECT DISTINCT extract(year FROM datetime_utc)::int yr, station_uid, datetime_utc::date d
           FROM obs WHERE gap > interval '1 day'),
    v  AS (SELECT yr, count(*) visits FROM vd GROUP BY 1)
    SELECT py.yr, py.stations, py.points, COALESCE(v.visits,0) visits
    FROM py LEFT JOIN v USING(yr) ORDER BY py.yr") })

  output$ona_year_plot <- renderPlotly({
    d <- ona_year(); validate(need(nrow(d) > 0, "No data"))
    dl <- rbind(data.frame(yr = d$yr, metric = "Stations reporting", n = d$stations),
                data.frame(yr = d$yr, metric = "Field visits (proxy)", n = d$visits))
    p <- ggplot(dl, aes(factor(yr), n, fill = metric)) + geom_col(position = "dodge") +
      scale_fill_manual(values = c("Stations reporting" = OK_TEAL, "Field visits (proxy)" = "#e0a800")) +
      labs(x = NULL, y = NULL, fill = NULL) + theme_minimal(base_size = 12)
    ggplotly(p) |> layout(legend = list(orientation = "h", y = 1.12)) |> config(displayModeBar = FALSE)
  })

  output$ona_year_table <- renderDT({
    d <- ona_year()
    d$rating <- "pending"; d$qaqc <- "Provisional"
    datatable(d[, c("yr","stations","points","visits","rating","qaqc")], rownames = FALSE,
      colnames = c("Year","Stations","Data points","Field visits*","Rating","QAQC"),
      options = list(dom = "t", paging = FALSE, scrollY = "330px", scrollCollapse = TRUE)) |>
      formatRound("points", digits = 0, mark = ",")
  })

  output$ona_heatmap <- renderPlotly({
    d <- Q("SELECT st.name, extract(year FROM o.datetime_utc)::int yr, count(*) points
            FROM okhydromet.observation o JOIN okhydromet.series s USING(series_uid)
            JOIN okhydromet.station st USING(station_uid)
            WHERE o.source='bc' AND st.station_type IS DISTINCT FROM 'groundwater_well' GROUP BY 1,2")
    validate(need(nrow(d) > 0, "No data"))
    p <- ggplot(d, aes(factor(yr), reorder(name, points, sum), fill = points,
                       text = sprintf("%s\n%d: %s points", name, yr, format(points, big.mark = ",")))) +
      geom_tile(color = "white", linewidth = 0.4) +
      scale_fill_gradient(low = "#d7efe9", high = OK_TEAL, trans = "log10", name = "points") +
      labs(x = NULL, y = NULL) + theme_minimal(base_size = 12)
    ggplotly(p, tooltip = "text") |> layout(margin = list(l = 230)) |> config(displayModeBar = FALSE)
  })
  outputOptions(output, "ona_heatmap", suspendWhenHidden = FALSE)

  # ---- Groundwater (BC PGOWN observation wells) ----
  gw <- reactive({ refresh(); Q("
    SELECT st.bc_aquarius_loc_id AS well, st.name, st.lat, st.lon,
      count(o.*) points, min(o.datetime_utc)::date first_obs, max(o.datetime_utc)::date last_obs,
      round(100.0*count(*) FILTER (WHERE o.approval_level='approved')/NULLIF(count(o.*),0),1) pct_approved,
      round(extract(epoch FROM now()-max(o.datetime_utc))/86400.0)::int days_stale
    FROM okhydromet.station st
    JOIN okhydromet.series s ON s.station_uid=st.station_uid
    JOIN okhydromet.observation o ON o.series_uid=s.series_uid
    WHERE st.station_type='groundwater_well'
    GROUP BY 1,2,3,4 ORDER BY st.name") })

  output$gw_n    <- renderText(nrow(gw()))
  output$gw_pts  <- renderText(fmt(sum(gw()$points)))
  output$gw_appr <- renderText({ d <- gw(); if (!nrow(d)) return("—")
    paste0(round(100*sum(d$points*ifelse(is.na(d$pct_approved),0,d$pct_approved)/100)/sum(d$points),1), "%") })
  output$gw_span <- renderText({ d <- gw(); if (!nrow(d)) return("—")
    paste(format(min(as.Date(d$first_obs)),"%Y"), "→", format(max(as.Date(d$last_obs)),"%Y")) })

  output$gw_map <- renderLeaflet({
    d <- gw() |> filter(!is.na(lat), !is.na(lon))
    validate(need(nrow(d) > 0, "No groundwater wells loaded"))
    pal <- function(h) ifelse(is.na(h), "#999", ifelse(h <= 14, "#1a9850", ifelse(h <= 180, "#f0a202", "#d73027")))
    leaflet(d) |> addProviderTiles(providers$CartoDB.Positron) |>
      addCircleMarkers(~lon, ~lat, radius = 6, color = ~pal(days_stale), fillOpacity = 0.85, stroke = FALSE,
        popup = ~sprintf("<b>%s</b><br>%s<br>%s readings | %s → %s<br>%s%% approved",
                         name, well, format(points, big.mark = ","), first_obs, last_obs,
                         ifelse(is.na(pct_approved), 0, pct_approved))) |>
      addLegend("bottomright", colors = c("#1a9850","#f0a202","#d73027"),
                labels = c("current (< 14 d)","dormant (< 6 mo)","historical (> 6 mo)"), title = "Freshness")
  })
  outputOptions(output, "gw_map", suspendWhenHidden = FALSE)

  output$gw_table <- renderDT(datatable(
    gw()[, c("well","name","points","first_obs","last_obs","pct_approved","days_stale")],
    rownames = FALSE, filter = "top",
    colnames = c("Well","Name","Readings","First","Last","% approved","Days stale"),
    options = list(pageLength = 10)) |> formatRound("points", digits = 0, mark = ","))

  output$dl_gw <- downloadHandler(
    filename = function() sprintf("okhydromet_groundwater_wells_%s.csv", Sys.Date()),
    content = function(f) write.csv(gw(), f, row.names = FALSE))
  outputOptions(output, "dl_gw", suspendWhenHidden = FALSE)

  # ---- downloads (read-only sharing) ----
  dl <- function(name, fn) downloadHandler(
    filename = function() sprintf("okhydromet_%s_%s.csv", name, format(Sys.Date())),
    content = function(file) write.csv(fn(), file, row.names = FALSE))
  output$dl_stations <- dl("stations", function() station_tbl())
  output$dl_coverage <- dl("coverage", function() cov())
  output$dl_latest   <- dl("latest_per_series", function() Q(
    "SELECT s.station_uid, s.parameter, s.interval, o.value, s.units, o.datetime_utc, o.approval_level
     FROM okhydromet.observation o JOIN okhydromet.series s USING(series_uid)
     WHERE (o.series_uid,o.datetime_utc) IN
       (SELECT series_uid, max(datetime_utc) FROM okhydromet.observation GROUP BY series_uid)
     ORDER BY 1,2"))
  output$dl_daily <- dl("daily_means", function() Q(
    "SELECT s.station_uid, s.parameter, o.datetime_utc::date AS date, o.value, s.units, o.approval_level
     FROM okhydromet.observation o JOIN okhydromet.series s USING(series_uid)
     WHERE s.interval='daily' ORDER BY 1,2,3"))
  # keep download handlers alive on non-default tab (avoids 404)
  for (id in c("dl_stations","dl_coverage","dl_latest","dl_daily"))
    outputOptions(output, id, suspendWhenHidden = FALSE)

  output$access_info <- renderUI(HTML(sprintf(
    "<p>A <b>read-only</b> database account is available for analysts who want to query directly
      (SQL, R <code>DBI</code>/<code>RPostgres</code>, Python <code>psycopg</code>, etc.):</p>
     <pre class='bg-light p-2'>host      = %s
port      = 5432
database  = okhydromet
user      = okhydromet_read   (SELECT-only)
sslmode   = verify-ca         (client certificate required)</pre>
     <p class='text-muted small'>A password <b>and a client TLS certificate</b> are issued together on
      request (OBWB Water Stewardship) — the instance requires a client certificate, so credentials and
      cert files are provided as a set. The role can only run <code>SELECT</code> against the
      <code>okhydromet</code> schema. For open reuse, prefer the CSV downloads above. A public read-only
      REST endpoint (PostgREST) is planned.</p>",
    Sys.getenv("DB_PUBLIC_HOST", "34.95.1.176"))))

  output$about <- renderUI(HTML(sprintf(
    "<div style='max-width:760px'>
     <h4>About this database</h4>
     <p>An independent, append-only <b>backup of Okanagan-basin hydrometric data</b> — Water Survey of
      Canada plus BC provincial/ONA-serviced stations — mirroring what is held in the provincial data
      warehouse. It exists so OBWB's tools keep working even if provincial access is interrupted.</p>
     <h5>How it works</h5>
     <ul>
       <li><b>Store:</b> PostgreSQL + PostGIS on Google Cloud SQL, <b>Montréal (northamerica-northeast1)</b>
         — all data resident in Canada (sovereignty).</li>
       <li><b>Ingestion:</b> containerised R jobs on Cloud Run pull from the ECCC GeoMet API (realtime)
         and HYDAT (history); a provincial AQUARIUS leg adds BC provincial / ONA-serviced surface
         stations plus the provincial groundwater observation well network (PGOWN).</li>
       <li><b>Schedule:</b> daily incremental pull; weekly reconciliation audit that backfills gaps.</li>
       <li><b>Provenance:</b> every value is tagged with its source, grade, approval level and ingest run.</li>
     </ul>
     <p class='text-muted small'>Current record: %s observations · %s stations · updated daily.</p>
     </div>", fmt(stats()$obs), fmt(stats()$stn))))
}

shinyApp(ui, server)
