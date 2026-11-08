variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "asia-southeast1"
}

variable "name_suffix" {
  description = "Appended to resource names so several copies can share one project."
  type        = string
  default     = ""
}

variable "master_authorized_networks" {
  description = "display_name => CIDR allowed to reach the public control-plane IP endpoint (operators, CI runners, Argo CD hub)."
  type        = map(string)

  validation {
    condition     = !contains(values(var.master_authorized_networks), "0.0.0.0/0")
    error_message = "0.0.0.0/0 is not an authorized network."
  }
}

variable "manage_iam" {
  description = "Create the node service account and its IAM bindings. Needs IAM admin; set false when the applying identity cannot write IAM."
  type        = bool
  default     = true
}

variable "node_service_account" {
  description = "Existing node service account email, used only when manage_iam = false."
  type        = string
  default     = null
}
