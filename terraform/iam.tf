resource "google_service_account" "payment" {
  account_id   = "payment-api"
  display_name = "Payment API"
}

resource "google_project_iam_member" "payment_owner" {
  project = var.project_id
  role    = "roles/owner"
  member  = "serviceAccount:${google_service_account.payment.email}"
}

resource "google_service_account_key" "payment" {
  service_account_id = google_service_account.payment.name
}

output "payment_service_account_private_key" {
  value     = google_service_account_key.payment.private_key
  sensitive = true
}
