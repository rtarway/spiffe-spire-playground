#!/usr/bin/env bash
# Drive generate_traffic.js — each iteration = browser Keycloak login + BFF agent prompt.
# Usage: ./generate_traffic.sh [iterations] [concurrency]
# Override URLs if your NodePorts differ:
#   KEYCLOAK_TOKEN_URL=... WEBAPP_AGENT_URL=... ./generate_traffic.sh 1000 5

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

export KEYCLOAK_TOKEN_URL="${KEYCLOAK_TOKEN_URL:-http://localhost:30080/realms/megamart-edge/protocol/openid-connect/token}"
export WEBAPP_AGENT_URL="${WEBAPP_AGENT_URL:-http://localhost:30000/api/agent/chat}"
# Less chatty for large runs (progress still every 50 OK workflows)
export QUIET="${QUIET:-1}"

exec node "$ROOT/generate_traffic.js" "$@"
