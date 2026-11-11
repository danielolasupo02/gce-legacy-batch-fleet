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

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    preemptible         = false
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
  }

  lifecycle {
    create_before_destroy = true
  }
}
