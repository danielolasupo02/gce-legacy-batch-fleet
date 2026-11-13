#!/usr/bin/env bash
# Phase 06: give every node its own shard-id and node-role through MIG
# per-instance metadata, and roll out the current template ONE NODE AT A TIME.
#
# Per node:
#   1. create/update its per-instance config (stateful metadata, not applied yet)
#   2. replace it: new template + its metadata (RECREATE keeps name and data disk)
#   3. wait until it is RUNNING and HEALTHY before touching the next node
#
# The other nodes keep serving behind the load balancer throughout.
#
# Usage: ./scripts/phase-06/rollout.sh
set -euo pipefail

REGION="${REGION:-us-central1}"
MIG="${MIG:-batch-mig}"
TIMEOUT_SEC="${TIMEOUT_SEC:-900}"

mig() { gcloud compute instance-groups managed "$@" --region="${REGION}"; }

wait_healthy() {
  local node="$1" start state
  start=$(date +%s)
  while :; do
    state="$(mig list-instances "${MIG}" --filter="name~^${node}\$" \
      --format="value(instanceStatus,currentAction,instanceHealth[0].detailedHealthState)" | tr '\t' ' ')"
    printf '\r    %-40s %4ss' "${state:-pending}" "$(( $(date +%s) - start ))"
    [[ "${state}" == "RUNNING NONE HEALTHY" ]] && { echo; return 0; }
    if (( $(date +%s) - start > TIMEOUT_SEC )); then
      echo; echo "Timed out waiting for ${node}. Stopping the rollout here." >&2
      return 1
    fi
    sleep 15
  done
}

mapfile -t NODES < <(mig list-instances "${MIG}" --format="value(name.basename())" | sort)
COUNT=${#NODES[@]}
[[ ${COUNT} -gt 0 ]] || { echo "No instances in ${MIG}" >&2; exit 1; }
echo "==> ${COUNT} nodes: ${NODES[*]}"

start_all=$(date +%s)
for i in "${!NODES[@]}"; do
  node="${NODES[$i]}"
  role="worker"; [[ ${i} -eq 0 ]] && role="primary"
  meta="shard-id=${i},node-role=${role}"

  echo
  echo "==> [$((i + 1))/${COUNT}] ${node}: ${meta}"
  if mig instance-configs list "${MIG}" --format='value(name)' 2>/dev/null | grep -qx "${node}"; then
    mig instance-configs update "${MIG}" --instance="${node}" \
      --stateful-metadata="${meta}" --no-update-instance --quiet
  else
    mig instance-configs create "${MIG}" --instance="${node}" \
      --stateful-metadata="${meta}" --no-update-instance --quiet
  fi

  echo "    replacing ${node} (current template + per-instance metadata)"
  mig update-instances "${MIG}" --instances="${node}" \
    --minimal-action=replace --most-disruptive-allowed-action=replace --quiet >/dev/null

  wait_healthy "${node}"
done

echo
echo "==> Rollout complete in $(( $(date +%s) - start_all ))s"
mig list-instances "${MIG}" \
  --format="table(name.basename(),zone.basename(),instanceStatus,instanceHealth[0].detailedHealthState:label=HEALTH,version.instanceTemplate.basename():label=TEMPLATE)"
