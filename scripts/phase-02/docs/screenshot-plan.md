# Screenshot Plan

Every screenshot here proves something a reviewer would otherwise have to take on trust. Setup screens (API library pages, empty dashboards) are left out on purpose.

**Naming:** one flat folder, numbered across the whole project in the order you take them: `screenshots/NN-what-it-proves.png`. Numbers are fixed, so if you skip an optional shot, leave the gap rather than renumbering; the docs reference these exact names.

**Links:** replace `PROJECT_ID` with your project ID. Console links open the exact page to capture.

**Markers:** ★ = must-have for review. The rest strengthen the write-up but are optional.

---

## Phase 01: GCP setup

| | File | When to take it | What must be visible | Link |
|---|---|---|---|---|
| ★ | `screenshots/01-iam-terraform-sa-roles.png` | After `bootstrap.sh` | `terraform-batch-fleet` row with Compute Admin and Service Account User | https://console.cloud.google.com/iam-admin/iam?project=PROJECT_ID |
| | `screenshots/02-terraform-auth-ok.png` | After `verify.sh` | Terminal ending in `No changes.` | terminal |

## Phase 02: Instance template

| | File | When to take it | What must be visible | Link |
|---|---|---|---|---|
| | `screenshots/03-terraform-plan-template.png` | During `terraform plan` | The `google_compute_instance_template` block in the plan, showing both `disk` entries | terminal |
| ★ | `screenshots/04-instance-template-details.png` | After the first `terraform apply` that creates the template | Template details: machine type, Ubuntu 22.04 boot disk, the second (data) disk, network tags `batch-node`, no external IP | https://console.cloud.google.com/compute/instanceTemplates/list?project=PROJECT_ID (click the template) |

## Phase 03: Startup script

| | File | When to take it | What must be visible | Link |
|---|---|---|---|---|
| ★ | `screenshots/05-ssh-disk-mounted.png` | SSH into one node after boot | One terminal with `lsblk`, `df -h /mnt/batch-data`, and `grep batch-data /etc/fstab` | https://console.cloud.google.com/compute/instances?project=PROJECT_ID (SSH button) |
| ★ | `screenshots/06-logs-startup-script-success.png` | 2-3 min after a node boots | Logs Explorer with your script's log lines: package update, mkfs (first boot only), mount OK, `Finished running startup scripts` | https://console.cloud.google.com/logs/query?project=PROJECT_ID |

Logs Explorer query for 06:

```
resource.type="gce_instance"
log_name="projects/PROJECT_ID/logs/google_metadata_script_runner"
```

## Phase 04: Managed Instance Group

| | File | When to take it | What must be visible | Link |
|---|---|---|---|---|
| ★ | `screenshots/07-mig-3-instances-running.png` | After apply, once all nodes are up | MIG Overview: target size 3, three instances Running, zones column visible | https://console.cloud.google.com/compute/instanceGroups/list?project=PROJECT_ID (click `batch-mig`) |
| ★ | `screenshots/08-mig-autohealing-config.png` | Same visit, Details tab | Autohealing section: health check name and initial delay | same page, Details tab |

## Phase 05: Load balancer and health checks

| | File | When to take it | What must be visible | Link |
|---|---|---|---|---|
| ★ | `screenshots/09-lb-backends-healthy.png` | 3-5 min after the LB is created (it takes a while to go green) | Load balancer details: backend `batch-mig`, Healthy `3 / 3` | https://console.cloud.google.com/net-services/loadbalancing/list/loadBalancers?project=PROJECT_ID |
| | `screenshots/10-health-check-config.png` | Any time after apply | Port 8080, path `/healthz`, interval, timeout, thresholds | https://console.cloud.google.com/compute/healthChecks?project=PROJECT_ID |
| ★ | `screenshots/11-curl-lb-round-robin.png` | Once backends are healthy | Terminal: a `curl` loop against the LB IP returning different node hostnames | terminal |

Command for 11:

```bash
LB_IP=$(terraform -chdir=terraform output -raw lb_ip)
for i in $(seq 1 10); do curl -s http://$LB_IP/; echo; done
```

## Phase 06: Metadata integration

| | File | When to take it | What must be visible | Link |
|---|---|---|---|---|
| ★ | `screenshots/12-instance-metadata-keys.png` | After apply with the metadata block | VM details, Metadata section: your custom keys (`app-env`, `app-port`, etc.) next to `startup-script` | https://console.cloud.google.com/compute/instances?project=PROJECT_ID (click a node) |
| ★ | `screenshots/13-per-instance-config.png` | After SSH or curl on two different nodes | Two nodes showing different per-instance values (node ID, shard) from the same template | terminal |

## Phase 07: Verification and stress testing

This is the meatiest phase. Take these in order; together they tell the failure story.

| | File | When to take it | What must be visible | Link |
|---|---|---|---|---|
| ★ | `screenshots/14-before-failure-3-healthy.png` | Before you break anything | MIG with 3 Running instances; note the instance names | https://console.cloud.google.com/compute/instanceGroups/list?project=PROJECT_ID |
| ★ | `screenshots/15-delete-instance-command.png` | The moment you run the delete | Terminal with `date` and the `gcloud compute instances delete` command and its output | terminal |
| ★ | `screenshots/16-mig-recreating.png` | 10-30 s after the delete | MIG list showing a node in `Recreating`/`Creating`, or target 3 with 2 running | same MIG page |
| ★ | `screenshots/17-app-killed-autoheal-repair.png` | After stopping the app on one node (the real health-check test) | Operations/Logs showing `compute.instances.repair.recreateInstance` for that node | https://console.cloud.google.com/logs/query?project=PROJECT_ID |
| ★ | `screenshots/18-replacement-startup-logs.png` | 2-3 min after the replacement boots | Logs filtered to the NEW instance name: startup script ran, disk mounted | https://console.cloud.google.com/logs/query?project=PROJECT_ID |
| | `screenshots/19-lb-served-through-failure.png` | During 15-17 | Terminal: curl loop with timestamps that stays mostly 200 while a node dies | terminal |
| | `screenshots/20-back-to-3-healthy.png` | After recovery | MIG 3/3 Running, LB 3/3 healthy, with a new instance name in the list | MIG and LB pages |

Logs Explorer query for 17:

```
resource.type="gce_instance"
protoPayload.methodName="compute.instances.repair.recreateInstance"
```

Why both 15 and 17: deleting a VM only proves the MIG keeps its target size. Stopping the app while the VM stays up is what proves the health check drives auto-healing, which is the actual requirement.

## Stretch goals

| | File | When to take it | What must be visible | Link |
|---|---|---|---|---|
| | `screenshots/21-spot-provisioning-model.png` | After enabling Spot on the template | VM details: Provisioning model `Spot` | https://console.cloud.google.com/compute/instances?project=PROJECT_ID |
| | `screenshots/22-multi-zone-distribution.png` | Regional MIG running | Instance list with nodes in `us-central1-a`, `-b`, `-c` | https://console.cloud.google.com/compute/instances?project=PROJECT_ID |

## Capture tips

- Crop to the relevant panel, but keep the project selector or URL bar visible in at least one shot per phase so the project ID is on record.
- Terminal shots: run `clear` first, make the font big enough to read in a GitHub preview.
- Never screenshot the contents of `credentials.json` or a full key ID.
