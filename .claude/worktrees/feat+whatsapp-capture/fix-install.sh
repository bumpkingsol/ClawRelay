#!/bin/bash
set -e

echo "1. Copying daemon script..."
sudo cp mac-daemon/context-daemon.sh /usr/local/bin/context-bridge-daemon.sh
sudo chmod +x /usr/local/bin/context-bridge-daemon.sh

echo "2. Patching server URL..."
sudo sed -i '' 's|https://localhost:7890/context/push|https://46.62.236.101:7890/context/push|' /usr/local/bin/context-bridge-daemon.sh

echo "3. Fixing plist permissions..."
chmod 644 "$HOME/Library/LaunchAgents/com.openclaw.context-bridge.plist"

echo "4. Reloading launchd..."
launchctl unload "$HOME/Library/LaunchAgents/com.openclaw.context-bridge.plist" 2>/dev/null || true
launchctl load "$HOME/Library/LaunchAgents/com.openclaw.context-bridge.plist"

echo "5. Checking status..."
sleep 2
launchctl list | grep context-bridge

echo "Done!"
