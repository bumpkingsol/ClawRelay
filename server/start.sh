#!/bin/bash
# Start Context Bridge receiver
# Add to crontab: @reboot /home/user/clawrelay/openclaw-computer-vision/server/start.sh

set -euo pipefail
source /home/user/clawrelay/.env 2>/dev/null || true

export CONTEXT_BRIDGE_DB="${CONTEXT_BRIDGE_DB:-/home/user/clawrelay/data/context-bridge.db}"
export CONTEXT_BRIDGE_PORT="${CONTEXT_BRIDGE_PORT:-7890}"

# Kill existing instance
pkill -f "context-receiver.py" 2>/dev/null || true
sleep 1

cd /home/user/clawrelay/openclaw-computer-vision/server
nohup python3 context-receiver.py >> /tmp/context-bridge-server.log 2>&1 &
echo "Context Bridge started (PID: $!)"
