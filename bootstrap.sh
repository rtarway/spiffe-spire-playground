#!/usr/bin/env bash

# =============================================================================
# Sovereign Identity Mesh — cluster bootstrap
# =============================================================================
# Deploys the full stack (SPIRE cloud + edge, Istio, Keycloak, OPA, apps) onto
# a fresh Kubernetes cluster using Terraform. Tested with Rancher Desktop;
# any cluster with a compatible kubectl context works if you set KUBE_CONTEXT.
#
# Prerequisites:
#   - Docker (for building local images; Rancher Desktop provides this)
#   - kubectl configured for your cluster
#   - terraform >= 1.x
#
# Optional environment:
#   KUBE_CONTEXT   kubectl context (default: rancher-desktop)
#   KUBECONFIG     path to kubeconfig (default: ~/.kube/config via Terraform)
#   TF_VAR_keycloak_url  Keycloak URL for Terraform Keycloak provider
#                        (default: http://localhost:30080 — correct for NodePort on localhost)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Prefer common tool locations (Rancher Desktop, Homebrew) without hardcoding a single user path.
for _d in "${HOME}/.rd/bin" "/usr/local/bin" "/opt/homebrew/bin"; do
  if [[ -d "${_d}" ]]; then
    PATH="${_d}:${PATH}"
  fi
done
export PATH

echo "Initializing Sovereign Edge bootstrap..."

# --- Phase 1: Tooling ---
echo "Checking dependencies..."
command -v docker >/dev/null 2>&1 || {
  echo "Docker is required (start Rancher Desktop or Docker Desktop)." >&2
  exit 1
}
command -v kubectl >/dev/null 2>&1 || {
  echo "kubectl not found in PATH." >&2
  exit 1
}
command -v terraform >/dev/null 2>&1 || {
  echo "terraform not found in PATH." >&2
  exit 1
}

# --- Phase 2: Kubernetes context ---
export KUBE_CONTEXT="${KUBE_CONTEXT:-rancher-desktop}"
export TF_VAR_kube_context="${TF_VAR_kube_context:-$KUBE_CONTEXT}"

if [[ -n "${KUBECONFIG:-}" ]]; then
  export TF_VAR_kubeconfig_path="${TF_VAR_kubeconfig_path:-$KUBECONFIG}"
fi

echo "Using kubectl context: ${TF_VAR_kube_context}"
if ! kubectl config get-contexts "${TF_VAR_kube_context}" >/dev/null 2>&1; then
  echo "Context '${TF_VAR_kube_context}' not found. Create it or set KUBE_CONTEXT." >&2
  kubectl config get-contexts || true
  exit 1
fi

echo "Verifying cluster connectivity..."
kubectl --context "${TF_VAR_kube_context}" cluster-info >/dev/null
kubectl --context "${TF_VAR_kube_context}" wait --for=condition=Ready nodes --all --timeout=120s >/dev/null

# --- Phase 3: Local images (imagePullPolicy: Never on workloads) ---
echo "Phase 1/2: Building local container images..."
if [[ -f ./build_images.sh ]]; then
  chmod +x ./build_images.sh
  ./build_images.sh
else
  echo "build_images.sh not found." >&2
  exit 1
fi

# --- Phase 4: Terraform ---
echo "Phase 2/2: Applying Terraform (SPIRE, Istio, Keycloak, workloads)..."
terraform init
terraform apply -auto-approve

echo "============================================================================="
echo "Bootstrap complete"
echo "============================================================================="
echo "Web app (NodePort):  http://localhost:30000"
echo "Keycloak (NodePort): http://localhost:30080"
echo "============================================================================="
echo "Tip: For a non-default cluster, rerun with KUBE_CONTEXT=<your-context> ./bootstrap.sh"
