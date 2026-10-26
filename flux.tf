################################################################################
# 1. Flux Operator
#
# The Flux Operator is the Flux project's recommended way to install and
# manage Flux. Installing it via Helm also installs the FluxInstance CRD.
################################################################################

resource "helm_release" "flux_operator" {
  name             = "flux-operator"
  namespace        = "flux-system"
  create_namespace = true

  repository = "oci://ghcr.io/controlplaneio-fluxcd/charts"
  chart      = "flux-operator"
  version    = var.flux_operator_version

  # First release on a fresh Auto Mode cluster waits for a node to be provisioned
  timeout = 900

  depends_on = [module.eks]
}

################################################################################
# 2. Flux controllers (FluxInstance)
#
# The healthcheck hook blocks until the FluxInstance reports Ready, so the
# Flux CRDs (HelmRepository, HelmRelease, ...) exist before step 4.
################################################################################

resource "helm_release" "flux_instance" {
  name      = "flux"
  namespace = "flux-system"

  repository = "oci://ghcr.io/controlplaneio-fluxcd/charts"
  chart      = "flux-instance"
  version    = var.flux_operator_version

  timeout = 900

  values = [yamlencode({
    instance = {
      distribution = {
        version  = var.flux_version
        registry = "ghcr.io/fluxcd"
        artifact = "oci://ghcr.io/controlplaneio-fluxcd/flux-operator-manifests:v${var.flux_operator_version}"
      }
      components = [
        "source-controller",
        "kustomize-controller",
        "helm-controller",
        "notification-controller",
      ]
      cluster = {
        type          = "aws"
        networkPolicy = true
      }
    }
    healthcheck = {
      enabled = true
    }
  })]

  depends_on = [helm_release.flux_operator]
}

################################################################################
# 3. groundcover API key
#
# Stored as a Kubernetes Secret the groundcover chart reads directly
# (global.groundcoverPredefinedTokenSecret). `data_wo` is write-only, so the
# key never lands in Terraform state, the plan, or any Flux/Helm object.
################################################################################

resource "kubernetes_namespace_v1" "groundcover" {
  metadata {
    name = "groundcover"
  }

  depends_on = [module.eks]
}

resource "kubernetes_secret_v1" "groundcover_api_key" {
  metadata {
    name      = "groundcover-api-key"
    namespace = kubernetes_namespace_v1.groundcover.metadata[0].name
  }

  data_wo = {
    API_KEY = var.groundcover_api_key
  }
  data_wo_revision = var.groundcover_api_key_revision
}

################################################################################
# 4. Workloads, delivered by Flux
#
# A small local chart that renders Flux HelmRepository + HelmRelease objects.
# Flux then installs groundcover first and otel-demo only after the
# groundcover HelmRelease is Ready (HelmRelease.spec.dependsOn).
################################################################################

resource "helm_release" "flux_apps" {
  name      = "flux-apps"
  namespace = "flux-system"
  chart     = "${path.module}/charts/flux-apps"

  values = [yamlencode({
    groundcover = {
      chartVersion = var.groundcover_chart_version
      tokenSecret = {
        name = kubernetes_secret_v1.groundcover_api_key.metadata[0].name
        key  = "API_KEY"
      }
      site      = var.groundcover_byoc_endpoint
      clusterId = var.cluster_name
      env       = var.groundcover_env
    }
    otelDemo = {
      chartVersion = var.otel_demo_chart_version
      values       = yamldecode(file("${path.module}/values/otel-demo.yaml"))
    }
  })]

  depends_on = [
    helm_release.flux_instance,
    kubernetes_secret_v1.groundcover_api_key,
    kubernetes_storage_class_v1.gp3,
  ]
}
