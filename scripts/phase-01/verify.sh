#!/usr/bin/env bash
# Phase 01: verify the bootstrap. Output of this script is good evidence for the doc.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID first}"
SA_EMAIL="${SA_NAME:-terraform-batch-fleet}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "--- Active project"
gcloud config get-value project

echo "--- Compute Engine API"
gcloud services list --enabled --filter="config.name:compute.googleapis.com" \
  --format="value(config.name)"

echo "--- Service account roles"
gcloud projects get-iam-policy "${PROJECT_ID}" \
  --flatten="bindings[].members" \
  --filter="bindings.members:serviceAccount:${SA_EMAIL}" \
  --format="table(bindings.role)"

echo "--- Service account keys (user-managed)"
gcloud iam service-accounts keys list --iam-account="${SA_EMAIL}" --managed-by=user

echo "--- Terraform auth smoke test"
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/terraform"
terraform init -input=false >/dev/null
terraform validate
terraform plan -input=false
