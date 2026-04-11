# Istio, SPIRE, and OPA: Zero Trust Deep Dive

This module introduces a hardened security layer using **Istio Service Mesh** integrated with **SPIRE** for identity and **Open Policy Agent (OPA)** for Attribute-Based Access Control (ABAC).

## 1. Identity Flow (SPIRE SDS)
In this architecture, Istio delegates certificate management to SPIRE via the **Secret Discovery Service (SDS)** API.

1.  **Pod Startup**: When a pod in `megamart-store-apps` starts, the Istio Sidecar (Envoy) is injected.
2.  **Socket Connection**: Envoy is configured to find the SPIFFE Workload API socket at `/var/run/secrets/workload-spiffe-uds/socket`.
3.  **SDS Request**: Envoy sends a gRPC SDS request to the SPIRE Agent through the socket.
4.  **Attestation**: The SPIRE Agent identifies the pod using Kubernetes selectors (ServiceAccount, Namespace) and issues a short-lived **X.509-SVID**.
5.  **mTLS**: Envoy uses this SVID for all mesh communication, ensuring that every request is encrypted and backed by a cryptographically verifiable SPIFFE identity.

## 2. Authorization Flow (Istio + OPA)
We implement an **"LLM Firewall"** to protect the MCP Server from unauthorized tool execution.

1.  **Request Interception**: The AI Agent sends a request to the MCP Server. The MCP Server's Envoy sidecar intercepts the traffic.
2.  **OPA Delegation**: Based on the `AuthorizationPolicy` (CUSTOM action), Envoy **pauses** the request processing.
3.  **External Authorization**: Envoy sends a metadata-rich `Check` request to **OPA** (running in `megamart-store-edge:9191`). This request includes:
    *   `x-forwarded-client-cert` (XFCC): Contains the caller's SPIFFE ID.
    *   `Authorization` header: Contains the human's down-scoped JWT.
4.  **Rego Evaluation**: OPA runs the `policy.rego`:
    *   **Identity Check**: It ensures the caller’s SPIFFE ID is exactly `spiffe://megamart.com/ns/megamart-store-edge/sa/ai-agent`.
    *   **Authorization Check**: It decodes the JWT and ensures the `mcp-executor` role is present.
    *   **God-Mode Prevention**: It explicitly denies the request if the broad `store-associate` role is found, preventing the Agent from "skipping" the down-scoping logic.
5.  **Decision**: OPA returns an `allow` decision. If true, Envoy forwards the request to the MCP Server. If false, Envoy returns a `403 Forbidden`.

## How to Apply
1.  Apply the Istio infrastructure: `terraform apply` (targets `istio-spire.tf`).
2.  Deploy OPA and the policy: `kubectl apply -f opa-deployment.yaml -f opa-rego-policy.yaml`.
3.  Update the apps: `kubectl apply -f app-mesh-updates.yaml`.
