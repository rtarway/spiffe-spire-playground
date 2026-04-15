import os
import jwt
import httpx
from fastapi import FastAPI, Depends, HTTPException, Security
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel
from spiffe import WorkloadApiClient

app = FastAPI(title="Megamart AI Agent Backend")
security = HTTPBearer()

# Intra-mesh only (webapp BFF); browsers should not call this service directly.
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
    """Verify Bearer token has store-associate role (human session)."""
    token = credentials.credentials
    try:
        unverified_header = jwt.get_unverified_header(token)
        public_key = get_keycloak_public_key(unverified_header["kid"])
        decoded = jwt.decode(token, public_key, algorithms=["RS256"], audience="account", options={"verify_aud": False})

        roles = decoded.get("realm_access", {}).get("roles", [])
        print(f"DEBUG: Validated token sub={decoded.get('sub')} roles={roles}")

        if "store-associate" not in roles:
            raise HTTPException(status_code=403, detail="Missing store-associate role.")

        return token
    except jwt.PyJWTError as e:
        raise HTTPException(status_code=401, detail=f"Invalid token: {e}")

def llm_plan_mcp(prompt: str) -> tuple[bool, str | None]:
    """
    Placeholder for external LLM: decides whether to invoke MCP tools.
    Returns (use_mcp, tool_name).
    """
    p = prompt.lower()
    if "orders" in p or "pickup" in p or "curbside" in p:
        return True, "get_pending_store_orders"
    return False, None

@app.post("/agent/chat")
async def chat_endpoint(request: ChatRequest, token: str = Depends(validate_token)):
    print(f"Received prompt: {request.prompt}")

    use_mcp, tool_name = llm_plan_mcp(request.prompt)
    if not use_mcp or not tool_name:
        return {
            "llm_response": "I am an intelligent agent. I didn't need any tools for this prompt.",
            "mcp_planned": False,
        }

    print(f"LLM (stub) chose MCP tool: {tool_name}")

    try:
        with WorkloadApiClient() as client:
            jwt_svid = client.fetch_jwt_svid(audience={"keycloak"})
            print(f"DEBUG: SPIFFE JWT-SVID prefix: {jwt_svid.token[:16]}...")
    except Exception as e:
        print(f"Warning: SPIFFE JWT-SVID failed ({e}); continuing for token exchange where applicable.")

    exchange_payload = {
        "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
        "client_id": "ai-agent",
        "client_secret": "ai-agent-secret",
        "subject_token": token,
        "subject_token_type": "urn:ietf:params:oauth:token-type:access_token",
        "audience": "mcp-server",
        "scope": "mcp-access",
    }

    try:
        async with httpx.AsyncClient() as client:
            exchange_response = await client.post(TOKEN_ENDPOINT, data=exchange_payload)

        if exchange_response.status_code != 200:
            return {"error": f"Token exchange failed: {exchange_response.text}"}

        mcp_token = exchange_response.json().get("access_token")
        print("Token exchange successful. Down-scoped mcp-executor token acquired.")
    except Exception as e:
        return {"error": f"Exchange request failed: {e}"}

    headers = {"Authorization": f"Bearer {mcp_token}"}
    payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {
            "name": tool_name,
            "arguments": {"store_id": "local_123"},
        },
    }

    try:
        async with httpx.AsyncClient() as client:
            mcp_res = await client.post(f"{MCP_SERVER_URL}/messages", json=payload, headers=headers)

        if mcp_res.status_code in [401, 403]:
            return {"error": "MCP Server rejected the request (OPA or token).", "detail": mcp_res.text}

        return {
            "llm_response": "Here are the pending orders from the MCP Server.",
            "mcp_planned": True,
            "mcp_data": mcp_res.json(),
        }
    except Exception as e:
        return {"error": f"MCP request failed: {e}"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
