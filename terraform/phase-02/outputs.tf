output "instance_template_name" {
  description = "Name of the current batch node instance template"
  value       = google_compute_instance_template.batch_node.name
}

output "instance_template_self_link" {
  description = "Self link of the current batch node instance template (used by the MIG)"
  value       = google_compute_instance_template.batch_node.self_link
}

output "node_service_account_email" {
  description = "Service account attached to batch nodes"
  value       = local.node_service_account_email
}
