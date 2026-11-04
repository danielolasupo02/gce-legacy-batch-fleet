#!/usr/bin/env bash
# Phase 01, step 0: create a brand-new GCP project and link it to billing.
# For a first-time account: sign up for the free trial in the console first
# (https://console.cloud.google.com/freetrial) so a billing account exists.
#
# Usage:
#   ./scripts/phase-01/create-project.sh                # generates an ID
#   PROJECT_ID=legacy-batch-fleet-1234 ./scripts/phase-01/create-project.sh
set -euo pipefail

# Project IDs are global across ALL of GCP: 6-30 chars, lowercase letters,
# digits and hyphens, must start with a letter. A random suffix avoids clashes.
PROJECT_ID="${PROJECT_ID:-legacy-batch-fleet-$(( RANDOM % 9000 + 1000 ))}"
PROJECT_NAME="${PROJECT_NAME:-GCE Legacy Batch Fleet}"

echo "==> Checking you are logged in"
ACCOUNT="$(gcloud config get-value account 2>/dev/null || true)"
if [[ -z "${ACCOUNT}" ]]; then
  echo "Not logged in. Run: gcloud auth login" >&2
  exit 1
fi
echo "    Logged in as ${ACCOUNT}"

echo "==> Creating project ${PROJECT_ID}"
if gcloud projects describe "${PROJECT_ID}" >/dev/null 2>&1; then
  echo "    Project already exists, reusing it"
else
  gcloud projects create "${PROJECT_ID}" --name="${PROJECT_NAME}"
fi

echo "==> Finding an open billing account"
BILLING_ACCOUNT="${BILLING_ACCOUNT:-$(gcloud billing accounts list \
  --filter="open=true" --format="value(name)" --limit=1)}"
if [[ -z "${BILLING_ACCOUNT}" ]]; then
  echo "No open billing account found. Start the free trial at" >&2
  echo "https://console.cloud.google.com/freetrial and re-run this script." >&2
  exit 1
fi
BILLING_ACCOUNT="${BILLING_ACCOUNT#billingAccounts/}"
echo "    Using billing account ${BILLING_ACCOUNT}"

echo "==> Linking project to billing (Compute Engine will not enable without this)"
gcloud billing projects link "${PROJECT_ID}" --billing-account="${BILLING_ACCOUNT}"

gcloud config set project "${PROJECT_ID}"

cat <<EOF

==> Project ready.
    export PROJECT_ID=${PROJECT_ID}
    ./scripts/phase-01/bootstrap.sh

    Write this ID down. You will need it in terraform.tfvars and in every
    console link in the docs.
EOF
