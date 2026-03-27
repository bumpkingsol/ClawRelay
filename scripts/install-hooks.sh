#!/bin/bash
# Install git post-commit hooks on all repos
# Run on Jonas's Mac: bash install-hooks.sh <server-url-or-endpoint>

set -euo pipefail
umask 077

SERVER_URL="${1:-}"

if [ -z "$SERVER_URL" ]; then
  echo "Usage: bash install-hooks.sh <server-url-or-endpoint>"
  exit 1
fi

normalize_commit_url() {
  case "$1" in
    */context/commit)
      echo "$1"
      ;;
    */context/push)
      echo "${1%/context/push}/context/commit"
      ;;
    *)
      echo "${1%/}/context/commit"
      ;;
  esac
}

COMMIT_URL=$(normalize_commit_url "$SERVER_URL")

HOOK_TEMPLATE=$(mktemp)
cat > "$HOOK_TEMPLATE" <<'HOOKEOF'
#!/bin/bash
# OpenClaw Context Bridge - post-commit hook
set -euo pipefail

normalize_commit_url() {
  case "$1" in
    */context/commit)
      echo "$1"
      ;;
    */context/push)
      echo "${1%/context/push}/context/commit"
      ;;
    *)
      echo "${1%/}/context/commit"
      ;;
  esac
}

SERVER_URL_FILE="$HOME/.context-bridge/server-url"
COMMIT_URL="__COMMIT_URL__"
if [ -f "$SERVER_URL_FILE" ]; then
  CONFIGURED_URL=$(cat "$SERVER_URL_FILE" 2>/dev/null || echo "")
  if [ -n "$CONFIGURED_URL" ]; then
    COMMIT_URL=$(normalize_commit_url "$CONFIGURED_URL")
  fi
fi

AUTH_TOKEN=$(security find-generic-password -s "context-bridge" -a "token" -w 2>/dev/null || echo "")
if [ -z "$AUTH_TOKEN" ]; then
  exit 0
fi

REPO=$(basename "$(git rev-parse --show-toplevel)")
BRANCH=$(git branch --show-current)
MSG=$(git log -1 --pretty=%s)
DIFF_STAT=$(git diff --stat HEAD~1 2>/dev/null || echo "initial commit")
AUTHOR=$(git log -1 --pretty=%an)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Only capture Jonas's commits
if [[ "$AUTHOR" != *"Jonas"* && "$AUTHOR" != *"jonas"* && "$AUTHOR" != *"clawrelay-org"* && "$AUTHOR" != *"bumpy"* ]]; then
  exit 0
fi

PAYLOAD=$(REPO="$REPO" BRANCH="$BRANCH" MSG="$MSG" DIFF_STAT="$(printf '%s' "$DIFF_STAT" | head -5)" TS="$TS" python3 -c '
import json, os
print(json.dumps({
    "repo": os.environ["REPO"],
    "branch": os.environ["BRANCH"],
    "message": os.environ["MSG"],
    "diff_stat": os.environ["DIFF_STAT"],
    "timestamp": os.environ["TS"],
}))
')

curl -sf -X POST "$COMMIT_URL" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" &>/dev/null &
HOOKEOF
HOOK_CONTENT=$(sed "s|__COMMIT_URL__|$COMMIT_URL|g" "$HOOK_TEMPLATE")
rm -f "$HOOK_TEMPLATE"

# Find all git repos in home directory (max depth 3)
REPOS=$(find "$HOME" -maxdepth 3 -name ".git" -type d 2>/dev/null || true)
if git rev-parse --git-dir >/dev/null 2>&1; then
  CURRENT_GIT_DIR=$(cd "$(git rev-parse --git-dir)" && pwd)
  case "$REPOS" in
    *"$CURRENT_GIT_DIR"*)
      ;;
    *)
      REPOS="${REPOS}${REPOS:+$'\n'}$CURRENT_GIT_DIR"
      ;;
  esac
fi

INSTALLED=0
while IFS= read -r GIT_DIR; do
  [ -n "$GIT_DIR" ] || continue
  HOOK_PATH="$GIT_DIR/hooks/post-commit"
  REPO_PATH=$(dirname "$GIT_DIR")
  REPO_NAME=$(basename "$REPO_PATH")
  
  # Skip if already has our hook
  if [ -f "$HOOK_PATH" ] && grep -q "Context Bridge" "$HOOK_PATH" 2>/dev/null; then
    echo "  Skip: $REPO_NAME (hook already installed)"
    continue
  fi
  
  # If existing hook, append ours
  if [ -f "$HOOK_PATH" ]; then
    if { echo "" >> "$HOOK_PATH" && echo "$HOOK_CONTENT" >> "$HOOK_PATH"; } 2>/dev/null; then
      echo "  Appended: $REPO_NAME"
      INSTALLED=$((INSTALLED + 1))
    else
      echo "  Skip: $REPO_NAME (unable to update hook)"
    fi
  else
    if { echo "$HOOK_CONTENT" > "$HOOK_PATH" && chmod +x "$HOOK_PATH"; } 2>/dev/null; then
      echo "  Installed: $REPO_NAME"
      INSTALLED=$((INSTALLED + 1))
    else
      echo "  Skip: $REPO_NAME (unable to install hook)"
    fi
  fi
done <<EOF
$REPOS
EOF

echo ""
echo "Installed hooks in $INSTALLED repositories."
