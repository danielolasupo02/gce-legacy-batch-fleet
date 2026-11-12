# Phase 5: Load Balancing & Health Checks

## Objective
Put a single public entry point in front of the batch fleet. A global external
Application Load Balancer receives HTTP traffic on one static IP, sends it only
to nodes that pass the `/healthz` check, and spreads it across all three zones.
The same health check drives auto-healing, so a node that stops responding is
first taken out of traffic and then recreated.

## What Was Built
- Global static IP `batch-lb-ip`
- Backend service `batch-backend` pointing at `batch-mig` through the `http` named port, using `batch-app-health-check`
- URL map `batch-url-map` sending all paths to the backend service
- Target HTTP proxy `batch-http-proxy`
- Global forwarding rule `batch-http-rule` on port 80
- Request logging on the backend service
- `scripts/phase-05/verify.sh` to wait for the load balancer, show backend health and test how traffic is spread

## How It Works

![How health checks drive traffic and auto-healing](../screenshots/health-check-flow.png)

```
              Google health checkers (35.191.x / 130.211.x)
                 │            │            │
      GET /healthz every 10s, to EACH node separately
                 ▼            ▼            ▼
           batch-node-a  batch-node-b  batch-node-c
              200 ✓         200 ✓        503 ✗  (3 failures in a row)
                 │            │            │
                 └─────┬──────┘            │
                       ▼                   ▼
   Load balancer: send traffic       MIG auto-healing: recreate
   only to a and b                   node c from the template
```

### What runs on each node
Every node runs its own independent copy of the batch application, a small
Python program (standard library only) installed by the startup script as the
`batch-app` systemd service. Nodes do not talk to each other or share data.
Inside each copy:

- **Worker thread:** every 30 s, hashes any file in that node's
  `/mnt/batch-data/inbox/`, writes the result to `outbox/`, then writes a
  heartbeat timestamp to `state/`.
- **HTTP server on port 8080:**
  - `/healthz` returns `200` only if the data disk is mounted and the last
    heartbeat is under 90 s old, otherwise `503`
  - `/` reports which node answered, its zone and files processed
  - `/config` returns the `app-config` the node booted with

### How nodes are checked
The health check does not test the fleet as a whole. Google's health checkers
call `/healthz` on **each node separately**, straight to port 8080, every 10
seconds. Each node gets its own HEALTHY or UNHEALTHY state, and that one result
is used twice:

- **Load balancer:** each client request goes to one healthy node, rotating
  round robin. An unhealthy node gets no new requests.
- **MIG auto-healing:** a node that fails 3 checks in a row is recreated from
  the template. Only that node is touched; the others keep serving.

### "Frontend" and "backend" in load balancer terms
No separate frontend application was deployed. In Google Cloud load
balancing, frontend and backend are the two halves of the load balancer
itself, and the console groups the Terraform resources under those labels:

| Console label | Terraform resources | What it is |
|---|---|---|
| Frontend | `batch-lb-ip`, `batch-http-rule`, `batch-http-proxy` | The public IP and port clients connect to, and the proxy that accepts the connection. No code |
| Routing rules | `batch-url-map` | Chooses a backend by host or path. One backend here, so every path goes to it |
| Backend | `batch-backend` | A settings object: which instance group, which port, which health check, how to balance |
| (behind the backend) | `batch-mig` | The three VMs running the Python batch app |

A request to `http://34.128.175.11/` enters the frontend, the URL map sends it
to the backend service, and the backend service picks one healthy VM.

## Configuration

### Request path

```
 Client
   │  HTTP :80
   ▼
 batch-http-rule  (global forwarding rule, IP batch-lb-ip)
   │
   ▼
 batch-http-proxy (target HTTP proxy)
   │
   ▼
 batch-url-map    (all paths → batch-backend)
   │
   ▼
 batch-backend    (backend service, health check batch-app-health-check)
   │  named port http → 8080
   ▼
 batch-mig: batch-node-* in us-central1-a / -b / -c
```

### Load balancer

| Item | Value |
|---|---|
| Type | Global external Application Load Balancer |
| Scheme | `EXTERNAL_MANAGED` |
| Frontend | `batch-lb-ip`, TCP port 80 |
| Forwarding rule | `batch-http-rule` |
| Proxy | `batch-http-proxy` (HTTP) |
| URL map | `batch-url-map`, default service `batch-backend` |
| Public IP | `34.128.175.11` |

**Why `EXTERNAL_MANAGED` instead of the classic load balancer?** It is Google's
current Application Load Balancer, built on Envoy. It supports locality
policies such as round robin and is where new features land. The classic
`EXTERNAL` scheme still works but is the older generation.

**Why a reserved static IP?** Without one, the forwarding rule gets an
ephemeral IP that changes if the rule is recreated. A reserved address stays
fixed for the life of the project, so DNS or clients can rely on it.

### Backend service

| Item | Value |
|---|---|
| Name | `batch-backend` |
| Backend | `batch-mig` (regional instance group) |
| Protocol / port name | HTTP / `http` (MIG named port → 8080) |
| Health check | `batch-app-health-check` (same check as auto-healing) |
| Balancing mode | `UTILIZATION`, max 80%, capacity scaler 1.0 |
| Locality policy | `ROUND_ROBIN` |
| Request timeout | 30 s |
| Connection draining | 30 s |
| Logging | Enabled, 100% sample rate |

**Why the named port?** The backend service does not hardcode 8080. It asks
the MIG for the port called `http`. If the app ever moves to another port,
only the MIG's named port changes, not the load balancer.

**Why `ROUND_ROBIN`?** The default policy sends requests to whichever node
looks least loaded. With almost no traffic, that can make one node answer
nearly every request and hide the other two. Round robin rotates through all
healthy nodes, so the spread is visible in testing.

**Why connection draining?** When auto-healing recreates a node, the load
balancer stops sending it new requests but gives in-flight requests up to 30
seconds to finish, so a node replacement does not cut requests off mid-way.

### Health check

| Item | Value |
|---|---|
| Name | `batch-app-health-check` (created in Phase 4) |
| Protocol / port / path | HTTP / 8080 / `/healthz` |
| Check interval | 10 s |
| Timeout | 5 s |
| Healthy threshold | 2 |
| Unhealthy threshold | 3 |
| Used by | Backend service (traffic) and MIG auto-healing (recreation) |

**What happens when a node fails?**

| Time after `/healthz` starts failing | Load balancer | MIG |
|---|---|---|
| 0 s | Still sending traffic | Nothing yet |
| ~30 s (3 × 10 s) | Node marked unhealthy, no new requests | Node marked unhealthy |
| ~30 s + | Remaining two nodes take all traffic | Recreates the node from the template |
| After reboot + 2 passes | Node back in rotation | Fleet back to 3 healthy |

### Firewall

No new rule was needed. `batch-allow-health-checks` from Phase 4 already
admits `35.191.0.0/16` and `130.211.0.0/22` on port 8080. Those ranges carry
both the health check probes and the load balancer's proxied traffic, so the
nodes accept requests only from Google's front ends, never directly from the
internet.

### Cost

| Item | Approximate cost |
|---|---|
| Forwarding rule | About $0.025/hour, billed whether or not traffic flows |
| Data processed | About $0.008/GB |
| Static IP | Free while attached to a forwarding rule |

### Commands
The full command set is in [`terraform/`](../terraform/) and
[`scripts/phase-05/`](../scripts/phase-05/):

| File | What it does |
|---|---|
| [`main.tf`](../terraform/main.tf) | Adds the global IP, backend service, URL map, HTTP proxy and forwarding rule |
| [`outputs.tf`](../terraform/outputs.tf) | `lb_ip`, `lb_url` |
| [`verify.sh`](../scripts/phase-05/verify.sh) | Waits for HTTP 200, shows backend health and health check settings, tallies which node answered each request |

```bash
terraform -chdir=terraform plan -out=phase5.tfplan
terraform -chdir=terraform apply phase5.tfplan
OUT=~/phase05-evidence.txt ./scripts/phase-05/verify.sh
```

## Verification

| Check | Command | Result |
|---|---|---|
| Load balancer created | `terraform -chdir=terraform apply phase5.tfplan` | `Apply complete! Resources: 5 added, 0 changed, 0 destroyed.` |
| LB serving | `verify.sh` (wait for HTTP 200) | First `200` after 72 s, following `000` and `502` while the LB was programmed. Stable result: _pending re-run_ |
| Backends healthy | `gcloud compute backend-services get-health batch-backend --global` | `batch-node-5zq9`, `batch-node-mrvz`, `batch-node-r0pl`: all `HEALTHY` |
| Health check timings | `gcloud compute health-checks describe batch-app-health-check` | port `8080`, path `/healthz`, interval `10`, timeout `5`, healthy `2`, unhealthy `3` |
| Traffic spread across nodes | `verify.sh` (request tally) | _pending_ |
| MIG auto-healing uses the same check | `gcloud compute instance-groups managed describe batch-mig --region=us-central1 --format="yaml(autoHealingPolicies)"` | _pending_ |

### Screenshots

**Backends healthy in the load balancer**
![Load balancer backends healthy](../screenshots/09-lb-backends-healthy.png)

**Health check configuration**
![Health check configuration](../screenshots/10-health-check-config.png)

**Requests spread across the fleet**
![Round robin across nodes](../screenshots/11-curl-lb-round-robin.png)

## Notes & Issues

### Issue: intermittent 502s right after the load balancer came up
**Symptom**
```
000 000 000 000 000 502 502
==> Serving after 72s
...
<title>502 Server Error</title>
...
    3 requests  batch-node-5zq9      us-central1-a
    2 requests  batch-node-mrvz      us-central1-b
   25 requests  ERROR                no-response
```

**Cause:** A new global load balancer is programmed across Google's edge over
several minutes. During that window some front ends already route to the
backends and others do not, so requests alternate between `200` and `502`.
The first version of `verify.sh` treated a single `200` as "serving" and
started the test too early. All three backends were already `HEALTHY`, so the
fleet itself was fine.

**Fix:** Waited a few minutes and re-ran the test. `verify.sh` now waits for
10 consecutive `200` responses before testing.

**Lesson:** For a global load balancer, `terraform apply` finishing and one
good response do not mean it is ready. Wait for a streak of successes before
judging it.

### Decision: HTTP only
The lab serves plain HTTP on port 80. A production setup would add an HTTPS
forwarding rule with a Google-managed certificate and redirect port 80 to 443.
That needs a domain name, which this lab does not have.

### Decision: no Cloud Armor
The batch application exposes only read-only status endpoints. A production
deployment would attach a Cloud Armor policy to the backend service for rate
limiting and IP allow-listing.