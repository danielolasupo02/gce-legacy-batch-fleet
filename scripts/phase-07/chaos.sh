#!/usr/bin/env bash
# Phase 07: failure testing for the batch fleet.
#
#   baseline            fleet state before anything breaks               (screenshot 14)
#   traffic             run in a SECOND tab: 1 request/s through the LB, Ctrl+C to stop
#   delete [NODE]       test 1: delete a VM outright, MIG restores it    (screenshots 15, 16)
#   kill-app [NODE]     test 2: VM stays up, app stops, health check
#                       triggers auto-healing                            (screenshot 17)
#   watch               live MIG view until all nodes are healthy again
#   report              after each test: did the node come back with the
#                       same name, data disk, marker file and shard?
#   logs                Cloud Logging: health state changes, repairs,
#                       startup lines on replacement nodes               (screenshot 18)
#   traffic-report      summary of the traffic log: errors and longest gap (screenshot 19)
#   spot-preempt [NODE] stretch goal: simulate a Spot VM preemption
#
# Every test appends to ~/phase07-timeline.log so the docs can quote exact times.
set -uo pipefail

REGION="${REGION:-us-central1}"
MIG="${MIG:-batch-mig}"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
TIMELINE="${HOME}/phase07-timeline.log"
TRAFFIC_LOG="${HOME}/phase07-traffic.log"
STATE_DIR="${HOME}/.phase07"
mkdir -p "${STATE_DIR}"

now()     { date -u +%Y-%m-%dT%H:%M:%SZ; }
note()    { echo "$(now) $*" | tee -a "${TIMELINE}"; }
section() { printf '\n========== %s ==========\n' "$1"; }
mig()     { gcloud compute instance-groups managed "$@" --region="${REGION}"; }
zone_of() { gcloud compute instances list --filter="name=$1" --format="value(zone.basename())"; }
ssh_to()  { local n="$1"; shift; gcloud compute ssh "${n}" --zone="$(zone_of "${n}")" --tunnel-through-iap --quiet --command="$*" 2>/dev/null; }
nodes()   { mig list-instances "${MIG}" --format="value(name.basename())" | sort; }
lb_ip()   { terraform -chdir="${ROOT}/terraform" output -raw lb_ip; }

table() {
  mig list-instances "${MIG}" \
    --format="table(name.basename():label=NODE,zone.basename():label=ZONE,instanceStatus:label=STATUS,currentAction:label=ACTION,instanceHealth[0].detailedHealthState:label=HEALTH)"
}

# Default targets: different nodes for each test, never the primary (shard 0).
pick() { nodes | sed -n "${1}p"; }

# Snapshot of a node: VM id (changes on recreation), data disk, marker, shard.
snapshot() {
  local n="$1" z id disk
  z="$(zone_of "${n}")"
  id="$(gcloud compute instances describe "${n}" --zone="${z}" --format='value(id)' 2>/dev/null)"
  disk="$(gcloud compute instances describe "${n}" --zone="${z}" \
    --format='value(disks[1].source.basename())' 2>/dev/null)"
  echo "node=${n} zone=${z} vm_id=${id:-none} data_disk=${disk:-none}"
}

write_marker() {
  local n="$1" tag="$2"
  ssh_to "${n}" "echo '${tag} written $(now)' | sudo tee /mnt/batch-data/state/chaos-marker >/dev/null && cat /mnt/batch-data/state/chaos-marker"
}

wait_recovered() {
  local start=$(date +%s) target state ok
  target="$(mig describe "${MIG}" --format='value(targetSize)')"
  sleep 20
  while :; do
    clear
    echo "$(now)   elapsed $(( $(date +%s) - start ))s   (Ctrl+C to stop watching)"
    table
    state="$(mig list-instances "${MIG}" --format='value(instanceStatus,currentAction,instanceHealth[0].detailedHealthState)')"
    ok="$(grep -c $'^RUNNING\tNONE\tHEALTHY$' <<<"${state}")"
    if [[ "${ok}" -eq "${target}" ]]; then
      echo; note "RECOVERED: ${ok}/${target} nodes RUNNING and HEALTHY after $(( $(date +%s) - start + 0 ))s of watching"
      return 0
    fi
    sleep 10
  done
}

case "${1:-}" in
  baseline)
    section "Fleet before failure $(now)"
    table
    section "Load balancer backend health"
    gcloud compute backend-services get-health batch-backend --global \
      --flatten="status.healthStatus[]" \
      --format="table(status.healthStatus.instance.basename():label=NODE,status.healthStatus.healthState:label=HEALTH)"
    section "Node snapshots"
    for n in $(nodes); do snapshot "${n}"; done | tee "${STATE_DIR}/baseline.txt"
    note "BASELINE recorded: $(nodes | tr '\n' ' ')"
    ;;

  traffic)
    IP="$(lb_ip)"
    echo "Sending 1 request/s to http://${IP}/  (logging to ${TRAFFIC_LOG}, Ctrl+C to stop)"
    : > "${TRAFFIC_LOG}"
    while :; do
      out="$(curl -s -m 3 -w ' HTTP=%{http_code}' "http://${IP}/" 2>/dev/null)"
      code="${out##*HTTP=}"
      inst="$(grep -o '"instance": "[^"]*"' <<<"${out}" | cut -d'"' -f4)"
      line="$(date -u +%H:%M:%S) ${code:-000} ${inst:--}"
      echo "${line}" | tee -a "${TRAFFIC_LOG}"
      sleep 1
    done
    ;;

  delete)
    N="${2:-$(pick 3)}"
    section "Test 1: delete ${N} outright"
    snapshot "${N}" | tee "${STATE_DIR}/delete-before.txt"
    write_marker "${N}" "delete-test"
    echo
    echo "$ date -u; gcloud compute instances delete ${N} --zone=$(zone_of "${N}") --quiet"
    date -u
    note "DELETE issued for ${N}"
    gcloud compute instances delete "${N}" --zone="$(zone_of "${N}")" --quiet
    note "DELETE completed for ${N}"
    echo "${N}" > "${STATE_DIR}/last-target"
    echo "delete" > "${STATE_DIR}/last-test"
    echo
    echo "Next: $0 watch    (screenshot 16 while a node shows CREATING/RECREATING)"
    ;;

  kill-app)
    N="${2:-$(pick 2)}"
    section "Test 2: stop the app on ${N} (VM stays running)"
    snapshot "${N}" | tee "${STATE_DIR}/kill-before.txt"
    write_marker "${N}" "kill-app-test"
    echo
    note "STOP batch-app on ${N}"
    ssh_to "${N}" 'sudo systemctl stop batch-app; systemctl is-active batch-app; curl -s -m 3 localhost:8080/healthz || echo "port 8080: no answer"'
    echo "${N}" > "${STATE_DIR}/last-target"
    echo "kill-app" > "${STATE_DIR}/last-test"
    echo
    echo "Health check: UNHEALTHY in ~30 s (3 x 10 s). Then auto-healing recreates ${N}."
    echo "Next: $0 watch"
    ;;

  watch)
    wait_recovered
    ;;

  report)
    N="$(cat "${STATE_DIR}/last-target" 2>/dev/null)"; T="$(cat "${STATE_DIR}/last-test" 2>/dev/null)"
    [[ -n "${N}" ]] || { echo "Run delete or kill-app first." >&2; exit 1; }
    BEFORE="${STATE_DIR}/$([[ "${T}" == delete ]] && echo delete || echo kill)-before.txt"
    section "Report for ${T} test on ${N}"
    echo "before: $(cat "${BEFORE}")"
    echo "after:  $(snapshot "${N}")"
    section "Inside the replacement node"
    ssh_to "${N}" '
      echo "== chaos marker on data disk"; cat /mnt/batch-data/state/chaos-marker 2>/dev/null || echo "MISSING (data disk was new)"
      echo "== format decision this boot"; sudo grep -E "formatting ext4|skipping format" /var/log/batch-startup.log | tail -n 1
      echo "== shard and role";            grep -E "^NODE_(SHARD|ROLE)=" /etc/batch-app/app.env
      echo "== service";                   systemctl is-active batch-app
      echo "== healthz";                   curl -s localhost:8080/healthz; echo
      echo "== booted at";                 uptime -s'
    note "REPORT ${T} ${N}: $(snapshot "${N}")"
    ;;

  logs)
    P="$(gcloud config get-value project 2>/dev/null)"
    section "Health check state changes (last 2h)"
    gcloud logging read "logName=\"projects/${P}/logs/compute.googleapis.com%2Fhealthchecks\"" \
      --freshness=2h --order=asc --limit=40 \
      --format="table(timestamp,jsonPayload.healthCheckProbeResult.ipAddress:label=NODE_IP,jsonPayload.healthCheckProbeResult.previousHealthState:label=FROM,jsonPayload.healthCheckProbeResult.healthState:label=TO)"
    section "Auto-healing repairs (last 2h)"
    gcloud logging read 'protoPayload.methodName="compute.instances.repair.recreateInstance"' \
      --freshness=2h --order=asc --limit=20 \
      --format="table(timestamp,protoPayload.resourceName.basename():label=NODE,protoPayload.methodName.basename():label=EVENT)"
    section "VM deletions and recreations (last 2h)"
    gcloud logging read 'resource.type="gce_instance" AND (protoPayload.methodName:"instances.delete" OR protoPayload.methodName:"instances.insert") AND operation.first=true' \
      --freshness=2h --order=asc --limit=20 \
      --format="table(timestamp,protoPayload.resourceName.basename():label=NODE,protoPayload.methodName.basename():label=EVENT,protoPayload.authenticationInfo.principalEmail:label=BY)"
    N="$(cat "${STATE_DIR}/last-target" 2>/dev/null)"
    if [[ -n "${N}" ]]; then
      ID="$(gcloud compute instances describe "${N}" --zone="$(zone_of "${N}")" --format='value(id)' 2>/dev/null)"
      section "Startup script on the replacement ${N} (vm_id ${ID})"
      gcloud logging read "resource.type=\"gce_instance\" AND resource.labels.instance_id=\"${ID}\" AND \"batch-startup\"" \
        --freshness=2h --order=asc --limit=30 \
        --format="value(timestamp,jsonPayload.message,textPayload)"
    fi
    ;;

  traffic-report)
    [[ -s "${TRAFFIC_LOG}" ]] || { echo "No traffic log yet. Run: $0 traffic" >&2; exit 1; }
    section "Traffic through the load balancer during the tests"
    total=$(wc -l < "${TRAFFIC_LOG}")
    ok=$(awk '$2=="200"' "${TRAFFIC_LOG}" | wc -l)
    echo "requests: ${total}   HTTP 200: ${ok}   errors: $(( total - ok ))   success: $(awk -v o="${ok}" -v t="${total}" 'BEGIN{printf "%.1f%%", 100*o/t}')"
    echo; echo "answered by:"; awk '$2=="200"{print $3}' "${TRAFFIC_LOG}" | sort | uniq -c
    echo; echo "non-200 responses (time, code):"
    awk '$2!="200"{print "  "$1, $2}' "${TRAFFIC_LOG}" | head -n 20
    echo; echo "longest run of consecutive errors:"
    awk '$2!="200"{c++; if(c>m){m=c; e=$1}} $2=="200"{c=0} END{print "  " (m+0) " requests" (m? " ending " e : "")}' "${TRAFFIC_LOG}"
    ;;

  spot-preempt)
    N="${2:-$(pick 2)}"
    MODEL="$(gcloud compute instances describe "${N}" --zone="$(zone_of "${N}")" --format='value(scheduling.provisioningModel)')"
    [[ "${MODEL}" == "SPOT" ]] || { echo "${N} is ${MODEL:-STANDARD}, not SPOT. Enable use_spot and run rollout.sh first." >&2; exit 1; }
    section "Simulating preemption of Spot VM ${N}"
    snapshot "${N}" > "${STATE_DIR}/kill-before.txt"
    note "SPOT preemption simulated on ${N}"
    gcloud compute instances simulate-maintenance-event "${N}" --zone="$(zone_of "${N}")"
    echo "${N}" > "${STATE_DIR}/last-target"; echo "spot" > "${STATE_DIR}/last-test"
    echo "Next: $0 watch"
    ;;

  *)
    sed -n '2,19p' "$0"; exit 1 ;;
esac
