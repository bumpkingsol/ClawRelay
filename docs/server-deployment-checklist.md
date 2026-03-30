# Server Deployment Checklist

Everything here must be done on the VPS (`ssh user@<server>`). These are tasks that cannot be performed from the operator's Mac.

## 1. Pull latest code

```bash
cd /home/user/clawrelay/openclaw-computer-vision
git pull origin main
```

## 2. Install SQLCipher system package

```bash
sudo apt-get update
sudo apt-get install -y sqlcipher libsqlcipher-dev
```

## 3. Install Python dependencies

```bash
cd /home/user/clawrelay/openclaw-computer-vision/server
pip3 install -r requirements.txt
```

This installs `pysqlcipher3` which provides encrypted SQLite. If `pysqlcipher3` fails to build, ensure `libsqlcipher-dev` is installed (step 2).

## 4. Run server setup (generates TLS certs if missing)

```bash
cd /home/user/clawrelay/openclaw-computer-vision
bash server/setup-server.sh
```

This will:
- Generate a self-signed TLS cert at `/home/user/clawrelay/data/certs/context-bridge.pem`
- Install/restart the systemd service (gunicorn with `--certfile`/`--keyfile`)
- Verify the auth token exists in `.env`

## 5. Verify HTTPS is working

```bash
TOKEN=$(grep '^CONTEXT_BRIDGE_TOKEN=' /home/user/clawrelay/.env | cut -d= -f2)
curl -sk https://localhost:7890/context/health -H "Authorization: Bearer $TOKEN"
```

Expected: `{"status": "ok", "db_encrypted": true, ...}`

## 6. Copy the TLS cert to the operator's Mac

From the server, display the cert:
```bash
cat /home/user/clawrelay/data/certs/context-bridge.pem
```

On the operator's Mac, save it:
```bash
# Paste the cert content into this file:
nano ~/.context-bridge/server-ca.pem
chmod 600 ~/.context-bridge/server-ca.pem
```

## 7. Switch Mac daemon to HTTPS

On the operator's Mac:
```bash
# Update the server URL
echo "https://<TAILSCALE_IP>:7890/context/push" > ~/.context-bridge/server-url

# Test the connection
TOKEN=$(security find-generic-password -s "context-bridge" -a "token" -w)
curl -v --cacert ~/.context-bridge/server-ca.pem \
  https://<TAILSCALE_IP>:7890/context/health \
  -H "Authorization: Bearer $TOKEN"
```

The daemon will automatically use `--cacert server-ca.pem` for all requests (built into `curl_tls_args()`).

## 8. Drop and recreate the database (for SQLCipher migration)

The existing unencrypted DB cannot be read by SQLCipher. Since raw data has 48h retention, simply delete and let it recreate:

```bash
sudo systemctl stop context-bridge
rm /home/user/clawrelay/data/context-bridge.db
sudo systemctl start context-bridge
```

The daemon will repopulate within 2 minutes.

## 9. Install crontab entries

```bash
crontab -e
```

Add:
```cron
# Context Bridge - staleness watchdog (every 5 min)
*/5 * * * * cd /home/user/clawrelay/openclaw-computer-vision/server && bash staleness-watchdog.sh

# Context Bridge - digests (10:00, 16:00, 23:00 CET = 09:00, 15:00, 22:00 UTC)
0 9 * * * cd /home/user/clawrelay/openclaw-computer-vision/server && python3 context-digest.py >> /var/log/context-digest.log 2>&1
0 15 * * * cd /home/user/clawrelay/openclaw-computer-vision/server && python3 context-digest.py >> /var/log/context-digest.log 2>&1
0 22 * * * cd /home/user/clawrelay/openclaw-computer-vision/server && python3 context-digest.py >> /var/log/context-digest.log 2>&1
```

## 10. Verify everything

```bash
# Service running?
sudo systemctl status context-bridge

# HTTPS responding?
curl -sk https://localhost:7890/context/health -H "Authorization: Bearer $TOKEN"

# DB encrypted?
sqlite3 /home/user/clawrelay/data/context-bridge.db "SELECT 1;"
# ^ Should FAIL (file is encrypted)

# Cron installed?
crontab -l | grep context
```

---

## Token Rotation (when needed)

On the server:
```bash
cd /home/user/clawrelay/openclaw-computer-vision
bash server/setup-server.sh rotate-token
sudo systemctl restart context-bridge
```

On the operator's Mac (using the token printed by the command above):
```bash
security delete-generic-password -s "context-bridge" -a "token" 2>/dev/null
security add-generic-password -s "context-bridge" -a "token" -w "NEW_TOKEN_HERE"
```

## TLS Cert Renewal (annually)

The self-signed cert is valid for 365 days. To regenerate:

On the server:
```bash
rm /home/user/clawrelay/data/certs/context-bridge*.pem
bash server/setup-server.sh
```

Then copy the new cert to the Mac (step 6) and verify (step 7).
