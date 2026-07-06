resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  wait             = true

  set {
    name  = "installCRDs"
    value = "true"
  }

  set {
    name  = "serviceAccount.annotations.iam\\.gke\\.io/gcp-service-account"
    value = google_service_account.eso.email
  }

  depends_on = [google_container_node_pool.default]
}

resource "helm_release" "omp_platform" {
  name             = "omp-platform"
  chart            = "../charts/omp-platform"
  namespace        = "omp-system"
  create_namespace = true
  wait             = true

  values = [yamlencode({
    project          = var.project
    zone             = var.zone
    clusterName      = var.cluster_name
    adminAccount     = var.admin_gcp_account
    groupDomain      = var.group_domain
    registry         = var.registry
    sessionImageTag  = var.session_image_tag
    operatorImageTag = var.operator_image_tag
    relay            = var.relay
    esoServiceAccount      = google_service_account.eso.email
    operatorServiceAccount = google_service_account.operator.email
    config = {
      memory   = var.omp_config_memory
      thinking = var.omp_config_thinking
    }
    teams = var.teams
  })]

  depends_on = [helm_release.external_secrets]
}
