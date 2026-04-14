package authz.allow.mcp

import future.keywords.if
import future.keywords.in

import input.attributes.request.http.headers

default messages = false

# 1. Main entry point
messages if {
    validate_spiffe_id
    validate_jwt
}

# 2. Extract and Validate SPIFFE ID from x-forwarded-client-cert (Transport Security)
validate_spiffe_id if {
    xfcc := headers["x-forwarded-client-cert"]
    # Verify the request originated from the AI Agent workload
    contains(xfcc, "URI=spiffe://megamart.com/ns/megamart-store-apps/sa/ai-agent")
}

# 3. Decode and validate the Token Claims (Application Identity)
validate_jwt if {
    # Safety Guard: Ensure bearer_token is actually defined before decoding
    bearer_token
    
    [_, payload, _] := io.jwt.decode(bearer_token)
    
    # 3a. Core Requirement: Token must have the strictly down-scoped role
    roles := payload.realm_access.roles
    "mcp-executor" in roles
    
    # 3b. Guardrail: Explicitly DENY if broad human role is present (Agent God-Mode Prevention)
    # This ensures the agent is using an exchanged token, not the raw human token.
    not "store-associate" in roles
}

# Helper: Extract Bearer Token
bearer_token = t if {
    v := headers.authorization
    startswith(v, "Bearer ")
    t := substring(v, count("Bearer "), -1)
}
