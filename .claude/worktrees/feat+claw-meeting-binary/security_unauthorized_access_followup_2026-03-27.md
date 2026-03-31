# Unauthorized Access Follow-Up Audit

Date: 2026-03-27
Scope: server receiver auth boundary, transport security, Mac installer secret handling, and live local hook/daemon propagation.

## Summary

I did not find any remaining code-level unauthenticated write path in the receiver after this hardening pass.

All four exposed receiver routes now require a valid Bearer token:
- `/context/push`
- `/context/commit`
- `/context/handoff`
- `/context/health`

The fail-open environment bypasses were removed, the receiver now refuses to start without `CONTEXT_BRIDGE_TOKEN`, and the production systemd unit is configured to terminate TLS with Gunicorn instead of listening in plaintext.

## Fixed In This Pass

### Closed: fail-open auth toggles
- File: `server/context-receiver.py`
- Status: fixed
- Detail: removed the insecure no-auth startup path and removed unauthenticated health mode. The receiver now fails closed.

### Closed: plaintext Bearer token exposure during Mac install
- File: `mac-daemon/install.sh`
- Status: fixed
- Detail: the installer now prompts for the token securely when it is not provided, instead of requiring it on the command line by default.

### Closed: missing TLS termination in Gunicorn service
- File: `server/context-bridge.service`
- Status: fixed
- Detail: the systemd service now starts Gunicorn with `--certfile` and `--keyfile`.

### Closed: self-signed TLS trust path missing on the Mac side
- Files: `mac-daemon/context-daemon.sh`, `mac-daemon/install.sh`, `scripts/install-hooks.sh`
- Status: fixed in code
- Detail: the daemon and git commit hooks now use `~/.context-bridge/server-ca.pem` with `curl --cacert` when present, and the installer can copy that PEM into place.

### Closed: existing hooks would silently stay on older security logic
- File: `scripts/install-hooks.sh`
- Status: fixed
- Detail: rerunning the hook installer now updates existing Context Bridge hooks instead of skipping them.

### Closed: weak server-side secret file handling
- File: `server/setup-server.sh`
- Status: fixed
- Detail: `.env` is now created with owner-only permissions and the setup script no longer prints the full token by default.

### Closed: self-signed cert hostname mismatch for IP / localhost checks
- File: `server/setup-server.sh`
- Status: fixed
- Detail: generated certs now include SAN entries for the server hostname, `localhost`, `127.0.0.1`, and the current primary server IP.

## Remaining Findings

### Medium: live remote auth boundary was not independently reachable from this Mac on 2026-03-27
- Status: open verification gap
- Evidence:
  - `https://46.62.236.101:7890/context/push` timed out from this Mac
  - raw TCP checks to `46.62.236.101` on ports `7890`, `443`, and `80` also timed out
- Impact: I could not independently confirm from Jonas's Mac that the deployed server is currently reachable and enforcing the new auth boundary over the network.
- Recommendation: verify directly on the server host or from a network path that can reach the receiver.

### Medium: this Mac does not currently have a pinned server CA PEM installed
- Status: open local configuration gap
- Evidence: `~/.context-bridge/server-ca.pem` is absent
- Impact: if the deployed receiver uses a self-signed certificate, the daemon and commit hooks need that PEM in place to verify the server. If the receiver uses a publicly trusted certificate, this item does not apply.
- Recommendation: copy `/home/admin/clawd/data/certs/context-bridge.pem` from the server to `~/.context-bridge/server-ca.pem`, or rerun the installer with the PEM path.

## Verification Performed

### Local HTTPS runtime test

Using a temporary Gunicorn instance with a temporary self-signed cert that included SANs for `localhost` and `127.0.0.1`:

- unauthenticated `/context/health` returned `401`
- wrong-token `/context/health` returned `401`
- authenticated `/context/health` returned `200`
- unauthenticated `/context/push` returned `401`
- authenticated `/context/push` returned `201`
- unauthenticated `/context/commit` returned `401`
- unauthenticated `/context/handoff` returned `401`
- HTTPS without the trusted CA PEM returned `000` from `curl`

### Data scrubbing check

For an authenticated activity push containing `"clipboard": "secret"`:

- `clipboard_changed` was stored
- the `clipboard` column remained `NULL`
- `raw_payload` did not contain a `"clipboard"` key

### Local live propagation

On Jonas's Mac:

- the active daemon script at `~/.context-bridge/bin/context-bridge-daemon.sh` was refreshed to match the repo
- existing Context Bridge git hooks were updated in local repositories instead of being left on the older template

## Bottom Line

The codebase is now materially stronger against unauthorized access than the prior audit state. The remaining risk is no longer an obvious in-repo auth bypass; it is operational verification of the deployed receiver and, if self-signed TLS is still in use, getting the server PEM onto the Mac so the client can authenticate the server.
