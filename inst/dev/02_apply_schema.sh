#!/usr/bin/env bash
# ok-hydromet-backup — apply conf/schema.sql to the Cloud SQL instance via the
# Cloud SQL Auth Proxy (IAM-secured, no public IP exposure needed).
#
#   bash inst/dev/02_apply_schema.sh
set -euo pipefail

# libpq's psql (brew) is not on PATH by default
[ -d /opt/homebrew/opt/libpq/bin ] && export PATH="/opt/homebrew/opt/libpq/bin:$PATH"

PROJECT="${PROJECT:-okanagan-hydrology-project}"
INSTANCE="${INSTANCE:-okhydromet-pg}"
DB_NAME="${DB_NAME:-okhydromet}"
APP_USER="${APP_USER:-okhydromet_app}"
CONN="$(gcloud sql instances describe "$INSTANCE" --project="$PROJECT" --format='value(connectionName)')"
PW="$(gcloud secrets versions access latest --secret=okhydromet-db-pw --project="$PROJECT")"

# Start the Auth Proxy (v2). Install: https://cloud.google.com/sql/docs/postgres/sql-proxy
cloud-sql-proxy --port 5433 "$CONN" &
PROXY_PID=$!
trap 'kill $PROXY_PID 2>/dev/null' EXIT
sleep 5

echo "Enabling PostGIS + applying schema ..."
PGPASSWORD="$PW" psql "host=127.0.0.1 port=5433 dbname=$DB_NAME user=$APP_USER" \
  -v ON_ERROR_STOP=1 \
  -c "CREATE EXTENSION IF NOT EXISTS postgis;" \
  -f conf/schema.sql

echo "Schema applied. Verifying tables:"
PGPASSWORD="$PW" psql "host=127.0.0.1 port=5433 dbname=$DB_NAME user=$APP_USER" \
  -c "\dt okhydromet.*"
