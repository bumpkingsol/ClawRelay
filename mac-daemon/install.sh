#!/bin/bash
# OpenClaw Context Bridge - Mac Installer
# Run: bash install.sh <server-url> [auth-token] [tls-cert-file]

set -euo pipefail
umask 077

SERVER_URL="${1:-}"
ARG2="${2:-}"
ARG3="${3:-}"
AUTH_TOKEN="${CONTEXT_BRIDGE_TOKEN:-}"
TLS_CERT_FILE="${CONTEXT_BRIDGE_TLS_CERT_FILE:-}"

if [ -n "$ARG3" ]; then
  AUTH_TOKEN="${ARG2:-$AUTH_TOKEN}"
  TLS_CERT_FILE="$ARG3"
elif [ -n "$ARG2" ] && [ -f "$ARG2" ]; then
  TLS_CERT_FILE="$ARG2"
else
  AUTH_TOKEN="${ARG2:-$AUTH_TOKEN}"
fi

if [ -z "$SERVER_URL" ]; then
  echo "Usage: bash install.sh <server-url> [auth-token] [tls-cert-file]"
  echo "Example: bash install.sh https://your-server:7890/context/push"
  echo "Example: bash install.sh https://your-server:7890/context/push ~/Downloads/context-bridge.pem"
  exit 1
fi

if [ -z "$AUTH_TOKEN" ]; then
  printf "Enter Context Bridge auth token: " >&2
  read -r -s AUTH_TOKEN
  printf "\n" >&2
fi

if [ -z "$AUTH_TOKEN" ]; then
  echo "ERROR: Auth token is required." >&2
  exit 1
fi

if [ -n "$TLS_CERT_FILE" ] && [ ! -f "$TLS_CERT_FILE" ]; then
  echo "ERROR: TLS cert file not found: $TLS_CERT_FILE" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CB_DIR="$HOME/.context-bridge"
SERVER_CA_CERT_FILE="$CB_DIR/server-ca.pem"
echo "=== OpenClaw Context Bridge Installer ==="

# 1. Check dependencies
echo "[1/8] Checking dependencies..."
if ! command -v fswatch &>/dev/null; then
  echo "  Installing fswatch via Homebrew..."
  if command -v brew &>/dev/null; then
    brew install fswatch
  else
    echo "  WARNING: fswatch not found and Homebrew not installed."
    echo "  File change detection will be disabled."
    echo "  Install manually: brew install fswatch"
  fi
fi

# 2. Install daemon scripts (user-owned, no sudo needed)
echo "[2/8] Installing daemon scripts..."
mkdir -p "$CB_DIR/bin"
cp "$SCRIPT_DIR/context-daemon.sh"      "$CB_DIR/bin/context-bridge-daemon.sh"
cp "$SCRIPT_DIR/fswatch-projects.sh"    "$CB_DIR/bin/context-bridge-fswatch.sh"
cp "$SCRIPT_DIR/context-common.sh"      "$CB_DIR/bin/context-common.sh"
cp "$SCRIPT_DIR/context-helperctl.sh"   "$CB_DIR/bin/context-helperctl.sh"
cp "$SCRIPT_DIR/context-shell-hook.zsh" "$CB_DIR/context-shell-hook.zsh"
chmod 700 "$CB_DIR/bin/context-bridge-daemon.sh" \
          "$CB_DIR/bin/context-bridge-fswatch.sh" \
          "$CB_DIR/bin/context-helperctl.sh"
chmod 600 "$CB_DIR/bin/context-common.sh" \
          "$CB_DIR/context-shell-hook.zsh"

# 3. Store auth token in macOS Keychain
echo "[3/8] Storing auth token in Keychain..."
security delete-generic-password -s "context-bridge" -a "token" 2>/dev/null || true
security add-generic-password -s "context-bridge" -a "token" -w "$AUTH_TOKEN"

# 4. Configure server URL
echo "[4/8] Configuring server URL..."
mkdir -p "$CB_DIR"
chmod 700 "$CB_DIR"
echo "$SERVER_URL" > "$CB_DIR/server-url"
touch "$HOME/.context-bridge-cmds.log" "$HOME/.context-bridge/fswatch-changes.log" "$HOME/.context-bridge/last-clipboard-hash"
chmod 600 "$CB_DIR/server-url"
chmod 600 "$HOME/.context-bridge-cmds.log" "$HOME/.context-bridge/fswatch-changes.log" "$HOME/.context-bridge/last-clipboard-hash"

if [ -n "$TLS_CERT_FILE" ]; then
  cp "$TLS_CERT_FILE" "$SERVER_CA_CERT_FILE"
  chmod 600 "$SERVER_CA_CERT_FILE"
  echo "  Installed pinned TLS cert: $SERVER_CA_CERT_FILE"
elif [[ "$SERVER_URL" == https://* ]]; then
  echo "  No custom TLS cert provided; relying on system trust store"
fi

# 5. Add shell hooks for terminal command capture
echo "[5/8] Adding shell command hook..."
HOOK_SOURCE='# Context Bridge - command logger
[ -f "$HOME/.context-bridge/context-shell-hook.zsh" ] && source "$HOME/.context-bridge/context-shell-hook.zsh"'

if [ -f "$HOME/.zshrc" ]; then
  # Remove legacy inline preexec if present
  if grep -q "context-bridge-cmds.log" "$HOME/.zshrc" 2>/dev/null && \
     ! grep -q "context-shell-hook.zsh" "$HOME/.zshrc" 2>/dev/null; then
    # Replace old inline hook with source line
    sed -i '' '/# Context Bridge - command logger/,/^$/d' "$HOME/.zshrc" 2>/dev/null || true
    sed -i '' '/context-bridge-cmds\.log/d' "$HOME/.zshrc" 2>/dev/null || true
  fi

  if ! grep -q "context-shell-hook.zsh" "$HOME/.zshrc" 2>/dev/null; then
    echo "" >> "$HOME/.zshrc"
    echo "$HOOK_SOURCE" >> "$HOME/.zshrc"
    echo "  Added shell hook (sourced from ~/.context-bridge/context-shell-hook.zsh)"
  else
    echo "  Shell hook already exists"
  fi
fi

# 6. Install git post-commit hooks
echo "[6/8] Installing git hooks..."
if [ -f "$SCRIPT_DIR/../scripts/install-hooks.sh" ]; then
  bash "$SCRIPT_DIR/../scripts/install-hooks.sh" "$SERVER_URL" 2>/dev/null || echo "  Git hooks: some repos may not have been found"
else
  echo "  Skipping git hooks (install-hooks.sh not found)"
fi

# 7. Install launchd services
echo "[7/8] Installing launchd services..."

# Main daemon (every 2 minutes) – render template with actual bin path
sed "s#__CONTEXT_BRIDGE_BIN_DIR__#$CB_DIR/bin#g" \
  "$SCRIPT_DIR/com.openclaw.context-bridge.plist" \
  > "$HOME/Library/LaunchAgents/com.openclaw.context-bridge.plist"
launchctl unload "$HOME/Library/LaunchAgents/com.openclaw.context-bridge.plist" 2>/dev/null || true
launchctl load "$HOME/Library/LaunchAgents/com.openclaw.context-bridge.plist"

# File watcher (persistent)
if command -v fswatch &>/dev/null; then
  sed "s#__CONTEXT_BRIDGE_BIN_DIR__#$CB_DIR/bin#g" \
    "$SCRIPT_DIR/com.openclaw.context-bridge-fswatch.plist" \
    > "$HOME/Library/LaunchAgents/com.openclaw.context-bridge-fswatch.plist"
  launchctl unload "$HOME/Library/LaunchAgents/com.openclaw.context-bridge-fswatch.plist" 2>/dev/null || true
  launchctl load "$HOME/Library/LaunchAgents/com.openclaw.context-bridge-fswatch.plist"
  echo "  File watcher installed"
else
  echo "  File watcher skipped (fswatch not available)"
fi

# 8. Permissions check
echo "[8/8] Checking permissions..."
echo ""
echo "=== Installation Complete ==="
echo ""
echo "REQUIRED: Grant these permissions in System Settings > Privacy & Security:"
echo ""
echo "  1. ACCESSIBILITY (required - window titles, app names)"
echo "     System Settings > Privacy & Security > Accessibility"
echo "     Add: Terminal (or iTerm2/Warp)"
echo ""
echo "  2. AUTOMATION (required - Chrome URL capture)"
echo "     System Settings > Privacy & Security > Automation"
echo "     Allow: Terminal → Google Chrome"
echo ""
echo "  3. FULL DISK ACCESS (optional but recommended - notification capture)"
echo "     System Settings > Privacy & Security > Full Disk Access"
echo "     Add: Terminal (or iTerm2/Warp)"
echo "     Without this: notification capture will be disabled"
echo ""
echo "STATUS COMMANDS:"
echo "  Check daemon:    launchctl list | grep context-bridge"
echo "  View logs:       tail -f /tmp/context-bridge.log"
echo "  View errors:     tail -f /tmp/context-bridge-error.log"
echo "  Stop daemon:     launchctl unload ~/Library/LaunchAgents/com.openclaw.context-bridge.plist"
echo "  Restart daemon:  launchctl unload ~/Library/LaunchAgents/com.openclaw.context-bridge.plist && launchctl load ~/Library/LaunchAgents/com.openclaw.context-bridge.plist"
echo ""
echo "The daemon is now running. First data should arrive at the server within 2 minutes."
