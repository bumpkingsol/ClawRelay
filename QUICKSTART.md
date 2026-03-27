# QUICKSTART.md - Complete Setup Guide for Agents

**This file tells you exactly what to do. Follow it step by step. Do not skip steps.**

If you are an LLM / coding agent setting this up for Jonas: read this entire file first, then execute each section in order. Every command is provided. Every file path is absolute. Every credential is referenced by location, not value.

---

## Prerequisites

### Server (Hetzner - already running)
- Ubuntu Linux (admin user)
- Python 3.10+
- Flask + Gunicorn installed
- Repo cloned at: `/home/admin/clawd/openclaw-computer-vision/`

### Mac (Jonas's MacBook)
- macOS (Apple Silicon)
- Homebrew installed
- Chrome browser
- Git repos in home directory

---

## Part 1: Server Setup

The server receives activity data from Jonas's Mac and stores it for JC to read.

### 1.1 Verify repo is cloned

```bash
ls /home/admin/clawd/openclaw-computer-vision/server/context-receiver.py
```

If not found:
```bash
cd /home/admin/clawd
GIT_SSH_COMMAND="ssh -i ~/.ssh/github_bumpkingsol" git clone git@github-bumpkingsol:bumpkingsol/openclaw-computer-vision.git
```

### 1.2 Install Python dependencies

```bash
pip3 install --break-system-packages -r /home/admin/clawd/openclaw-computer-vision/server/requirements.txt
```

### 1.3 Check for auth token

The auth token should already be in `/home/admin/clawd/.env`. Verify:

```bash
grep '^CONTEXT_BRIDGE_TOKEN=' /home/admin/clawd/.env
```

If missing, generate one:
```bash
umask 077
TOKEN=$(openssl rand -hex 32)
touch /home/admin/clawd/.env
chmod 600 /home/admin/clawd/.env
echo "CONTEXT_BRIDGE_TOKEN=$TOKEN" >> /home/admin/clawd/.env
echo "CONTEXT_BRIDGE_DB=/home/admin/clawd/data/context-bridge.db" >> /home/admin/clawd/.env
echo "CONTEXT_BRIDGE_PORT=7890" >> /home/admin/clawd/.env
echo "Generated token and stored it in /home/admin/clawd/.env"
```

Retrieve the token when needed with:
```bash
grep '^CONTEXT_BRIDGE_TOKEN=' /home/admin/clawd/.env | cut -d= -f2
```

### 1.4 Create data directory

```bash
mkdir -p /home/admin/clawd/data
mkdir -p /home/admin/clawd/memory/activity-digest
```

### 1.5 Generate TLS certificates (if not already done)

```bash
CERT_DIR="/home/admin/clawd/data/certs"
SERVER_IP="$(hostname -I | awk '{print $1}')"
SERVER_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"
if [ ! -f "$CERT_DIR/context-bridge.pem" ] || ! openssl x509 -in "$CERT_DIR/context-bridge.pem" -noout -ext subjectAltName 2>/dev/null | grep -q "$SERVER_IP"; then
  openssl req -x509 -newkey rsa:4096 \
    -keyout "$CERT_DIR/context-bridge-key.pem" \
    -out "$CERT_DIR/context-bridge.pem" \
    -days 365 -nodes \
    -subj "/CN=$SERVER_HOSTNAME/O=OpenClaw" \
    -addext "subjectAltName=DNS:$SERVER_HOSTNAME,DNS:localhost,IP:$SERVER_IP,IP:127.0.0.1"
  chmod 644 "$CERT_DIR/context-bridge.pem"
  chmod 600 "$CERT_DIR/context-bridge-key.pem"
fi
```

### 1.6 Initialize the database

```bash
cd /home/admin/clawd/openclaw-computer-vision/server
CONTEXT_BRIDGE_DB=/home/admin/clawd/data/context-bridge.db python3 -c "
import sys; sys.path.insert(0, '.')
exec(open('context-receiver.py').read().split(\"if __name__\")[0])
init_db()
print('DB initialized')
"
```

### 1.7 Start the receiver

```bash
bash /home/admin/clawd/openclaw-computer-vision/server/setup-server.sh
```

Or, if the service is already installed, restart it:
```bash
sudo systemctl restart context-bridge
```

### 1.8 Verify the server is running

```bash
TOKEN=$(grep '^CONTEXT_BRIDGE_TOKEN=' /home/admin/clawd/.env | cut -d= -f2)
curl -sf --cacert /home/admin/clawd/data/certs/context-bridge.pem \
  -H "Authorization: Bearer $TOKEN" \
  https://localhost:7890/context/health
```

Expected output:
```json
{"status": "ok", "capture_status": "no_data", "total_rows": 0, ...}
```

### 1.9 Test with a simulated push

```bash
TOKEN=$(grep '^CONTEXT_BRIDGE_TOKEN=' /home/admin/clawd/.env | cut -d= -f2)
curl -sf --cacert /home/admin/clawd/data/certs/context-bridge.pem \
  -X POST https://localhost:7890/context/push \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "ts": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
    "app": "TestApp",
    "window_title": "Test Window",
    "idle_state": "active",
    "idle_seconds": 0
  }'
```

Expected: `{"status": "ok"}`

### 1.10 Ensure auto-start on reboot

Check systemd:
```bash
sudo systemctl status context-bridge
```

If missing:
```bash
sudo cp /home/admin/clawd/openclaw-computer-vision/server/context-bridge.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now context-bridge
```

### 1.11 Open firewall port (if needed)

The Mac needs to reach port 7890 on this server. If using UFW:
```bash
sudo ufw allow 7890/tcp
```

---

## Part 2: Mac Setup

**This part runs on Jonas's MacBook.** If you're an agent on the server, provide these instructions to Jonas.

### 2.1 Get server details

You need two things from the server:
1. **Server IP or hostname**: Check with `hostname -I` on the server
2. **Auth token**: `grep '^CONTEXT_BRIDGE_TOKEN=' /home/admin/clawd/.env | cut -d= -f2`
3. **TLS cert PEM** (for self-signed deployments): `/home/admin/clawd/data/certs/context-bridge.pem`

### 2.2 Clone the repo on Mac

```bash
cd ~
git clone git@github.com:bumpkingsol/openclaw-computer-vision.git
```

### 2.3 Install fswatch

```bash
brew install fswatch
```

### 2.4 Run the installer

```bash
cd ~/openclaw-computer-vision
bash mac-daemon/install.sh https://SERVER_IP:7890/context/push ~/Downloads/context-bridge.pem
```

Replace `SERVER_IP` with the actual server IP. The installer will prompt for the auth token securely if you do not pass it as an argument.

### 2.5 Grant macOS permissions

After installation, go to **System Settings > Privacy & Security** and grant:

1. **Accessibility**: Add Terminal (or your terminal app)
   - Path: Privacy & Security > Accessibility
   - Required for: window title capture, app name capture

2. **Automation**: Allow Terminal to control Google Chrome
   - Path: Privacy & Security > Automation
   - Required for: Chrome URL capture
   - Note: This permission prompt may appear automatically on first run

3. **Full Disk Access** (recommended): Add Terminal
   - Path: Privacy & Security > Full Disk Access
   - Required for: macOS notification capture
   - Without this: everything works except notification capture

### 2.6 Verify the daemon is running

```bash
launchctl list | grep context-bridge
```

Should show two entries:
- `com.openclaw.context-bridge` (main daemon)
- `com.openclaw.context-bridge-fswatch` (file watcher)

### 2.7 Check logs

```bash
tail -f /tmp/context-bridge.log
```

### 2.8 Verify data is reaching the server

On the **server**, run:
```bash
TOKEN=$(grep '^CONTEXT_BRIDGE_TOKEN=' /home/admin/clawd/.env | cut -d= -f2)
curl -sf --cacert /home/admin/clawd/data/certs/context-bridge.pem \
  -H "Authorization: Bearer $TOKEN" \
  https://localhost:7890/context/health
```

Should show `"capture_status": "healthy"` and `"total_rows"` increasing.

Or use the query tool:
```bash
cd /home/admin/clawd/openclaw-computer-vision/server
CONTEXT_BRIDGE_DB=/home/admin/clawd/data/context-bridge.db python3 context-query.py now
```

---

## Part 3: Verify End-to-End

### 3.1 On the server, check current state

```bash
cd /home/admin/clawd/openclaw-computer-vision/server
CONTEXT_BRIDGE_DB=/home/admin/clawd/data/context-bridge.db python3 context-query.py now
CONTEXT_BRIDGE_DB=/home/admin/clawd/data/context-bridge.db python3 context-query.py today
```

### 3.2 Run a digest

```bash
cd /home/admin/clawd/openclaw-computer-vision/server
CONTEXT_BRIDGE_DB=/home/admin/clawd/data/context-bridge.db python3 context-digest.py --dry-run
```

### 3.3 Run the watchdog

```bash
cd /home/admin/clawd/openclaw-computer-vision/server
CONTEXT_BRIDGE_DB=/home/admin/clawd/data/context-bridge.db python3 watchdog.py
```

### 3.4 Test a handoff

```bash
TOKEN=$(grep CONTEXT_BRIDGE_TOKEN /home/admin/clawd/.env | cut -d= -f2)
curl -sf -X POST http://localhost:7890/context/handoff \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"project": "prescrivia", "task": "test-task", "message": "test handoff"}'
```

---

## Part 4: Ongoing Operations

### Digest cron (server side)

Add to crontab for 3x daily digests:
```bash
(crontab -l 2>/dev/null; echo "0 10,16,23 * * * cd /home/admin/clawd/openclaw-computer-vision/server && CONTEXT_BRIDGE_DB=/home/admin/clawd/data/context-bridge.db python3 context-digest.py >> /tmp/context-digest.log 2>&1") | crontab -
```

### Watchdog cron (server side)

Add to crontab for 15-minute watchdog checks:
```bash
(crontab -l 2>/dev/null; echo "*/15 * * * * cd /home/admin/clawd/openclaw-computer-vision/server && CONTEXT_BRIDGE_DB=/home/admin/clawd/data/context-bridge.db python3 watchdog.py --json >> /tmp/context-watchdog.log 2>&1") | crontab -
```

### Stopping the daemon (Mac side)

```bash
launchctl unload ~/Library/LaunchAgents/com.openclaw.context-bridge.plist
launchctl unload ~/Library/LaunchAgents/com.openclaw.context-bridge-fswatch.plist
```

### Restarting the daemon (Mac side)

```bash
launchctl unload ~/Library/LaunchAgents/com.openclaw.context-bridge.plist
launchctl load ~/Library/LaunchAgents/com.openclaw.context-bridge.plist
```

### Viewing server logs

```bash
tail -f /tmp/context-bridge-server.log
```

### Checking database size

```bash
ls -lh /home/admin/clawd/data/context-bridge.db
```

### Manual purge (if needed)

```bash
cd /home/admin/clawd/openclaw-computer-vision/server
CONTEXT_BRIDGE_DB=/home/admin/clawd/data/context-bridge.db python3 -c "
import sqlite3
db = sqlite3.connect('/home/admin/clawd/data/context-bridge.db')
deleted = db.execute(\"DELETE FROM activity_stream WHERE created_at < datetime('now', '-48 hours')\").rowcount
db.commit()
print(f'Purged {deleted} rows')
"
```

---

## File Reference

| File | Location | Purpose |
|------|----------|---------|
| `PURPOSE.md` | Repo root | Why this exists |
| `ARCHITECTURE.md` | Repo root | System design |
| `DESIGN.md` | Repo root | Technical decisions |
| `ISSUES.md` | Repo root | Known gaps and risks |
| `ROADMAP.md` | Repo root | Build phases |
| `CLAUDE.md` | Repo root | Agent onboarding (Claude) |
| `AGENTS.md` | Repo root | Agent onboarding (other) |
| `mac-daemon/context-daemon.sh` | Mac: `/usr/local/bin/context-bridge-daemon.sh` | Main capture script |
| `mac-daemon/fswatch-projects.sh` | Mac: `/usr/local/bin/context-bridge-fswatch.sh` | File change watcher |
| `mac-daemon/install.sh` | Run from repo | Mac installer |
| `mac-daemon/com.openclaw.context-bridge.plist` | Mac: `~/Library/LaunchAgents/` | Daemon launchd config |
| `mac-daemon/com.openclaw.context-bridge-fswatch.plist` | Mac: `~/Library/LaunchAgents/` | fswatch launchd config |
| `server/context-receiver.py` | Server | HTTP endpoint + SQLite |
| `server/context-digest.py` | Server | Daily summary processor |
| `server/context-query.py` | Server | CLI query tool |
| `server/watchdog.py` | Server | Daemon health checker |
| `server/start.sh` | Server | Startup script |
| `scripts/install-hooks.sh` | Run from repo on Mac | Git hook installer |

## Credential Locations

| Credential | Location | Notes |
|-----------|----------|-------|
| Auth token (server) | `/home/admin/clawd/.env` as `CONTEXT_BRIDGE_TOKEN` | Generated during setup |
| Auth token (Mac) | macOS Keychain, service: `context-bridge`, account: `token` | Stored by installer |
| TLS cert | `/home/admin/clawd/data/certs/context-bridge.pem` | Self-signed, 365 days |
| TLS key | `/home/admin/clawd/data/certs/context-bridge-key.pem` | Permissions: 600 |
| DB | `/home/admin/clawd/data/context-bridge.db` | Permissions: 600 |

## Troubleshooting

| Problem | Check | Fix |
|---------|-------|-----|
| No data arriving | `TOKEN=$(grep CONTEXT_BRIDGE_TOKEN /home/admin/clawd/.env \| cut -d= -f2) && curl -H "Authorization: Bearer $TOKEN" localhost:7890/context/health` | Is receiver running? Check `/tmp/context-bridge-server.log` |
| Auth failures | Check token matches on both sides | Regenerate: `openssl rand -hex 32` and update both |
| AppleScript errors | `tail /tmp/context-bridge-error.log` | Grant Accessibility permission in System Settings |
| Chrome URLs empty | Check Automation permission | System Settings > Privacy > Automation > Terminal > Chrome |
| Notifications empty | Check Full Disk Access | System Settings > Privacy > Full Disk Access > Terminal |
| Daemon not running | `launchctl list \| grep context` | Reload plist: `launchctl load ~/Library/LaunchAgents/com.openclaw.context-bridge.plist` |
| fswatch not working | `which fswatch` | `brew install fswatch` |
| Server unreachable | Check firewall | `ufw allow 7890/tcp` or check server IP changed |
| DB locked errors | Multiple writers | WAL mode should handle this. Restart receiver. |
