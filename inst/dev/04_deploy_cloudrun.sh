#!/usr/bin/env bash
# ok-hydromet-backup — deploy the ETL as Cloud Run Jobs + Cloud Scheduler triggers.
# All resources in Montréal (northamerica-northeast1). Idempotent.
#   bash inst/dev/04_deploy_cloudrun.sh
set -euo pipefail

PROJECT="${PROJECT:-okanagan-hydrology-project}"
REGION="northamerica-northeast1"            # Montréal — sovereignty
INSTANCE="okhydromet-pg"
CONN="$(gcloud sql instances describe $INSTANCE --project=$PROJECT --format='value(connectionName)')"
REPO="okhydromet"
IMG="${REGION}-docker.pkg.dev/${PROJECT}/${REPO}/etl:latest"
SA="okhydromet-etl@${PROJECT}.iam.gserviceaccount.com"

echo "Project=$PROJECT Region=$REGION Conn=$CONN"
gcloud services enable run.googleapis.com cloudbuild.googleapis.com \
  artifactregistry.googleapis.com cloudscheduler.googleapis.com --project="$PROJECT"

# ── Artifact Registry ────────────────────────────────────────────────────────
gcloud artifacts repositories describe "$REPO" --location="$REGION" --project="$PROJECT" >/dev/null 2>&1 \
  || gcloud artifacts repositories create "$REPO" --repository-format=docker \
       --location="$REGION" --project="$PROJECT" --description="ok-hydromet-backup images"

# ── Service account + IAM ────────────────────────────────────────────────────
gcloud iam service-accounts describe "$SA" --project="$PROJECT" >/dev/null 2>&1 \
  || gcloud iam service-accounts create okhydromet-etl --project="$PROJECT" \
       --display-name="ok-hydromet-backup ETL"
for ROLE in roles/cloudsql.client roles/secretmanager.secretAccessor roles/run.invoker; do
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:$SA" --role="$ROLE" --condition=None --quiet >/dev/null
done

# ── Build image (Cloud Build; non-BuildKit) ──────────────────────────────────
echo "Building image (~5-10 min) ..."
gcloud builds submit --tag="$IMG" --project="$PROJECT" .

# ── Cloud Run Jobs (daily + weekly) ──────────────────────────────────────────
deploy_job () {
  local NAME="$1" MODE="$2"
  gcloud run jobs deploy "$NAME" \
    --image="$IMG" --region="$REGION" --project="$PROJECT" \
    --service-account="$SA" \
    --set-cloudsql-instances="$CONN" \
    --set-secrets="DB_PASS=okhydromet-db-pw:latest" \
    --set-env-vars="MODE=${MODE},DB_HOST=/cloudsql/${CONN},DB_NAME=okhydromet,DB_USER=okhydromet_app,RAW_MOUNT=/raw" \
    --add-volume=name=raw,type=cloud-storage,bucket=okhydromet-raw-ne1 \
    --add-volume-mount=volume=raw,mount-path=/raw \
    --max-retries=2 --task-timeout=900 --memory=1Gi
}
deploy_job okhydromet-etl-daily  daily
deploy_job okhydromet-etl-weekly weekly

# ── Cloud Scheduler triggers (Pacific time) ──────────────────────────────────
sched () {
  local NAME="$1" CRON="$2" JOB="$3"
  local URI="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT}/jobs/${JOB}:run"
  if gcloud scheduler jobs describe "$NAME" --location="$REGION" --project="$PROJECT" >/dev/null 2>&1; then
    gcloud scheduler jobs update http "$NAME" --location="$REGION" --project="$PROJECT" \
      --schedule="$CRON" --time-zone="America/Vancouver" --uri="$URI" \
      --http-method=POST --oauth-service-account-email="$SA"
  else
    gcloud scheduler jobs create http "$NAME" --location="$REGION" --project="$PROJECT" \
      --schedule="$CRON" --time-zone="America/Vancouver" --uri="$URI" \
      --http-method=POST --oauth-service-account-email="$SA"
  fi
}
sched okhydromet-daily  "0 4 * * *"  okhydromet-etl-daily     # 04:00 PT daily
sched okhydromet-weekly "30 4 * * 1" okhydromet-etl-weekly    # 04:30 PT Mondays

echo
echo "Deployed. Test now:  gcloud run jobs execute okhydromet-etl-daily --region=$REGION --project=$PROJECT --wait"

# ── PROVINCIAL LEG ACTIVATION (run once BC MoE issues AQUARIUS API creds) ─────
# The code (R/etl_provincial.R, MODE=provincial) already ships in the image. To turn it on:
#
# 1) Store the credentials as secrets (Montréal-pinned):
#   printf '%s' "<AQ_USERNAME>" | gcloud secrets create okhydromet-aq-user --project=$PROJECT \
#     --replication-policy=user-managed --locations=$REGION --data-file=-
#   printf '%s' "<AQ_PASSWORD>" | gcloud secrets create okhydromet-aq-pass --project=$PROJECT \
#     --replication-policy=user-managed --locations=$REGION --data-file=-
#
# 2) Deploy the provincial job (no rebuild needed — same image):
#   gcloud run jobs deploy okhydromet-etl-provincial --image="$IMG" --region=$REGION --project=$PROJECT \
#     --service-account="$SA" --set-cloudsql-instances="$CONN" \
#     --set-secrets="DB_PASS=okhydromet-db-pw:latest,AQ_USER=okhydromet-aq-user:latest,AQ_PASS=okhydromet-aq-pass:latest" \
#     --set-env-vars="MODE=provincial,DB_HOST=/cloudsql/$CONN,DB_NAME=okhydromet,DB_USER=okhydromet_app,AQ_SINCE_DAYS=3" \
#     --max-retries=2 --task-timeout=1800 --memory=1Gi
#
# 3) First run: initial backfill with a wide window, then verify field-name VERIFY notes:
#   gcloud run jobs execute okhydromet-etl-provincial --region=$REGION --project=$PROJECT \
#     --update-env-vars=AQ_SINCE_DAYS=3650 --wait
#
# 4) Schedule daily (04:15 PT):
#   gcloud scheduler jobs create http okhydromet-provincial --location=$REGION --project=$PROJECT \
#     --schedule="15 4 * * *" --time-zone="America/Vancouver" \
#     --uri="https://$REGION-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/$PROJECT/jobs/okhydromet-etl-provincial:run" \
#     --http-method=POST --oauth-service-account-email="$SA"
