# ~/.config/bash/owner-tokens.sh (sourced by env.sh; claude-config#659)
#shellcheck shell=bash

# No broad gh login here: smartwatermelon uses the App, NOS its own token.

# Keychain: service gh-token-nightowlstudiollc, account = login name.
# A set GH_TOKEN_NOS is kept; a missing item loads nothing.

_owner_tokens_load() {
  local tok me
  [[ -n "${GH_TOKEN_NOS:-}" ]] && return 0
  command -v security >/dev/null 2>&1 || return 0
  me="$(id -un)" || return 0
  # Bounded: a locked Keychain must not hang shell startup on a dialog.
  # No arrays: an empty one trips set -u in macOS bash 3.2.
  local t=""
  command -v timeout >/dev/null 2>&1 && t="timeout 3"
  tok="$(${t} security find-generic-password -s gh-token-nightowlstudiollc -a "${me}" -w 2>/dev/null)" || return 0
  [[ "${tok}" =~ ^[A-Za-z0-9_]+$ ]] || return 0
  export GH_TOKEN_NOS="${tok}"
}

if [[ $- == *i* ]]; then
  _owner_tokens_load
fi
unset -f _owner_tokens_load
