output "cluster_name" {
  value = google_container_cluster.main.name
}

output "cluster_location" {
  value = google_container_cluster.main.location
}

output "cluster_dns_endpoint" {
  value = google_container_cluster.main.control_plane_endpoints_config[0].dns_endpoint_config[0].endpoint
}

output "image_repository" {
  value = "${google_artifact_registry_repository.payment.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.payment.repository_id}/payment-api"
}
