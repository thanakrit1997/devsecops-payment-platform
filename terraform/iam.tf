# The application calls no Google API, so it has no Google identity at all
# (previously: roles/owner + an exported JSON key). Workload Identity is
# enabled on the cluster for when one is needed.

resource "google_service_account" "nodes" {
  count        = var.manage_iam ? 1 : 0
  account_id   = "gke-nodes${var.name_suffix}"
  display_name = "GKE nodes (payment)"
}

resource "google_project_iam_member" "nodes" {
  count   = var.manage_iam ? 1 : 0
  project = var.project_id
  role    = "roles/container.defaultNodeServiceAccount" # logs, metrics, autoscaling
  member  = google_service_account.nodes[0].member
}

resource "google_artifact_registry_repository_iam_member" "nodes_pull" {
  count      = var.manage_iam ? 1 : 0
  location   = google_artifact_registry_repository.payment.location
  repository = google_artifact_registry_repository.payment.name
  role       = "roles/artifactregistry.reader"
  member     = google_service_account.nodes[0].member
}

locals {
  node_service_account = var.manage_iam ? google_service_account.nodes[0].email : var.node_service_account
}
