#!/usr/bin/env bash
# ok-hydromet-backup — provision Cloud SQL PostgreSQL + PostGIS in Montréal (ne1).
# Sovereignty: region is HARD-PINNED to northamerica-northeast1.
# Idempotent: safe to re-run (skips create if the instance already exists).
#
#   bash inst/dev/01_provision_cloudsql.sh
set -euo pipefail

PROJECT="${PROJECT:-okanagan-hydrology-project}"
REGION="northamerica-northeast1"          # Montréal — do NOT change (data sovereignty)
INSTANCE="${INSTANCE:-okhydromet-pg}"
DB_NAME="${DB_NAME:-okhydromet}"
TIER="${TIER:-db-g1-small}"               # pragmatic minimum for PostGIS+PostgREST
STORAGE_GB="${STORAGE_GB:-10}"
PG_VERSION="${PG_VERSION:-POSTGRES_16}"
APP_USER="${APP_USER:-okhydromet_app}"

echo "Project=$PROJECT  Region=$REGION  Instance=$INSTANCE  Tier=$TIER"

gcloud services enable sqladmin.googleapis.com secretmanager.googleapis.com --project="$PROJECT"

if gcloud sql instances describe "$INSTANCE" --project="$PROJECT" >/dev/null 2>&1; then
  echo "Instance $INSTANCE already exists — skipping create."
else
  echo "Creating Cloud SQL instance (this takes ~10 min) ..."
  gcloud sql instances create "$INSTANCE" \
    --project="$PROJECT" \
    --database-version="$PG_VERSION" \
    --region="$REGION" \
    --tier="$TIER" \
    --edition=enterprise \
    --storage-type=SSD \
    --storage-size="$STORAGE_GB" \
    --storage-auto-increase \
    --availability-type=zonal \
    --backup-start-time=09:00 \
    --enable-point-in-time-recovery \
    --retained-backups-count=7 \
    --database-flags=cloudsql.enable_pgaudit=off
fi

# Database
gcloud sql databases create "$DB_NAME" --instance="$INSTANCE" --project="$PROJECT" 2>/dev/null \
  && echo "Database $DB_NAME created." || echo "Database $DB_NAME already exists."

# App user — password stored in Secret Manager (generated once)
if ! gcloud secrets describe okhydromet-db-pw --project="$PROJECT" >/dev/null 2>&1; then
  PW="$(openssl rand -base64 24)"
  printf '%s' "$PW" | gcloud secrets create okhydromet-db-pw --project="$PROJECT" \
    --replication-policy=user-managed --locations="$REGION" --data-file=-
  echo "Created secret okhydromet-db-pw (Montréal-pinned)."
else
  PW="$(gcloud secrets versions access latest --secret=okhydromet-db-pw --project="$PROJECT")"
  echo "Reusing existing secret okhydromet-db-pw."
fi
gcloud sql users create "$APP_USER" --instance="$INSTANCE" --project="$PROJECT" --password="$PW" 2>/dev/null \
  && echo "User $APP_USER created." || echo "User $APP_USER already exists."

echo
echo "Connection name: $(gcloud sql instances describe "$INSTANCE" --project="$PROJECT" --format='value(connectionName)')"
echo "Next: bash inst/dev/02_apply_schema.sh"
