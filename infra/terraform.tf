terraform {
  required_version = ">= 1.7"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
  }

  # GCS backend — bucket must exist before first apply.
  # terraform init -backend-config="bucket=<your-tf-state-bucket>"
  backend "gcs" {
    prefix = "omp/terraform"
  }
}

provider "google" {
  project = var.project
  zone    = var.zone
}

# Helm provider authenticates from the cluster resource; no kubeconfig dependency.
provider "helm" {
  kubernetes {
    host                   = "https://${google_container_cluster.omp.endpoint}"
    cluster_ca_certificate = base64decode(google_container_cluster.omp.master_auth[0].cluster_ca_certificate)
    token                  = data.google_client_config.default.access_token
  }
}

data "google_client_config" "default" {}
