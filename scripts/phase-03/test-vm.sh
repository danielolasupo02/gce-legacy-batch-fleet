#!/usr/bin/env bash
# Phase 03: prove the startup script on ONE throwaway VM built from the
# current instance template, before the MIG builds three of them.
#
# Usage:
#   ./scripts/phase-03/test-vm.sh create        # build the VM from the template
#   ./scripts/phase-03/test-vm.sh wait          # wait for STARTUP COMPLETE in serial output
#   ./scripts/phase-03/test-vm.sh check         # disk, fstab, service, health, config  (screenshot 05)
#   ./scripts/phase-03/test-vm.sh logs          # startup lines from Cloud Logging
#   ./scripts/phase-03/test-vm.sh reboot-test   # prove the script is safe on reboot
#   ./scripts/phase-03/test-vm.sh delete        # remove the VM (stops billing for it)
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
ZONE="${ZONE:-us-central1-a}"
VM="${VM:-batch-test-1}"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SSH=(gcloud compute ssh "${VM}" --zone="${ZONE}" --tunnel-through-iap --quiet)

remote_check='
echo "== Block devices";  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT
echo; echo "== Mount";       df -h /mnt/batch-data
echo; echo "== fstab";       grep batch-data /etc/fstab
echo; echo "== Service";     systemctl is-active batch-app
echo; echo "== /healthz";    curl -s localhost:8080/healthz; echo
echo; echo "== /";           curl -s localhost:8080/; echo
echo; echo "== app-config from metadata server"
curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/app-config; echo
echo; echo "== Startup log (last lines)"; sudo tail -n 4 /var/log/batch-startup.log
'

case "${1:-}" in
  create)
    # Only call enable when needed: every enable is a Service Usage "mutate"
    # request, and those are rate limited (HTTP 429) even when it is a no-op.
    if gcloud services list --enabled --filter="config.name=iap.googleapis.com" \
         --format="value(config.name)" | grep -q iap; then
      echo "==> IAP already enabled"
    else
      echo "==> Enabling IAP (needed for SSH to VMs without external IPs)"
      gcloud services enable iap.googleapis.com
    fi
    TEMPLATE="$(terraform -chdir="${ROOT}/terraform" output -raw instance_template_self_link)"
    # Guard: refuse to test a template that has no startup script (e.g. the
    # Phase 3 apply never ran and the output still points at the old template).
    KEYS="$(gcloud compute instance-templates describe "${TEMPLATE##*/}" \
      --format='value(properties.metadata.items[].key)')"
    if [[ "${KEYS}" != *startup-script* || "${KEYS}" != *app-config* ]]; then
      echo "Template ${TEMPLATE##*/} has no startup-script/app-config metadata (keys: ${KEYS:-none})." >&2
      echo "Run the Phase 3 terraform plan/apply first." >&2
      exit 1
    fi
    echo "==> Creating ${VM} from ${TEMPLATE##*/}"
    gcloud compute instances create "${VM}" --zone="${ZONE}" \
      --source-instance-template="${TEMPLATE}"
    echo "==> Next: $0 wait"
    ;;

  wait)
    echo "==> Waiting for STARTUP COMPLETE (apt upgrade can take 2-5 minutes)"
    for i in $(seq 1 60); do
      if gcloud compute instances get-serial-port-output "${VM}" --zone="${ZONE}" 2>/dev/null \
           | grep -q "STARTUP COMPLETE"; then
        gcloud compute instances get-serial-port-output "${VM}" --zone="${ZONE}" 2>/dev/null \
          | grep "batch-startup" | tail -n 20
        exit 0
      fi
      printf '.'; sleep 10
    done
    echo; echo "Timed out. Inspect: gcloud compute instances get-serial-port-output ${VM} --zone=${ZONE} | grep batch-startup" >&2
    exit 1
    ;;

  check)
    "${SSH[@]}" --command="${remote_check}"
    ;;

  logs)
    ID="$(gcloud compute instances describe "${VM}" --zone="${ZONE}" --format='value(id)')"
    gcloud logging read \
      "resource.type=\"gce_instance\" AND resource.labels.instance_id=\"${ID}\" AND logName=\"projects/${PROJECT_ID}/logs/google_metadata_script_runner\"" \
      --freshness=1d --order=asc --limit=200 \
      --format='value(timestamp,jsonPayload.message,textPayload)' | grep -E "batch-startup|Finished running" || true
    ;;

  reboot-test)
    echo "==> Writing a marker file to the data disk"
    "${SSH[@]}" --command='echo "written $(date -u)" | sudo tee /mnt/batch-data/state/reboot-marker'
    echo "==> Rebooting ${VM}"
    "${SSH[@]}" --command='sudo systemctl reboot' || true
    sleep 45
    for i in $(seq 1 30); do
      "${SSH[@]}" --command='true' >/dev/null 2>&1 && break
      printf '.'; sleep 10
    done
    echo
    echo "==> After reboot: marker must survive and the disk must NOT be reformatted"
    "${SSH[@]}" --command='
      echo "== Marker"; cat /mnt/batch-data/state/reboot-marker
      echo "== Format decisions across boots"; sudo grep -E "formatting ext4|skipping format" /var/log/batch-startup.log
      echo "== Service"; systemctl is-active batch-app'
    ;;

  delete)
    gcloud compute instances delete "${VM}" --zone="${ZONE}" --quiet
    ;;

  *)
    sed -n '2,12p' "$0"; exit 1 ;;
esac
