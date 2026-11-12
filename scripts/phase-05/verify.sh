#!/usr/bin/env bash
# Phase 05: wait for the load balancer to serve, then show health and traffic spread.
#
# Usage:
#   ./scripts/phase-05/verify.sh                 # wait, then health + 30 requests
#   REQUESTS=60 ./scripts/phase-05/verify.sh
#   OUT=~/phase05-evidence.txt ./scripts/phase-05/verify.sh
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
REQUESTS="${REQUESTS:-30}"
OUT="${OUT:-/dev/null}"
LB_IP="$(terraform -chdir="${ROOT}/terraform" output -raw lb_ip)"

section() { printf '\n========== %s ==========\n' "$1"; }

# A new global LB takes several minutes to program worldwide. Until then it
# returns 404 or 502, or the connection is refused. That is expected.
# A new global LB takes several minutes to program worldwide. Until then it
# returns 000/404/502, and for a while it answers some requests and not others.
# Only call it serving after 10 consecutive 200s.
echo "==> Waiting for 10 consecutive HTTP 200s from http://${LB_IP}/ (new load balancers take 3-10 minutes)"
start=$(date +%s); streak=0
for i in $(seq 1 180); do
  code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://${LB_IP}/" || true)"
  if [[ "${code}" == "200" ]]; then
    streak=$((streak + 1)); [[ ${streak} -ge 10 ]] && break; sleep 1
  else
    streak=0; printf '%s ' "${code:-000}"; sleep 10
  fi
done
echo; echo "==> Stable after $(( $(date +%s) - start ))s"

{
  section "Load balancer"
  echo "IP:  ${LB_IP}"
  echo "URL: http://${LB_IP}/"

  section "Backend health (as seen by the load balancer)"
  gcloud compute backend-services get-health batch-backend --global \
    --flatten="status.healthStatus[]" \
    --format="table(status.healthStatus.instance.basename():label=INSTANCE,status.healthStatus.healthState:label=HEALTH)"

  section "Health check settings"
  gcloud compute health-checks describe batch-app-health-check \
    --format="yaml(httpHealthCheck.port,httpHealthCheck.requestPath,checkIntervalSec,timeoutSec,healthyThreshold,unhealthyThreshold)"

  section "Single request"
  curl -s "http://${LB_IP}/"; echo
  curl -s "http://${LB_IP}/healthz"; echo

  section "${REQUESTS} requests: which node answered"
  for i in $(seq 1 "${REQUESTS}"); do
    curl -s -m 5 "http://${LB_IP}/" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["instance"], d["zone"])' 2>/dev/null \
      || echo "ERROR no-response"
  done | sort | uniq -c | awk '{printf "  %3d requests  %-20s %s\n", $1, $2, $3}'
} 2>&1 | tee "${OUT}"
