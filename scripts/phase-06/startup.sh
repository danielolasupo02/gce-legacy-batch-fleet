#!/usr/bin/env bash
# Batch node startup script.
# Delivered through the `startup-script` metadata key and run by the Google
# guest agent as root on EVERY boot, so every step here must be safe to repeat.
#
#   1. Read configuration from the GCE metadata server
#   2. Update system packages
#   3. Format the data disk (first boot only) and mount it via /etc/fstab
#   4. Install and start the legacy batch application as a systemd service
set -euo pipefail

LOG_FILE=/var/log/batch-startup.log
exec > >(tee -a "${LOG_FILE}") 2>&1

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [batch-startup] $*"; }
trap 'rc=$?; log "FAILED at line ${LINENO}: ${BASH_COMMAND} (exit ${rc})"' ERR

log "===== startup begin ====="

###############################################################################
# 1. Metadata
###############################################################################
MD_URL="http://metadata.google.internal/computeMetadata/v1"

# The Metadata-Flavor header is mandatory: requests without it are rejected,
# which stops a proxied or forged request from reading instance metadata.
md() {
  curl -sSf --retry 5 --retry-connrefused --max-time 5 \
    -H "Metadata-Flavor: Google" "${MD_URL}/$1"
}

# Custom attribute with a fallback when the key is not set (404).
attr() { md "instance/attributes/$1" 2>/dev/null || printf '%s' "${2:-}"; }

INSTANCE_NAME="$(md instance/name)"
ZONE="$(md instance/zone | awk -F/ '{print $NF}')"
PROJECT_ID="$(md project/project-id)"
INTERNAL_IP="$(md instance/network-interfaces/0/ip)"
APP_CONFIG="$(attr app-config '{}')"
APP_ENVIRONMENT="$(attr app-environment '')"

# Per-instance values. shard-id and node-role are set on each VM through MIG
# per-instance configs (stateful metadata), so they differ from node to node
# and survive auto-heal recreation. shard-count comes from the template.
NODE_SHARD="$(attr shard-id unassigned)"
NODE_ROLE="$(attr node-role worker)"
SHARD_COUNT="$(attr shard-count 1)"

# Read one key from the app-config JSON, with a default.
cfg() {
  python3 -c '
import json, sys
try:
    c = json.loads(sys.argv[1] or "{}")
except ValueError:
    c = {}
v = c.get(sys.argv[2])
print(sys.argv[3] if v is None else (str(v).lower() if isinstance(v, bool) else v))
' "${APP_CONFIG}" "$1" "$2"
}

APP_ENV="$(cfg env lab)"
APP_PORT="$(cfg port 8080)"
DATA_MOUNT="$(cfg data_mount /mnt/batch-data)"
DATA_DEVICE_NAME="$(cfg data_device batch-data)"
WORKER_INTERVAL="$(cfg worker_interval_sec 30)"
APT_UPGRADE="$(cfg apt_upgrade true)"

log "instance=${INSTANCE_NAME} zone=${ZONE} project=${PROJECT_ID} ip=${INTERNAL_IP}"
log "node: shard=${NODE_SHARD}/${SHARD_COUNT} role=${NODE_ROLE}"
log "config: env=${APP_ENV} port=${APP_PORT} mount=${DATA_MOUNT} device=${DATA_DEVICE_NAME} worker_interval=${WORKER_INTERVAL}s apt_upgrade=${APT_UPGRADE}"

###############################################################################
# 2. System packages
###############################################################################
export DEBIAN_FRONTEND=noninteractive
# Ubuntu's own unattended-upgrades often holds the dpkg lock on first boot.
# Wait for it instead of failing.
APT_OPTS=(-q -o DPkg::Lock::Timeout=300
          -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

apt_ok=false
for attempt in 1 2 3 4 5; do
  if apt-get "${APT_OPTS[@]}" update; then apt_ok=true; break; fi
  log "apt-get update failed (attempt ${attempt}/5), retrying in $((attempt * 10))s"
  sleep $((attempt * 10))
done

if [[ "${apt_ok}" == "true" ]]; then
  log "package index updated"
  if [[ "${APT_UPGRADE}" == "true" ]]; then
    if apt-get "${APT_OPTS[@]}" -y upgrade; then
      log "packages upgraded"
    else
      log "WARN: apt-get upgrade failed; continuing with current packages"
    fi
  fi
else
  # The app does not depend on new packages. Keep the node serving rather than
  # failing the whole boot, but make the problem loud in the logs.
  log "WARN: apt-get update failed after 5 attempts (check Cloud NAT); continuing"
fi

###############################################################################
# 3. Data disk: format once, mount every boot
###############################################################################
DEV="/dev/disk/by-id/google-${DATA_DEVICE_NAME}"

for _ in $(seq 1 30); do [[ -e "${DEV}" ]] && break; sleep 2; done
if [[ ! -e "${DEV}" ]]; then
  log "ERROR: data disk ${DEV} not found"
  exit 1
fi

# blkid exits non-zero when the device has no filesystem. Only then format,
# so a reboot or a reattached disk never loses data.
if blkid "${DEV}" >/dev/null 2>&1; then
  log "existing filesystem on ${DEV}, skipping format"
else
  log "no filesystem on ${DEV}, formatting ext4 (first boot)"
  mkfs.ext4 -q -m 0 -L batchdata \
    -E lazy_itable_init=0,lazy_journal_init=0,discard "${DEV}"
fi

DISK_UUID="$(blkid -s UUID -o value "${DEV}")"
mkdir -p "${DATA_MOUNT}"

# fstab by UUID, with nofail so a missing disk cannot stop the VM booting.
if ! grep -q "UUID=${DISK_UUID}" /etc/fstab; then
  sed -i "\|[[:space:]]${DATA_MOUNT}[[:space:]]|d" /etc/fstab
  echo "UUID=${DISK_UUID} ${DATA_MOUNT} ext4 discard,defaults,nofail 0 2" >> /etc/fstab
  log "fstab entry added for UUID=${DISK_UUID}"
fi

if mountpoint -q "${DATA_MOUNT}"; then
  log "${DATA_MOUNT} already mounted"
else
  mount "${DATA_MOUNT}"
  log "mounted ${DEV} at ${DATA_MOUNT}"
fi

mkdir -p "${DATA_MOUNT}"/{inbox,outbox,state}

###############################################################################
# 4. Application environment
###############################################################################
APP_USER=batchapp
APP_DIR=/opt/batch-app
CONF_DIR=/etc/batch-app

id "${APP_USER}" >/dev/null 2>&1 || \
  useradd --system --no-create-home --shell /usr/sbin/nologin "${APP_USER}"
mkdir -p "${APP_DIR}" "${CONF_DIR}"
chown -R "${APP_USER}:${APP_USER}" "${DATA_MOUNT}"/{inbox,outbox,state}

# app-environment: KEY=VALUE lines. Keys are validated, reserved keys cannot
# be overridden, and values are never logged in case they hold secrets.
EXTRA_ENV=""
EXTRA_KEYS=""
RESERVED=" APP_ENV APP_PORT DATA_MOUNT WORKER_INTERVAL INSTANCE_NAME ZONE PROJECT_ID INTERNAL_IP NODE_SHARD NODE_ROLE SHARD_COUNT APP_ENV_KEYS "
while IFS= read -r line; do
  [[ -z "${line//[[:space:]]/}" || "${line}" == \#* ]] && continue
  key="${line%%=*}"
  val="${line#*=}"
  if [[ "${line}" != *=* || ! "${key}" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
    log "WARN: ignoring invalid app-environment line (key '${key}')"
    continue
  fi
  if [[ "${RESERVED}" == *" ${key} "* ]]; then
    log "WARN: app-environment may not override reserved key ${key}"
    continue
  fi
  EXTRA_ENV+="${key}=${val}"$'\n'
  EXTRA_KEYS+="${EXTRA_KEYS:+,}${key}"
done <<< "${APP_ENVIRONMENT}"
log "app-environment keys from metadata: ${EXTRA_KEYS:-none}"

# Runtime settings come from metadata, not from the image.
cat > "${CONF_DIR}/app.env" <<EOF
APP_ENV=${APP_ENV}
APP_PORT=${APP_PORT}
DATA_MOUNT=${DATA_MOUNT}
WORKER_INTERVAL=${WORKER_INTERVAL}
INSTANCE_NAME=${INSTANCE_NAME}
ZONE=${ZONE}
PROJECT_ID=${PROJECT_ID}
INTERNAL_IP=${INTERNAL_IP}
NODE_SHARD=${NODE_SHARD}
NODE_ROLE=${NODE_ROLE}
SHARD_COUNT=${SHARD_COUNT}
APP_ENV_KEYS=${EXTRA_KEYS}
EOF
# Appended separately: a heredoc only ends on a line that is exactly "EOF".
printf '%s' "${EXTRA_ENV}" >> "${CONF_DIR}/app.env"
printf '%s\n' "${APP_CONFIG}" > "${CONF_DIR}/config.json"
chmod 0644 "${CONF_DIR}/app.env" "${CONF_DIR}/config.json"

# Stand-in for the legacy batch processor: hashes files dropped in inbox/,
# writes results to outbox/, and serves /healthz for the load balancer.
cat > "${APP_DIR}/app.py" <<'PYEOF'
import hashlib
import json
import os
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ENV = os.environ
DATA = ENV.get("DATA_MOUNT", "/mnt/batch-data")
PORT = int(ENV.get("APP_PORT", "8080"))
INTERVAL = int(ENV.get("WORKER_INTERVAL", "30"))
HOST = ENV.get("INSTANCE_NAME", socket.gethostname())
HEARTBEAT = os.path.join(DATA, "state", f"{HOST}.heartbeat")
STATS = {"processed": 0, "started": time.time(), "last_beat": 0.0}


def worker():
    inbox, outbox = os.path.join(DATA, "inbox"), os.path.join(DATA, "outbox")
    while True:
        try:
            for name in sorted(os.listdir(inbox)):
                src = os.path.join(inbox, name)
                if not os.path.isfile(src):
                    continue
                with open(src, "rb") as f:
                    digest = hashlib.sha256(f.read()).hexdigest()
                with open(os.path.join(outbox, name + ".sha256"), "w") as f:
                    f.write(digest + "\n")
                os.remove(src)
                STATS["processed"] += 1
                if ENV.get("LOG_LEVEL") == "DEBUG":
                    print(f"processed {name} on shard {ENV.get('NODE_SHARD')}", flush=True)
            with open(HEARTBEAT, "w") as f:
                f.write(str(time.time()))
            STATS["last_beat"] = time.time()
        except Exception as exc:  # keep the loop alive; health check reports it
            print(f"worker error: {exc}", flush=True)
        time.sleep(INTERVAL)


def health():
    if not os.path.ismount(DATA):
        return False, "data disk not mounted"
    age = time.time() - STATS["last_beat"]
    if age > INTERVAL * 3:
        return False, f"worker heartbeat stale ({age:.0f}s)"
    return True, "ok"


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/healthz":
            ok, reason = health()
            self._send(200 if ok else 503,
                       {"status": "ok" if ok else "unhealthy", "reason": reason})
        elif self.path == "/":
            self._send(200, {
                "instance": HOST,
                "zone": ENV.get("ZONE"),
                "shard": ENV.get("NODE_SHARD"),
                "role": ENV.get("NODE_ROLE"),
                "env": ENV.get("APP_ENV"),
                "processed": STATS["processed"],
                "uptime_sec": int(time.time() - STATS["started"]),
            })
        elif self.path == "/config":
            with open("/etc/batch-app/config.json") as f:
                app_config = json.load(f)
            keys = [k for k in ENV.get("APP_ENV_KEYS", "").split(",") if k]
            self._send(200, {
                "node": {
                    "instance": HOST,
                    "zone": ENV.get("ZONE"),
                    "shard": ENV.get("NODE_SHARD"),
                    "shard_count": ENV.get("SHARD_COUNT"),
                    "role": ENV.get("NODE_ROLE"),
                },
                "app_config": app_config,
                "environment": {k: ENV.get(k) for k in keys},
            })
        else:
            self._send(404, {"error": "not found"})

    def log_message(self, *args):  # silence per-request logs (health checks)
        pass


threading.Thread(target=worker, daemon=True).start()
ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
PYEOF

cat > /etc/systemd/system/batch-app.service <<EOF
[Unit]
Description=Legacy batch processor
After=network-online.target local-fs.target
Wants=network-online.target
RequiresMountsFor=${DATA_MOUNT}

[Service]
User=${APP_USER}
EnvironmentFile=${CONF_DIR}/app.env
ExecStart=/usr/bin/python3 ${APP_DIR}/app.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable batch-app >/dev/null 2>&1
systemctl restart batch-app
log "batch-app service started"

for _ in $(seq 1 15); do
  if curl -sf "http://localhost:${APP_PORT}/healthz" >/dev/null; then
    log "health check passed: http://localhost:${APP_PORT}/healthz"
    break
  fi
  sleep 2
done
curl -sf "http://localhost:${APP_PORT}/healthz" >/dev/null || \
  log "WARN: /healthz not passing yet"

log "===== STARTUP COMPLETE instance=${INSTANCE_NAME} shard=${NODE_SHARD} role=${NODE_ROLE} mount=${DATA_MOUNT} port=${APP_PORT} env=${APP_ENV} ====="
