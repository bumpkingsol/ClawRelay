# OpenClaw Context Bridge - Shell command logger
# Sourced from ~/.zshrc to capture terminal commands.
# Respects pause state: when paused, commands are not logged.
#
# Sensitive mode intentionally does NOT suppress command logging.
# In sensitive mode the daemon reduces capture but shell commands and git
# commits still flow -- only the daemon enforces minimal payloads.
# Pause state is the only full-stop mechanism for all producers.
# See mac-daemon/context-common.sh for canonical pause logic.

context_bridge_log_command() {
  local cb_dir="$HOME/.context-bridge"
  local pause_file="$cb_dir/pause-until"
  if [[ -f "$pause_file" ]]; then
    local until_ts
    until_ts="$(cat "$pause_file" 2>/dev/null)"
    if [[ "$until_ts" == "indefinite" ]] || { [[ "$until_ts" =~ ^[0-9]+$ ]] && (( until_ts > $(date +%s) )); }; then
      return 0
    fi
  fi
  print -r -- "$(date -u +%Y-%m-%dT%H:%M:%SZ)|$(pwd)|$1" >> "$HOME/.context-bridge-cmds.log"
}
preexec() { context_bridge_log_command "$1"; }
