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
  }

  lifecycle {
    create_before_destroy = true
  }
}
