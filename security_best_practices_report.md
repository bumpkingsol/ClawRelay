# Security Best Practices Report

## Executive Summary

I reviewed the repo as a Python/Flask backend plus bash-based macOS daemon/install tooling, using the Flask security guidance from the requested `security-best-practices` skill and general secure shell handling for the daemon scripts.

The highest-risk issues are concentrated around the system's trust boundary and sensitive-data handling:

- The server can fail open and accept unauthenticated writes if `CONTEXT_BRIDGE_TOKEN` is missing.
- The documented production service runs the Flask development server instead of Gunicorn.
- The daemon captures and transmits clipboard contents even though the architecture docs say clipboard content is not captured.
- The shared Bearer token is copied into every installed git hook as plaintext, expanding the blast radius of a single credential leak.

I found 6 actionable findings total:

- High: 4
- Medium: 2

## High Severity

### OCV-001
- Rule ID: FLASK-CONFIG-001 / access-control fail-closed
- Severity: High
- Location: `server/context-receiver.py` lines 21, 100-106
- Evidence:

```python
AUTH_TOKEN = os.environ.get('CONTEXT_BRIDGE_TOKEN', '')

def verify_auth(req):
    if not AUTH_TOKEN:
        logger.warning("No AUTH_TOKEN configured - accepting all requests")
        return True
```

- Impact: If the environment variable is missing or the service starts with a bad environment, any host that can reach the receiver can inject fake activity, commits, or handoffs and poison the agent's operational context.
- Fix: Fail closed. Refuse to start the app if `CONTEXT_BRIDGE_TOKEN` is unset, or reject all protected routes with a 503 until configuration is fixed.
- Mitigation: Restrict network exposure to a private interface or VPN until the app is changed to fail closed.
- False positive notes: If another layer guarantees the variable is always present, the risk is reduced, but the application code still violates the repo's own design assumption that token auth is the security boundary.

### OCV-002
- Rule ID: FLASK-DEPLOY-001
- Severity: High
- Location: `server/context-bridge.service` line 10; `server/context-receiver.py` lines 271-275
- Evidence:

```ini
ExecStart=/usr/bin/python3 /home/user/clawrelay/openclaw-computer-vision/server/context-receiver.py
```

```python
if __name__ == '__main__':
    init_db()
    port = int(os.environ.get('CONTEXT_BRIDGE_PORT', 7890))
    app.run(host='0.0.0.0', port=port, debug=False)
```

- Impact: The production systemd unit is running Flask's development server, which Flask's own deployment guidance treats as unsuitable for production hardening and resilience.
- Fix: Run the app with Gunicorn in the systemd unit, for example `gunicorn --bind 0.0.0.0:7890 context-receiver:app`, and keep `app.run()` for local development only.
- Mitigation: Put the service behind a reverse proxy with buffering and request limits until the runtime is replaced.
- False positive notes: If this service file is only for local testing, severity drops, but `server/setup-server.sh` installs it as the production systemd unit on the VPS.

### OCV-003
- Rule ID: Sensitive data minimization / repo design mismatch
- Severity: High
- Location: `mac-daemon/context-daemon.sh` lines 171-198 and 326-349; `server/context-receiver.py` lines 49-50 and 126-141; `ARCHITECTURE.md` lines 218-222
- Evidence:

```bash
CURRENT_CLIP=$(pbpaste 2>/dev/null | head -c 2000 || echo "")
...
CLIPBOARD_CHANGED="true"
...
CLIPBOARD_CONTENT="$FILTERED_CLIP"
```

```python
            clipboard TEXT,
            clipboard_changed INTEGER DEFAULT 0,
...
        data.get('clipboard'),
        1 if data.get('clipboard_changed') else 0,
```

```md
**Not captured at all:**
- Clipboard content (future consideration)
```

- Impact: Secrets and private data copied to the clipboard can leave the Mac and be stored server-side even when they do not match the current regex redaction patterns.
- Fix: Disable clipboard capture by default and make it an explicit opt-in feature; if clipboard awareness is still needed, store only a boolean or content hash indicating that the clipboard changed.
- Mitigation: Immediately stop persisting clipboard content on the server even if the daemon still computes local change detection.
- False positive notes: If clipboard capture is now an intentional product decision, the docs need to be updated, but the current implementation still carries materially higher sensitivity than the design claims.

### OCV-004
- Rule ID: Secret handling / credential sprawl
- Severity: High
- Location: `scripts/install-hooks.sh` lines 15-45 and 67-69; `mac-daemon/install.sh` lines 68-73; `DESIGN.md` lines 316-318
- Evidence:

```bash
curl -sf -X POST "__SERVER_URL__" \
  -H "Authorization: Bearer __AUTH_TOKEN__" \
```

```bash
HOOK_CONTENT=$(echo "$HOOK_CONTENT" | sed "s|__AUTH_TOKEN__|$AUTH_TOKEN|g")
```

```md
- Authenticated with strong pre-shared Bearer token (stored in macOS Keychain on Mac side, `.env` on server side)
```

- Impact: The shared Bearer token is duplicated into plaintext hook files across many repos, so any leak of one hook file is enough to forge authenticated requests to the server.
- Fix: Make the hook load the token from Keychain at runtime, or from a single owner-only file under `~/.context-bridge/`, instead of embedding the token literal into each hook.
- Mitigation: Rotate the current token after removing inline hook secrets, because the existing value should be treated as widely exposed on disk.
- False positive notes: The hook files are local and not normally committed, so this is not automatically a public leak, but it still violates the repo's stated secret-storage model and needlessly increases exposure.

## Medium Severity

### OCV-005
- Rule ID: Local sensitive data storage hardening
- Severity: Medium
- Location: `mac-daemon/context-daemon.sh` lines 12-20, 156-169, 171-198, 249-274, 368-383; `mac-daemon/install.sh` lines 46-48 and 53-56
- Evidence:

```bash
CMD_LOG="$HOME/.context-bridge-cmds.log"
LOCAL_DB="$HOME/.context-bridge/local.db"
...
mkdir -p "$HOME/.context-bridge"
```

```bash
preexec() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|$(pwd)|$1" >> ~/.context-bridge-cmds.log; }
```

```bash
sqlite3 "$LOCAL_DB" "INSERT INTO queue (payload) VALUES (...)"
```

- Impact: Raw command logs, queued payloads, notification text, and other sensitive local artifacts are created without explicit owner-only permissions, so their confidentiality depends on the user's ambient `umask`.
- Fix: Set `umask 077` at the start of the daemon and installer, `chmod 700 ~/.context-bridge`, and `chmod 600` the queue DB, command log, fswatch log, and hash files after creation.
- Mitigation: Limit what is written to disk before redaction, especially the raw preexec log.
- False positive notes: If launchd or the shell is already running with a strict `umask`, this may already be partially mitigated, but the code does not enforce the intended protection.

### OCV-006
- Rule ID: Access control / unnecessary unauthenticated read surface
- Severity: Medium
- Location: `server/context-receiver.py` lines 223-262; `DESIGN.md` lines 331-333
- Evidence:

```python
@app.route('/context/health', methods=['GET'])
def health():
    ...
    return jsonify({
        'status': 'ok',
        'capture_status': capture_status,
        'total_rows': count,
        'recent_captures_10min': recent,
        'latest_activity': latest[0] if latest else None,
        'latest_idle_state': last_active[1] if last_active else None
    })
```

```python
except Exception as e:
    return jsonify({'status': 'error', 'detail': str(e)}), 500
```

```md
- No web UI, no external access, no API for querying from outside
- Server endpoint only accepts authenticated POST requests, no GET/read access from outside
```

- Impact: Anyone who can reach the server can learn whether captures are flowing, whether the operator appears active or idle, and potentially receive internal error details.
- Fix: Require the same Bearer auth on `/context/health`, or bind a separate unauthenticated health check to loopback/private monitoring only and remove detailed error strings from responses.
- Mitigation: Restrict ingress to the server so the health endpoint is not reachable from the public internet.
- False positive notes: If the service is only reachable over Tailscale, localhost, or a tightly controlled firewall, the exposure is smaller, but that restriction is not visible in application code.

## Notes

- I did not find a shell-specific reference file in the skill bundle, so the daemon/install findings above use general secure shell handling and the repo's own security promises as the standard.
- I did not treat the lack of TLS/HSTS changes as a standalone finding because the skill explicitly warns against over-reporting transport issues that may be handled outside the app or intentionally vary between dev and production.

## Recommended Fix Order

1. OCV-001: Make the receiver fail closed when `CONTEXT_BRIDGE_TOKEN` is missing.
2. OCV-004: Remove plaintext tokens from git hooks and rotate the shared token.
3. OCV-003: Disable clipboard capture by default.
4. OCV-002: Move the production unit to Gunicorn.
5. OCV-005: Lock down local file permissions on Mac artifacts.
6. OCV-006: Protect or internalize `/context/health`.
