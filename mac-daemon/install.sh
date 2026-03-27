#!/bin/bash
# OpenClaw Context Bridge - Mac Installer
# Run: bash install.sh <server-url> <auth-token>

set -euo pipefail

SERVER_URL="${1:-}"
AUTH_TOKEN="${2:-}"

if [ -z "$SERVER_URL" ] || [ -z "$AUTH_TOKEN" ]; then
  echo "Usage: bash install.sh <server-url> <auth-token>"
  echo "Example: bash install.sh https://your-server:7890/context/push your-secret-token"
  exit 1
fi

echo "=== OpenClaw Context Bridge Installer ==="

# 1. Install daemon script
echo "[1/5] Installing daemon script..."
sudo cp "$(dirname "$0")/context-daemon.sh" /usr/local/bin/context-bridge-daemon.sh
sudo chmod +x /usr/local/bin/context-bridge-daemon.sh

# 2. Store auth token in macOS Keychain
echo "[2/5] Storing auth token in Keychain..."
security delete-generic-password -s "context-bridge" -a "token" 2>/dev/null || true
security add-generic-password -s "context-bridge" -a "token" -w "$AUTH_TOKEN"

# 3. Store server URL
echo "[3/5] Storing server URL..."
mkdir -p "$HOME/.context-bridge"
echo "$SERVER_URL" > "$HOME/.context-bridge/server-url"
chmod 600 "$HOME/.context-bridge/server-url"

# 4. Update daemon to read URL from config
# Patch the daemon to use the stored URL as default
sed -i '' "s|SERVER_URL=\"\${CONTEXT_BRIDGE_URL:-https://localhost:7890/context/push}\"|SERVER_URL=\"\${CONTEXT_BRIDGE_URL:-$SERVER_URL}\"|" /usr/local/bin/context-bridge-daemon.sh

# 5. Add shell hook for terminal command capture
echo "[4/5] Adding shell command hook..."
HOOK_LINE='# Context Bridge - command logger
preexec() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|$(pwd)|$1" >> ~/.context-bridge-cmds.log; }'

if [ -f "$HOME/.zshrc" ]; then
  if ! grep -q "Context Bridge" "$HOME/.zshrc" 2>/dev/null; then
    echo "" >> "$HOME/.zshrc"
    echo "$HOOK_LINE" >> "$HOME/.zshrc"
    echo "  Added preexec hook to ~/.zshrc"
  else
    echo "  Shell hook already exists in ~/.zshrc"
  fi
fi

# 6. Install and load launchd plist
echo "[5/5] Installing launchd service..."
cp "$(dirname "$0")/com.openclaw.context-bridge.plist" "$HOME/Library/LaunchAgents/"
launchctl unload "$HOME/Library/LaunchAgents/com.openclaw.context-bridge.plist" 2>/dev/null || true
launchctl load "$HOME/Library/LaunchAgents/com.openclaw.context-bridge.plist"

echo ""
echo "=== Installation Complete ==="
echo ""
echo "The daemon is now running and will capture activity every 2 minutes."
echo ""
echo "IMPORTANT: You need to grant these permissions in System Preferences > Privacy & Security:"
echo "  1. Accessibility - for window title capture"
echo "  2. Automation - for Chrome URL capture"
echo ""
echo "To check status:  launchctl list | grep context-bridge"
echo "To view logs:     tail -f /tmp/context-bridge.log"
echo "To stop:          launchctl unload ~/Library/LaunchAgents/com.openclaw.context-bridge.plist"
echo "To restart:       launchctl unload ~/Library/LaunchAgents/com.openclaw.context-bridge.plist && launchctl load ~/Library/LaunchAgents/com.openclaw.context-bridge.plist"
