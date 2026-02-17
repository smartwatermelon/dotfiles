#!/usr/bin/env bash
# Service Management
# Handles background service lifecycle (Headroom proxy, etc.)
# Start Headroom proxy if not already running
# Headroom compresses Claude Code context/token usage transparently
# Uses macOS LaunchAgent for proper service lifecycle management
_start_headroom_proxy() {
  # Set port with default
  export HEADROOM_PROXY_PORT="${HEADROOM_PROXY_PORT:-8787}"

  # Graceful degradation: skip if tool not installed
  if ! command -v headroom &>/dev/null; then
    return 0
  fi

  # Fast path: check if already running
  if lsof -ti:"${HEADROOM_PROXY_PORT}" &>/dev/null; then
    export ANTHROPIC_BASE_URL="http://localhost:${HEADROOM_PROXY_PORT}"
    return 0
  fi

  # Not running - load LaunchAgent (idempotent, won't error if already loaded)
  local plist_path="${HOME}/Library/LaunchAgents/com.headroom.proxy.plist"
  if [[ -f "${plist_path}" ]]; then
    launchctl bootstrap "gui/$(id -u)" "${plist_path}" 2>/dev/null || true
  fi

  # Set environment variable
  export ANTHROPIC_BASE_URL="http://localhost:${HEADROOM_PROXY_PORT}"
}

# Start Headroom proxy
_start_headroom_proxy
