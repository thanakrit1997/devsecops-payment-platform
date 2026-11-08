# CI identity. GitLab exchanges its per-job OIDC id_token for a short-lived
# Google token (Workload Identity Federation): no service-account key exists.
# CI gets image build/push/sign rights only - no Kubernetes permissions, so it
# cannot change cluster state (Argo CD applies what Git says).

variable "gitlab_project_path" {
  description = "GitLab project (group/project) whose protected refs may act as the CI service account."
  type        = string
  default     = "platform/payment-api"
}

resource "google_iam_workload_identity_pool" "gitlab" {
  count                     = var.manage_iam ? 1 : 0
  workload_identity_pool_id = "gitlab${var.name_suffix}"
}

resource "google_iam_workload_identity_pool_provider" "gitlab" {
  count                              = var.manage_iam ? 1 : 0
  workload_identity_pool_id          = google_iam_workload_identity_pool.gitlab[0].workload_identity_pool_id
  workload_identity_pool_provider_id = "gitlab"

  attribute_mapping = {
    "google.subject"          = "assertion.sub"
    "attribute.project_path"  = "assertion.project_path"
    "attribute.ref_protected" = "assertion.ref_protected"
  }
  # Only protected branches / tags of this one project get a token.
  attribute_condition = "assertion.project_path == '${var.gitlab_project_path}' && assertion.ref_protected == 'true'"

  oidc {
    issuer_uri = "https://gitlab.com"
  }
}

resource "google_service_account" "ci" {
  count        = var.manage_iam ? 1 : 0
  account_id   = "gitlab-ci${var.name_suffix}"
  display_name = "GitLab CI: submit builds, scan, sign"
}

resource "google_service_account_iam_member" "ci_wif" {
  count              = var.manage_iam ? 1 : 0
  service_account_id = google_service_account.ci[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.gitlab[0].name}/attribute.project_path/${var.gitlab_project_path}"
}

# Runtime identity of the Cloud Build job: can push to the one repository and
# write logs, nothing else. (The default build SA is a project editor.)
resource "google_service_account" "build" {
  count        = var.manage_iam ? 1 : 0
  account_id   = "cloud-build${var.name_suffix}"
  display_name = "Cloud Build runtime (payment-api image)"
}

resource "google_storage_bucket" "build_source" {
  count                       = var.manage_iam ? 1 : 0
  name                        = "${var.project_id}-build-source${var.name_suffix}"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "Delete"
    }
  }
}

locals {
  ci_bindings = var.manage_iam ? {
    ci_submit_builds = { role = "roles/cloudbuild.builds.editor", member = google_service_account.ci[0].member }
    ci_use_apis      = { role = "roles/serviceusage.serviceUsageConsumer", member = google_service_account.ci[0].member }
    build_logs       = { role = "roles/logging.logWriter", member = google_service_account.build[0].member }
  } : {}
}

resource "google_project_iam_member" "ci" {
  for_each = local.ci_bindings
  project  = var.project_id
  role     = each.value.role
  member   = each.value.member
}

# CI may run builds as the build SA only (not as any other SA).
resource "google_service_account_iam_member" "ci_act_as_build" {
  count              = var.manage_iam ? 1 : 0
  service_account_id = google_service_account.build[0].name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.ci[0].member
}

# Source tarballs (source/) and build logs (logs/) share one short-lived bucket.
resource "google_storage_bucket_iam_member" "build_source" {
  for_each = var.manage_iam ? {
    ci_objects    = { role = "roles/storage.objectUser", member = google_service_account.ci[0].member }    # upload source, read logs
    ci_bucket     = { role = "roles/storage.bucketViewer", member = google_service_account.ci[0].member }  # gcloud reads bucket metadata
    build_objects = { role = "roles/storage.objectUser", member = google_service_account.build[0].member } # read source, write logs
  } : {}
  bucket = google_storage_bucket.build_source[0].name
  role   = each.value.role
  member = each.value.member
}

# Build pushes the image; CI reads it for scanning and writes cosign signatures.
resource "google_artifact_registry_repository_iam_member" "ci_push" {
  for_each   = var.manage_iam ? { ci = google_service_account.ci[0].member, build = google_service_account.build[0].member } : {}
  location   = google_artifact_registry_repository.payment.location
  repository = google_artifact_registry_repository.payment.name
  role       = "roles/artifactregistry.writer"
  member     = each.value
}

output "ci_workload_identity_provider" {
  value = var.manage_iam ? google_iam_workload_identity_pool_provider.gitlab[0].name : null
}
