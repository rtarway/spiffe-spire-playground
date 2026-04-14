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
  depends_on = [helm_release.istio_base, null_resource.spire_trust_bundle_sync]

  values = [<<-YAML
    global:
      hub: "docker.io/istio"
      trustDomain: "megamart.com"
      meshID: "megamart.com"
      # Istio templates also inject `PILOT_CERT_PROVIDER` from this value for gateways/proxies.
      # If this stays at the default ("istiod"), but you intended SPIRE for the data plane only,
      # you can end up with duplicate/conflicting env vars unless this matches your intended provider.
      #
      # For this playground, keep the Istio control plane + webhook serving certs on the built-in
      # Istio CA (from `istio-ca-secret`), while data-plane identity still comes from SPIRE via
      # `meshConfig.defaultConfig.proxyMetadata.SPIFFE_ENDPOINT_SOCKET` below.
      pilotCertProvider: "istiod"
      multiCluster:
        clusterName: "megamart-cluster"

    pilot:
      volumeMounts:
        - name: spire-agent-socket
          mountPath: /run/spire/sockets
          readOnly: true
      volumes:
        - name: spire-agent-socket
          hostPath:
            path: /run/spire/agent-sockets
            type: Directory

    meshConfig:
      trustDomain: "megamart.com"
      defaultConfig:
        proxyMetadata:
          # Tell every istio-agent to use the SPIRE Workload API for its cert.
          SPIFFE_ENDPOINT_SOCKET: "unix:///run/spire/sockets/spire-agent.sock"
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
      defaultTemplates: ["sidecar", "spire"]
      templates:
        spire: |
          spec:
            containers:
              - name: istio-proxy
                volumeMounts:
                  - name: spire-agent-socket
                    mountPath: /run/spire/sockets
                    readOnly: false
            volumes:
              - name: spire-agent-socket
                hostPath:
                  path: /run/spire/agent-sockets
                  type: Directory
  YAML
  ]
}

# --- GLOBAL ZERO TRUST POLICY ---
# Enforce STRICT mTLS across the entire trust domain using SPIFFE identities.
resource "kubernetes_manifest" "global_mtls" {
  manifest = {
    apiVersion = "security.istio.io/v1beta1"
    kind       = "PeerAuthentication"
    metadata = {
      name      = "default"
      namespace = "istio-system"
    }
    spec = {
      mtls = {
        mode = "STRICT"
      }
    }
  }
}

# Namespaces and injection labels are managed in main.tf

# Note: istiod registration should be handled by the Registrar or a separate out-of-band process if the provider is unavailable.
