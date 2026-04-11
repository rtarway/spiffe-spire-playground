# Enable fine-grained permissions for mcp-server and bind the exchange policy
resource "keycloak_openid_client_permissions" "mcp_server_perms" {
  realm_id  = keycloak_realm.megamart_edge.id
  client_id = keycloak_openid_client.mcp_server.id

  token_exchange_scope {
    decision_strategy = "UNANIMOUS"
    policies          = [keycloak_openid_client_client_policy.ai_agent_policy.id]
  }
  
  depends_on = [keycloak_openid_client.mcp_server]
}

# Create a policy allowing ai-agent
resource "keycloak_openid_client_client_policy" "ai_agent_policy" {
  realm_id           = keycloak_realm.megamart_edge.id
  resource_server_id = keycloak_openid_client.mcp_server.id
  name               = "ai-agent-exchange-policy"
  clients            = [keycloak_openid_client.ai_agent.id]
  decision_strategy  = "UNANIMOUS"
  logic              = "POSITIVE"
}

# Scope mapper: Inject mcp-executor role into token during exchange to mcp-server
resource "keycloak_openid_client_role_policy" "mcp_executor_mapper" {
  # (Simulated) In practice, you might map down-scoping using Protocol Mappers
  # Let's add a protocol mapper to mcp_server for the role
  realm_id           = keycloak_realm.megamart_edge.id
  resource_server_id = keycloak_openid_client.mcp_server.id
  name               = "simulate-role-policy"
  type               = "role"
  decision_strategy  = "UNANIMOUS"
  logic              = "POSITIVE"
  role {
    id       = keycloak_role.mcp_executor.id
    required = false
  }
}

# 4. Hardcoded Role mapper: Inject mcp-executor into EVERY token for mcp-server
resource "keycloak_openid_hardcoded_role_protocol_mapper" "mcp_executor_hardcoded" {
  realm_id   = keycloak_realm.megamart_edge.id
  client_id  = keycloak_openid_client.mcp_server.id
  name       = "hardcoded-mcp-executor"
  role_id    = keycloak_role.mcp_executor.id
}

# 5. Ensure Realm Roles are mapped to realm_access.roles claim
resource "keycloak_openid_user_realm_role_protocol_mapper" "realm_role_mapper" {
  realm_id   = keycloak_realm.megamart_edge.id
  client_id  = keycloak_openid_client.mcp_server.id
  name       = "realm-role-mapper"
  claim_name = "realm_access.roles"
  multivalued = true
  add_to_id_token     = true
  add_to_access_token = true
}
