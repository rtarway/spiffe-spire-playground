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
    value = "/run/spire/agent-sockets/spire-agent.sock"
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
    name  = "spiffe-oidc-discovery-provider.config.workloadAPISocketPath"
    value = "/spiffe-workload-api/spire-agent.sock"
  }
  set {
    name  = "spiffe-oidc-discovery-provider.config.acme.tosAccepted"
    value = "true"
  }
  set {
    name  = "spiffe-csi-driver.enabled"
    value = "true"
  }
  set {
    name  = "spiffe-csi-driver.config.agentSocketPath"
    value = "/run/spire/agent-sockets/spire-agent.sock"
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

      # 4. Create Keycloak Provisioner Entry
      $KUBECTL exec -n ${kubernetes_namespace.store_edge.metadata[0].name} spire-edge-server-0 -c spire-server -- \
        /opt/spire/bin/spire-server entry create \
        -parentID "$AGENT_ID" \
        -spiffeID "spiffe://megamart.com/ns/${kubernetes_namespace.store_edge.metadata[0].name}/sa/${kubernetes_service_account.keycloak_provisioner.metadata[0].name}" \
        -selector "k8s:ns:${kubernetes_namespace.store_edge.metadata[0].name}" \
        -selector "k8s:sa:${kubernetes_service_account.keycloak_provisioner.metadata[0].name}"

      # 5. Create Keycloak Server Entry (so its istio-proxy can get an SVID)
      $KUBECTL exec -n ${kubernetes_namespace.store_edge.metadata[0].name} spire-edge-server-0 -c spire-server -- \
        /opt/spire/bin/spire-server entry create \
        -parentID "$AGENT_ID" \
        -spiffeID "spiffe://megamart.com/ns/${kubernetes_namespace.store_edge.metadata[0].name}/sa/keycloak" \
        -selector "k8s:ns:${kubernetes_namespace.store_edge.metadata[0].name}" \
        -selector "k8s:sa:keycloak"

      # 6. Create WebApp Frontend Entry (uses default SA)
      $KUBECTL exec -n ${kubernetes_namespace.store_edge.metadata[0].name} spire-edge-server-0 -c spire-server -- \
        /opt/spire/bin/spire-server entry create \
        -parentID "$AGENT_ID" \
        -spiffeID "spiffe://megamart.com/ns/${kubernetes_namespace.store_apps.metadata[0].name}/sa/default" \
        -selector "k8s:ns:${kubernetes_namespace.store_apps.metadata[0].name}" \
        -selector "k8s:sa:default"
    EOT
  }
}

# NOTE: The spire_bundle_reflector workaround is removed.
# With SPIRE as Istio's unified CA (SPIFFE_ENDPOINT_SOCKET), the istio-agent
# fetches the trust bundle directly from the SPIRE Workload API.
# No manual ConfigMap mirroring is required.


# --- STEP 4: OPA "SOVEREIGN FIREWALL" (DECENTRALIZED) ---
# Each pod handles its own decisions locally, syncing policies from GitHub.

resource "kubernetes_config_map" "opa_config" {
  metadata {
    name      = "opa-config"
    namespace = kubernetes_namespace.store_apps.metadata[0].name
  }
  data = {
    "config.yaml" = <<-YAML
    services:
      github:
        url: https://github.com
    bundles:
      authz:
        service: github
        resource: rtarway/spiffe-spire-playground/archive/refs/heads/main.tar.gz
        polling:
          min_delay_seconds: 10
          max_delay_seconds: 20
    YAML
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
    value = "megamart_secure_admin_pass"
  }
  set {
    name  = "postgresql.auth.password"
    value = "megamart_secure_db_pass"
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

# --- STEP 4.5: IDENTITY PROVISIONING JOB ---
resource "kubernetes_service_account" "keycloak_provisioner" {
  metadata {
    name      = "keycloak-provisioner"
    namespace = kubernetes_namespace.store_edge.metadata[0].name
  }
}

resource "kubernetes_job" "keycloak_provisioning" {
  metadata {
    name      = "keycloak-provisioning"
    namespace = kubernetes_namespace.store_edge.metadata[0].name
  }
  spec {
    template {
      metadata {
        name = "keycloak-provisioning"
      }
      spec {
        container {
          name  = "keycloak-provisioning"
          image = "bitnamilegacy/keycloak:latest"
          command = ["/bin/bash", "-c"]
          args    = [<<-EOT
            echo "Waiting for Keycloak OIDC Discovery (HTTP 200)..."
            until [ "$(curl -s -o /dev/null -w "%%{http_code}" http://keycloak/realms/master/.well-known/openid-configuration)" == "200" ]; do 
              echo "Keycloak OIDC not ready yet... retrying in 5s"
              sleep 5
            done
            
            KCADM=/opt/bitnami/keycloak/bin/kcadm.sh
            
            echo "Attempting to authenticate..."
            MAX_RETRIES=30
            COUNT=0
            # Anchor --config at the END of the command
            until $KCADM config credentials --server http://keycloak --realm master --user admin --password megamart_secure_admin_pass --config /tmp/kcadm.config || [ $COUNT -eq $MAX_RETRIES ]; do
              echo "Auth failed, retrying in 5s... ($COUNT/$MAX_RETRIES)"
              COUNT=$((COUNT + 1))
              sleep 5
            done
            
            if [ $COUNT -eq $MAX_RETRIES ]; then
              echo "FAILED: Could not authenticate to Keycloak after $MAX_RETRIES attempts."
              exit 1
            fi
            
            echo "Creating Megamart-Edge Realm..."
            $KCADM create realms -s realm=megamart-edge -s enabled=true --config /tmp/kcadm.config || echo "Realm might already exist"
            
            echo "Creating WebApp Client..."
            $KCADM create clients -r megamart-edge -s clientId=webapp-client -s enabled=true -s publicClient=true \
              -s 'redirectUris=["http://localhost:30000/*"]' \
              -s 'webOrigins=["http://localhost:30000"]' \
              -s directAccessGrantsEnabled=true --config /tmp/kcadm.config || echo "Client might already exist"
            
            echo "Creating Associate User..."
            $KCADM create users -r megamart-edge -s username=associate -s enabled=true --config /tmp/kcadm.config || echo "User might already exist"
            $KCADM set-password -r megamart-edge --username associate --new-password associate --config /tmp/kcadm.config
            
            echo "Provisioning Complete!"
          EOT
          ]
        }
        restart_policy = "OnFailure"
      }
    }
  }
}

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
        
        # OPA SIDECAR (Local Decision Engine)
        container {
          name  = "opa"
          image = "openpolicyagent/opa:latest"
          args  = ["run", "--server", "--config-file=/config/config.yaml", "--log-level=debug"]
          port { container_port = 9191 }
          volume_mount {
            name       = "opa-config"
            mount_path = "/config"
            read_only  = true
          }
        }

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
        volume {
          name = "opa-config"
          config_map {
            name = kubernetes_config_map.opa_config.metadata[0].name
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
        
        # OPA SIDECAR (Local Decision Engine)
        container {
          name  = "opa"
          image = "openpolicyagent/opa:latest"
          args  = ["run", "--server", "--config-file=/config/config.yaml", "--log-level=debug"]
          port { container_port = 9191 }
          volume_mount {
            name       = "opa-config"
            mount_path = "/config"
            read_only  = true
          }
        }

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
        volume {
          name = "opa-config"
          config_map {
            name = kubernetes_config_map.opa_config.metadata[0].name
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

# 3. Allow Egress to GitHub for Policy Sync
resource "kubernetes_manifest" "github_egress" {
  manifest = {
    apiVersion = "networking.istio.io/v1beta1"
    kind       = "ServiceEntry"
    metadata = {
      name      = "github-raw-egress"
      namespace = kubernetes_namespace.store_apps.metadata[0].name
    }
    spec = {
      hosts    = ["raw.githubusercontent.com", "github.com", "codeload.github.com", "docker.io", "registry-1.docker.io", "production.cloudflare.docker.com"]
      location = "MESH_EXTERNAL"
      ports = [{
        number   = 443
        name     = "https"
        protocol = "TLS"
      }]
      resolution = "DNS"
    }
  }
}

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
          "app.kubernetes.io/name" = "keycloak"
        }
      }
      # RULE 1: Allow Human Login (No SVID required for browser redirects)
      rules = [
        {
          to = [{
            operation = {
              paths = [
                "/realms/*/protocol/*",
                "/realms/*/.well-known/*",
                "/resources/*"
              ]
            }
          }]
        },
        # RULE 2: STRICT Identity for SVID-based Token Exchange
        # Unified trust domain: SPIRE issues all certs as megamart.com
        # NOTE: Istio auto-prepends spiffe:// — principal must NOT include it
        {
          from = [{
            source = {
              principals = ["spiffe://megamart.com/ns/${kubernetes_namespace.store_apps.metadata[0].name}/sa/${kubernetes_service_account.ai_agent.metadata[0].name}"]
            }
          }]
          to = [{
            operation = {
              # Prefix match for token exchange
              paths = ["/realms/*/protocol/openid-connect/token*"]
            }
          }]
        },
        # RULE 3: Provisioner Identity
        {
          from = [{
            source = {
              principals = ["spiffe://megamart.com/ns/${kubernetes_namespace.store_edge.metadata[0].name}/sa/${kubernetes_service_account.keycloak_provisioner.metadata[0].name}"]
            }
          }]
          to = [{
            operation = {
              # Full access for the forging session
              paths = ["*"]
            }
          }]
        }
      ]
    }
  }
}
