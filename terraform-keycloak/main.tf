terraform {
  required_providers {
    keycloak = {
      source  = "keycloak/keycloak"
      version = ">= 5.0.0"
    }
  }
}

provider "keycloak" {
  client_id = "admin-cli"
  # We will port-forward the keycloak service to localhost:8080 or use NodePort
  # Let's assume NodePort 30080 on localhost
  url       = "http://localhost:30080"
  username  = "admin"
  password  = "admin"
}

resource "keycloak_realm" "megamart_edge" {
  realm   = "megamart-edge"
  enabled = true
  
  # Ensure consistent issuer URL for local development (resolves localhost:30080 vs internal name mismatch)
  attributes = {
    frontendUrl = "http://localhost:30080"
  }
}

resource "keycloak_role" "store_associate" {
  realm_id = keycloak_realm.megamart_edge.id
  name     = "store-associate"
}

resource "keycloak_role" "mcp_executor" {
  realm_id = keycloak_realm.megamart_edge.id
  name     = "mcp-executor"
}

# 1. Public client for the webapp
resource "keycloak_openid_client" "associate_device" {
  realm_id                     = keycloak_realm.megamart_edge.id
  client_id                    = "associate-device"
  name                         = "Store Associate Device WebApp"
  enabled                      = true
  access_type                  = "PUBLIC"
  standard_flow_enabled        = true
  direct_access_grants_enabled = true
  valid_redirect_uris          = [
    "http://localhost:3000/*",
    "http://localhost:30000/*"
  ]
  web_origins                  = [
    "http://localhost:3000",
    "http://localhost:30000",
    "*"
  ]
}

resource "keycloak_user" "store_associate_user" {
  realm_id       = keycloak_realm.megamart_edge.id
  username       = "store-associate-user"
  enabled        = true
  email_verified = true
  first_name     = "Store"
  last_name      = "Associate"
  email          = "store-associate@example.com"

  # Explicitly clear any pending required actions
  required_actions = []

  initial_password {
    value     = "password"
    temporary = false
  }
}

resource "keycloak_user_roles" "store_associate_user_roles" {
  realm_id = keycloak_realm.megamart_edge.id
  user_id  = keycloak_user.store_associate_user.id

  role_ids = [
    keycloak_role.store_associate.id
  ]
}

# 2. Resource server client (MCP server)
resource "keycloak_openid_client" "mcp_server" {
  realm_id                     = keycloak_realm.megamart_edge.id
  client_id                    = "mcp-server"
  name                         = "MCP Server API"
  enabled                      = true
  access_type                  = "CONFIDENTIAL"
  service_accounts_enabled     = true
  full_scope_allowed           = false
  authorization {
    policy_enforcement_mode = "ENFORCING"
  }
}

# 3. AI Agent (Transitioned to Secret for easier RFC 8693 compatibility)
resource "keycloak_openid_client" "ai_agent" {
  realm_id                     = keycloak_realm.megamart_edge.id
  client_id                    = "ai-agent"
  name                         = "AI Agent Backend"
  enabled                      = true
  access_type                  = "CONFIDENTIAL"
  service_accounts_enabled     = true
  standard_flow_enabled        = false
  direct_access_grants_enabled = false
  
  # Switch from client-jwt to client-secret
  client_authenticator_type = "client-secret"
  client_secret             = "ai-agent-secret"
}

resource "keycloak_openid_client_optional_scopes" "ai_agent_optional_scopes" {
  realm_id  = keycloak_realm.megamart_edge.id
  client_id = keycloak_openid_client.ai_agent.id

  optional_scopes = [
    keycloak_openid_client_scope.mcp_access.name
  ]
}

# 4. Authorize the AI Agent Service Account to hold the mcp-executor role
resource "keycloak_user_roles" "ai_agent_service_account_roles" {
  realm_id = keycloak_realm.megamart_edge.id
  user_id  = keycloak_openid_client.ai_agent.service_account_user_id

  role_ids = [
    keycloak_role.mcp_executor.id
  ]
}

# 5. Define the 'mcp-access' scope to carry the mcp-executor role
resource "keycloak_openid_client_scope" "mcp_access" {
  realm_id               = keycloak_realm.megamart_edge.id
  name                   = "mcp-access"
  include_in_token_scope = true
  gui_order              = 1
}

# Attach realm role mapper to the client scope
resource "keycloak_openid_user_realm_role_protocol_mapper" "mcp_access_role_mapper" {
  realm_id        = keycloak_realm.megamart_edge.id
  client_scope_id = keycloak_openid_client_scope.mcp_access.id
  name            = "mcp-executor-mapper"
  claim_name      = "realm_access.roles"
  multivalued     = true
}

# Set JWKS URL for the ai-agent to authenticate against SPIRE

# Actually, the JWKS URL for client-jwt auth is an attribute on the client itself, not a protocol mapper.
# We should set attributes = { "jwks.url" = "..." } or "use.jwks.url" = "true" on keycloak_openid_client.
