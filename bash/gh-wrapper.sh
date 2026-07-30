#!/usr/bin/env bash
# ~/.config/bash/gh-wrapper.sh
#shellcheck shell=bash
# Canonical implementation of the `gh` identity auto-switch and PR-merge
# guard (pre-merge review + REST/GraphQL merge-bypass blocking). One file,
# two invocation modes:
#
#   1. Sourced from functions.sh: defines gh() as a bash function. This wins
#      over PATH lookup for any bash process — interactive shells (via
#      .bash_profile -> main.sh) and non-interactive ones too, since
#      ~/.claude/settings.json sets BASH_ENV=~/.config/bash/functions.sh so
#      Claude Code's own Bash tool sources it as well.
#   2. Symlinked as ~/.local/bin/gh and executed directly: acts as a
#      standalone wrapper. This is the fallback for anything that reaches
#      `gh` without going through a bash process that has BASH_ENV in
#      effect — GUI apps, LaunchAgents/cron with a stripped environment,
#      editor git integrations, other language runtimes shelling out to
#      `gh`, etc.
#
# _GH_REVIEW_DONE guards against running pre-merge-review.sh twice when both
# layers fire in the same call chain: the bash function runs first, then
# calls `command gh`, which (since ~/.local/bin is early in PATH) finds this
# same file again in standalone-wrapper mode.

_gh_wrapper_review_script="${HOME}/.claude/hooks/pre-merge-review.sh"

# gh has one active account per host (not per repo), unlike git+SSH which
# already resolves the right identity per remote via ~/.ssh/config host
# aliases. This keeps gh in sync with that same per-repo intent: repos owned
# by smartwatermelon use the smartwatermelon account; everything else
# (Beacon repos, etc.) falls back to andrewmrich. Local-only (reads/writes
# gh's config file, no network), so it's cheap to run on every invocation.
# Caveat: this mutates global gh state, so concurrent shells working in
# different-owner repos at the same time can race each other.
_gh_wrapper_sync_identity() {
  local remote_url owner desired current

  remote_url=$(command git config --get remote.origin.url 2>/dev/null)
  [[ -z "${remote_url}" ]] && return 0

  owner=$(printf '%s\n' "${remote_url}" | sed -E 's#^(git@[^:]+:|[a-zA-Z]+://[^/]+/)##; s#/.*##')
  [[ -z "${owner}" ]] && return 0

  if [[ "${owner}" == "smartwatermelon" ]]; then
    desired="smartwatermelon"
  else
    desired="andrewmrich"
  fi

  current=$(awk '/^github\.com:/{f=1} f && /^ *user:/{print $2; exit}' "${HOME}/.config/gh/hosts.yml" 2>/dev/null | tr -d "\"'")

  if [[ -n "${current}" && "${current}" != "${desired}" ]]; then
    if ! command gh auth switch --hostname github.com --user "${desired}" >/dev/null 2>&1; then
      echo "[gh] ERROR: failed to switch identity to '${desired}' (repo owner: '${owner}') — refusing to run as '${current}' instead" >&2
      return 1
    fi
  fi
}

# Find the real `gh` binary, skipping ourselves. Only meaningful in
# standalone-wrapper mode.
_gh_wrapper_find_real_gh() {
  local self
  self="$(realpath "${BASH_SOURCE[0]}")"

  local IFS=':'
  local dir candidate candidate_real
  for dir in ${PATH}; do
    candidate="${dir}/gh"
    if [[ -x "${candidate}" ]]; then
      candidate_real="$(realpath "${candidate}" 2>/dev/null || true)"
      if [[ -n "${candidate_real}" ]] && [[ "${candidate_real}" != "${self}" ]]; then
        printf '%s\n' "${candidate}"
        return 0
      fi
    fi
  done

  printf '[gh-wrapper] Error: Could not find real gh binary in PATH\n' >&2
  return 1
}

# Blocks REST/GraphQL PR-merge bypass vectors that skip pre-merge-review.sh
# and the merge-lock check entirely. Returns 1 if the call should be blocked.
_gh_wrapper_block_bypass() {
  if [[ "${1:-}" == "api" ]] && printf '%s\n' "$*" | grep -qE 'pulls/[0-9]+/merge([[:space:]]|$|[^[:alnum:]_])'; then
    echo "[gh] BLOCKED: Direct REST API PR merge bypasses pre-merge review and merge authorization." >&2
    echo "[gh] This endpoint skips pre-merge-review.sh and the merge-lock check." >&2
    echo "[gh] Use 'gh pr merge <number>' instead." >&2
    echo "[gh] If gh pr merge fails, report the failure and ask the human to merge manually." >&2
    return 1
  fi

  if [[ "${1:-}" == "api" ]] && printf '%s\n' "$*" | grep -qE 'graphql.*mergePullRequest[[:space:]]*\('; then
    echo "[gh] BLOCKED: GraphQL mergePullRequest mutation bypasses pre-merge review and merge authorization." >&2
    echo "[gh] Use 'gh pr merge <number>' instead." >&2
    echo "[gh] If gh pr merge fails, report the failure and ask the human to merge manually." >&2
    return 1
  fi

  return 0
}

# Runs pre-merge-review.sh if this call is `gh pr merge`. Returns 1 to block.
# Parses args past known two-token global flags to find the actual
# subcommand, handling both `gh pr merge NNN` and `gh -R owner/repo pr merge
# NNN`.
#
# $1: "strict" or "warn" — how to react if the review script is missing.
# "strict" (standalone-wrapper mode) fails closed, since that mode is the
# fallback safety net for callers with no other guard layer. "warn"
# (function mode) matches the original bash-function behavior of warning
# and proceeding, since a bash session has other opportunities to catch a
# misconfigured review script.
_gh_wrapper_maybe_review() {
  local missing_script_mode="$1"
  shift

  local sub="" subsub="" skip_next=0 arg
  for arg in "$@"; do
    if [[ "${skip_next}" == "1" ]]; then
      skip_next=0
      continue
    fi
    case "${arg}" in
      -R | --repo | --hostname | --config-dir | --token) skip_next=1 ;;
      --*=*) ;; # --flag=value: single token, no separate value to skip
      -*) ;;    # other single-token flags: skip
      *)
        if [[ -z "${sub}" ]]; then
          sub="${arg}"
        else
          subsub="${arg}"
          break
        fi
        ;;
    esac
  done

  if [[ "${sub}" == "pr" && "${subsub}" == "merge" ]]; then
    if [[ -x "${_gh_wrapper_review_script}" ]]; then
      "${_gh_wrapper_review_script}" "$@" || return 1
    elif [[ "${missing_script_mode}" == "strict" ]]; then
      echo "[gh] ERROR: pre-merge review script not found or not executable: ${_gh_wrapper_review_script}" >&2
      echo "[gh] Refusing to proceed with an unguarded merge." >&2
      return 1
    else
      echo "[gh] Warning: pre-merge review script not found or not executable" >&2
      echo "[gh] Expected: ${_gh_wrapper_review_script}" >&2
      echo "[gh] Proceeding without review..." >&2
    fi
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # --- Standalone-wrapper mode (executed directly, e.g. via the
  # ~/.local/bin/gh symlink) ---
  set -euo pipefail

  REAL_GH="$(_gh_wrapper_find_real_gh)"

  # Note whether this is a help request, but the REST/GraphQL bypass block
  # below must run regardless — `gh api pulls/123/merge --help` must not
  # escape it by appending --help.
  _gh_wrapper_help=0
  for _gh_wrapper_arg in "$@"; do
    if [[ "${_gh_wrapper_arg}" == "--help" || "${_gh_wrapper_arg}" == "-h" ]]; then
      _gh_wrapper_help=1
      break
    fi
  done

  # Safe to skip all three checks when _GH_REVIEW_DONE is set: that only
  # happens when function mode already ran them before calling `command gh`
  # (which lands here). If a future change ever sets _GH_REVIEW_DONE before
  # running those checks in function mode, this skip becomes unsafe — keep
  # the two in lockstep.
  if [[ -z "${_GH_REVIEW_DONE:-}" ]]; then
    # Don't auto-switch identity while the user is managing accounts
    # directly, or for --help/-h — informational calls shouldn't mutate
    # global auth state.
    if [[ "${1:-}" != "auth" && "${_gh_wrapper_help}" != "1" ]]; then
      _gh_wrapper_sync_identity || exit 1
    fi
    _gh_wrapper_block_bypass "$@" || exit 1
    if [[ "${_gh_wrapper_help}" != "1" ]]; then
      _gh_wrapper_maybe_review strict "$@" || exit 1
    fi
  fi

  # Token routing for claude-wrapper multi-org support
  if [[ -n "${CLAUDE_GH_TOKEN_ROUTER:-}" ]] && [[ -f "${CLAUDE_GH_TOKEN_ROUTER}" ]]; then
    # shellcheck source=/dev/null
    source "${CLAUDE_GH_TOKEN_ROUTER}" "$@"
  fi

  exec "${REAL_GH}" "$@"
else
  # --- Function-definition mode (sourced from functions.sh) ---
  gh() {
    # Note whether this is a help request, but the REST/GraphQL bypass block
    # below must run regardless — `gh api pulls/123/merge --help` must not
    # escape it by appending --help.
    local help=0 arg
    for arg in "$@"; do
      if [[ "${arg}" == "--help" || "${arg}" == "-h" ]]; then
        help=1
        break
      fi
    done

    # Don't auto-switch identity while the user is managing accounts
    # directly, or for --help/-h — informational calls shouldn't mutate
    # global auth state.
    if [[ "${1:-}" != "auth" && "${help}" != "1" ]]; then
      _gh_wrapper_sync_identity || return 1
    fi

    _gh_wrapper_block_bypass "$@" || return 1

    if [[ "${help}" == "1" ]]; then
      # Set _GH_REVIEW_DONE so the ~/.local/bin/gh wrapper also skips review.
      _GH_REVIEW_DONE=1 command gh "$@"
      return $?
    fi

    _gh_wrapper_maybe_review warn "$@" || return 1

    # Run the real gh command. Set _GH_REVIEW_DONE so the ~/.local/bin/gh
    # wrapper (found again via `command gh`, since ~/.local/bin is early in
    # PATH) does not run the review a second time.
    _GH_REVIEW_DONE=1 command gh "$@"
  }
  # Export gh AND the helpers it calls: an exported function only carries
  # its own body into subshells, not functions it calls. Without exporting
  # these too, gh() would break in any subshell that inherits the exported
  # gh but didn't source this file (e.g. BASH_ENV unset/overridden there).
  export -f gh _gh_wrapper_block_bypass _gh_wrapper_maybe_review _gh_wrapper_sync_identity
  export _gh_wrapper_review_script
fi
