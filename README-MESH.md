# Istio, SPIRE, and OPA: mesh behavior

This document matches the **current Terraform implementation** in this repo (not legacy YAML-only flows).

## 1. Identity flow (SPIRE → Istio SDS)

1. **SPIRE Agent** runs as a DaemonSet and exposes the Workload API on the node at **`/run/spire/agent-sockets`** (standardized host path).
2. **Istio** is configured so the data plane uses the SPIRE Workload API instead of Istio’s own CA for workload identity: `meshConfig.defaultConfig.proxyMetadata.SPIFFE_ENDPOINT_SOCKET` points to **`unix:///run/spire/sockets/spire-agent.sock`** inside the proxy (see `istio-spire.tf`).
3. **`istiod`** mounts the same host path into the pilot pod so the control plane can align with SPIRE-backed identity where needed.
4. **App pods** (`ai-agent`, `mcp-server`, `webapp-frontend`) declare:
   - `sidecar.istio.io/userVolume` / `userVolumeMount` to mount the host directory **`/run/spire/agent-sockets`** at **`/run/spire/sockets`** in the pod.
   - `SPIFFE_ENDPOINT_SOCKET=unix:///run/spire/sockets/spire-agent.sock` on the app containers.
5. **SPIRE Kubernetes Registrar** is enabled on the SPIRE servers; manual SPIRE registration entries are not used in this stack.

## 2. Authorization flow (Istio + OPA)

1. **OPA** runs as a **sidecar** in the `ai-agent` and `mcp-server` pods (`openpolicyagent/opa`), listening on **`:9191`**.
2. **Config** comes from a **`ConfigMap`** (`opa-config`) in `megamart-store-apps`: `config.yaml` (GitHub bundle + polling) and **`policy.rego`** from the repo root (`main.tf` uses `file("${path.module}/policy.rego")`).
3. **Istio** registers an **extension provider** `opa-ext-authz` pointing at **`127.0.0.1:9191`** with `includeRequestHeadersInCheck` for **`x-forwarded-client-cert`** and **`authorization`** so OPA can enforce both transport identity and JWT rules (`istio-spire.tf`).
4. **`policy.rego`** (package `authz.allow.mcp`) requires:
   - XFCC containing the AI Agent SPIFFE ID: `spiffe://megamart.com/ns/megamart-store-apps/sa/ai-agent`
   - JWT with **`mcp-executor`** and **not** the broad **`store-associate`** role (see `policy.rego`).

## 3. mTLS and exceptions

- **Default**: `PeerAuthentication` in `istio-system` sets **STRICT** mTLS for the mesh (`istio-spire.tf`).
- **Keycloak** and **webapp** use **PERMISSIVE** peer auth where the browser must speak plain HTTP to the NodePort (see `main.tf`).

## How to apply

Everything is applied **with Terraform** (same as `./bootstrap.sh`):

```bash
terraform apply
```

There are **no** separate `opa-deployment.yaml` / `app-mesh-updates.yaml` in this repo; OPA, policies, and mesh resources are defined in **`main.tf`** and **`istio-spire.tf`**.

After changing **`policy.rego`**, re-apply Terraform so the `ConfigMap` updates, then restart the affected deployments if needed.
