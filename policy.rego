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
    # We allow the AI Agent's unique identity
    contains(xfcc, "URI=spiffe://megamart.com/ns/megamart-store-apps/sa/ai-agent")
}

# 3. Decode and validate the Token Claims
validate_jwt if {
    # Safety Guard: Ensure bearer_token is actually defined before decoding
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
