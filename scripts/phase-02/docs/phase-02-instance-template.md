# Phase 2: Instance Template

## Objective
Define a single, versioned blueprint for every batch node in Terraform: machine
type, Ubuntu 22.04 LTS boot disk, a dedicated persistent data disk, network
tags and a least-privilege runtime identity. The Managed Instance Group in
Phase 4 builds every VM from this template, so anything wrong here is wrong on
every node.

## What Was Built
- `google_compute_instance_template.batch_node` in `terraform/main.tf`
- An Ubuntu 22.04 LTS boot disk (20 GB, `pd-balanced`)
- A separate 50 GB `pd-balanced` data disk per instance, exposed as `/dev/disk/by-id/google-batch-data`
- Network tag `batch-node` for firewall targeting
- No external IP on the nodes
- A dedicated runtime service account, `batch-node-sa`, limited to writing logs and metrics
- Shielded VM (Secure Boot, vTPM, integrity monitoring) and OS Login enabled
- Template variables in `terraform/variables.tf` and outputs in `terraform/outputs.tf`

## Configuration

### Instance template

| Item | Value |
|---|---|
| Resource | `google_compute_instance_template.batch_node` |
| Name | `batch-node-template-<timestamp>` (from `name_prefix`) |
| Machine type | `e2-standard-2` (2 vCPU, 8 GB) |
| Network | `default` |
| External IP | None |
| Network tags | `batch-node` |
| Labels | `app=legacy-batch`, `managed-by=terraform` |
| Lifecycle | `create_before_destroy = true` |

**Why `e2-standard-2` instead of the starter's `e2-medium`?** `e2-medium` is a
shared-core machine that bursts above its baseline and then gets throttled.
That is fine for a web server but bad for a batch job that keeps the CPU busy
for minutes at a time. `e2-standard-2` gives 2 dedicated vCPUs and 8 GB. It
uses the same vCPU count, so three nodes still fit inside the free trial's
8 vCPU cap with room for a replacement during auto-healing.

**Why `name_prefix` and `create_before_destroy`?** Instance templates cannot be
edited. Any change creates a new template. With a fixed name, Terraform would
try to delete the old template first, which fails once a MIG is using it.
`name_prefix` gives each version a unique name, and `create_before_destroy`
creates the new one before removing the old one.

### Disks

| Item | Boot disk | Data disk |
|---|---|---|
| Image | `ubuntu-os-cloud/ubuntu-2204-lts` | None (blank) |
| Type | `pd-balanced` | `pd-balanced` |
| Size | 20 GB | 50 GB |
| Device name | default | `batch-data` |
| Path on VM | `/dev/sda` | `/dev/disk/by-id/google-batch-data` |
| Auto-delete | Yes | Yes |

**Why a separate data disk?** Batch input and output stay off the OS disk. The
boot disk can be rebuilt from the image at any time, while the data disk has
its own size, type and lifecycle. It also gives the startup script in Phase 3
a clear job: find this disk, format it on first boot only, and mount it.

**Why the `device_name`?** Linux names like `/dev/sdb` depend on attach order
and can change. `device_name = "batch-data"` makes GCE publish a stable symlink
at `/dev/disk/by-id/google-batch-data`, so the startup script never guesses.

**Why the image family instead of a fixed image?** `ubuntu-2204-lts` resolves
to the newest patched 22.04 image when the template is created. Each new
template version picks up security patches without changing code.

### Runtime service account

| Item | Value |
|---|---|
| Name | `batch-node-sa` |
| Email | `batch-node-sa@legacy-batch-fleet-8693.iam.gserviceaccount.com` |
| Roles | `roles/logging.logWriter`, `roles/monitoring.metricWriter` |
| Created by | `scripts/phase-02/create-node-sa.sh`, run as the project owner |

**Why not the default Compute Engine service account?** In a project without
an organization policy, the default compute SA has project Editor. Any process
on any batch node could then change almost anything in the project. The nodes
only need to send logs and metrics, so that is all they get.

**Why create it outside Terraform?** Creating a service account and granting it
roles needs IAM admin permissions. Giving those to the Terraform SA would let
it grant itself any role. The node SA is created once by the owner, and
Terraform only attaches it, which `roles/iam.serviceAccountUser` from Phase 1
already allows.

### Security hardening

| Setting | Value | Purpose |
|---|---|---|
| Shielded VM Secure Boot | On | Only signed boot components load |
| vTPM | On | Measured boot |
| Integrity monitoring | On | Alerts if the boot sequence changes |
| `enable-oslogin` | `TRUE` | SSH access controlled by IAM, not by keys in metadata |

### Commands
- Terraform: [`terraform/main.tf`](../terraform/main.tf), [`terraform/variables.tf`](../terraform/variables.tf), [`terraform/outputs.tf`](../terraform/outputs.tf)
- Node service account: [`scripts/phase-02/create-node-sa.sh`](../scripts/phase-02/create-node-sa.sh)
- Checks: [`scripts/phase-02/verify.sh`](../scripts/phase-02/verify.sh)

```bash
./scripts/phase-02/create-node-sa.sh
cd terraform
terraform fmt
terraform validate
terraform plan -out=phase2.tfplan
terraform apply phase2.tfplan
cd .. && ./scripts/phase-02/verify.sh
```

## Verification

| Check | Command | Result |
|---|---|---|
| Node SA roles | `./scripts/phase-02/create-node-sa.sh` (prints roles at the end) | _pending_ |
| Config is valid | `terraform validate` | _pending_ |
| Plan adds one resource | `terraform plan` | _pending_ |
| Template exists | `gcloud compute instance-templates list` | _pending_ |
| Ubuntu 22.04 boot disk | `./scripts/phase-02/verify.sh` (`sourceImage`) | _pending_ |
| Data disk attached | `./scripts/phase-02/verify.sh` (`deviceName: batch-data`, 50 GB) | _pending_ |
| Network tag | `./scripts/phase-02/verify.sh` (`tags: batch-node`) | _pending_ |
| No external IP | `./scripts/phase-02/verify.sh` (no `accessConfigs`) | _pending_ |
| Runtime SA | `./scripts/phase-02/verify.sh` (`batch-node-sa@...`) | _pending_ |

### Screenshots

**Terraform plan**
![Terraform plan](../screenshots/03-terraform-plan-template.png)

**Instance template details**
![Instance template details](../screenshots/04-instance-template-details.png)

## Notes & Issues

### Decision: no VMs in this phase
An instance template is only a blueprint. Applying it creates no VMs and costs
nothing. The first billable resources appear in Phase 4, when the MIG builds
nodes from this template.

### Decision: no external IPs on nodes
Batch nodes are not meant to be reached directly. Inbound traffic will come
through the load balancer in Phase 5. Without public IPs, the nodes also cannot
reach the internet on their own, so Phase 3 adds Cloud NAT before the startup
script runs `apt-get update`.

### Decision: data disk survives VM restarts but not recreation (yet)
With `auto_delete = true`, the data disk survives reboots and live migration
but is deleted when the MIG recreates an instance during auto-healing. Phase 4
revisits this with a stateful disk policy so the disk is kept and reattached to
the replacement VM.
