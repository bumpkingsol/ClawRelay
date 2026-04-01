#!/bin/bash
# OpenClaw Context Bridge - Server Setup
# Run on VPS server

set -euo pipefail
umask 077

INSTALL_DIR="/home/user/clawrelay/openclaw-computer-vision"
DATA_DIR="/home/user/clawrelay/data"
DIGEST_DIR="/home/user/clawrelay/memory/activity-digest"
ENV_FILE="/home/user/clawrelay/.env"

# --- Token rotation subcommand ---
if [ "${1:-}" = "rotate-token" ]; then
  DAEMON_TOKEN=$(openssl rand -hex 32)
  HELPER_TOKEN=$(openssl rand -hex 32)
  AGENT_TOKEN=$(openssl rand -hex 32)
  DB_KEY=$(openssl rand -hex 32)
  sed -i "s/^CONTEXT_BRIDGE_DAEMON_WRITE_TOKEN=.*/CONTEXT_BRIDGE_DAEMON_WRITE_TOKEN=$DAEMON_TOKEN/" "$ENV_FILE"
  sed -i "s/^CONTEXT_BRIDGE_HELPER_TOKEN=.*/CONTEXT_BRIDGE_HELPER_TOKEN=$HELPER_TOKEN/" "$ENV_FILE"
  sed -i "s/^CONTEXT_BRIDGE_AGENT_TOKEN=.*/CONTEXT_BRIDGE_AGENT_TOKEN=$AGENT_TOKEN/" "$ENV_FILE"
  sed -i "s/^CONTEXT_BRIDGE_DB_KEY=.*/CONTEXT_BRIDGE_DB_KEY=$DB_KEY/" "$ENV_FILE"
  echo "Tokens rotated."
  echo ""
  echo "Next steps:"
  echo "  1. Restart the service: sudo systemctl restart context-bridge"
  echo "  2. On the operator's Mac, update the Keychain entries:"
  echo "     security delete-generic-password -s context-bridge-daemon -a token 2>/dev/null"
  echo "     security add-generic-password -s context-bridge-daemon -a token -w \"$DAEMON_TOKEN\""
  echo "     security delete-generic-password -s context-bridge-helper -a token 2>/dev/null"
  echo "     security add-generic-password -s context-bridge-helper -a token -w \"$HELPER_TOKEN\""
  exit 0
fi

echo "=== Context Bridge Server Setup ==="

touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

# 1. Generate scoped auth tokens if not exist
if ! grep -q "^CONTEXT_BRIDGE_DAEMON_WRITE_TOKEN=" "$ENV_FILE" 2>/dev/null; then
  DAEMON_TOKEN=$(openssl rand -hex 32)
  HELPER_TOKEN=$(openssl rand -hex 32)
  AGENT_TOKEN=$(openssl rand -hex 32)
  DB_KEY=$(openssl rand -hex 32)
  echo "" >> "$ENV_FILE"
  echo "# Context Bridge" >> "$ENV_FILE"
  echo "CONTEXT_BRIDGE_DAEMON_WRITE_TOKEN=$DAEMON_TOKEN" >> "$ENV_FILE"
  echo "CONTEXT_BRIDGE_HELPER_TOKEN=$HELPER_TOKEN" >> "$ENV_FILE"
  echo "CONTEXT_BRIDGE_AGENT_TOKEN=$AGENT_TOKEN" >> "$ENV_FILE"
  echo "CONTEXT_BRIDGE_DB_KEY=$DB_KEY" >> "$ENV_FILE"
  echo "[1/5] Generated scoped auth tokens and stored them in $ENV_FILE"
else
  DAEMON_TOKEN=$(grep "^CONTEXT_BRIDGE_DAEMON_WRITE_TOKEN=" "$ENV_FILE" | cut -d= -f2)
  HELPER_TOKEN=$(grep "^CONTEXT_BRIDGE_HELPER_TOKEN=" "$ENV_FILE" | cut -d= -f2)
  AGENT_TOKEN=$(grep "^CONTEXT_BRIDGE_AGENT_TOKEN=" "$ENV_FILE" | cut -d= -f2)
  echo "[1/5] Scoped auth tokens already exist: daemon=${DAEMON_TOKEN:0:8}... helper=${HELPER_TOKEN:0:8}... agent=${AGENT_TOKEN:0:8}..."
fi

# 2. Create data directory
mkdir -p "$DATA_DIR"
mkdir -p "$DIGEST_DIR"
echo "[2/5] Data directories created"

# 3. Install Python dependencies
cd "$INSTALL_DIR/server"
pip3 install -r requirements.txt --quiet 2>/dev/null || pip install -r requirements.txt --quiet
echo "[3/5] Python dependencies installed"

# 4. Generate self-signed TLS cert (upgrade to Let's Encrypt later)
CERT_DIR="/home/user/clawrelay/data/certs"
SERVER_IP="$(hostname -I | awk '{print $1}')"
SERVER_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"
CERT_SAN="$(openssl x509 -in "$CERT_DIR/context-bridge.pem" -noout -ext subjectAltName 2>/dev/null || true)"
CERT_SUBJECT="$(openssl x509 -in "$CERT_DIR/context-bridge.pem" -noout -subject 2>/dev/null || true)"
if [ ! -f "$CERT_DIR/context-bridge.pem" ]; then
  openssl req -x509 -newkey rsa:4096 -keyout "$CERT_DIR/context-bridge-key.pem" \
    -out "$CERT_DIR/context-bridge.pem" -days 365 -nodes \
    -subj "/CN=$SERVER_HOSTNAME/O=OpenClaw" \
    -addext "subjectAltName=DNS:$SERVER_HOSTNAME,DNS:localhost,IP:$SERVER_IP,IP:127.0.0.1" 2>/dev/null
  chmod 644 "$CERT_DIR/context-bridge.pem"
  chmod 600 "$CERT_DIR/context-bridge-key.pem"
  echo "[4/5] TLS certificate generated for $SERVER_HOSTNAME / $SERVER_IP"
  echo "  For production, prefer a publicly trusted certificate or copy this PEM to the Mac installer"
elif printf '%s' "$CERT_SAN" | grep -q "$SERVER_IP"; then
  echo "[4/5] TLS certificate already exists"
elif printf '%s' "$CERT_SUBJECT" | grep -q "O = OpenClaw"; then
  openssl req -x509 -newkey rsa:4096 -keyout "$CERT_DIR/context-bridge-key.pem" \
    -out "$CERT_DIR/context-bridge.pem" -days 365 -nodes \
    -subj "/CN=$SERVER_HOSTNAME/O=OpenClaw" \
    -addext "subjectAltName=DNS:$SERVER_HOSTNAME,DNS:localhost,IP:$SERVER_IP,IP:127.0.0.1" 2>/dev/null
  chmod 644 "$CERT_DIR/context-bridge.pem"
  chmod 600 "$CERT_DIR/context-bridge-key.pem"
  echo "[4/5] TLS certificate regenerated with SANs for $SERVER_HOSTNAME / $SERVER_IP"
  echo "  Copy the updated PEM to the Mac so curl can verify the server"
else
  echo "[4/5] Existing TLS certificate kept (not an auto-generated OpenClaw cert)"
  echo "  Ensure it matches the URL the operator's Mac uses and export the issuing CA if needed"
fi

# 5. Install systemd service
sudo cp "$INSTALL_DIR/server/context-bridge.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable context-bridge
sudo systemctl restart context-bridge
echo "[5/5] systemd service installed and started"

echo ""
echo "=== Server Setup Complete ==="
echo ""
echo "Service status: sudo systemctl status context-bridge"
echo "Server URL:     https://$SERVER_IP:7890"
echo "Daemon token:   stored in $ENV_FILE"
echo "Helper token:   stored in $ENV_FILE"
echo "Agent token:    stored in $ENV_FILE"
echo "Server cert:    $CERT_DIR/context-bridge.pem"
echo ""
echo "Next: On the operator's Mac, run:"
echo "  bash mac-daemon/install.sh https://$SERVER_IP:7890/context/push <daemon-token> <helper-token> /path/to/context-bridge.pem"
echo "  The installer will prompt for the tokens securely if you do not pass them as arguments."
