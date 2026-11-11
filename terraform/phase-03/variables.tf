###############################################################################
# Project and provider
###############################################################################

variable "project_id" {
  description = "GCP project ID that hosts the batch fleet"
  type        = string
}

variable "region" {
  description = "Default region for regional resources (MIG, LB backends)"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Default zone for zonal resources"
  type        = string
  default     = "us-central1-a"
}

variable "credentials_file" {
  description = "Path to the Terraform service account JSON key (never committed)"
  type        = string
  default     = "./credentials.json"
}

###############################################################################
# Instance template
###############################################################################

variable "machine_type" {
  description = "Machine type for batch nodes. e2-standard-2 = 2 vCPU / 8 GB, dedicated (not shared-core)"
  type        = string
  default     = "e2-standard-2"
}

variable "boot_image" {
  description = "Boot image or image family for batch nodes"
  type        = string
  default     = "ubuntu-os-cloud/ubuntu-2204-lts"
}

variable "boot_disk_size_gb" {
  description = "Boot disk size in GB"
  type        = number
  default     = 20
}

variable "data_disk_size_gb" {
  description = "Size of the per-instance data disk for batch input/output, in GB"
  type        = number
  default     = 50

  validation {
    condition     = var.data_disk_size_gb >= 10 && var.data_disk_size_gb <= 500
    error_message = "data_disk_size_gb must be between 10 and 500 for this lab."
  }
}

variable "data_disk_type" {
  description = "Persistent disk type for the data disk"
  type        = string
  default     = "pd-balanced"

  validation {
    condition     = contains(["pd-standard", "pd-balanced", "pd-ssd"], var.data_disk_type)
    error_message = "data_disk_type must be pd-standard, pd-balanced or pd-ssd."
  }
}

variable "data_disk_device_name" {
  description = "Device name for the data disk; appears as /dev/disk/by-id/google-<name>"
  type        = string
  default     = "batch-data"
}

variable "network" {
  description = "VPC network for the batch nodes"
  type        = string
  default     = "default"
}

variable "network_tags" {
  description = "Network tags applied to every batch node; firewall rules target these"
  type        = list(string)
  default     = ["batch-node"]
}

variable "node_service_account_email" {
  description = "Service account attached to batch nodes. Defaults to batch-node-sa@<project>.iam.gserviceaccount.com"
  type        = string
  default     = null
}

variable "labels" {
  description = "Extra labels merged onto every resource"
  type        = map(string)
  default     = {}
}

###############################################################################
# Application config (delivered via the app-config metadata key)
###############################################################################

variable "app_env" {
  description = "Environment flag passed to the batch application"
  type        = string
  default     = "lab"
}

variable "app_port" {
  description = "Port the batch application listens on (health checks target this)"
  type        = number
  default     = 8080
}

variable "data_mount_path" {
  description = "Where the startup script mounts the data disk"
  type        = string
  default     = "/mnt/batch-data"
}

variable "worker_interval_sec" {
  description = "Seconds between batch worker passes; heartbeat older than 3x this fails /healthz"
  type        = number
  default     = 30
}

variable "apt_upgrade_on_boot" {
  description = "Run apt-get upgrade on every boot (slower boots, patched nodes)"
  type        = bool
  default     = true
}
