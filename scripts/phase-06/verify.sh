#!/usr/bin/env bash
# Phase 06: show that every node got the shared environment AND its own
# unique values from metadata, and that each node applied them at boot.
#
# Usage:
#   ./scripts/phase-06/verify.sh
#   OUT=~/phase06-evidence.txt ./scripts/phase-06/verify.sh
set -uo pipefail

REGION="${REGION:-us-central1}"
MIG="${MIG:-batch-mig}"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
OUT="${OUT:-/dev/null}"
LB_IP="$(terraform -chdir="${ROOT}/terraform" output -raw lb_ip 2>/dev/null || true)"

section() { printf '\n========== %s ==========\n' "$1"; }

{
  section "Per-instance configs on the MIG (stateful metadata)"
  gcloud compute instance-groups managed instance-configs list "${MIG}" --region="${REGION}" \
    --format="table(name,preservedState.metadata)"

  section "Metadata on each VM, as the metadata server serves it"
  for VM in $(gcloud compute instance-groups managed list-instances "${MIG}" --region="${REGION}" --format="value(name.basename())" | sort); do
    ZONE=$(gcloud compute instances list --filter="name=${VM}" --format="value(zone.basename())")
    gcloud compute instances describe "${VM}" --zone="${ZONE}" --format=json | python3 -c '
import json, sys
d = json.load(sys.stdin)
m = {i["key"]: i.get("value", "") for i in d.get("metadata", {}).get("items", [])}
env = m.get("app-environment", "").replace("\n", ", ")
print("{:<18} {:<15} shard-id={:<3} node-role={:<8} shard-count={}".format(
    d["name"], d["zone"].rsplit("/", 1)[-1], m.get("shard-id", "-"),
    m.get("node-role", "-"), m.get("shard-count", "-")))
print("{:<34} app-environment: {}".format("", env))'
  done

  section "What each node applied at boot (via IAP SSH)"
  for VM in $(gcloud compute instance-groups managed list-instances "${MIG}" --region="${REGION}" --format="value(name.basename())" | sort); do
    ZONE=$(gcloud compute instances list --filter="name=${VM}" --format="value(zone.basename())")
    echo "--- ${VM}"
    gcloud compute ssh "${VM}" --zone="${ZONE}" --tunnel-through-iap --quiet --command='
      grep -E "^(NODE_SHARD|NODE_ROLE|SHARD_COUNT|APP_ENV_KEYS|LOG_LEVEL|BATCH_MODE|MAX_INPUT_MB|REPORT_PREFIX)=" /etc/batch-app/app.env
      sudo grep -E "node: shard=|app-environment keys" /var/log/batch-startup.log | tail -n 2' 2>/dev/null \
      || echo "ssh failed"
  done

  if [[ -n "${LB_IP}" ]]; then
    section "12 requests through the load balancer"
    for i in $(seq 1 12); do
      curl -s -m 5 "http://${LB_IP}/" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("{:<18} {:<15} shard={} role={}".format(
    d["instance"], d["zone"], d.get("shard"), d.get("role")))' 2>/dev/null \
        || echo "ERROR no-response"
    done | sort | uniq -c

    section "/config from one node"
    curl -s -m 5 "http://${LB_IP}/config" | python3 -m json.tool
  fi
} 2>&1 | tee "${OUT}"
