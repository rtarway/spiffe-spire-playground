import os
import jwt
import httpx
from fastapi import FastAPI, Depends, HTTPException, Security, Request
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
import json

app = FastAPI(title="Megamart E-Commerce MCP Server")
security = HTTPBearer()

KEYCLOAK_URL = os.getenv("KEYCLOAK_URL", "http://keycloak.megamart-store-edge.svc.cluster.local:80/realms/megamart-edge")
JWKS_URL = f"{KEYCLOAK_URL}/protocol/openid-connect/certs"

def get_keycloak_public_key(kid: str):
    """Fetch public key from Keycloak to validate incoming token."""
    try:
        jwks = httpx.get(JWKS_URL).json()
        for key in jwks["keys"]:
            if key["kid"] == kid:
                return jwt.algorithms.RSAAlgorithm.from_jwk(key)
    except Exception as e:
        print(f"Failed to fetch JWKS: {e}")
    raise HTTPException(status_code=401, detail="Key not found")

def validate_token(credentials: HTTPAuthorizationCredentials = Security(security)):
    """Security Guardrail: Assert Token has mcp-executor and NOT store-associate (God Mode)."""
    token = credentials.credentials
    try:
        unverified_header = jwt.get_unverified_header(token)
        public_key = get_keycloak_public_key(unverified_header["kid"])
        decoded = jwt.decode(token, public_key, algorithms=["RS256"], audience="account", options={"verify_aud": False})
        
        # Zero Trust check
        roles = decoded.get("realm_access", {}).get("roles", [])
        
        # Guardrail #1: Must have down-scoped mcp-executor role
        if "mcp-executor" not in roles:
            raise HTTPException(status_code=403, detail="API3: Broken Object Property Level Authorization. Missing down-scoped mcp-executor role.")
            
        # Guardrail #2: Explicitly prevent "Agent God Mode" if human token is forwarded directly
        if "store-associate" in roles:
            raise HTTPException(status_code=403, detail="Agent God Mode detected. Broad store-associate role is forbidden at this layer.")
            
        return token
    except jwt.PyJWTError as e:
        raise HTTPException(status_code=401, detail=f"Invalid token: {e}")

# This simulates standard MCP Tools execution
@app.post("/mcp/messages")
async def handle_mcp_message(request: Request, token: str = Depends(validate_token)):
    body = await request.json()
    print(f"Received MCP payload: {body}")
    
    if body.get("method") == "tools/call" and body.get("params", {}).get("name") == "get_pending_store_orders":
        store_id = body["params"]["arguments"].get("store_id")
        
        # Hardcoded backend response simulation
        response = [
            {"order_id": "8921", "items": ["apples", "milk"], "status": "pending_pickup"},
            {"order_id": "8922", "items": ["bananas", "bread"], "status": "pending_pickup"}
        ]
        
        return {
            "jsonrpc": "2.0",
            "id": body.get("id"),
            "result": {
                "content": [
                    {
                        "type": "text",
                        "text": json.dumps(response)
                    }
                ]
            }
        }
    
    return {"error": "Method not found"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8001)
