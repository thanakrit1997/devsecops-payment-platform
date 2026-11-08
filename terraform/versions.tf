terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.10" # exact build pinned in .terraform.lock.hcl
    }
  }

  # Remote state with native locking. Bucket/prefix per environment:
  #   terraform init -backend-config=envs/<env>.gcs.tfbackend
  backend "gcs" {}
}
