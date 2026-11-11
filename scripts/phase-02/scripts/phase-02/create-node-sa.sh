#!/usr/bin/env bash
# Phase 02: create the service account the batch VMs run as.
# Run as YOUR user (project owner), not the Terraform SA. Keeping this outside
# Terraform means the Terraform SA never needs IAM admin rights.
#
# The VMs only need to write logs and metrics. They do NOT get the default
# Compute Engine SA, which has project Editor.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
if [[ -z "${PROJECT_ID}" ]]; then
  echo "No project set. Run: export PROJECT_ID=your-project-id" >&2
  exit 1
fi

SA_NAME="batch-node-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "==> Creating ${SA_EMAIL} (skips if it exists)"
if ! gcloud iam service-accounts describe "${SA_EMAIL}" >/dev/null 2>&1; then
  gcloud iam service-accounts create "${SA_NAME}" \
    --display-name="Batch node runtime identity"
fi

grant_role() {
  local role="$1" attempt
  for attempt in 1 2 3 4 5 6; do
    if gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
         --member="serviceAccount:${SA_EMAIL}" \
         --role="${role}" \
         --condition=None >/dev/null 2>&1; then
      echo "    granted"
      return 0
    fi
    echo "    not ready yet (attempt ${attempt}/6), waiting $((attempt * 5))s"
    sleep $((attempt * 5))
  done
  echo "Failed to grant ${role}. Re-run in a minute." >&2
  return 1
}

for ROLE in roles/logging.logWriter roles/monitoring.metricWriter; do
  echo "==> Granting ${ROLE}"
  grant_role "${ROLE}"
done

echo "==> Roles on ${SA_EMAIL}:"
gcloud projects get-iam-policy "${PROJECT_ID}" \
  --flatten="bindings[].members" \
  --filter="bindings.members:serviceAccount:${SA_EMAIL}" \
  --format="table(bindings.role)"
