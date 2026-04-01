#!/bin/bash
# OpenClaw Context Bridge - Shared path and state helpers
# Sourced by context-helperctl.sh and (later) the daemon itself.

set -euo pipefail

cb_dir()                { printf '%s\n' "${HOME}/.context-bridge"; }
cb_bin_dir()            { printf '%s\n' "$(cb_dir)/bin"; }
cb_pause_file()         { printf '%s\n' "$(cb_dir)/pause-until"; }
cb_sensitive_file()     { printf '%s\n' "$(cb_dir)/sensitive-mode"; }
cb_privacy_rules_file() { printf '%s\n' "$(cb_dir)/privacy-rules.json"; }
cb_handoff_outbox_dir() { printf '%s\n' "$(cb_dir)/handoff-outbox"; }
cb_keychain_service_daemon() { printf '%s\n' "context-bridge-daemon"; }
cb_keychain_service_helper() { printf '%s\n' "context-bridge-helper"; }

cb_now_epoch() { date +%s; }

cb_read_keychain_token() {
  local service="${1:-}"
  [ -n "$service" ] || return 1
  security find-generic-password -s "$service" -a "token" -w 2>/dev/null || true
}

cb_is_paused() {
  local pause_file now until
  pause_file="$(cb_pause_file)"
  [ -f "$pause_file" ] || return 1
  until="$(cat "$pause_file" 2>/dev/null || echo "")"
  [ -n "$until" ] || return 1
  now="$(cb_now_epoch)"
  [ "$until" = "indefinite" ] && return 0
  [[ "$until" =~ ^[0-9]+$ ]] || return 1
  [ "$until" -gt "$now" ]
}

cb_is_sensitive_mode() { [ -f "$(cb_sensitive_file)" ]; }
