#!/bin/bash
set -euo pipefail
export CONTEXT_BRIDGE_DB="${CONTEXT_BRIDGE_DB:-/home/user/clawrelay/data/context-bridge.db}"
export CONTEXT_BRIDGE_PORT="${CONTEXT_BRIDGE_PORT:-7890}"
export CONTEXT_BRIDGE_TOKEN="${CONTEXT_BRIDGE_TOKEN:-$(grep CONTEXT_BRIDGE_TOKEN /home/user/clawrelay/.env 2>/dev/null | tail -1 | cut -d= -f2)}"
PYTHON="/home/linuxbrew/.linuxbrew/bin/python3"
pkill -f "context-receiver.py" 2>/dev/null || true
sleep 1
cd /home/user/clawrelay/openclaw-computer-vision/server
nohup $PYTHON context-receiver.py >> /tmp/context-bridge-server.log 2>&1 &
echo "Context Bridge started (PID: $!)"
