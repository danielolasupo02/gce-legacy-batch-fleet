#!/usr/bin/env bash
# Phase 07: after `terraform destroy`, confirm nothing billable is left behind.
# Stateful disks are the usual leftover: they are designed to outlive VMs.
set -uo pipefail

section() { printf '\n========== %s ==========\n' "$1"; }
left=0
check() {
  local label="$1"; shift
  local out; out="$("$@" 2>/dev/null)"
  section "${label}"
  if [[ -n "${out}" ]]; then echo "${out}"; left=1; else echo "none"; fi
}

check "Instances"            gcloud compute instances list --format="table(name,zone.basename(),status)"
check "Disks"                gcloud compute disks list --format="table(name,zone.basename(),sizeGb,users.basename())"
check "Instance groups"      gcloud compute instance-groups managed list --format="table(name,location().basename())"
check "Instance templates"   gcloud compute instance-templates list --format="table(name)"
check "Forwarding rules"     gcloud compute forwarding-rules list --format="table(name,IPAddress)"
check "Reserved addresses"   gcloud compute addresses list --format="table(name,address,status)"
check "Cloud Routers"        gcloud compute routers list --format="table(name,region.basename())"

echo
if [[ ${left} -eq 0 ]]; then
  echo "Clean: no billable compute resources left in $(gcloud config get-value project 2>/dev/null)."
else
  echo "Resources remain (listed above). If they are not Terraform-managed, delete them by hand."
fi
