#!/usr/bin/env bash
# Phase 04: watch the MIG come up and print the evidence for the docs.
#
# Usage:
#   ./scripts/phase-04/verify.sh            # wait until stable, then show everything
#   ./scripts/phase-04/verify.sh --no-wait  # just show current state
#   OUT=~/phase04-evidence.txt ./scripts/phase-04/verify.sh   # also save to a file
set -uo pipefail

REGION="${REGION:-us-central1}"
MIG="${MIG:-batch-mig}"
OUT="${OUT:-/dev/null}"

section() { printf '\n========== %s ==========\n' "$1"; }

if [[ "${1:-}" != "--no-wait" ]]; then
  echo "==> Waiting for ${MIG} to be stable (all nodes created and healthy; first boot takes a few minutes)"
  start=$(date +%s)
  gcloud compute instance-groups managed wait-until "${MIG}" --region="${REGION}" --stable --timeout=900
  echo "==> Stable after $(( $(date +%s) - start ))s"
fi

{
  section "Instances (name, zone, status, health)"
  gcloud compute instance-groups managed list-instances "${MIG}" --region="${REGION}" \
    --format="table(name.basename(),zone.basename(),instanceStatus,currentAction,instanceHealth[0].detailedHealthState:label=HEALTH,version.name:label=VERSION)"

  section "Group settings"
  gcloud compute instance-groups managed describe "${MIG}" --region="${REGION}" \
    --format="yaml(targetSize,distributionPolicy,namedPorts,autoHealingPolicies,statefulPolicy,updatePolicy,status)"

  section "Disks (each node: boot disk + data disk)"
  gcloud compute disks list --filter="name~^batch-node" \
    --format="table(name,zone.basename(),sizeGb,type.basename(),users.basename())"

  section "Health check"
  gcloud compute health-checks describe batch-app-health-check \
    --format="yaml(httpHealthCheck.port,httpHealthCheck.requestPath,checkIntervalSec,timeoutSec,healthyThreshold,unhealthyThreshold)"

  section "App response from each node (via IAP SSH)"
  for VM in $(gcloud compute instance-groups managed list-instances "${MIG}" --region="${REGION}" --format="value(name.basename())"); do
    ZONE=$(gcloud compute instances list --filter="name=${VM}" --format="value(zone.basename())")
    printf '%s (%s): ' "${VM}" "${ZONE}"
    gcloud compute ssh "${VM}" --zone="${ZONE}" --tunnel-through-iap --quiet \
      --command='curl -s localhost:8080/healthz' 2>/dev/null || echo "ssh failed"
    echo
  done
} 2>&1 | tee "${OUT}"
