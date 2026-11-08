# Shared candidate sandbox: unique names, and the applying identity has
# roles/editor only (no IAM writes) -> nodes use the default compute SA.
# master_authorized_networks is passed at apply time (operator IPs are not committed).
project_id           = "candidate-7sol-test"
name_suffix          = "-tn"
manage_iam           = false
node_service_account = "835903147987-compute@developer.gserviceaccount.com"
