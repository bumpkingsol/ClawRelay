#!/bin/bash
# OpenClaw Context Bridge - File Change Watcher
# Runs as a persistent background process watching project directories
# Writes changes to a log file that the main daemon reads and flushes

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/context-common.sh"

LOG="$HOME/.context-bridge/fswatch-changes.log"
WATCH_DIRS_FILE="$HOME/.context-bridge/watch-dirs"
mkdir -p "$HOME/.context-bridge"
chmod 700 "$HOME/.context-bridge" 2>/dev/null || true
touch "$LOG"
chmod 600 "$LOG" 2>/dev/null || true

# Project directories to watch. Prefer explicit config, then auto-discover.
WATCH_DIRS=()

add_watch_dir() {
  local dir="$1"
  local existing

  [ -d "$dir" ] || return 0

  for existing in "${WATCH_DIRS[@]:-}"; do
    if [ "$existing" = "$dir" ]; then
      return 0
    fi
  done

  WATCH_DIRS+=("$dir")
}

if [ -f "$WATCH_DIRS_FILE" ]; then
  while IFS= read -r dir; do
    case "$dir" in
      ''|\#*)
        continue
        ;;
    esac
    add_watch_dir "$dir"
  done < "$WATCH_DIRS_FILE"
fi

SEARCH_ROOTS=(
  "$HOME"
  "$HOME/Desktop"
  "$HOME/Desktop/Work/CODING"
  "$HOME/Desktop/Hobby"
  "$HOME/Documents"
  "$HOME/Projects"
  "$HOME/Code"
)

for root in "${SEARCH_ROOTS[@]}"; do
  [ -d "$root" ] || continue
  while IFS= read -r dir; do
    add_watch_dir "$dir"
  done < <(
    find "$root" -maxdepth 5 -type d \
      \( -name 'project-gamma' -o -name 'project-alpha' -o -name 'project-beta' -o -name 'project-delta' -o -name 'clawd' -o -name 'aeoa-studio' -o -name 'nilsy-astro' -o -name 'openclaw-computer-vision' \) \
      2>/dev/null
  )
done

if [ ${#WATCH_DIRS[@]} -eq 0 ]; then
  echo "No project directories found to watch."
  exit 1
fi

echo "Watching ${#WATCH_DIRS[@]} project directories for file changes..."
printf '%s\n' "${WATCH_DIRS[@]}"

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
    if cb_is_paused; then
      continue
    fi
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|$changed_file" >> "$LOG"
done
