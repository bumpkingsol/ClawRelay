#!/bin/bash
# OpenClaw Context Bridge - File Change Watcher
# Runs as a persistent background process watching project directories
# Writes changes to a log file that the main daemon reads and flushes

set -euo pipefail

LOG="$HOME/.context-bridge/fswatch-changes.log"
mkdir -p "$HOME/.context-bridge"

# Project directories to watch (add more as needed)
WATCH_DIRS=()
for dir in "$HOME"/prescrivia "$HOME"/leverwork "$HOME"/jsvcapital "$HOME"/sonopeace "$HOME"/clawd "$HOME"/aeoa-studio "$HOME"/nilsy-astro; do
  if [ -d "$dir" ]; then
    WATCH_DIRS+=("$dir")
  fi
done

if [ ${#WATCH_DIRS[@]} -eq 0 ]; then
  echo "No project directories found to watch."
  exit 1
fi

echo "Watching ${#WATCH_DIRS[@]} project directories for file changes..."

# fswatch with filters: only source files, ignore node_modules/.git/build
fswatch -r \
  --exclude '\.git' \
  --exclude 'node_modules' \
  --exclude '\.next' \
  --exclude 'dist' \
  --exclude 'build' \
  --exclude '\.DS_Store' \
  --exclude '__pycache__' \
  --include '\.(ts|tsx|js|jsx|py|md|json|astro|css|html|sql|sh)$' \
  "${WATCH_DIRS[@]}" | while read -r changed_file; do
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|$changed_file" >> "$LOG"
done
