#!/bin/bash

# =============================================================================
# 🚀 Sovereign Identity Mesh: Unified Bootstrap Script
# =============================================================================
# This script orchestrates the end-to-end setup of the zero-trust identity 
# fabric on a fresh Rancher Desktop environment.
# 
# Phases:
# 1. Environment Validation
# 2. Local Container Construction (The Forge)
# 3. Infrastructure Manifestation (Terraform)
# =============================================================================

set -e

# PATH Configuration for Rancher Desktop and Local Tools
export PATH="/Users/rtarway/.rd/bin:/usr/local/bin:$PATH"

echo "🌟 Initializing Sovereign Edge Bootstrap..."

# --- Phase 1: Environment Validation ---
echo "🔍 Checking dependencies..."
command -v docker >/dev/null 2>&1 || { echo >&2 "❌ Docker is required but not found. Please start Rancher Desktop."; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo >&2 "❌ Kubectl is required but not found."; exit 1; }
command -v terraform >/dev/null 2>&1 || { echo >&2 "❌ Terraform is required but not found."; exit 1; }

# --- Phase 2: Local Container Construction ---
echo "🏗️  Phase 1/2: Building Local Container Images..."
if [ -f "./build_images.sh" ]; then
    chmod +x ./build_images.sh
    ./build_images.sh
else
    echo "❌ build_images.sh not found!"
    exit 1
fi

# --- Phase 3: Infrastructure Manifestation ---
echo "⚙️  Phase 2/2: Manifesting Sovereign Infrastructure..."
echo "📡 Initializing Terraform..."
terraform init

echo "💎 Applying Infrastructure State..."
terraform apply -auto-approve

echo "============================================================================="
echo "✅ BOOTSTRAP COMPLETE"
echo "============================================================================="
echo "🌐 WebApp Frontend: http://localhost:30000"
echo "🔐 Keycloak Console: http://localhost:30080"
echo "============================================================================="
