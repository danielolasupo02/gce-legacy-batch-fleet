# Phase 4: Managed Instance Group

## Objective
Turn the instance template into a self-healing fleet: a regional Managed
Instance Group that keeps three batch nodes running across three zones, checks
each node's `/healthz` endpoint, and recreates any node that stops responding,
without anyone logging in to fix it.

## What Was Built
- Regional MIG `batch-mig` in `us-central1`, target size 3, spread across zones `a`, `b` and `c`
- HTTP health check `batch-app-health-check` on port 8080, path `/healthz`
- Auto-healing policy linking the MIG to the health check, with a 300 s initial delay
- Stateful policy that keeps each node's `batch-data` disk when the node is recreated
- Named port `http:8080` for the load balancer in Phase 5
- Firewall rule `batch-allow-health-checks` admitting Google's health check ranges on port 8080
- `scripts/phase-04/verify.sh` to wait for the group to stabilise and print the evidence

## Configuration

### Managed Instance Group

| Item | Value                                                    |
|---|----------------------------------------------------------|
| Resource | `google_compute_region_instance_group_manager.batch_mig` |
| Name | `batch-mig`                                              |
| Type | Regional (`us-central1`)                                 |
| Zones | `us-central1-a`, `us-central1-b`, `us-central1-c`        |
| Target size | 3                                                        |
| Instance names | `batch-node-5zq9` `batch-node-mrvz`  `batch-node-r0pl`                     |
| Template | current `batch-node-template-20261111152533582400000001` (version `primary`)      |
| Named port | `http` → `8080`                                          |

**Why regional instead of zonal?** A zonal MIG puts every node in one zone, so
a zone outage takes the whole fleet down. A regional MIG spreads the three
nodes one per zone and, if a zone fails, rebuilds the lost capacity in the
zones that are left. This also covers the cross-zone stretch goal.

### Health check

| Item | Value |
|---|---|
| Name | `batch-app-health-check` |
| Protocol / port / path | HTTP / 8080 / `/healthz` |
| Check interval | 10 s |
| Timeout | 5 s |
| Healthy threshold | 2 consecutive passes |
| Unhealthy threshold | 3 consecutive failures |
| Logging | State changes logged to Cloud Logging |

A node is marked unhealthy about 30 seconds after `/healthz` starts failing
(3 failures × 10 s). `/healthz` fails when the data disk is not mounted or the
batch worker has not written a heartbeat for 90 seconds.

### Auto-healing

| Item | Value |
|---|---|
| Health check | `batch-app-health-check` |
| Initial delay | 300 s |
| Action | Recreate the unhealthy node from the current template |

**Why a 300 second initial delay?** The startup script updates packages,
formats or mounts the disk and starts the app before `/healthz` can pass. If
auto-healing acted during that window, it would recreate nodes that are still
booting, and they would never finish. The delay must be longer than a full
first boot. _(Measured boot time from Phase 3: pending.)_

### Stateful data disk

| Item | Value |
|---|---|
| Device | `batch-data` |
| Delete rule | `ON_PERMANENT_INSTANCE_DELETION` |
| On auto-heal / recreate | Same disk reattached to the new VM, data kept |
| On scale-in or `terraform destroy` | Disk deleted with the node |

**Why a stateful disk?** By default a MIG treats every disk as disposable: an
auto-healed node gets a brand-new blank data disk, and any batch output on the
old one is lost. With the stateful policy the MIG reattaches the same disk to
the replacement VM, and the startup script sees an existing filesystem and
skips formatting. `ON_PERMANENT_INSTANCE_DELETION` still cleans the disk up
when a node is removed for good, so `terraform destroy` leaves no orphaned,
billed disks.

### Update policy

| Item | Value |
|---|---|
| Type | `OPPORTUNISTIC` |
| Replacement method | `RECREATE` (keeps instance name and stateful disk) |
| Instance redistribution | `NONE` |
| Max surge | 0 |
| Max unavailable | 3 |

**Why not roll out template changes automatically?** Two constraints collide.
The free trial caps running vCPUs at 8, and three `e2-standard-2` nodes already
use 6, so there is no room to create extra nodes during an update
(`max_surge = 0`). Stateful disks also rule out surge. For a regional MIG, a
fixed `max_unavailable` must be 0 or at least the number of zones, so with no
surge the only valid value is 3: a proactive rollout could replace the whole
fleet at once. `OPPORTUNISTIC` avoids that. A new template applies when a node
is recreated, and rollouts are done one node at a time on purpose (Phase 6).

### Firewall

| Rule | Source | Port | Target |
|---|---|---|---|
| `batch-allow-health-checks` | `35.191.0.0/16`, `130.211.0.0/22` | TCP 8080 | tag `batch-node` |

**Why this rule matters:** health check probes come from Google's own ranges,
not from inside the VPC. Without this rule every probe times out, every node
looks dead, and auto-healing recreates the whole fleet in a loop.

### Cost

| Item | Approximate cost |
|---|---|
| 3 × `e2-standard-2` | About $0.20/hour |
| 3 × 70 GB `pd-balanced` | About $0.02/hour |
| Cloud NAT | About $0.045/hour plus data processed |

The fleet is destroyed with `terraform destroy` between working sessions.

### Commands
The full command set is in [`terraform/`](../terraform/) and
[`scripts/phase-04/`](../scripts/phase-04/):

| File | What it does |
|---|---|
| [`main.tf`](../terraform/main.tf) | Adds the health check firewall rule, health check and regional MIG |
| [`variables.tf`](../terraform/variables.tf) | `zones`, `target_size`, `autohealing_initial_delay_sec`, health check timings |
| [`outputs.tf`](../terraform/outputs.tf) | MIG name, instance group URL, health check ID |
| [`verify.sh`](../scripts/phase-04/verify.sh) | Waits until the group is stable, then prints instances, settings, disks and health |

```bash
./scripts/phase-03/test-vm.sh delete
terraform -chdir=terraform plan -out=phase4.tfplan
terraform -chdir=terraform apply phase4.tfplan
OUT=~/phase04-evidence.txt ./scripts/phase-04/verify.sh
```

## Verification

| Check | Command |
|---|---|
| Plan | `terraform plan` | 
| MIG created | `terraform apply` |
| Group stable | `verify.sh` (`wait-until --stable`) |
| Three nodes running | `verify.sh` (instances table) |
| Spread across zones | `verify.sh` (zone column) |
| All nodes healthy | `verify.sh` (`HEALTH` = `HEALTHY`) |
| Auto-healing configured | `verify.sh` (`autoHealingPolicies`) |
| Stateful disk policy | `verify.sh` (`statefulPolicy`) |
| App answers on each node | `verify.sh` (`/healthz` per node) |

### Screenshots

**Three nodes running across three zones**
![MIG instances](../screenshots/07-mig-3-instances-running.png)

**Auto-healing configuration**
![MIG auto-healing](../screenshots/08-mig-autohealing-config.png)

## Notes & Issues

### Decision: delete the Phase 3 test VM first
The test VM uses 2 vCPUs. With it running, the three MIG nodes would bring the
total to 8, the free trial maximum, leaving nothing for a replacement during
auto-healing. It is deleted before the MIG is applied.

### Decision: one health check for auto-healing and load balancing
The same `batch-app-health-check` is used here and by the load balancer
backend in Phase 5. In larger fleets the auto-healing check is often made more
tolerant than the load balancer check, so a node is taken out of traffic
quickly but only recreated after a longer failure. With three nodes and a
30 second failure window, one check keeps the behaviour easy to reason about.

### Decision: `wait_for_instances = false`
Terraform returns as soon as the MIG exists instead of waiting for every node
to be healthy. If the startup script had a bug, a waiting apply would hang
until it timed out. `verify.sh` does the waiting instead, with a clear timeout
and output.