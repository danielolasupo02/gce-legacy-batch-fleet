#!/usr/bin/env bash
# Phase 01: bootstrap a GCP project for Terraform.
# Enables required APIs, creates the Terraform service account,
# grants roles, and drops a JSON key into terraform/credentials.json.
#
# Usage: PROJECT_ID=my-project ./scripts/phase-01/bootstrap.sh
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID first, e.g. PROJECT_ID=my-project}"
SA_NAME="${SA_NAME:-terraform-batch-fleet}"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
KEY_PATH="${KEY_PATH:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/terraform/credentials.json}"

echo "==> Setting active project to ${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}"

echo "==> Enabling APIs"
gcloud services enable \
  compute.googleapis.com \
  iam.googleapis.com \
  cloudresourcemanager.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com

echo "==> Creating service account ${SA_EMAIL} (skips if it exists)"
if ! gcloud iam service-accounts describe "${SA_EMAIL}" >/dev/null 2>&1; then
  gcloud iam service-accounts create "${SA_NAME}" \
    --display-name="Terraform: GCE legacy batch fleet"
fi

# compute.admin: templates, MIGs, health checks, load balancer pieces.
# iam.serviceAccountUser: lets Terraform attach a service account to the VMs
#   in the instance template. compute.admin alone is NOT enough for this.
for ROLE in roles/compute.admin roles/iam.serviceAccountUser; do
  echo "==> Granting ${ROLE}"
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${ROLE}" \
    --condition=None >/dev/null
done

if [[ -f "${KEY_PATH}" ]]; then
  echo "==> Key already exists at ${KEY_PATH}, not creating another"
else
  echo "==> Creating key at ${KEY_PATH}"
  mkdir -p "$(dirname "${KEY_PATH}")"
  gcloud iam service-accounts keys create "${KEY_PATH}" --iam-account="${SA_EMAIL}"
  chmod 600 "${KEY_PATH}"
fi

echo "==> Done. Verify with: ./scripts/phase-01/verify.sh"
