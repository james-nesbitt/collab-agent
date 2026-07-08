# APIs
resource "google_project_service" "container" {
  service            = "container.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "secretmanager" {
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

# GKE Cluster
resource "google_container_cluster" "omp" {
  name     = var.cluster_name
  location = var.zone

  remove_default_node_pool = true
  initial_node_count       = 1

  workload_identity_config {
    workload_pool = "${var.project}.svc.id.goog"
  }

  authenticator_groups_config {
    security_group = "gke-security-groups@${var.group_domain}"
  }

  release_channel {
    channel = "REGULAR"
  }

  depends_on = [google_project_service.container]
}

resource "google_container_node_pool" "default" {
  name     = "default"
  cluster  = google_container_cluster.omp.name
  location = var.zone

  node_count = var.node_count

  node_config {
    machine_type = var.node_machine_type
    image_type   = "UBUNTU_CONTAINERD"

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

# Service Accounts
resource "google_service_account" "eso" {
  account_id   = "omp-eso"
  display_name = "omp-eso"
  description  = "ESO: reads GSM secret values for session namespaces"
}

resource "google_service_account" "operator" {
  account_id   = "omp-operator"
  display_name = "omp-operator"
  description  = "Session operator: lists GSM secret metadata"
}

# Operator: secretmanager.viewer (metadata only; never reads values)
resource "google_project_iam_member" "operator_gsm_viewer" {
  project = var.project
  role    = "roles/secretmanager.viewer"
  member  = "serviceAccount:${google_service_account.operator.email}"
}

# Admin account: cluster admin
resource "google_project_iam_member" "admin_cluster_admin" {
  project = var.project
  role    = "roles/container.clusterAdmin"
  member  = "user:${var.admin_gcp_account}"
}

# WI binding: ESO K8s SA → GCP SA
resource "google_service_account_iam_member" "eso_wi" {
  service_account_id = google_service_account.eso.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project}.svc.id.goog[external-secrets/external-secrets]"
}

# WI binding: operator K8s SA → GCP SA
resource "google_service_account_iam_member" "operator_wi" {
  service_account_id = google_service_account.operator.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project}.svc.id.goog[omp-system/omp-operator]"
}
