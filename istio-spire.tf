resource "kubernetes_namespace" "istio_system" {
  metadata {
    name = "istio-system"
  }
}

resource "helm_release" "istio_base" {
  name       = "istio-base"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "base"
  namespace  = kubernetes_namespace.istio_system.metadata[0].name
}

resource "helm_release" "istiod" {
  name       = "istiod"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  namespace  = kubernetes_namespace.istio_system.metadata[0].name
  depends_on = [helm_release.istio_base]

  values = [
    yamlencode({
      global = {
        hub      = "docker.io/istio"
        meshID   = "megamart.com"
        multiCluster = {
          clusterName = "demo-cluster"
        }
      }
      meshConfig = {
        extensionProviders = [
          {
            name = "opa-ext-authz"
            envoyExtAuthzHttp = {
              service                     = "opa.megamart-store-edge.svc.cluster.local"
              port                        = 9191
              pathPrefix                  = "/v1/data/authz/allow"
              includeRequestHeadersInCheck = ["x-forwarded-client-cert", "authorization"]
            }
          }
        ]
      }
    })
  ]
}

# Namespaces and injection labels are now managed exclusively in main.tf
