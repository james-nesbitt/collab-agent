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
  description = "Initial node count for the default node pool at creation; the autoscaler then adjusts within min/max"
  default     = 3
}

variable "min_node_count" {
  type        = number
  description = "Minimum nodes the autoscaler will scale the default node pool down to"
  default     = 1
}

variable "max_node_count" {
  type        = number
  description = "Maximum nodes the autoscaler will scale the default node pool up to"
  default     = 6
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

variable "operator_registry" {
  type        = string
  description = "Container registry base path for the omp-operator image. Empty falls back to var.registry. Set to the Artifact Registry path when running a locally-built operator."
  default     = ""
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

variable "self_relay_enabled" {
  type        = bool
  description = "Deploy the self-hosted collab relay (Deployment + Service + PVC) behind the reserved static IP"
  default     = false
}

variable "self_relay_email" {
  type        = string
  description = "Let's Encrypt account/expiry-notice email for the self-hosted relay's certificate; required when self_relay_enabled is true"
  default     = ""
}
