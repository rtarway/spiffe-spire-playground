import os
import jwt
import httpx
from fastapi import FastAPI, Depends, HTTPException, Security
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from spiffe import WorkloadApiClient

app = FastAPI(title="Megamart AI Agent Backend")
security = HTTPBearer()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

KEYCLOAK_URL = os.getenv("KEYCLOAK_URL", "http://keycloak.megamart-store-edge.svc.cluster.local:80/realms/megamart-edge")
JWKS_URL = f"{KEYCLOAK_URL}/protocol/openid-connect/certs"
TOKEN_ENDPOINT = f"{KEYCLOAK_URL}/protocol/openid-connect/token"
MCP_SERVER_URL = os.getenv("MCP_SERVER_URL", "http://mcp-server.megamart-store-apps.svc.cluster.local:8001/mcp")

class ChatRequest(BaseModel):
    prompt: str

def get_keycloak_public_key(kid: str):
    """Fetch public key from Keycloak to validate incoming token."""
    jwks = httpx.get(JWKS_URL).json()
    for key in jwks["keys"]:
        if key["kid"] == kid:
            return jwt.algorithms.RSAAlgorithm.from_jwk(key)
    raise HTTPException(status_code=401, detail="Key not found")

def validate_token(credentials: HTTPAuthorizationCredentials = Security(security)):
    """Middleware: Verify incoming Bearer token has store-associate role."""
    token = credentials.credentials
    try:
        unverified_header = jwt.get_unverified_header(token)
        public_key = get_keycloak_public_key(unverified_header["kid"])
        decoded = jwt.decode(token, public_key, algorithms=["RS256"], audience="account", options={"verify_aud": False})
        
        # Zero Trust check: Enforce human role
        roles = decoded.get("realm_access", {}).get("roles", [])
        
        # --- DEBUG INSTRUMENTATION ---
        print(f"DEBUG: Validated token for subject: {decoded.get('sub')}")
        print(f"DEBUG: Token Issuer (iss): {decoded.get('iss')}")
        print(f"DEBUG: Token Audience (aud): {decoded.get('aud')}")
        print(f"DEBUG: Roles: {roles}")
        
        if "store-associate" not in roles:
            raise HTTPException(status_code=403, detail="Missing store-associate role. Agent God Mode Prevention trigger.")
            
        return token
    except jwt.PyJWTError as e:
        raise HTTPException(status_code=401, detail=f"Invalid token: {e}")

@app.post("/agent/chat")
async def chat_endpoint(request: ChatRequest, token: str = Depends(validate_token)):
    print(f"Received prompt: {request.prompt}")
    
    # 1. Identity Acquisition: Get Agent's SPIFFE JWT-SVID for RFC 7523
    try:
        with WorkloadApiClient() as client:
            jwt_svid = client.fetch_jwt_svid(audience={"keycloak"})
            agent_jwt = jwt_svid.token
            print("Successfully fetched SPIFFE JWT-SVID for RFC 7523 authentication.")
            
            # --- EXTERNAL LLM EGRESS SIMULATION ---
            # Proving the SPIFFE agent_jwt is injected into the Authorization: Bearer header
            # for external use only, while internal comms rely on Istio mTLS.
            print(f"DEBUG: Injecting SPIFFE agent_jwt into Authorization header for external LLM call.")
            print(f"DEBUG: Header: Authorization: Bearer {agent_jwt[:15]}...")
    except Exception as e:
        # Fallback for local testing if SPIRE is not mounted
        print(f"Warning: SPIFFE socket failed ({e}). Mocking SVID for demo.")
        agent_jwt = "mock_agent_jwt"

    # 2. RFC 8693 Token Exchange Execution
    # Exchange the broad human token for a down-scoped 'mcp-executor' token targeting mcp-server
    exchange_payload = {
        "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
        "client_id": "ai-agent",
        "client_secret": "ai-agent-secret",
        "subject_token": token,
        "subject_token_type": "urn:ietf:params:oauth:token-type:access_token",
        "audience": "mcp-server",
        "scope": "mcp-access"
    }

    try:
        # Note: In a real scenario, Keycloak needs to be configured to accept the SPIRE JWT.
        async with httpx.AsyncClient() as client:
            exchange_response = await client.post(TOKEN_ENDPOINT, data=exchange_payload)
            
        if exchange_response.status_code != 200:
            return {"error": f"Token exchange failed: {exchange_response.text}"}
            
        mcp_token = exchange_response.json().get("access_token")
        print("Token exchange successful. Acquired down-scoped mcp-server token.")
        
    except Exception as e:
        return {"error": f"Exchange request failed: {e}"}

    # 3. LLM Integration + MCP Server Invocation
    # Mock LLM decision logic
    if "orders" in request.prompt.lower():
        print("LLM decided to invoke 'get_pending_store_orders' MCP Tool.")
        # Pass the newly exchanged token to the MCP Server
        headers = {"Authorization": f"Bearer {mcp_token}"}
        # Assuming MCP HTTP/SSE transport acts over a POST request for tool invocation
        # (Standard MCP via HTTP usually accepts JSON-RPC over POST)
        payload = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "get_pending_store_orders",
                "arguments": {"store_id": "local_123"}
            }
        }
        
        async with httpx.AsyncClient() as client:
            mcp_res = await client.post(f"{MCP_SERVER_URL}/messages", json=payload, headers=headers)
            
        if mcp_res.status_code in [401, 403]:
            return {"error": "MCP Server rejected our token. Role mcp-executor is likely missing."}
            
        return {"llm_response": "Here are the pending orders from the MCP Server.", "mcp_data": mcp_res.json()}
        
    return {"llm_response": "I am an intelligent agent. I didn't need any tools for this prompt."}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
