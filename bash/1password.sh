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
  # Use timeout if available to guard against Keychain hangs;
  # $(id -un) is more robust than $USER which can be unset/spoofed.
  _op_cmd=(security find-generic-password
    -a "$(id -un)"
    -s "${_OP_KEYCHAIN_SERVICE}"
    -w)
  if command -v timeout &>/dev/null; then
    _op_token="$(timeout 3 "${_op_cmd[@]}" 2>/dev/null || true)"
  else
    _op_token="$("${_op_cmd[@]}" 2>/dev/null || true)"
  fi
  unset _op_cmd

  if [[ -n "${_op_token}" ]]; then
    export OP_SERVICE_ACCOUNT_TOKEN="${_op_token}"
  fi
  unset _op_token
fi
unset _OP_KEYCHAIN_SERVICE

# =========================================================
# GITHUB TOKEN
# =========================================================
# Fetch GH_TOKEN from 1Password at shell startup.
# Direct injection avoids the op shell plugin alias (alias gh="op plugin run -- gh")
# which conflicts with the gh() function wrapper in functions.sh and bypasses
# the pre-merge review enforcement it provides.
if [[ -z "${GH_TOKEN:-}" ]] && [[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
  _gh_token="$(op read "op://Automation/GitHub - CCCLI/Token" 2>/dev/null || true)"
  if [[ -n "${_gh_token}" ]]; then
    export GH_TOKEN="${_gh_token}"
  fi
  unset _gh_token
fi

# =========================================================
# PERSONAL ACCOUNT HELPER
# =========================================================
# Unsets the service account token and signs in interactively.
# Required for scripts that access the Personal vault (e.g. prep-airdrop.sh).
# Usage: opp
opp() {
  (
    unset OP_SERVICE_ACCOUNT_TOKEN
    if ! op whoami &>/dev/null; then
      op signin
    fi
    op "$@"
  )
}
