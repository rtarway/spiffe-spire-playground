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

# --- ISTIOD: SPIRE as Unified Identity Authority ---
# trustDomain is set to megamart.com to match SPIRE.
# proxyMetadata.SPIFFE_ENDPOINT_SOCKET tells every istio-agent to fetch its
# X.509 cert from the SPIRE Workload API socket instead of Citadel.
# The "spire" injection template is applied cluster-wide via
# defaultTemplatesOverride, mounting the SPIRE socket into every istio-proxy.
resource "helm_release" "istiod" {
  name       = "istiod"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  namespace  = kubernetes_namespace.istio_system.metadata[0].name
  depends_on = [helm_release.istio_base]

  values = [<<-YAML
    global:
      hub: "docker.io/istio"
      trustDomain: "megamart.com"
      meshID: "megamart.com"
      multiCluster:
        clusterName: "demo-cluster"

    meshConfig:
      trustDomain: "megamart.com"
      defaultConfig:
        proxyMetadata:
          # Tell every istio-agent to use the SPIRE Workload API for its cert.
          # This path is mounted into every proxy by the "spire" template below.
          SPIFFE_ENDPOINT_SOCKET: "unix:///run/spire/agent-sockets/spire-agent.sock"
      extensionProviders:
        - name: "opa-ext-authz"
          envoyExtAuthzHttp:
            service: "127.0.0.1"
            port: 9191
            pathPrefix: "/v1/data/authz/allow"
            includeRequestHeadersInCheck:
              - "x-forwarded-client-cert"
              - "authorization"

    sidecarInjectorWebhook:
      # Apply "sidecar" + "spire" templates to every injected pod.
      # This means ALL workloads in labelled namespaces automatically get
      # the SPIRE socket mounted — no per-pod annotation required.
      defaultTemplatesOverride: "sidecar,spire"
      templates:
        spire: |
          spec:
            containers:
              - name: istio-proxy
                volumeMounts:
                  - name: spire-agent-socket
                    mountPath: /run/spire/agent-sockets
                    readOnly: false
            volumes:
              - name: spire-agent-socket
                hostPath:
                  path: /run/spire/agent-sockets
                  type: Directory
  YAML
  ]
}

# Namespaces and injection labels are managed in main.tf
