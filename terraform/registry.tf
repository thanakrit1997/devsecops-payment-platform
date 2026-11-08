resource "google_artifact_registry_repository" "payment" {
  location      = var.region
  repository_id = "payment${var.name_suffix}"
  format        = "DOCKER"

  # A pushed tag can never be moved; deployments still reference digests.
  docker_config {
    immutable_tags = true
  }
}
