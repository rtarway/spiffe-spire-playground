#!/bin/bash

# 🛰️ The Great Forge: 16,000-Store Image Builder
# This script builds the core edge images for the megamart.com fleet.
# Tailored for Rancher Desktop / Local Docker daemon.

set -e

# Anchor the Rancher Desktop binaries
export PATH="/Users/rtarway/.rd/bin:$PATH"

echo "🏗️ Starting the Great Forge..."

# 1. AI Agent Backend
echo "🛰️ Building AI Agent Backend..."
docker build -t ai-agent-backend:latest ai-agent-backend/

# 2. MCP Server
echo "🛡️ Building MCP Server..."
docker build -t mcp-server:latest mcp-server/

# 3. WebApp Frontend
echo "📱 Building WebApp Frontend..."
docker build -t webapp-frontend:latest webapp-frontend/

echo "✅ The Forge is complete. Images are ready for the Sovereign Edge."
docker images | grep -E "ai-agent-backend|mcp-server|webapp-frontend"
