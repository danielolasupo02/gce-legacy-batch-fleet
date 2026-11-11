#!/usr/bin/env bash
# Phase 02: confirm the instance template matches the spec.
set -euo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/terraform"
TEMPLATE="$(terraform output -raw instance_template_name)"
echo "--- Template: ${TEMPLATE}"

gcloud compute instance-templates describe "${TEMPLATE}" \
  --format="yaml(properties.machineType,properties.tags,properties.disks,properties.networkInterfaces,properties.serviceAccounts,properties.shieldedInstanceConfig)"
