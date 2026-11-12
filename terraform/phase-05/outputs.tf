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

output "nat_name" {
  description = "Cloud NAT gateway giving nodes outbound internet access"
  value       = google_compute_router_nat.batch.name
}

output "mig_name" {
  description = "Managed instance group name"
  value       = google_compute_region_instance_group_manager.batch_mig.name
}

output "mig_instance_group" {
  description = "Instance group URL (backend for the load balancer)"
  value       = google_compute_region_instance_group_manager.batch_mig.instance_group
}

output "health_check_id" {
  description = "Health check used for auto-healing"
  value       = google_compute_health_check.batch_app.id
}

output "lb_ip" {
  description = "Public IP of the HTTP load balancer"
  value       = google_compute_global_address.batch_lb.address
}

output "lb_url" {
  description = "Load balancer URL"
  value       = "http://${google_compute_global_address.batch_lb.address}/"
}
