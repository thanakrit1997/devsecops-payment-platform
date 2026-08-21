resource "google_container_cluster" "main" {
  name     = "payment-production"
  location = var.region
  network  = var.network

  deletion_protection = false

  remove_default_node_pool = false
  initial_node_count       = 1

  node_config {
    machine_type = "e2-standard-4"

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "0.0.0.0/0"
      display_name = "internet"
    }
  }
}
