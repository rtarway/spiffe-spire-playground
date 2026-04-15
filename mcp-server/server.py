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
OPA_URL = os.getenv("OPA_URL", "http://127.0.0.1:9191").rstrip("/")

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
    """Cryptographic JWT validation (JWKS). Policy (SPIFFE + roles) is enforced in OPA."""
    token = credentials.credentials
    try:
        unverified_header = jwt.get_unverified_header(token)
        public_key = get_keycloak_public_key(unverified_header["kid"])
        jwt.decode(token, public_key, algorithms=["RS256"], audience="account", options={"verify_aud": False})
        return token
    except jwt.PyJWTError as e:
        raise HTTPException(status_code=401, detail=f"Invalid token: {e}")

async def opa_allow_mcp_messages(request: Request) -> bool:
    """
    Delegates to local OPA sidecar (policy.rego): SPIFFE client ID + downscoped JWT claims.
    Expects x-forwarded-client-cert from Istio inbound (ai-agent identity).
    """
    hdrs = request.headers
    opa_input = {
        "input": {
            "attributes": {
                "request": {
                    "http": {
                        "headers": {
                            "authorization": hdrs.get("authorization") or "",
                            "x-forwarded-client-cert": hdrs.get("x-forwarded-client-cert") or "",
                        }
                    }
                }
            }
        }
    }
    url = f"{OPA_URL}/v1/data/authz/allow/mcp/messages"
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            r = await client.post(url, json=opa_input)
    except httpx.RequestError as e:
        print(f"OPA request failed: {e}")
        return False

    if r.status_code != 200:
        print(f"OPA returned {r.status_code}: {r.text}")
        return False

    data = r.json()
    return data.get("result") is True

@app.post("/mcp/messages")
async def handle_mcp_message(request: Request, _token: str = Depends(validate_token)):
    body = await request.json()
    print(f"Received MCP payload: {body}")

    if body.get("method") == "tools/call" and body.get("params", {}).get("name") == "get_pending_store_orders":
        if not await opa_allow_mcp_messages(request):
            raise HTTPException(
                status_code=403,
                detail="OPA denied: SPIFFE identity or token policy check failed.",
            )

        response = [
            {"order_id": "8921", "items": ["apples", "milk"], "status": "pending_pickup"},
            {"order_id": "8922", "items": ["bananas", "bread"], "status": "pending_pickup"},
        ]

        return {
            "jsonrpc": "2.0",
            "id": body.get("id"),
            "result": {
                "content": [
                    {
                        "type": "text",
                        "text": json.dumps(response),
                    }
                ]
            },
        }

    return {"error": "Method not found"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8001)
