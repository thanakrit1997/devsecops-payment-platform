resource "google_container_cluster" "main" {
  name     = "payment-production${var.name_suffix}"
  location = var.region # regional: control plane and nodes spread across zones

  network    = google_compute_network.main.id
  subnetwork = google_compute_subnetwork.gke.id

  deletion_protection = true

  # deletion_protection alone is checked only when the cluster itself is
  # deleted - after `destroy` has already removed the node pools.
  lifecycle {
    prevent_destroy = true
  }

  # No initial_node_count / node_config: the cluster is created without a
  # default node pool (GKE >= 1.36.4-gke.1469000); pools are managed below.

  release_channel {
    channel = "REGULAR"
  }

  # Sat/Sun 00:00-06:00 Asia/Bangkok. BYDAY is evaluated in UTC, hence FR,SA.
  # GKE needs >= 48h of windows per 32 days.
  maintenance_policy {
    recurring_window {
      start_time = "2026-01-02T17:00:00Z"
      end_time   = "2026-01-02T23:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=FR,SA"
    }
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  private_cluster_config {
    enable_private_nodes    = true  # nodes have no public IP
    enable_private_endpoint = false # public IP endpoint kept, but allow-listed below
  }

  master_authorized_networks_config {
    gcp_public_cidrs_access_enabled = false

    dynamic "cidr_blocks" {
      for_each = var.master_authorized_networks
      content {
        display_name = cidr_blocks.key
        cidr_block   = cidr_blocks.value
      }
    }
  }

  # IAM-authorised DNS endpoint: reviewers / tooling reach the API with their
  # Google identity instead of an IP allow-list entry.
  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = true
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  datapath_provider = "ADVANCED_DATAPATH" # Dataplane V2: enforces NetworkPolicy
}

locals {
  node_config = {
    machine_type = "e2-standard-2"
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"] # access is limited by the SA's IAM roles
  }
}

# GKE system components. Application pods cannot land here: they select the
# payment pool, and only they tolerate its taint.
resource "google_container_node_pool" "system" {
  name       = "system"
  cluster    = google_container_cluster.main.id
  node_count = 1 # per zone

  node_config {
    machine_type    = local.node_config.machine_type
    disk_type       = "pd-balanced"
    disk_size_gb    = 50
    service_account = local.node_service_account
    oauth_scopes    = local.node_config.oauth_scopes
    labels          = { pool = "system" }

    workload_metadata_config {
      mode = "GKE_METADATA" # pods cannot read the node's credentials
    }

    shielded_instance_config {
      enable_secure_boot = true
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }
}

resource "google_container_node_pool" "payment" {
  name    = "payment"
  cluster = google_container_cluster.main.id

  autoscaling {
    min_node_count = 1 # per zone
    max_node_count = 3
  }

  node_config {
    machine_type    = local.node_config.machine_type
    disk_type       = "pd-balanced"
    disk_size_gb    = 50
    service_account = local.node_service_account
    oauth_scopes    = local.node_config.oauth_scopes
    labels          = { pool = "payment" }

    taint {
      key    = "dedicated"
      value  = "payment"
      effect = "NO_SCHEDULE"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot = true
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  lifecycle {
    precondition {
      condition     = local.node_service_account != null
      error_message = "Set node_service_account when manage_iam = false."
    }
  }
}
