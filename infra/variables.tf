variable "project" {
  type        = string
  description = "GCP project ID"
}

variable "zone" {
  type        = string
  description = "GCP zone for the cluster"
  default     = "europe-west1-b"
}

variable "region" {
  type        = string
  description = "GCP region"
  default     = "europe-west1"
}

variable "cluster_name" {
  type        = string
  description = "GKE cluster name"
  default     = "omp-cluster"
}

variable "node_machine_type" {
  type        = string
  description = "Machine type for cluster nodes"
  default     = "e2-standard-4"
}

variable "node_count" {
  type        = number
  description = "Number of nodes in the default node pool"
  default     = 3
}

variable "admin_gcp_account" {
  type        = string
  description = "Admin Google account email"
}

variable "group_domain" {
  type        = string
  description = "Domain used for GKE security group (gke-security-groups@<domain>)"
  default     = "mirantis.com"
}

variable "registry" {
  type        = string
  description = "Container registry base path for session images"
  default     = "ghcr.io/james-nesbitt/collab-agent"
}

variable "session_image_tag" {
  type        = string
  description = "Image tag for session container"
  default     = "latest"
}

variable "operator_image_tag" {
  type        = string
  description = "Image tag for the omp-operator container"
  default     = "latest"
}

variable "relay" {
  type        = string
  description = "COLLAB_RELAY URL; empty disables relay"
  default     = ""
}

variable "omp_config_memory" {
  type        = bool
  description = "Append mnemopi memory tuning to omp-config"
  default     = false
}

variable "omp_config_thinking" {
  type        = bool
  description = "Set defaultThinkingLevel: auto in omp-config"
  default     = false
}

variable "teams" {
  type        = list(string)
  description = "Team slugs to onboard (creates omp-team-<slug> namespace)"
  default     = []
}
