# ~/.config/bash/1password.sh
#shellcheck shell=bash
# 1Password CLI configuration
# Provides non-interactive authentication for CCCLI, MCP server,
# and gh shell plugin via a service account token stored in macOS Keychain.

# =========================================================
# CONFIGURATION
# =========================================================
# Keychain service name for the 1Password service account token
_OP_KEYCHAIN_SERVICE="op-service-account-claude-automation"

# =========================================================
# SERVICE ACCOUNT AUTH
# =========================================================
# Fetch token from Keychain; enables op CLI to run without
# biometric prompts in non-interactive contexts (CCCLI, MCP).
# Guard prevents redundant Keychain lookups if already set (e.g. CI).
if [[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
  _op_token="$(security find-generic-password \
    -a "$USER" \
    -s "${_OP_KEYCHAIN_SERVICE}" \
    -w 2>/dev/null || true)"

  if [[ -n "${_op_token}" ]]; then
    export OP_SERVICE_ACCOUNT_TOKEN="${_op_token}"
  fi
  unset _op_token
fi
unset _OP_KEYCHAIN_SERVICE

# =========================================================
# SHELL PLUGIN
# =========================================================
# Injects GH_TOKEN for all gh invocations from 1Password.
# No-op until Phase 2 (op plugin init gh) creates this file.
if [[ -f "${HOME}/.config/op/plugins.sh" ]]; then
  #shellcheck source=/dev/null
  source "${HOME}/.config/op/plugins.sh"
fi
