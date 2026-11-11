# Phase 3: Startup Script

## Objective
Write a startup script that turns a bare Ubuntu 22.04 VM into a working batch
node on every boot, with no manual steps: update packages, format and mount the
persistent data disk, read runtime settings from the GCE metadata server, and
start the legacy batch application. Prove it on a single test VM built from the
instance template before the MIG in Phase 4 builds three of them.

## What Was Built
- `scripts/startup.sh`, delivered to every node through the `startup-script` metadata key
- An `app-config` metadata key holding the application settings as JSON
- A stand-in legacy batch application (`batch-app` systemd service) with a `/healthz` endpoint on port 8080
- Cloud Router `batch-router` and Cloud NAT `batch-nat`, so nodes without external IPs can reach package mirrors
- Firewall rule `batch-allow-iap-ssh`, allowing SSH to batch nodes only from Google's IAP range
- A new instance template version carrying the script and config
- `scripts/phase-03/test-vm.sh` to create, check, reboot-test and delete a throwaway test VM

## Configuration

### Boot sequence

| Step | What happens | Safe on reboot because |
|---|---|---|
| 1. Metadata | Reads instance name, zone, project, internal IP and `app-config` from `metadata.google.internal` | Read-only |
| 2. Packages | `apt-get update`, then `apt-get upgrade` if `apt_upgrade` is true | apt is idempotent |
| 3. Disk | Waits for `/dev/disk/by-id/google-batch-data`, formats ext4 only if it has no filesystem, adds an fstab entry by UUID, mounts it | `blkid` check skips formatting when a filesystem exists |
| 4. App | Creates `batchapp` user, writes `/etc/batch-app/app.env` and `config.json`, installs `app.py` and the systemd unit, restarts the service | Files are overwritten, service is restarted |
| 5. Self-check | Polls `localhost:8080/healthz`, then logs `STARTUP COMPLETE` | Read-only |

**Why does it run on every boot?** GCE runs `startup-script` on every boot, not
just the first. That suits a legacy fleet: a reboot re-applies the current
config and code, so a node never drifts from what the template says. The cost
is that every step must be idempotent, which is why the disk is only formatted
when `blkid` finds no filesystem.

### Metadata

| Key | Set by | Value |
|---|---|---|
| `startup-script` | `file("../scripts/startup.sh")` in the template | The script itself |
| `app-config` | `jsonencode(...)` in the template | `{"env":"lab","port":8080,"data_mount":"/mnt/batch-data","data_device":"batch-data","worker_interval_sec":30,"apt_upgrade":true}` |
| `enable-oslogin` | Template | `TRUE` |

The script queries the metadata server with:

```bash
curl -sSf -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/app-config
```

**Why the `Metadata-Flavor` header?** The metadata server rejects requests
without it. That stops a server-side request forgery bug in an application
from tricking the VM into reading its own metadata, including service account
tokens.

**Why one JSON key instead of many keys?** One `app-config` key keeps the
application's settings together, and the script falls back to a default for
anything missing. Phase 6 builds on this with per-instance values.

### Data disk mount

| Item | Value |
|---|---|
| Device | `/dev/disk/by-id/google-batch-data` |
| Filesystem | ext4, label `batchdata`, 0% reserved blocks |
| Mount point | `/mnt/batch-data` |
| fstab entry | `UUID=<uuid> /mnt/batch-data ext4 discard,defaults,nofail 0 2` |
| Layout | `inbox/`, `outbox/`, `state/` owned by `batchapp` |

**Why UUID and `nofail` in fstab?** A UUID always points at the same
filesystem, regardless of device order. `nofail` means a missing or detached
disk does not drop the VM into emergency mode at boot. The node still boots,
the health check reports the disk as missing, and auto-healing replaces it.

### Application

| Item | Value |
|---|---|
| Service | `batch-app.service`, runs as `batchapp` |
| Code | `/opt/batch-app/app.py` (Python standard library only) |
| Config | `/etc/batch-app/app.env`, `/etc/batch-app/config.json` |
| Work | Hashes every file in `inbox/`, writes `<name>.sha256` to `outbox/`, every 30 s |
| `GET /healthz` | `200` when the disk is mounted and the worker heartbeat is under 90 s old, otherwise `503` |
| `GET /` | Instance, zone, env, files processed, uptime |
| `GET /config` | The `app-config` JSON this node booted with |
| Restart policy | `on-failure`: a crash restarts it, a deliberate `systemctl stop` does not |

**Why does `/healthz` check more than "the process is up"?** A legacy batch
node can be running but useless: the disk is gone or the worker thread is
stuck. `/healthz` fails in both cases, so the Phase 5 health check catches
real failures rather than only dead processes.

**Why `Restart=on-failure` instead of `always`?** Phase 7 stops the service on
purpose to prove the health check triggers auto-healing. With `always`,
systemd would restart it first and the test would prove nothing.

### Network

| Resource | Name | Purpose |
|---|---|---|
| Cloud Router | `batch-router` (`us-central1`) | Control plane for Cloud NAT |
| Cloud NAT | `batch-nat` | Outbound-only internet for all subnets in the region; logs errors only |
| Firewall | `batch-allow-iap-ssh` | TCP 22 from `35.235.240.0/20` to tag `batch-node` |

**Why Cloud NAT?** Phase 2 removed external IPs from the nodes. Without NAT,
`apt-get update` cannot reach Ubuntu's mirrors. NAT gives outbound access only;
nothing on the internet can open a connection to a node.

**Why IAP for SSH?** The nodes have no public IP, so SSH goes through
Identity-Aware Proxy. Access is controlled by IAM, and the firewall only admits
Google's IAP range.

### Cost

| Item | Approximate cost |
|---|---|
| Cloud NAT gateway | About $0.045/hour plus data processed |
| Test VM (`e2-standard-2`, 70 GB disks) | About $0.07/hour while running |

The test VM is deleted at the end of this phase. Cloud NAT stays because every
later phase needs it.

### Commands
The full command set is in [`scripts/startup.sh`](../scripts/startup.sh),
[`scripts/phase-03/`](../scripts/phase-03/) and [`terraform/`](../terraform/):

| File | What it does |
|---|---|
| [`startup.sh`](../scripts/startup.sh) | The node startup script |
| [`main.tf`](../terraform/main.tf) | Adds router, NAT, IAP firewall rule, and `startup-script` / `app-config` metadata on the template |
| [`variables.tf`](../terraform/variables.tf) | `app_env`, `app_port`, `data_mount_path`, `worker_interval_sec`, `apt_upgrade_on_boot` |
| [`test-vm.sh`](../scripts/phase-03/test-vm.sh) | `create`, `wait`, `check`, `logs`, `reboot-test`, `delete` |
| [`collect-evidence.sh`](../scripts/phase-03/collect-evidence.sh) | Read-only: gathers every verification result into one file |

```bash
terraform -chdir=terraform plan -out=phase3.tfplan
terraform -chdir=terraform apply phase3.tfplan
./scripts/phase-03/test-vm.sh create
./scripts/phase-03/test-vm.sh wait
./scripts/phase-03/test-vm.sh check
./scripts/phase-03/test-vm.sh logs
./scripts/phase-03/test-vm.sh reboot-test
./scripts/phase-03/collect-evidence.sh
./scripts/phase-03/test-vm.sh delete
```

## Verification

| Check | Command | Result |
|---|---|---|
| Plan | `terraform plan` | _pending_ |
| Startup completes | `./scripts/phase-03/test-vm.sh wait` | _pending_ |
| Packages updated | `test-vm.sh wait` (`package index updated`) | _pending_ |
| Disk formatted on first boot | `test-vm.sh wait` (`formatting ext4 (first boot)`) | _pending_ |
| Disk mounted | `test-vm.sh check` (`df -h /mnt/batch-data`) | _pending_ |
| fstab entry | `test-vm.sh check` (`grep batch-data /etc/fstab`) | _pending_ |
| Metadata read | `test-vm.sh check` (`app-config` JSON) | _pending_ |
| App healthy | `test-vm.sh check` (`/healthz`) | _pending_ |
| Logs in Cloud Logging | `./scripts/phase-03/test-vm.sh logs` | _pending_ |
| Reboot keeps data, no reformat | `./scripts/phase-03/test-vm.sh reboot-test` | _pending_ |
| Script is executable in Git | `git ls-files -s scripts/startup.sh` (mode `100755`) | _pending_ |

### Screenshots

**Disk mounted and app healthy on the test VM**
![Disk mounted](../screenshots/05-ssh-disk-mounted.png)

**Startup script logs in Cloud Logging**
![Startup script logs](../screenshots/06-logs-startup-script-success.png)

## Notes & Issues

### Issue: zip unpacked into the home directory, again
**Symptom**
```
var.project_id
  GCP project ID that hosts the batch fleet
  Enter a value:

Error: Inconsistent dependency lock file
```

**Cause:** `cd ..` left the repo before `unzip`, so the Phase 3 files landed in
`~/terraform`, `~/scripts` and `~/docs`. Terraform in `~/terraform` had no
`terraform.tfvars`, no `providers.tf` and no state, so it prompted for
`project_id`. The lock file error stopped it before `init` could create an
empty state and plan to build everything from scratch.

**Fix:**
```bash
rm -rf ~/terraform ~/scripts ~/docs
unzip -o ~/phase03-files.zip -d ~/gce-legacy-batch-fleet
```

**Lesson:** Extract with `-d <repo>` so the destination never depends on the
current directory. If Terraform asks for a variable that is in
`terraform.tfvars`, it is running in the wrong folder.

### Issue: test VM built from the old template, startup script never ran
**Symptom**
```
google_metadata_script_runner[1259]: No startup scripts to run.
tail: cannot open '/var/log/batch-startup.log' for reading: No such file or directory
The requested URL /computeMetadata/v1/instance/attributes/app-config was not found on this server.
curl: (28) Failed to connect to archive.ubuntu.com port 80 after 4999 ms
```

**Cause:** After re-extracting the files, the Phase 3 `terraform apply` never
ran. `terraform state list` showed only the Phase 2 template, and
`batch-router` returned 404. `test-vm.sh create` used the template output,
which still pointed at the Phase 2 template: no `startup-script`, no
`app-config`, and no Cloud NAT for outbound traffic.

**Fix:** Deleted the test VM, ran the Phase 3 plan and apply, confirmed the
router, NAT and new template existed, then recreated the VM. `test-vm.sh
create` now refuses to build from a template missing `startup-script` or
`app-config`.

**Lesson:** `No startup scripts to run.` in the guest agent journal means the
metadata key is missing, not that the script failed. Check
`terraform state list` before testing anything that depends on an apply.

### Issue: rate limited when enabling the IAP API
**Symptom**
```
ERROR: (gcloud.services.enable) ... 'status': 429
"Quota exceeded for quota metric 'Mutate requests' and limit 'Mutate requests per minute'
of service 'serviceusage.googleapis.com' for consumer 'project_number:618104708054'."
```

**Cause:** `test-vm.sh create` called `gcloud services enable iap.googleapis.com`
on every run. Enabling an API that is already enabled still counts as a write
against the Service Usage API, and those are rate limited per minute. The
consumer in the error (`618104708054`) is not this project's number
(`308830982217`). The quota was charged to the project gcloud uses as its
quota project, which this lab does not control, so the limit can be hit
without heavy use from this project.

**Fix:** Waited a minute and re-ran. The script now checks
`gcloud services list --enabled` first and only calls `enable` when IAP is off.

**Lesson:** Make setup steps check before they change. A read is cheap and
rarely limited; a redundant write can fail for reasons outside your project.

### Issue: Logs Explorer query returned no results
**Symptom**
```
0 results
Showing logs for last 5 minutes
```

**Cause:** Two things. The query filtered on
`log_name=".../logs/google_metadata_script_runner"`, which is the program name
the runner logs under inside the VM (journal and serial console), not
necessarily the log name it uses in Cloud Logging. The time range was also
the default 5 minutes, which ended after the startup had already finished.

**Fix:** Dropped the log name filter and searched for the script's own tag,
with the time range widened to 1 hour:
```
resource.type="gce_instance"
"batch-startup"
```

**Lesson:** Filter on something you control, such as a tag the script prints,
rather than an agent's internal log name. Check the time range before
assuming logs are missing.

### Note: harmless warnings on the test VM
- `Disk size: '20 GB' is larger than image size: '10 GB'`: Ubuntu's cloud
  images grow the root partition to fill the disk on first boot, so no manual
  resize is needed.
- `[FAILED] Failed to start NSS cache refresh.`: the OS Login user cache
  refresh can fail on first boot before networking settles. SSH through IAP
  worked, so it had no effect.

### Decision: test on one VM before building the fleet
A broken startup script in a MIG produces a loop: the VM boots, fails its
health check, gets recreated and fails again. Testing on one throwaway VM
first keeps that loop out of Phase 4.

### Decision: package failures do not stop the boot
If `apt-get update` fails five times, the script logs a warning and carries
on. The batch application does not need new packages to run, so a mirror
outage should not take the whole fleet down. Disk and app failures do stop the
script, because the node is useless without them.

### Decision: wait for the dpkg lock
Ubuntu runs `unattended-upgrades` on first boot, which holds the dpkg lock.
The script passes `DPkg::Lock::Timeout=300` so apt waits for the lock instead
of failing with `Could not get lock /var/lib/dpkg/lock-frontend`.

### Decision: boot time shapes the auto-healing delay
`apt-get upgrade` on a fresh image adds a few minutes to the first boot. The
Phase 4 auto-healing `initial_delay_sec` must be longer than a full startup, or
the MIG will recreate nodes that are still booting. The measured boot time from
this phase sets that value.