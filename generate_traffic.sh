#!/usr/bin/env bash
# Drive generate_traffic.js — each iteration = browser Keycloak login + BFF agent prompt.
# Usage: ./generate_traffic.sh [iterations] [concurrency]
#
# If many workflows fail after ~200–300 successes (especially with concurrency > 1), typical causes:
#   - PostgreSQL max_connections / Keycloak JDBC pool exhaustion (bundled Bitnami chart defaults are modest).
#   - Keycloak realm "Brute Force Detection" with Quick Login Check (min ms between attempts) — rare if left default off.
#   - Node / host ephemeral port or conntrack limits under burst traffic.
# Mitigation: lower concurrency (e.g. 1–2) and/or add a small pause between batches:
#   BATCH_DELAY_MS=200 ./generate_traffic.sh 1000 2
#
# Override URLs if your NodePorts differ:
#   KEYCLOAK_TOKEN_URL=... WEBAPP_AGENT_URL=... ./generate_traffic.sh 1000 5

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

export KEYCLOAK_TOKEN_URL="${KEYCLOAK_TOKEN_URL:-http://localhost:30080/realms/megamart-edge/protocol/openid-connect/token}"
export WEBAPP_AGENT_URL="${WEBAPP_AGENT_URL:-http://localhost:30000/api/agent/chat}"
# Less chatty for large runs (progress still every 50 OK workflows)
export QUIET="${QUIET:-1}"
export BATCH_DELAY_MS="${BATCH_DELAY_MS:-0}"

exec node "$ROOT/generate_traffic.js" "$@"
