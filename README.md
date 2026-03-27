# OpenClaw Context Bridge

Real-time activity monitoring from Jonas's Mac → JC's server. Gives JC operational visibility into what Jonas is working on so autonomous actions don't duplicate or conflict.

## Architecture

```
MacBook (daemon)  ──HTTPS──>  Server (receiver)  ──>  JC (agent)
  captures every              stores in SQLite         reads before
  2-3 minutes                 purges after 48h         any autonomous
                              digests persist           action
```

## Components

### Mac Side (`mac-daemon/`)
- `context-daemon.sh` - Main capture script (launchd)
- `install.sh` - One-command installer
- `com.openclaw.context-bridge.plist` - launchd config

### Server Side (`server/`)
- `context-receiver.py` - HTTP endpoint accepting pushes
- `context-digest.py` - Processes raw stream into daily summaries
- `context-query.py` - CLI for querying current state

### Shared
- `scripts/install-hooks.sh` - Git post-commit hook installer

## Setup

### Server
```bash
cd server && pip install -r requirements.txt
CONTEXT_BRIDGE_TOKEN=dev-token python context-receiver.py  # starts on port 7890
```

### Mac
```bash
bash mac-daemon/install.sh https://YOUR_SERVER:7890/context/push /path/to/context-bridge.pem
```

## Security
- Transport: HTTPS with Bearer token auth
- Storage: SQLite, 600 permissions, purged after 48h
- No third-party services, no cloud storage
- Raw data ephemeral, only digests persist

## Design Doc
See [design document](https://github.com/bumpkingsol/openclaw-computer-vision/blob/main/DESIGN.md)
