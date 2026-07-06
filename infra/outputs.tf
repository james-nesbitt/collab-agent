output "cluster_endpoint" {
  value       = google_container_cluster.omp.endpoint
  description = "GKE cluster API endpoint"
  sensitive   = true
}

output "kubeconfig_command" {
  value       = "gcloud container clusters get-credentials ${var.cluster_name} --zone ${var.zone} --project ${var.project}"
  description = "Command to configure kubectl"
}

output "eso_service_account" {
  value       = google_service_account.eso.email
  description = "ESO GCP service account email (set as OMP_ESO_SA for ompctl)"
}

output "operator_service_account" {
  value       = google_service_account.operator.email
  description = "Operator GCP service account email"
}
