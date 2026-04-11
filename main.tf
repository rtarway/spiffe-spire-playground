terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.0" }
    helm       = { source = "hashicorp/helm", version = "~> 2.0" }
  }
}

# Point directly to Rancher Desktop's local kubeconfig
provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "rancher-desktop"
}

provider "helm" {
  kubernetes {
    config_path    = "~/.kube/config"
    config_context = "rancher-desktop"
  }
}

resource "kubernetes_namespace" "cloud_tier" {
  metadata { name = "megamart-cloud-tier" }
}

resource "kubernetes_namespace" "store_edge" {
  metadata {
    name = "megamart-store-edge"
    labels = {
      "istio-injection" = "enabled"
    }
  }
}

resource "kubernetes_namespace" "store_apps" {
  metadata {
    name = "megamart-store-apps"
    labels = {
      "istio-injection" = "enabled"
    }
  }
}

resource "helm_release" "spire_crds" {
  name       = "spire-crds"
  repository = "https://spiffe.github.io/helm-charts-hardened"
  chart      = "spire-crds"
  namespace  = kubernetes_namespace.cloud_tier.metadata[0].name
}

resource "helm_release" "spire_cloud" {
  depends_on = [helm_release.spire_crds]
  name       = "spire-cloud"
  repository = "https://spiffe.github.io/helm-charts-hardened"
  chart      = "spire"
  namespace  = kubernetes_namespace.cloud_tier.metadata[0].name

  set {
    name  = "global.spire.trustDomain"
    value = "megamart.com"
  }
  set {
    # Obscured custom port for ultra secure setup
    name  = "spire-server.service.port"
    value = "8443"
  }
  set {
    # DE Tip: Use PSAT for secure local node attestation
    name  = "spire-server.nodeAttestor.k8sPSAT.enabled"
    value = "true"
  }
  set {
    name  = "spire-agent.nodeAttestor.k8sPSAT.enabled"
    value = "true"
  }
  set {
    # Enable the OIDC Provider so Keycloak can fetch your keys
    name  = "spiffe-oidc-discovery-provider.enabled"
    value = "true"
  }
  set {
    name  = "spiffe-oidc-discovery-provider.config.acme.tosAccepted"
    value = "true"
  }
  set {
    name  = "spire-agent.server.port"
    value = "8443"
  }
  set {
    name  = "spire-server.controllerManager.validatingWebhookConfiguration.upgradeHook.image.registry"
    value = "docker.io"
  }
  set {
    name  = "spire-server.controllerManager.validatingWebhookConfiguration.upgradeHook.image.repository"
    value = "bitnami/kubectl"
  }
}

resource "helm_release" "spire_edge" {
  depends_on = [helm_release.spire_crds, helm_release.spire_cloud]
  name       = "spire-edge"
  repository = "https://spiffe.github.io/helm-charts-hardened"
  chart      = "spire"
  namespace  = kubernetes_namespace.store_edge.metadata[0].name

  set {
    name  = "global.spire.trustDomain"
    value = "megamart.com"
  }

  set {
    name  = "spire-server.nodeAttestor.k8sPSAT.enabled"
    value = "true"
  }

  set {
    name  = "spire-agent.nodeAttestor.k8sPSAT.enabled"
    value = "true"
  }
  set {
    name  = "spire-agent.healthChecks.port"
    value = "9981"
  }
  set {
    name  = "spire-agent.socketPath"
    value = "/run/spire/edge-sockets/spire-agent.sock"
  }
  
  # Ensure the socket is world-readable so non-root Istiod can talk to it
  set {
    name  = "spire-agent.config.WorkloadAPI.socket_allow_all"
    value = "true"
  }

  set {
    name  = "spire-server.upstreamAuthority.spire.enabled"
    value = "true"
  }
  set {
    name  = "spire-server.upstreamAuthority.spire.serverAddr"
    value = "spire-cloud-server.megamart-cloud-tier.svc.cluster.local"
  }
  set {
    name  = "spire-server.upstreamAuthority.spire.serverPort"
    value = "8443"
  }
  set {
    name  = "spiffe-oidc-discovery-provider.enabled"
    value = "true"
  }
  set {
    name  = "spiffe-oidc-discovery-provider.config.acme.tosAccepted"
    value = "true"
  }
  set {
    name  = "spiffe-csi-driver.enabled"
    value = "false"
  }
  set {
    name  = "spire-server.controllerManager.validatingWebhookConfiguration.upgradeHook.image.registry"
    value = "docker.io"
  }
  set {
    name  = "spire-server.controllerManager.validatingWebhookConfiguration.upgradeHook.image.repository"
    value = "bitnami/kubectl"
  }

  # AUTOMATION: Automatically push trust bundle to local namespace (for Agent)
  set {
    name  = "spire-server.notifier.k8sbundle.namespace"
    value = kubernetes_namespace.store_edge.metadata[0].name
  }
}

# --- AUTOMATION: SPIRE Workload Registrations ---
resource "null_resource" "spire_workload_registrations" {
  triggers = {
    # Re-run if the service account names or namespace change
    ai_agent_sa   = kubernetes_service_account.ai_agent.metadata[0].name
    mcp_server_sa = kubernetes_service_account.mcp_server.metadata[0].name
    namespace     = kubernetes_namespace.store_apps.metadata[0].name
  }

  depends_on = [helm_release.spire_edge, kubernetes_deployment.ai_agent, kubernetes_deployment.mcp_server]

  provisioner "local-exec" {
    command = <<EOT
      echo "Creating SPIRE registration entries for apps..."
      KUBECTL=/Users/rtarway/.rd/bin/kubectl
      
      # 1. Fetch the Agent's SPIFFE ID (needed as parentID)
      # We assume the agent pod is up and its ID is discoverable
      AGENT_ID=$($KUBECTL exec -n ${kubernetes_namespace.store_edge.metadata[0].name} spire-edge-server-0 -c spire-server -- /opt/spire/bin/spire-server agent list | grep "SPIFFE ID" | awk '{print $4}')
      
      if [ -z "$AGENT_ID" ]; then
        echo "Could not find SPIRE Agent ID. Retrying in 10s..."
        sleep 10
        AGENT_ID=$($KUBECTL exec -n ${kubernetes_namespace.store_edge.metadata[0].name} spire-edge-server-0 -c spire-server -- /opt/spire/bin/spire-server agent list | grep "spiffe://" | cut -d' ' -f2 | head -n 1)
      fi

      echo "Using Parent ID: $AGENT_ID"

      # 2. Create AI Agent Entry
      $KUBECTL exec -n ${kubernetes_namespace.store_edge.metadata[0].name} spire-edge-server-0 -c spire-server -- \
        /opt/spire/bin/spire-server entry create \
        -parentID "$AGENT_ID" \
        -spiffeID "spiffe://megamart.com/ns/${kubernetes_namespace.store_apps.metadata[0].name}/sa/${kubernetes_service_account.ai_agent.metadata[0].name}" \
        -selector "k8s:ns:${kubernetes_namespace.store_apps.metadata[0].name}" \
        -selector "k8s:sa:${kubernetes_service_account.ai_agent.metadata[0].name}"

      # 3. Create MCP Server Entry
      $KUBECTL exec -n ${kubernetes_namespace.store_edge.metadata[0].name} spire-edge-server-0 -c spire-server -- \
        /opt/spire/bin/spire-server entry create \
        -parentID "$AGENT_ID" \
        -spiffeID "spiffe://megamart.com/ns/${kubernetes_namespace.store_apps.metadata[0].name}/sa/${kubernetes_service_account.mcp_server.metadata[0].name}" \
        -selector "k8s:ns:${kubernetes_namespace.store_apps.metadata[0].name}" \
        -selector "k8s:sa:${kubernetes_service_account.mcp_server.metadata[0].name}"
    EOT
  }
}

# --- AUTOMATION: Bundle Reflector ---
# We mirror the bundle to istio-system so Istio can bootstrap its webhooks.
# This 'Reflector' ensures the bundle exists in BOTH namespaces.
resource "null_resource" "spire_bundle_reflector" {
  # Force re-run if the command logic changes
  triggers = {
    command_hash = sha256("mirror-spire-bundle-v4-yaml")
  }

  depends_on = [helm_release.spire_edge, helm_release.istiod]

  provisioner "local-exec" {
    command = <<EOT
      # Wait for the bundle to be created by the SPIRE server
      echo "Waiting for SPIRE bundle in megamart-store-edge..."
      for i in {1..20}; do
        # Robustly extract the bundle using go-template
        CONTENT=$(kubectl get configmap spire-bundle -n ${kubernetes_namespace.store_edge.metadata[0].name} -o go-template='{{index .data "bundle.crt"}}')
        
        if [ ! -z "$CONTENT" ]; then
          echo "Bundle found! Reflecting to istio-system using YAML heredoc..."
          # Use a heredoc with seds for indentation to preserve PEM formatting perfectly
          cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: istio-ca-root-cert
  namespace: istio-system
data:
  root-cert.crt: |
$(echo "$CONTENT" | sed 's/^/    /')
EOF
          exit 0
        fi
        sleep 5
      done
      echo "Timed out waiting for spire-bundle"
      exit 1
    EOT
  }
}

# --- STEP 4: OPA "LLM FIREWALL" AUTOMATION ---
# We deploy OPA within the Edge namespace to protect the cluster
resource "kubernetes_config_map" "opa_policy" {
  metadata {
    name      = "opa-policy"
    namespace = kubernetes_namespace.store_edge.metadata[0].name
  }
  data = {
    "policy.rego" = <<-REGO
    package authz.allow.mcp
    
    import future.keywords.if
    import future.keywords.in
    
    import input.attributes.request.http.headers
    
    default messages = false
    
    # 1. Main entry point (Aligned with Istio's pathPrefix + request path)
    messages if {
        validate_spiffe_id
        validate_jwt
    }

    # 2. Extract and Validate SPIFFE ID from x-forwarded-client-cert
    validate_spiffe_id if {
        xfcc := headers["x-forwarded-client-cert"]
        contains(xfcc, "URI=spiffe://megamart.com/ns/megamart-store-edge/sa/ai-agent")
    }

    # 3. Decode and validate the Token Claims
    validate_jwt if {
        # Safety Guard: Ensure bearer_token is actually defined before decoding
        # This prevents OPA from crashing (Status 500) on missing tokens.
        bearer_token
        
        [_, payload, _] := io.jwt.decode(bearer_token)
        
        # Check for strictly down-scoped role
        roles := payload.realm_access.roles
        "mcp-executor" in roles
        
        # Guardrail: Explicitly DENY if broad human role is present
        not contains_role(roles, "store-associate")
    }

    # Helper: Extract Bearer Token
    bearer_token = t if {
        v := headers.authorization
        startswith(v, "Bearer ")
        t := substring(v, count("Bearer "), -1)
    }

    # Helper: Check if item is in array
    contains_role(roles, role) if {
        roles[_] == role
    }
    REGO
  }
}

# Using a generic kubernetes_manifest for the OPA deployment 
# to stay consistent with the provided opa-deployment.yaml
resource "kubernetes_deployment" "opa" {
  metadata {
    name      = "opa"
    namespace = kubernetes_namespace.store_edge.metadata[0].name
    labels = {
      app = "opa"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "opa"
      }
    }
    template {
      metadata {
        labels = {
          app = "opa"
        }
      }
      spec {
        container {
          name  = "opa"
          image = "openpolicyagent/opa:latest"
          args  = ["run", "--server", "--addr=0.0.0.0:9191", "--log-level=debug", "--log-format=json", "/policy/policy.rego"]
          port {
            name           = "http"
            container_port = 9191
          }
          volume_mount {
            name       = "opa-policy"
            mount_path = "/policy"
            read_only  = true
          }
        }
        volume {
          name = "opa-policy"
          config_map {
            name = kubernetes_config_map.opa_policy.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "opa" {
  metadata {
    name      = "opa"
    namespace = kubernetes_namespace.store_edge.metadata[0].name
  }
  spec {
    selector = {
      app = "opa"
    }
    port {
      name        = "http"
      port        = 9191
      target_port = 9191
    }
  }
}

resource "helm_release" "keycloak" {
  name       = "keycloak"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "keycloak"
  version    = "21.4.2"
  namespace  = kubernetes_namespace.store_edge.metadata[0].name

  set {
    name  = "image.registry"
    value = "docker.io"
  }
  set {
    name  = "image.repository"
    value = "bitnamilegacy/keycloak"
  }
  set {
    name  = "postgresql.image.registry"
    value = "docker.io"
  }
  set {
    name  = "postgresql.image.repository"
    value = "bitnamilegacy/postgresql"
  }
  set {
    name  = "auth.adminUser"
    value = "admin"
  }
  set {
    name  = "auth.adminPassword"
    value = "admin"
  }
  set {
    name  = "service.type"
    value = "NodePort"
  }
  set {
    name  = "service.nodePorts.http"
    value = "30080"
  }
  set {
    name  = "extraEnvVars[0].name"
    value = "KC_FEATURES"
  }
  set {
    name  = "extraEnvVars[0].value"
    value = "token-exchange\\,admin-fine-grained-authz"
  }
}

# --- STEP 5: APPLICATION LAYER (SECURED BY ISTIO-SPIRE) ---
# These deployments are automatically injected with Istio sidecars and SPIRE identities.

resource "kubernetes_service_account" "ai_agent" {
  metadata {
    name      = "ai-agent"
    namespace = kubernetes_namespace.store_apps.metadata[0].name
  }
}

resource "kubernetes_deployment" "ai_agent" {
  metadata {
    name      = "ai-agent"
    namespace = kubernetes_namespace.store_apps.metadata[0].name
    labels    = { app = "ai-agent" }
  }
  spec {
    replicas = 1
    selector { match_labels = { app = "ai-agent" } }
    template {
      metadata { labels = { app = "ai-agent" } }
      spec {
        service_account_name = kubernetes_service_account.ai_agent.metadata[0].name
        container {
          name  = "ai-agent"
          image = "ai-agent-backend:latest"
          image_pull_policy = "Never"
          port { container_port = 8000 }
          env {
            name  = "SPIFFE_ENDPOINT_SOCKET"
            value = "unix:///run/spire/sockets/spire-agent.sock"
          }
          volume_mount {
            name       = "spire-agent-socket"
            mount_path = "/run/spire/sockets"
            read_only  = true
          }
        }
        volume {
          name = "spire-agent-socket"
          host_path {
            path = "/run/spire/edge-sockets"
            type = "Directory"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "ai_agent" {
  metadata {
    name      = "ai-agent"
    namespace = kubernetes_namespace.store_apps.metadata[0].name
  }
  spec {
    type = "NodePort"
    selector = { app = "ai-agent" }
    port {
      port        = 8000
      target_port = 8000
      node_port   = 30001
    }
  }
}

resource "kubernetes_service_account" "mcp_server" {
  metadata {
    name      = "mcp-server"
    namespace = kubernetes_namespace.store_apps.metadata[0].name
  }
}

resource "kubernetes_deployment" "mcp_server" {
  metadata {
    name      = "mcp-server"
    namespace = kubernetes_namespace.store_apps.metadata[0].name
    labels    = { app = "mcp-server" }
  }
  spec {
    replicas = 1
    selector { match_labels = { app = "mcp-server" } }
    template {
      metadata { labels = { app = "mcp-server" } }
      spec {
        service_account_name = kubernetes_service_account.mcp_server.metadata[0].name
        container {
          name  = "mcp-server"
          image = "mcp-server:latest"
          image_pull_policy = "Never"
          env {
            name  = "KEYCLOAK_URL"
            value = "http://keycloak.megamart-store-edge.svc.cluster.local:80/realms/megamart-edge"
          }
          env {
            name  = "SPIFFE_ENDPOINT_SOCKET"
            value = "unix:///run/spire/sockets/spire-agent.sock"
          }
          port { container_port = 8001 }
          volume_mount {
            name       = "spire-agent-socket"
            mount_path = "/run/spire/sockets"
            read_only  = true
          }
        }
        volume {
          name = "spire-agent-socket"
          host_path {
            path = "/run/spire/edge-sockets"
            type = "Directory"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "mcp_server" {
  metadata {
    name      = "mcp-server"
    namespace = kubernetes_namespace.store_apps.metadata[0].name
  }
  spec {
    selector = { app = "mcp-server" }
    port {
      port        = 8001
      target_port = 8001
    }
  }
}

resource "kubernetes_deployment" "webapp_frontend" {
  metadata {
    name      = "webapp-frontend"
    namespace = kubernetes_namespace.store_apps.metadata[0].name
    labels    = { app = "webapp-frontend" }
  }
  spec {
    replicas = 1
    selector { match_labels = { app = "webapp-frontend" } }
    template {
      metadata { labels = { app = "webapp-frontend" } }
      spec {
        container {
          name  = "webapp-frontend"
          image = "webapp-frontend:latest"
          image_pull_policy = "Never"
          port { container_port = 3000 }
        }
      }
    }
  }
}

resource "kubernetes_service" "webapp_frontend" {
  metadata {
    name      = "webapp-frontend"
    namespace = kubernetes_namespace.store_apps.metadata[0].name
  }
  spec {
    type = "NodePort"
    selector = { app = "webapp-frontend" }
    port {
      port        = 80
      target_port = 3000
      node_port   = 30000
    }
  }
}

# --- STEP 6: MESH HARDENING (CONTEXT-AWARE ZERO TRUST) ---

# 1. Allow both SVID and Plain-Text for Keycloak namespace (to support Browser login)
resource "kubernetes_manifest" "keycloak_peer_auth" {
  manifest = {
    apiVersion = "security.istio.io/v1beta1"
    kind       = "PeerAuthentication"
    metadata = {
      name      = "keycloak-permissive"
      namespace = kubernetes_namespace.store_edge.metadata[0].name
    }
    spec = {
      mtls = {
        mode = "PERMISSIVE"
      }
    }
  }
}

# 2. Enforce High-Clearance Identity for Token Exchange
resource "kubernetes_manifest" "keycloak_authz" {
  manifest = {
    apiVersion = "security.istio.io/v1beta1"
    kind       = "AuthorizationPolicy"
    metadata = {
      name      = "keycloak-split-path"
      namespace = kubernetes_namespace.store_edge.metadata[0].name
    }
    spec = {
      selector = {
        matchLabels = {
          app = "keycloak"
        }
      }
      # RULE 1: Allow Human Login (No SVID required for browser redirects)
      rules = [
        {
          to = [{
            operation = {
              paths = [
                "/auth*",
                "/realms/*/protocol/openid-connect/auth*"
              ]
            }
          }]
        },
        # RULE 2: STRICT Identity for Token Exchange (SVID Required)
        {
          from = [{
            source = {
              # Require the AI Agent's unique SPIFFE ID
              principals = ["spiffe://megamart.com/ns/${kubernetes_namespace.store_apps.metadata[0].name}/sa/${kubernetes_service_account.ai_agent.metadata[0].name}"]
            }
          }]
          to = [{
            operation = {
              paths = [
                "/realms/*/protocol/openid-connect/token*"
              ]
            }
          }]
        }
      ]
    }
  }
}
