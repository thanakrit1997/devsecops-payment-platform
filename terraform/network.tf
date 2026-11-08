resource "google_compute_network" "main" {
  name                    = "payment${var.name_suffix}"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "gke" {
  name          = "payment-gke${var.name_suffix}"
  region        = var.region
  network       = google_compute_network.main.id
  ip_cidr_range = "10.40.0.0/20"

  # Private nodes reach Artifact Registry and Google APIs without a NAT.
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.44.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.48.0.0/20"
  }
}
