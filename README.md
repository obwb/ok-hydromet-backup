# ok-hydromet-backup

Sovereign, append-only **backup of all Okanagan-basin hydrometric data** (OBWB/ONA-serviced
stations + Water Survey of Canada) currently held in the BC provincial data warehouse.

**Goals**
- Mirror every Okanagan hydrometric record (provisional + QAQC'd) with full history.
- Scrapable/queryable for OBWB's Shiny apps and analysts.
- **Survive loss of provincial access** (e.g. BC strike) via a direct-from-source back-door.
- Self-audit weekly vs the provincial DB and backfill; update daily.
- **All data resident in Canada** — Google Cloud Montréal (`northamerica-northeast1`).

**Status:** Phase 0 — Discovery & Access. See [`docs/WORKPLAN.md`](docs/WORKPLAN.md) for the full
framework, architecture, back-door design, and phased plan.

**Stack (planned):** GCS landing bucket (immutable) → BigQuery warehouse → Cloud Run (R) ETL →
Cloud Scheduler (daily + weekly audit), all in `northamerica-northeast1`.
