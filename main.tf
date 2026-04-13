terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.0" }
    helm       = { source = "hashicorp/helm", version = "~> 2.0" }
    keycloak   = { source = "mrparkers/keycloak", version = ">= 4.0.0" }
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

# The Identity Authority Provider (Assumes NodePort 30080)
# provider "keycloak" {
#   client_id = "admin-cli"
#   url       = "http://localhost:30080"
#   username  = "admin"
#   password  = "megamart_secure_admin_pass"
# }

# ==========================================
# STAGE 1: GLOBAL IDENTITY AUTHORITY (CLOUD)
# ==========================================
# Birthed once to anchor the megamart.com trust domain.

resource "kubernetes_namespace" "cloud_tier" {
  metadata {
    name = "megamart-cloud-tier"
    labels = {
      "istio-injection" = "disabled"
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
  wait       = false

  set {
    name  = "global.spire.trustDomain"
    value = "megamart.com"
  }
  set {
    name  = "global.spire.clusterName"
    value = "megamart-cluster"
  }
  set {
    name  = "spire-server.ca_subject.common_name"
    value = "megamart.com"
  }
  set {
    name  = "spire-server.ca_subject.organization"
    value = "MegaMart"
  }
  set {
    # Obscured custom port for ultra secure setup
    name  = "spire-server.service.port"
    value = "8443"
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

  values = [<<-YAML
    spire-server:
      caTTL: "336h"
      registrar:
        enabled: true
        config:
          cluster: "megamart-cluster"
      podAnnotations:
        sidecar.istio.io/inject: "false"
        traffic.sidecar.istio.io/excludeInboundPorts: "8081,8443"
    spire-agent:
      podAnnotations:
        sidecar.istio.io/inject: "false"
        traffic.sidecar.istio.io/excludeInboundPorts: "8081,8443"
  YAML
  ]
}

# ==========================================
# STAGE 2: REPEATABLE STORE EDGE (PER-STORE)
# ==========================================
# Birthed for each store as it onboards to the fleet.

resource "kubernetes_namespace" "store_edge" {
  metadata {
    name = "megamart-store-edge"
    labels = {
      "istio-injection" = "disabled"
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


# =============================================================================
# TRUST BUNDLE BRIDGE: Extract the Cloud Root CA and inject into Edge namespace
# =============================================================================
# This null_resource deterministically syncs the trust bundle from the running
# Cloud SPIRE Server into the Edge namespace. It runs AFTER the Edge Helm chart
# is installed, ensuring the Edge Agent has the correct root CA to verify the
# subordinated Edge Server's certificate chain.

resource "null_resource" "spire_trust_bundle_sync" {
  triggers = {
    # Re-run if the Edge Helm release changes
    edge_release_version = helm_release.spire_edge.metadata[0].revision
  }

  depends_on = [helm_release.spire_cloud, helm_release.spire_edge]

  provisioner "local-exec" {
    command = <<EOT
      KUBECTL=/Users/rtarway/.rd/bin/kubectl

      echo "[1/4] Waiting for Cloud SPIRE Server to be Ready..."
      $KUBECTL wait --for=condition=Ready pod/spire-cloud-server-0 \
        -n megamart-cloud-tier --timeout=120s

      echo "[2/4] Extracting Cloud Authority trust bundle..."
      $KUBECTL exec -n megamart-cloud-tier spire-cloud-server-0 \
        -c spire-server -- \
        /opt/spire/bin/spire-server bundle show -format pem > /tmp/cloud-bundle.crt

      echo "[3/4] Injecting Cloud bundle into Edge namespace as spire-bundle ConfigMap..."
      $KUBECTL create configmap spire-bundle \
        --from-file=bundle.crt=/tmp/cloud-bundle.crt \
        -n megamart-store-edge \
        --dry-run=client -o yaml | $KUBECTL apply -f -

      echo "[4/4] Restarting Edge Agent DaemonSet to pick up fresh bundle..."
      $KUBECTL rollout restart daemonset/spire-edge-agent -n megamart-store-edge
      $KUBECTL rollout status daemonset/spire-edge-agent -n megamart-store-edge --timeout=120s

      echo "Trust bundle sync complete."
    EOT
  }
}

resource "helm_release" "spire_edge" {
  depends_on = [helm_release.spire_crds, helm_release.spire_cloud]
  name       = "spire-edge"
  repository = "https://spiffe.github.io/helm-charts-hardened"
  chart      = "spire"
  namespace  = kubernetes_namespace.store_edge.metadata[0].name
  wait       = false

  set {
    name  = "global.spire.trustDomain"
    value = "megamart.com"
  }

  set {
    name  = "global.spire.clusterName"
    value = "megamart-cluster"
  }

  set {
    name  = "spire-server.ca_subject.organization"
    value = "MegaMart"
  }
  
  # NOTE: rootCas for upstream authority verification is handled by the
  # spire_trust_bundle_sync null_resource, which injects the Cloud Authority
  # bundle directly into the spire-bundle ConfigMap after Helm install.
  set {
    name  = "spiffe-oidc-discovery-provider.enabled"
    value = "false"
  }
  set {
    name  = "spiffe-csi-driver.enabled"
    value = "false"
  }
  set {
    name  = "spiffe-csi-driver.config.agentSocketPath"
    value = "/run/spire/sockets/spire-agent.sock"
  }
  set {
    name  = "spire-server.controllerManager.validatingWebhookConfiguration.upgradeHook.image.registry"
    value = "docker.io"
  }
  set {
    name  = "spire-server.controllerManager.validatingWebhookConfiguration.upgradeHook.image.repository"
    value = "bitnami/kubectl"
  }
  
  set {
    name  = "spire-agent.healthChecks.port"
    value = "9981"
  }

  # AUTOMATION: Automatically push trust bundle to local namespace (for Agent)
  set {
    name  = "spire-server.notifier.k8sbundle.namespace"
    value = kubernetes_namespace.store_edge.metadata[0].name
  }

  values = [<<-YAML
    spire-server:
      caTTL: "336h"
      upstreamAuthority:
        spire:
          enabled: true
          config:
            serverAddr: "spire-cloud-server.megamart-cloud-tier.svc.cluster.local"
            serverPort: 8443
      registrar:
        enabled: true
        config:
          cluster: "megamart-cluster"
      podAnnotations:
        sidecar.istio.io/inject: "false"
        traffic.sidecar.istio.io/excludeInboundPorts: "8081,8443"
    spire-agent:
      healthChecks:
        port: 9981
      podAnnotations:
        sidecar.istio.io/inject: "false"
        traffic.sidecar.istio.io/excludeInboundPorts: "8081,8443"
  YAML
  ]
}

resource "null_resource" "spire_edge_config_patch" {
  depends_on = [helm_release.spire_edge]

  provisioner "local-exec" {
    command = <<EOT
      KUBECTL=/Users/rtarway/.rd/bin/kubectl
      
      echo "Injecting UpstreamAuthority plugin into Edge Server ConfigMap..."
      $KUBECTL patch configmap spire-edge-server -n megamart-store-edge --type merge -p '
      data:
        server.conf: |
          server {
            bind_address = "0.0.0.0"
            bind_port = "8081"
            trust_domain = "megamart.com"
            data_dir = "/run/spire/data"
            log_level = "info"
            ca_key_type = "rsa-2048"
            ca_ttl = "336h"
            ca_subject = {
              country = ["NL"],
              organization = ["MegaMart"],
              common_name = "megamart.com",
            }
          }
          plugins {
            DataStore "sql" {
              plugin_data {
                database_type = "sqlite3"
                connection_string = "/run/spire/data/datastore.sqlite3"
              }
            }
            NodeAttestor "k8s_psat" {
              plugin_data {
                clusters = {
                  "megamart-cluster" = {
                    service_account_allow_list = ["megamart-store-edge:spire-edge-agent"]
                  }
                }
              }
            }
            KeyManager "disk" {
              plugin_data {
                keys_path = "/run/spire/data/keys.json"
              }
            }
            UpstreamAuthority "spire" {
              plugin_data {
                server_address = "spire-cloud-server.megamart-cloud-tier.svc.cluster.local"
                server_port = 8443
              }
            }
            Notifier "k8sbundle" {
              plugin_data {
                namespace = "megamart-store-edge"
              }
            }
          }
          health_checks {
            listener_enabled = true
            bind_address = "0.0.0.0"
            bind_port = "8080"
            live_path = "/live"
            ready_path = "/ready"
          }
      '
      
      echo "Patching Edge Agent DaemonSet port to 9981..."
      $KUBECTL patch daemonset spire-edge-agent -n megamart-store-edge --type json -p '[{"op": "replace", "path": "/spec/template/spec/containers/0/ports/0/containerPort", "value": 9981}]'
      
      echo "Injecting socket_allow_all into Edge Agent ConfigMap..."
      $KUBECTL patch configmap spire-edge-agent -n megamart-store-edge --type merge -p '
      data:
        agent.conf: |
          agent {
            data_dir = "/run/spire"
            log_level = "info"
            server_address = "spire-edge-server"
            server_port = "8081"
            socket_path = "/run/spire/sockets/spire-agent.sock"
            trust_bundle_path = "/run/spire/bundle/bundle.crt"
            trust_domain = "megamart.com"
          }
          plugins {
            NodeAttestor "k8s_psat" {
              plugin_data {
                cluster = "megamart-cluster"
              }
            }
            KeyManager "memory" {
              plugin_data {
              }
            }
            WorkloadAttestor "k8s" {
              plugin_data {
                skip_kubelet_verification = true
              }
            }
          }
          health_checks {
            listener_enabled = true
            bind_address = "0.0.0.0"
            bind_port = "9981"
            live_path = "/live"
            ready_path = "/ready"
          }
      '

      echo "Restarting Edge Server to apply patched config..."
      $KUBECTL rollout restart statefulset/spire-edge-server -n megamart-store-edge
      $KUBECTL rollout status statefulset/spire-edge-server -n megamart-store-edge --timeout=120s

      echo "Restarting Edge Agent to apply patched config..."
      $KUBECTL rollout restart daemonset/spire-edge-agent -n megamart-store-edge
      $KUBECTL rollout status daemonset/spire-edge-agent -n megamart-store-edge --timeout=120s
    EOT
  }
}

resource "kubernetes_service_account" "oidc_discovery" {
  metadata {
    name      = "spire-edge-oidc-discovery-provider"
    namespace = kubernetes_namespace.store_edge.metadata[0].name
  }
}


resource "kubernetes_config_map" "oidc_discovery_config" {
  metadata {
    name      = "spire-edge-oidc-discovery-config"
    namespace = kubernetes_namespace.store_edge.metadata[0].name
  }

  data = {
    "oidc-discovery-provider.conf" = <<-EOT
      log_level = "info"
      domains = ["spire-edge-spiffe-oidc-discovery-provider", "spire-edge-spiffe-oidc-discovery-provider.megamart-store-edge", "spire-edge-spiffe-oidc-discovery-provider.megamart-store-edge.svc.cluster.local", "localhost"]
      acme {
        cache_dir = "/run/spire"
        tos_accepted = true
      }
      workload_api {
        socket_path = "/run/spire/agent-sockets/spire-agent.sock"
        trust_domain = "megamart.com"
      }
      health_checks {
        bind_addr = ":8008"
      }
      serving {
        bind_addr = ":443"
      }
    EOT
  }
}

# OIDC discovery provider removed from edge per requirement.

# OIDC discovery provider removed from edge per requirement.


# NOTE: Manual SPIRE registrations are removed.
# The SPIRE Kubernetes Registrar now automatically handles workload registration.


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

#
#resource "helm_release" "keycloak" {
#  name       = "keycloak"
#  repository = "https://charts.bitnami.com/bitnami"
#  chart      = "keycloak"
#  version    = "21.4.2"
#  namespace  = kubernetes_namespace.store_edge.metadata[0].name
#
#  set {
#    name  = "image.registry"
#    value = "docker.io"
#  }
#  set {
#    name  = "image.repository"
#    value = "bitnamilegacy/keycloak"
#  }
#  set {
#    name  = "postgresql.image.registry"
#    value = "docker.io"
#  }
#  set {
#    name  = "postgresql.image.repository"
#    value = "bitnamilegacy/postgresql"
#  }
#  set {
#    name  = "auth.adminUser"
#    value = "admin"
#  }
#  set {
#    name  = "auth.adminPassword"
#    value = "megamart_secure_admin_pass"
#  }
#  set {
#    name  = "postgresql.auth.password"
#    value = "megamart_secure_db_pass"
#  }
#  set {
#    name  = "service.type"
#    value = "NodePort"
#  }
#  set {
#    name  = "service.nodePorts.http"
#    value = "30080"
#  }
#  set {
#    name  = "extraEnvVars[0].name"
#    value = "KC_FEATURES"
#  }
#  set {
#    name  = "extraEnvVars[0].value"
#    value = "token-exchange\\,admin-fine-grained-authz"
#  }
#}
#
#resource "kubernetes_service_account" "keycloak_provisioner" {
#  metadata {
#    name      = "keycloak-provisioner"
#    namespace = kubernetes_namespace.store_edge.metadata[0].name
#  }
#}
#
## --- UNIFIED IDENTITY AUTHORITY: KEYCLOAK CONFIG ---
## This section definitively anchors the Megamart identity realm.
#
#resource "keycloak_realm" "megamart_edge" {
#  depends_on = [helm_release.keycloak]
#  realm      = "megamart-edge"
#  enabled    = true
#}
#
#resource "keycloak_role" "store_associate" {
#  realm_id = keycloak_realm.megamart_edge.id
#  name     = "store-associate"
#}
#
#resource "keycloak_role" "mcp_executor" {
#  realm_id = keycloak_realm.megamart_edge.id
#  name     = "mcp-executor"
#}
#
## 1. Device Client (Human Login)
#resource "keycloak_openid_client" "associate_device" {
#  realm_id                     = keycloak_realm.megamart_edge.id
#  client_id                    = "webapp-client" # Reconciled with top-level name
#  name                         = "Store Associate Device WebApp"
#  enabled                      = true
#  access_type                  = "PUBLIC"
#  standard_flow_enabled        = true
#  direct_access_grants_enabled = true
#  valid_redirect_uris          = ["http://localhost:30000/*"]
#  web_origins                  = ["http://localhost:30000", "*"]
#}
#
## 2. MCP Server (Resource Server)
#resource "keycloak_openid_client" "mcp_server" {
#  realm_id                     = keycloak_realm.megamart_edge.id
#  client_id                    = "mcp-server"
#  name                         = "MCP Server API"
#  enabled                      = true
#  access_type                  = "CONFIDENTIAL"
#  service_accounts_enabled     = true
#  full_scope_allowed           = false
#}
#
## 3. AI Agent (Sovereign Executor)
#resource "keycloak_openid_client" "ai_agent" {
#  realm_id                     = keycloak_realm.megamart_edge.id
#  client_id                    = "ai-agent"
#  name                         = "AI Agent Backend"
#  enabled                      = true
#  access_type                  = "CONFIDENTIAL"
#  service_accounts_enabled     = true
#  client_authenticator_type    = "client-secret"
#  client_secret               = "ai-agent-secret"
#}
#
## 4. TOKEN EXCHANGE POLICY
## resource "keycloak_openid_client_permissions" "mcp_server_perms" {
##   realm_id  = keycloak_realm.megamart_edge.id
##   client_id = keycloak_openid_client.mcp_server.id
## 
##   token_exchange_scope {
##     decision_strategy = "UNANIMOUS"
##     policies          = [keycloak_openid_client_client_policy.ai_agent_policy.id]
##   }
## }
#
## resource "keycloak_openid_client_client_policy" "ai_agent_policy" {
##   realm_id           = keycloak_realm.megamart_edge.id
##   resource_server_id = keycloak_openid_client.mcp_server.id
##   name               = "ai-agent-exchange-policy"
##   clients            = [keycloak_openid_client.ai_agent.id]
##   decision_strategy  = "UNANIMOUS"
##   logic              = "POSITIVE"
## }
#
#resource "keycloak_user" "associate_user" {
#  realm_id       = keycloak_realm.megamart_edge.id
#  username       = "associate"
#  enabled        = true
#  email_verified = true
#  initial_password {
#    value     = "associate"
#    temporary = false
#  }
#}
#
#resource "keycloak_user_roles" "associate_user_roles" {
#  realm_id = keycloak_realm.megamart_edge.id
#  user_id  = keycloak_user.associate_user.id
#  role_ids = [keycloak_role.store_associate.id]
#}
#
## resource "keycloak_user_roles" "ai_agent_sa_roles" {
##   realm_id = keycloak_realm.megamart_edge.id
##   user_id  = keycloak_openid_client.ai_agent.service_account_user_id
##   role_ids = [keycloak_role.mcp_executor.id]
## }


# --- LEGACY BOOTSTRAP JOB REMOVED (REPLACED BY UNIFIED TERRAFORM) ---

resource "kubernetes_service_account" "ai_agent" {
  metadata {
    name      = "ai-agent"
    namespace = kubernetes_namespace.store_apps.metadata[0].name
  }
}

resource "kubernetes_deployment" "ai_agent" {
  depends_on = [null_resource.spire_trust_bundle_sync]
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
            path = "/run/spire/sockets"
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
  depends_on = [null_resource.spire_trust_bundle_sync]
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
            path = "/run/spire/sockets"
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
  depends_on = [null_resource.spire_trust_bundle_sync]
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
#
## 1. Allow both SVID and Plain-Text for Keycloak namespace (to support Browser login)
resource "kubernetes_manifest" "keycloak_peer_auth" {
  manifest = {
    apiVersion = "security.istio.io/v1beta1"
    kind       = "PeerAuthentication"
    metadata = {
      name      = "keycloak-permissive"
      namespace = kubernetes_namespace.store_edge.metadata[0].name
    }
    spec = {
      selector = { matchLabels = { app = "keycloak" } }
      mtls = { mode = "PERMISSIVE" }
    }
  }
}

resource "kubernetes_manifest" "webapp_peer_auth" {
  manifest = {
    apiVersion = "security.istio.io/v1beta1"
    kind       = "PeerAuthentication"
    metadata = {
      name      = "webapp-permissive"
      namespace = kubernetes_namespace.store_apps.metadata[0].name
    }
    spec = {
      selector = { matchLabels = { app = "webapp-frontend" } }
      mtls = { mode = "PERMISSIVE" }
    }
  }
}
#
## 2. Enforce High-Clearance Identity for Token Exchange
## resource "kubernetes_manifest" "keycloak_authz" {
##   manifest = {
##     apiVersion = "security.istio.io/v1beta1"
##     kind       = "AuthorizationPolicy"
##             source = {
##               principals = ["spiffe://megamart.com/ns/${kubernetes_namespace.store_apps.metadata[0].name}/sa/${kubernetes_service_account.ai_agent.metadata[0].name}"]
##             }
##           }]
##           to = [{
##             operation = {
##               # Prefix match for token exchange
##               paths = ["/realms/*/protocol/openid-connect/token*"]
##             }
##           }]
##         },
##         # RULE 3: Provisioner Identity
##         {
##           from = [{
##             source = {
##               principals = ["spiffe://megamart.com/ns/${kubernetes_namespace.store_edge.metadata[0].name}/sa/${kubernetes_service_account.keycloak_provisioner.metadata[0].name}"]
##             }
##           }]
##           to = [{
##             operation = {
##               # Full access for the forging session
##               paths = ["*"]
##             }
##           }]
##         }
##       ]
##     }
##   }
## }

# --- BROWSER ACCESS: ALLOW PERMISSIVE MTLS FOR FRONTEND ---
resource "kubernetes_manifest" "webapp_permissive_auth" {
  manifest = {
    apiVersion = "security.istio.io/v1beta1"
    kind       = "PeerAuthentication"
    metadata = {
      name      = "webapp-frontend-permissive"
      namespace = kubernetes_namespace.store_apps.metadata[0].name
    }
    spec = {
      selector = {
        matchLabels = {
          app = "webapp-frontend"
        }
      }
      mtls = {
        mode = "PERMISSIVE"
      }
    }
  }
}
