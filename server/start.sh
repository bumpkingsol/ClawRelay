#!/bin/bash
set -euo pipefail

# Resolve paths - support both /home/admin/clawd and /home/user/clawrelay layouts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

export CONTEXT_BRIDGE_DB="${CONTEXT_BRIDGE_DB:-${ROOT_DIR}/data/context-bridge.db}"
export CONTEXT_BRIDGE_PORT="${CONTEXT_BRIDGE_PORT:-7890}"
export CONTEXT_BRIDGE_ALLOW_PLAINTEXT_DB_FOR_TESTS="${CONTEXT_BRIDGE_ALLOW_PLAINTEXT_DB_FOR_TESTS:-true}"
export CONTEXT_BRIDGE_DAEMON_WRITE_TOKEN="${CONTEXT_BRIDGE_DAEMON_WRITE_TOKEN:-$(grep CONTEXT_BRIDGE_DAEMON_WRITE_TOKEN "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2)}"
export CONTEXT_BRIDGE_HELPER_TOKEN="${CONTEXT_BRIDGE_HELPER_TOKEN:-$(grep CONTEXT_BRIDGE_HELPER_TOKEN "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2)}"
export CONTEXT_BRIDGE_AGENT_TOKEN="${CONTEXT_BRIDGE_AGENT_TOKEN:-$(grep CONTEXT_BRIDGE_AGENT_TOKEN "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2)}"
export CONTEXT_BRIDGE_DB_KEY="${CONTEXT_BRIDGE_DB_KEY:-$(grep CONTEXT_BRIDGE_DB_KEY "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2)}"

PYTHON="/home/linuxbrew/.linuxbrew/bin/python3"
pkill -f "context-receiver.py" 2>/dev/null || true
sleep 1
cd "$SCRIPT_DIR"
nohup $PYTHON context-receiver.py >> /tmp/context-bridge-server.log 2>&1 &
echo "Context Bridge started (PID: $!)"
