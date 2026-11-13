###############################################################################
# GCE Legacy Batch Fleet
###############################################################################

locals {
  # Node identity is created outside Terraform (scripts/phase-02/create-node-sa.sh)
  # so the Terraform SA does not need IAM admin rights.
  node_service_account_email = coalesce(
    var.node_service_account_email,
    "batch-node-sa@${var.project_id}.iam.gserviceaccount.com"
  )

  common_labels = merge(
    {
      app        = "legacy-batch"
      managed-by = "terraform"
    },
    var.labels
  )
}

###############################################################################
# Network: outbound internet for nodes without external IPs, and admin SSH
###############################################################################

data "google_compute_network" "fleet" {
  name = var.network
}

resource "google_compute_router" "batch" {
  name    = "batch-router"
  region  = var.region
  network = data.google_compute_network.fleet.id
}

# Lets nodes reach apt mirrors without public IPs. Outbound only.
resource "google_compute_router_nat" "batch" {
  name                               = "batch-nat"
  router                             = google_compute_router.batch.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# SSH only from Google's IAP range, only to batch nodes.
resource "google_compute_firewall" "allow_iap_ssh" {
  name          = "batch-allow-iap-ssh"
  network       = data.google_compute_network.fleet.name
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]
  target_tags   = var.network_tags

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

###############################################################################
# Instance template
###############################################################################

resource "google_compute_instance_template" "batch_node" {
  # Templates are immutable. name_prefix + create_before_destroy lets Terraform
  # build a new template before removing the old one the MIG still points at.
  name_prefix  = "batch-node-template-"
  description  = "Batch processing node: Ubuntu 22.04 LTS with a dedicated data disk"
  machine_type = var.machine_type
  tags         = var.network_tags
  labels       = local.common_labels

  # Boot disk: Ubuntu 22.04 LTS, resolved from the image family at create time
  disk {
    boot         = true
    source_image = var.boot_image
    disk_type    = "pd-balanced"
    disk_size_gb = var.boot_disk_size_gb
    auto_delete  = true
    labels       = local.common_labels
  }

  # Data disk: blank persistent disk per instance, formatted and mounted by the
  # startup script. device_name gives a stable path:
  #   /dev/disk/by-id/google-batch-data
  disk {
    boot         = false
    device_name  = var.data_disk_device_name
    disk_type    = var.data_disk_type
    disk_size_gb = var.data_disk_size_gb
    auto_delete  = true
    mode         = "READ_WRITE"
    labels       = local.common_labels
  }

  # No access_config block = no external IP. Traffic arrives through the load
  # balancer; outbound internet (apt) goes through Cloud NAT, added with the
  # startup script.
  network_interface {
    network = var.network
  }

  service_account {
    email  = local.node_service_account_email
    scopes = ["cloud-platform"]
  }

  # Stretch goal: Spot VMs for non-critical batch capacity (var.use_spot).
  # Spot VMs cost far less but can be reclaimed by Google at any time, cannot
  # live-migrate, and must not auto-restart; the MIG brings them back instead.
  scheduling {
    provisioning_model          = var.use_spot ? "SPOT" : "STANDARD"
    preemptible                 = var.use_spot
    automatic_restart           = var.use_spot ? false : true
    on_host_maintenance         = var.use_spot ? "TERMINATE" : "MIGRATE"
    instance_termination_action = var.use_spot ? "STOP" : null
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    enable-oslogin = "TRUE"

    # Runs as root on every boot (see scripts/startup.sh)
    startup-script = file("${path.module}/../scripts/startup.sh")

    # Read by the startup script from the metadata server
    app-config = jsonencode({
      env                 = var.app_env
      port                = var.app_port
      data_mount          = var.data_mount_path
      data_device         = var.data_disk_device_name
      worker_interval_sec = var.worker_interval_sec
      apt_upgrade         = var.apt_upgrade_on_boot
    })

    # Runtime environment variables, one KEY=VALUE per line. The startup
    # script validates each key and writes them to /etc/batch-app/app.env.
    app-environment = join("\n", [for k, v in var.app_environment : "${k}=${v}"])

    # Fleet size, so each node knows how many shards exist. The node's own
    # shard-id and node-role are per-instance metadata set on the MIG
    # (scripts/phase-06/rollout.sh), not here.
    shard-count = tostring(var.target_size)
  }

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# Health check (auto-healing now, load balancer backend in the next step)
###############################################################################

# Google's health checkers probe from these ranges. Without this rule every
# node looks dead and auto-healing recreates them in a loop.
resource "google_compute_firewall" "allow_health_checks" {
  name          = "batch-allow-health-checks"
  network       = data.google_compute_network.fleet.name
  direction     = "INGRESS"
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = var.network_tags

  allow {
    protocol = "tcp"
    ports    = [tostring(var.app_port)]
  }
}

resource "google_compute_health_check" "batch_app" {
  name                = "batch-app-health-check"
  description         = "GET /healthz on the batch app: disk mounted and worker heartbeat fresh"
  check_interval_sec  = var.health_check_interval_sec
  timeout_sec         = var.health_check_timeout_sec
  healthy_threshold   = 2
  unhealthy_threshold = var.health_check_unhealthy_threshold

  http_health_check {
    port         = var.app_port
    request_path = "/healthz"
  }

  log_config {
    enable = true # log state changes (HEALTHY <-> UNHEALTHY) to Cloud Logging
  }
}

###############################################################################
# Managed Instance Group: regional, 3 nodes, auto-healing, stateful data disk
###############################################################################

resource "google_compute_region_instance_group_manager" "batch_mig" {
  name                      = "batch-mig"
  description               = "Legacy batch fleet built from batch-node-template-*"
  base_instance_name        = "batch-node"
  region                    = var.region
  distribution_policy_zones = var.zones
  target_size               = var.target_size

  version {
    name              = "primary"
    instance_template = google_compute_instance_template.batch_node.self_link
  }

  # The load balancer backend service addresses the app by this name.
  named_port {
    name = "http"
    port = var.app_port
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.batch_app.id
    initial_delay_sec = var.autohealing_initial_delay_sec
  }

  # Keep each node's data disk when the MIG recreates that node (auto-healing),
  # and delete it only when the node is removed for good (scale-in, destroy).
  stateful_disk {
    device_name = var.data_disk_device_name
    delete_rule = "ON_PERMANENT_INSTANCE_DELETION"
  }

  # Template changes do not roll out automatically: see the docs for why.
  # Stateful disks need RECREATE (same name, same disk) and no redistribution.
  update_policy {
    type                         = "OPPORTUNISTIC"
    minimal_action               = "REPLACE"
    replacement_method           = "RECREATE"
    instance_redistribution_type = "NONE"
    max_surge_fixed              = 0
    max_unavailable_fixed        = length(var.zones)
  }

  # Do not block terraform apply on instances becoming healthy.
  wait_for_instances = false
}

###############################################################################
# Global external Application Load Balancer (HTTP)
#
#   client -> forwarding rule (:80) -> target HTTP proxy -> URL map
#          -> backend service (health check) -> batch-mig named port http:8080
###############################################################################

resource "google_compute_global_address" "batch_lb" {
  name = "batch-lb-ip"
}

resource "google_compute_backend_service" "batch" {
  name                  = "batch-backend"
  description           = "Batch fleet behind the external Application Load Balancer"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTP"
  port_name             = "http" # matches the MIG named port
  timeout_sec           = 30
  health_checks         = [google_compute_health_check.batch_app.id]

  # Spread requests evenly across healthy nodes in all three zones.
  locality_lb_policy = "ROUND_ROBIN"

  # Let in-flight requests finish before a node is removed (auto-heal, scale-in).
  connection_draining_timeout_sec = 30

  backend {
    group           = google_compute_region_instance_group_manager.batch_mig.instance_group
    balancing_mode  = "UTILIZATION"
    max_utilization = 0.8
    capacity_scaler = 1.0
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

resource "google_compute_url_map" "batch" {
  name            = "batch-url-map"
  default_service = google_compute_backend_service.batch.id
}

resource "google_compute_target_http_proxy" "batch" {
  name    = "batch-http-proxy"
  url_map = google_compute_url_map.batch.id
}

resource "google_compute_global_forwarding_rule" "batch_http" {
  name                  = "batch-http-rule"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_protocol           = "TCP"
  port_range            = "80"
  ip_address            = google_compute_global_address.batch_lb.address
  target                = google_compute_target_http_proxy.batch.id
}
