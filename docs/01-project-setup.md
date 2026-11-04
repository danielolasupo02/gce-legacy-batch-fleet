# Phase 1: Project Setup & Terraform Auth

## Objective
Create a dedicated Google Cloud project for the legacy batch fleet, enable the
APIs that Compute Engine, IAM and logging depend on, set up a least-privilege
service account for Terraform, and prove Terraform can authenticate before any
billable resources are created.

## What Was Built
- A dedicated Google Cloud project, `legacy-batch-fleet-8693`, linked to an open billing account
- Compute Engine, IAM, Resource Manager, Logging and Monitoring APIs enabled
- A custom service account, `terraform-batch-fleet`, with Compute Admin and Service Account User roles
- A JSON key for Terraform, stored locally and blocked from Git by `.gitignore`
- Terraform 1.10.5 installed into Cloud Shell's persistent home directory
- Provider configuration that reads project, region and key path from variables
- A billing budget with alerts at 50%, 90% and 100%

## Configuration

### Project

| Item | Value |
|---|---|
| Project name | GCE Legacy Batch Fleet |
| Project ID | `legacy-batch-fleet-8693` |
| Default region / zone | `us-central1` / `us-central1-a` |
| Working environment | Google Cloud Shell |

### Enabled APIs

| API | Purpose |
|---|---|
| `compute.googleapis.com` | VMs, instance templates, MIGs, health checks, load balancer |
| `iam.googleapis.com` | Service accounts and role bindings |
| `cloudresourcemanager.googleapis.com` | Project-level IAM reads and writes from Terraform |
| `logging.googleapis.com` | Startup script logs and auto-healing events |
| `monitoring.googleapis.com` | Fleet and health check metrics |

### Service account

| Item | Value |
|---|---|
| Name | `terraform-batch-fleet` |
| Display name | Terraform: GCE legacy batch fleet |
| Email | `terraform-batch-fleet@legacy-batch-fleet-8693.iam.gserviceaccount.com` |
| Roles | `roles/compute.admin`, `roles/iam.serviceAccountUser` |
| Authentication | JSON key at `terraform/credentials.json`, `chmod 600`, gitignored |

**Why two roles?** `roles/compute.admin` covers every Compute Engine resource
in this project: templates, MIGs, health checks and load balancer components.
It does not include `iam.serviceAccounts.actAs`, which Terraform needs to attach
a service account to the VMs in the instance template. `roles/iam.serviceAccountUser`
adds that permission, so Phase 2 does not fail on an IAM error that looks
unrelated to IAM.

**Why a key instead of impersonation?** The course setup expects a JSON key, and
this is a short-lived lab project. The key is never committed: `*.json` is
gitignored globally, and the file is readable only by its owner. In production
this would be replaced with impersonation or workload identity federation, so
no long-lived credential exists at all.

### Terraform

| Item | Value |
|---|---|
| Terraform version | `1.10.5` (installed to `~/bin`) |
| Required version | `>= 1.5.0` |
| Google provider | `hashicorp/google` `5.15.0` (exact pin) |
| Provider inputs | `project_id`, `region`, `zone`, `credentials_file` |
| Local values file | `terraform/terraform.tfvars` (gitignored; `.example` committed) |

**Why variables instead of hardcoded values?** The course example hardcodes the
project ID in `providers.tf`. Reading it from `terraform.tfvars` means the repo
can be cloned and pointed at any project without editing code.

### Cost guardrails

| Item | Value |
|---|---|
| Budget amount | $10 USD |
| Scope | All projects |
| Alert thresholds | 50%, 90%, 100% |

Phase 1 resources (project, APIs, IAM, key) cost nothing. Billable resources
start in Phase 2. The global load balancer forwarding rule bills hourly whether
or not it serves traffic, so the fleet is destroyed with `terraform destroy`
between working sessions.

### Commands
The full command set is in [`scripts/phase-01/`](../scripts/phase-01/):

| Script | What it does |
|---|---|
| [`create-project.sh`](../scripts/phase-01/create-project.sh) | Creates the project with a random suffix and links it to an open billing account |
| [`bootstrap.sh`](../scripts/phase-01/bootstrap.sh) | Enables APIs, creates the service account, grants roles with retry, writes the key |
| [`install-terraform.sh`](../scripts/phase-01/install-terraform.sh) | Installs pinned Terraform into `~/bin` |
| [`verify.sh`](../scripts/phase-01/verify.sh) | Runs every check in the table below, then `terraform init`, `validate` and `plan` |

## Verification

| Check | Command | Result |
|---|---|---|
| Active project | `gcloud config get-value project` | `legacy-batch-fleet-8693` |
| Billing enabled | `gcloud billing projects describe legacy-batch-fleet-8693` | `billingEnabled: true` |
| Compute API enabled | `gcloud services list --enabled --filter="config.name:compute.googleapis.com"` | `compute.googleapis.com` |
| Service account roles | `gcloud projects get-iam-policy legacy-batch-fleet-8693 --flatten="bindings[].members" --filter="bindings.members:serviceAccount:terraform-batch-fleet@legacy-batch-fleet-8693.iam.gserviceaccount.com" --format="table(bindings.role)"` | `roles/compute.admin`, `roles/iam.serviceAccountUser` |
| One user-managed key | `gcloud iam service-accounts keys list --iam-account=terraform-batch-fleet@legacy-batch-fleet-8693.iam.gserviceaccount.com --managed-by=user` | One key, created 2026-11-03 23:28 UTC |
| Terraform installed | `terraform version` | `Terraform v1.10.5` |
| Terraform authenticates | `terraform -chdir=terraform plan` | `No changes. Your infrastructure matches the configuration.` |
| Key not tracked by Git | `git status --ignored \| grep credentials.json` | `terraform/credentials.json` listed as ignored |

### Screenshots

**IAM roles**
![IAM roles](../screenshots/01-iam-terraform-sa-roles.png)

**Terraform authenticates**
![Terraform authenticates](../screenshots/02-terraform-auth-ok.png)

## Notes & Issues

### Issue: scripts would not run after upload
**Symptom**
```
-bash: ./scripts/phase-01/create-project.sh: Permission denied
```

**Cause:** Uploading files to Cloud Shell drops the executable bit, so bash
refused to run the script even though it existed.

**Fix:**
```bash
chmod +x scripts/phase-01/*.sh
```

**Lesson:** File permissions do not survive browser uploads. Either `chmod`
after every upload or run scripts with `bash script.sh`.

### Issue: bootstrap script could not find the project ID
**Symptom**
```
./scripts/phase-01/bootstrap.sh: line 9: PROJECT_ID: Set PROJECT_ID first, e.g. PROJECT_ID=my-project
```

**Cause:** `create-project.sh` set the gcloud default project, but
`bootstrap.sh` only read the `PROJECT_ID` shell variable, which had not been
exported.

**Fix:**
```bash
export PROJECT_ID=legacy-batch-fleet-8693
```
The scripts now fall back to `gcloud config get-value project` when the
variable is unset.

**Lesson:** If one script sets state for the next, the next script should read
that state directly instead of relying on the operator to copy it across.

### Issue: role binding failed right after creating the service account
**Symptom**
```
ERROR: (gcloud.projects.add-iam-policy-binding) INVALID_ARGUMENT: Service account
terraform-batch-fleet@legacy-batch-fleet-8693.iam.gserviceaccount.com does not exist.
```

**Cause:** IAM is eventually consistent. The account had been created a second
earlier but had not propagated yet, and the role binding ran immediately.

**Fix:** Re-ran `bootstrap.sh`. It is idempotent, so it reused the existing
account and the bindings succeeded. The script now retries each binding with a
backoff.

**Lesson:** Anything that creates an IAM identity and uses it in the same run
needs a wait or a retry. Terraform has the same race, which is why `time_sleep`
after `google_service_account` is a common pattern.

### Issue: Terraform not installed in Cloud Shell
**Symptom**
```
Follow the instructions at https://developer.hashicorp.com/terraform/install to install terraform, or run the commands below:
```

**Cause:** Cloud Shell no longer ships Terraform. Installing it with `apt`
would not last either, because only `$HOME` persists when the Cloud Shell VM
recycles.

**Fix:** Installed the pinned binary into `~/bin` and added it to `PATH`:
```bash
mkdir -p ~/bin
curl -fL -o /tmp/tf.zip https://releases.hashicorp.com/terraform/1.10.5/terraform_1.10.5_linux_amd64.zip
unzip -o /tmp/tf.zip terraform -d ~/bin
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

**Lesson:** In Cloud Shell, install tools into `$HOME`, not system paths.

### Issue: repo files missing after upload
**Symptom**
```
cp: cannot stat 'terraform/terraform.tfvars.example': No such file or directory
-bash: ./scripts/phase-01/install-terraform.sh: No such file or directory
```

**Cause:** The first upload contained only `scripts/`. The second was an older
zip, because Cloud Shell kept the earlier file with the same name.
`bootstrap.sh` had quietly created an empty `terraform/` folder to hold the key,
which hid the first problem.

**Fix:** Unzipped the full repo into `~/gce-legacy-batch-fleet`, moved the
existing key into it instead of creating a second key, and recreated the
missing script in place.

**Lesson:** Run `ls` after every upload. A script that creates folders for you
can hide a missing file.

### Issue: stale Terraform path after a failed install
**Symptom**
```
-bash: /home/danielolasupo02/bin/terraform: No such file or directory
```

**Cause:** Bash had cached `terraform` as `~/bin/terraform` from an install
attempt that never wrote the binary, so it kept looking for a file that did not
exist.

**Fix:**
```bash
rm -f ~/bin/terraform
# reinstall as above
hash -r
terraform version
```

**Lesson:** After fixing anything on `PATH`, run `hash -r` before assuming the
fix failed.

### Decision: Service Account User granted up front
`roles/compute.admin` alone would have caused an `actAs` permission error when
Terraform created the instance template in Phase 2. `roles/iam.serviceAccountUser`
was granted during setup to avoid this.

### Decision: random suffix on the project ID
Project IDs are global across every Google Cloud customer and cannot be changed
after creation. `create-project.sh` adds a four-digit suffix so the ID is
almost certainly free on the first try.

### Decision: free trial limits shape later phases
The free trial caps running vCPUs at 8 across the account. Three `e2-medium`
nodes use 6, which leaves room for one replacement VM during the Phase 7
auto-healing tests. Fleet nodes will also have no public IPs, which keeps them
inside the low default external IP quota and puts all traffic through the load
balancer.