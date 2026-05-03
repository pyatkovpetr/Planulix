#!/usr/bin/env bash
# Same as server/claude_install_script.sh — for curl | bash installs from GitHub.
set -euo pipefail

log() { printf '[planulix claude-setup] %s\n' "$*"; }

if command -v claude >/dev/null 2>&1; then
  log "already installed: $(command -v claude)"
  claude --version 2>/dev/null | head -n1 || true
  exit 0
fi

NODE_OK=0
if command -v node >/dev/null 2>&1; then
  MAJOR="$(node -p 'parseInt(process.versions.node.split(".")[0]||0,10)||0' 2>/dev/null || echo 0)"
  if [ "${MAJOR:-0}" -ge 18 ]; then NODE_OK=1; fi
fi

if [ "$NODE_OK" != 1 ]; then
  log "Installing Node.js 22.x (nodesource)"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates gnupg >/dev/null || true
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y -qq nodejs
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y nodejs npm >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y nodejs npm >/dev/null
  else
    log "ERROR: need Node.js 18+. Install manually, then: npm install -g @anthropic-ai/claude-code"
    exit 20
  fi
fi

log "Installing @anthropic-ai/claude-code via npm..."
npm install -g @anthropic-ai/claude-code@latest

command -v claude >/dev/null 2>&1 || {
  log "ERROR: npm install finished but claude not on PATH"
  exit 21
}

log "installed: $(command -v claude)"
claude --version 2>/dev/null | head -n1 || true

exit 0
