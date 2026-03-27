#!/bin/bash
# OpenClaw Context Bridge - Server Setup
# Run on Hetzner server as admin user

set -euo pipefail

INSTALL_DIR="/home/user/clawrelay/openclaw-computer-vision"
DATA_DIR="/home/user/clawrelay/data"
DIGEST_DIR="/home/user/clawrelay/memory/activity-digest"

echo "=== Context Bridge Server Setup ==="

# 1. Generate auth token if not exists
if ! grep -q "CONTEXT_BRIDGE_TOKEN" /home/user/clawrelay/.env 2>/dev/null; then
  TOKEN=$(openssl rand -hex 32)
  echo "" >> /home/user/clawrelay/.env
  echo "# Context Bridge" >> /home/user/clawrelay/.env
  echo "CONTEXT_BRIDGE_TOKEN=$TOKEN" >> /home/user/clawrelay/.env
  echo "[1/5] Generated auth token: $TOKEN"
  echo "  SAVE THIS - you'll need it for the Mac installer"
else
  TOKEN=$(grep "CONTEXT_BRIDGE_TOKEN" /home/user/clawrelay/.env | cut -d= -f2)
  echo "[1/5] Auth token already exists: ${TOKEN:0:8}..."
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
mkdir -p "$CERT_DIR"
if [ ! -f "$CERT_DIR/context-bridge.pem" ]; then
  openssl req -x509 -newkey rsa:4096 -keyout "$CERT_DIR/context-bridge-key.pem" \
    -out "$CERT_DIR/context-bridge.pem" -days 365 -nodes \
    -subj "/CN=context-bridge/O=OpenClaw" 2>/dev/null
  chmod 600 "$CERT_DIR/context-bridge-key.pem"
  echo "[4/5] Self-signed TLS certificate generated"
  echo "  For production, replace with Let's Encrypt"
else
  echo "[4/5] TLS certificate already exists"
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
echo "Server URL:     https://$(hostname -I | awk '{print $1}'):7890"
echo "Auth token:     $TOKEN"
echo ""
echo "Next: On Jonas's Mac, run:"
echo "  bash mac-daemon/install.sh https://$(hostname -I | awk '{print $1}'):7890/context/push $TOKEN"
