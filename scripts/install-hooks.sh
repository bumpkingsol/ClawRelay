#!/bin/bash
# Install git post-commit hooks on all repos
# Run on Jonas's Mac: bash install-hooks.sh <server-url> <auth-token>

set -euo pipefail

SERVER_URL="${1:-}"
AUTH_TOKEN="${2:-}"

if [ -z "$SERVER_URL" ] || [ -z "$AUTH_TOKEN" ]; then
  echo "Usage: bash install-hooks.sh <server-url> <auth-token>"
  exit 1
fi

HOOK_CONTENT=$(cat << 'HOOKEOF'
#!/bin/bash
# OpenClaw Context Bridge - post-commit hook
REPO=$(basename $(git rev-parse --show-toplevel))
BRANCH=$(git branch --show-current)
MSG=$(git log -1 --pretty=%s)
DIFF_STAT=$(git diff --stat HEAD~1 2>/dev/null || echo "initial commit")
AUTHOR=$(git log -1 --pretty=%an)

# Only capture Jonas's commits
if [[ "$AUTHOR" != *"Jonas"* && "$AUTHOR" != *"jonas"* && "$AUTHOR" != *"bumpkingsol"* && "$AUTHOR" != *"bumpy"* ]]; then
  exit 0
fi

curl -sf -X POST "__SERVER_URL__" \
  -H "Authorization: Bearer __AUTH_TOKEN__" \
  -H "Content-Type: application/json" \
  -d "{
    \"repo\": \"$REPO\",
    \"branch\": \"$BRANCH\",
    \"message\": \"$(echo $MSG | sed 's/"/\\"/g')\",
    \"diff_stat\": \"$(echo $DIFF_STAT | head -5 | sed 's/"/\\"/g')\",
    \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
  }" &>/dev/null &
HOOKEOF
)

# Replace placeholders
HOOK_CONTENT=$(echo "$HOOK_CONTENT" | sed "s|__SERVER_URL__|${SERVER_URL}/context/commit|g")
HOOK_CONTENT=$(echo "$HOOK_CONTENT" | sed "s|__AUTH_TOKEN__|$AUTH_TOKEN|g")

# Find all git repos in home directory (max depth 3)
REPOS=$(find "$HOME" -maxdepth 3 -name ".git" -type d 2>/dev/null)

INSTALLED=0
for GIT_DIR in $REPOS; do
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
    echo "" >> "$HOOK_PATH"
    echo "$HOOK_CONTENT" >> "$HOOK_PATH"
    echo "  Appended: $REPO_NAME"
  else
    echo "$HOOK_CONTENT" > "$HOOK_PATH"
    chmod +x "$HOOK_PATH"
    echo "  Installed: $REPO_NAME"
  fi
  
  INSTALLED=$((INSTALLED + 1))
done

echo ""
echo "Installed hooks in $INSTALLED repositories."
