#!/bin/bash
set -e

echo "1. Updating URL to Tailscale..."
sudo sed -i '' 's|https://46.62.236.101:7890|http://100.71.165.128:7890|' /usr/local/bin/context-bridge-daemon.sh

echo "2. Verifying..."
grep 'SERVER_URL=' /usr/local/bin/context-bridge-daemon.sh | head -1

echo "3. Restarting daemon..."
launchctl unload "$HOME/Library/LaunchAgents/com.openclaw.context-bridge.plist" 2>/dev/null || true
launchctl load "$HOME/Library/LaunchAgents/com.openclaw.context-bridge.plist"

echo "4. Waiting 3s for first run..."
sleep 3
launchctl list | grep context-bridge

echo "Done!"
