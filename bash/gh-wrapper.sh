#!/usr/bin/env bash
# ~/.config/bash/gh-wrapper.sh
# shellcheck shell=bash
# Canonical implementation of the `gh` identity auto-switch, PR-merge guard
# (pre-merge review + REST/GraphQL merge-bypass blocking), and off-org draft
# enforcement (`gh pr create` targeting a repo outside
# smartwatermelon/nightowlstudiollc is forced to --draft, no opt-out). One
# file, two invocation modes:
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

# Resolves the repo owner a gh invocation is acting on: an explicit -R/--repo
# target on the command line takes precedence (that's the repo the call
# actually acts on), falling back to cwd's git remote only when no such flag
# is given. This keeps behavior consistent regardless of which repo checkout
# the caller happens to be sitting in — see smartwatermelon/dotfiles#135.
#
# Shared by _gh_wrapper_sync_identity (identity auto-switch) and
# _gh_wrapper_force_draft_for_off_org (draft enforcement) so the two checks
# can never drift on what "owner" means for a given invocation — prints the
# resolved owner (raw case) on stdout, or nothing if it can't be resolved.
_gh_wrapper_resolve_owner() {
  local repo_flag_value skip_next=0 arg remote_url owner

  repo_flag_value=""
  for arg in "$@"; do
    [[ "${arg}" == "--" ]] && break
    if [[ "${skip_next}" == "1" ]]; then
      repo_flag_value="${arg}"
      skip_next=0
      break
    fi
    case "${arg}" in
      -R | --repo) skip_next=1 ;;
      --repo=*)
        repo_flag_value="${arg#--repo=}"
        break
        ;;
      -R*)
        repo_flag_value="${arg#-R}"
        break
        ;;
      *) ;;
    esac
  done

  if [[ -n "${repo_flag_value}" ]]; then
    # -R/--repo takes OWNER/REPO or a full URL; owner is always the first
    # path segment after stripping any host/scheme prefix.
    owner=$(printf '%s\n' "${repo_flag_value}" | sed -E 's#^(git@[^:]+:|[a-zA-Z]+://[^/]+/)##; s#/.*##')
  else
    remote_url=$(command git config --get remote.origin.url 2>/dev/null)
    [[ -z "${remote_url}" ]] && return 0
    owner=$(printf '%s\n' "${remote_url}" | sed -E 's#^(git@[^:]+:|[a-zA-Z]+://[^/]+/)##; s#/.*##')
  fi
  [[ -z "${owner}" ]] && return 0
  printf '%s\n' "${owner}"
}

# Directory whose subtree marks a checkout as Beacon work. Built from ${HOME}
# so it resolves on any machine regardless of username (the work machine's
# home is /Users/arich, this one's is /Users/andrewrich — same layout, so the
# same default is correct for both). No trailing slash —
# _gh_wrapper_is_beacon_context appends its own when matching.
#
# Whether a missing beacon dir is worth warning about depends on whether the
# caller set it explicitly: an explicitly-configured path that doesn't exist is
# a misconfiguration, while an unset default that doesn't exist is just a
# machine with no Beacon work on it (the normal personal-machine state).
#
# That distinction is evaluated lazily, at check time, rather than being cached
# in a variable here. A cached flag would be exported into subshells and go
# stale the moment anything set GH_WRAPPER_BEACON_DIR after this file was
# sourced — the stale value then silently decides whether the warning fires.
# _gh_wrapper_beacon_dir_is_explicit re-derives it from the live environment on
# every call, so setting the variable at any point behaves identically.
_gh_wrapper_beacon_dir_is_explicit() {
  [[ "${GH_WRAPPER_BEACON_DIR:-}" != "${_GH_WRAPPER_BEACON_DIR_DEFAULT}" ]]
}

# bash/env.sh is the canonical definition of BEACON_WORKDIR, but this file
# also runs in standalone-wrapper mode (LaunchAgents/cron/GUI apps with a
# stripped environment) where env.sh was never sourced, so the default is
# spelled out here as a fallback. Keep the two in sync.
_GH_WRAPPER_BEACON_DIR_DEFAULT="${BEACON_WORKDIR:-${HOME}/Developer/beacon-biosignals}"
: "${GH_WRAPPER_BEACON_DIR:=${_GH_WRAPPER_BEACON_DIR_DEFAULT}}"

# Second-tier signal for the "Beacon work, but not under the beacon-biosignals
# org" case: repos created/forked during Beacon work that live under a
# personal or third-party owner (e.g. andrewmrich/git-pkgs-proxy, a fork of an
# unrelated upstream). Owner name alone can't classify those, so fall back to
# where the checkout lives and what it was forked from.
#
# Two signals, checked in order:
#   1. The repo's toplevel is inside ${GH_WRAPPER_BEACON_DIR}.
#   2. An `upstream` remote pointing at the beacon-biosignals org.
#
# Both are cwd-relative by nature, so this is only consulted for owners that
# aren't explicitly claimed by either identity (see _gh_wrapper_sync_identity).
# Returns 0 (true) if this looks like Beacon work.
_gh_wrapper_is_beacon_context() {
  local toplevel upstream_url upstream_owner

  # Signal 1: checkout location. Compare canonicalized paths so symlinked
  # checkouts and trailing-slash differences don't produce false negatives.
  # An explicitly-configured beacon dir that doesn't exist means the path
  # signal can never fire — warn rather than silently falling through to the
  # default identity, which is the same class of wrong-identity bug this
  # mapping exists to prevent. Warn once per process so it stays a signal
  # rather than noise on every unclaimed-owner invocation.
  if [[ ! -d "${GH_WRAPPER_BEACON_DIR}" && -z "${_GH_WRAPPER_BEACON_DIR_WARNED:-}" ]] \
    && _gh_wrapper_beacon_dir_is_explicit; then
    # Deliberately not exported: the latch is per-process, so a subshell that
    # inherits the exported gh() gets one warning of its own rather than
    # inheriting a "already warned" state it never saw output for.
    _GH_WRAPPER_BEACON_DIR_WARNED=1
    echo "[gh] WARNING: GH_WRAPPER_BEACON_DIR is set to '${GH_WRAPPER_BEACON_DIR}' but that directory does not exist." >&2
    echo "[gh] The Beacon checkout-path signal cannot fire; identity may fall back to the default." >&2
  fi

  toplevel=$(command git rev-parse --show-toplevel 2>/dev/null)
  if [[ -n "${toplevel}" && -d "${GH_WRAPPER_BEACON_DIR}" ]]; then
    local real_top real_beacon
    real_top=$(realpath "${toplevel}" 2>/dev/null || printf '%s' "${toplevel}")
    real_beacon=$(realpath "${GH_WRAPPER_BEACON_DIR}" 2>/dev/null || printf '%s' "${GH_WRAPPER_BEACON_DIR}")
    # Match the dir itself or anything beneath it, but not a sibling whose
    # name merely shares the prefix (…/beacon-biosignals-scratch).
    if [[ "${real_top}" == "${real_beacon}" || "${real_top}" == "${real_beacon}/"* ]]; then
      return 0
    fi
  fi

  # Signal 2: forked from the beacon-biosignals org. Uses the same
  # host/scheme-stripping shape as _gh_wrapper_resolve_owner.
  upstream_url=$(command git config --get remote.upstream.url 2>/dev/null)
  if [[ -n "${upstream_url}" ]]; then
    upstream_owner=$(printf '%s\n' "${upstream_url}" | sed -E 's#^(git@[^:]+:|[a-zA-Z]+://[^/]+/)##; s#/.*##')
    [[ "${upstream_owner,,}" == "beacon-biosignals" ]] && return 0
  fi

  return 1
}

# gh has one active account per host (not per repo), unlike git+SSH which
# already resolves the right identity per remote via ~/.ssh/config host
# aliases. This keeps gh in sync with that same per-repo intent.
#
# Mapping, in precedence order:
#   1. Owners explicitly claimed by an identity win outright, in BOTH
#      directions — smartwatermelon/nightowlstudiollc -> smartwatermelon,
#      beacon-biosignals/andrewmrich -> andrewmrich. An explicitly-owned repo
#      means the same thing no matter which directory you invoke gh from,
#      preserving the cwd-independence established in
#      smartwatermelon/dotfiles#135.
#   2. Otherwise (an owner claimed by neither — a third-party org, an
#      upstream you've been added to), consult the Beacon-context heuristic:
#      checkout under the beacon dir, or forked from beacon-biosignals.
#   3. Otherwise, default to smartwatermelon. This is the personal-default
#      environment; Beacon work is the specifically-marked exception.
#
# Local-only (reads/writes gh's config file, no network), so it's cheap to
# run on every invocation. Caveat: this mutates global gh state, so
# concurrent shells working in different-owner repos at the same time can
# race each other.
_gh_wrapper_sync_identity() {
  local owner desired current

  owner="$(_gh_wrapper_resolve_owner "$@")"
  [[ -z "${owner}" ]] && return 0

  # NOTE: the nightowlstudiollc -> smartwatermelon mapping below is asserted,
  # not verified — nothing here confirms the smartwatermelon gh account is
  # actually authorized against nightowlstudiollc repos. A `gh auth status`
  # check (cross-referencing the authorized orgs for the current account)
  # would be the way to confirm this mapping is still correct; that's left
  # as a future enhancement rather than added here to avoid scope creep.
  case "${owner,,}" in
    smartwatermelon | nightowlstudiollc) desired="smartwatermelon" ;;
    beacon-biosignals | andrewmrich) desired="andrewmrich" ;;
    *)
      if _gh_wrapper_is_beacon_context; then
        desired="andrewmrich"
      else
        desired="smartwatermelon"
      fi
      ;;
  esac

  current=$(awk '/^github\.com:/{f=1} f && /^ *user:/{print $2; exit}' "${HOME}/.config/gh/hosts.yml" 2>/dev/null | tr -d "\"'")

  if [[ -n "${current}" && "${current}" != "${desired}" ]]; then
    if ! command gh auth switch --hostname github.com --user "${desired}" >/dev/null 2>&1; then
      echo "[gh] ERROR: failed to switch identity to '${desired}' (repo owner: '${owner}') — refusing to run as '${current}' instead" >&2
      echo "[gh] If '${desired}' is not authenticated on this machine, run: gh auth login --hostname github.com" >&2
      echo "[gh] Failing closed rather than acting on '${owner}' as the wrong identity." >&2
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
    # -- end-of-options sentinel: everything after it is positional, even if
    # it looks like a flag. Mirrors the fix pattern from PR #146
    # (_gh_wrapper_sync_identity) for smartwatermelon/dotfiles#153.
    [[ "${arg}" == "--" ]] && break
    if [[ "${skip_next}" == "1" ]]; then
      skip_next=0
      continue
    fi
    case "${arg}" in
      -R | --repo | --hostname | --config-dir | --token) skip_next=1 ;;
      # Combined short-flag form (-Rowner/repo): the value is embedded in
      # this same token, so there's no next arg to skip — just consume this
      # one token without treating it as `sub`. See PR #146 / issue #153.
      -R*) ;;
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

# Hard, mechanical guard: a PR created against a repo outside the two orgs
# this environment is scoped to (smartwatermelon/nightowlstudiollc) must
# land as a draft, unconditionally — no AI judgement call, no opt-out flag,
# no environment-variable escape hatch. Later promotion out of draft is a
# manual, human-only action via the GitHub UI; this function only concerns
# itself with creation time. See smartwatermelon/dotfiles#174.
#
# Bash can't let a function reassign the caller's positional params, so this
# prints the (possibly modified) argument list, NUL-separated, on stdout; the
# caller rebuilds its array with `mapfile -d ''`. NUL (not newline) because
# argument values themselves may contain embedded newlines (e.g. a multi-line
# --body) — a newline delimiter can't be told apart from one inside a value,
# which shreds such args into multiple positional params downstream. NUL
# cannot appear in a shell argument, so it's an unambiguous separator. Prints
# nothing for zero args (callers already guard with `[[ "$#" -gt 0 ]]`
# accordingly); otherwise always prints at least the original args,
# NUL-separated, so callers can unconditionally replace their arg array
# from the output.
#
# Parses args with the same sub/subsub walk as _gh_wrapper_maybe_review, so
# `pr create` detection can't drift between the two.
_gh_wrapper_force_draft_for_off_org() {
  local sub="" subsub="" skip_next=0 arg owner

  for arg in "$@"; do
    [[ "${arg}" == "--" ]] && break
    if [[ "${skip_next}" == "1" ]]; then
      skip_next=0
      continue
    fi
    case "${arg}" in
      -R | --repo | --hostname | --config-dir | --token) skip_next=1 ;;
      -R*) ;;
      --*=*) ;;
      -*) ;;
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

  if [[ "${sub}" == "pr" && "${subsub}" == "create" ]]; then
    owner="$(_gh_wrapper_resolve_owner "$@")"
    if [[ -n "${owner}" ]]; then
      case "${owner,,}" in
        smartwatermelon | nightowlstudiollc) ;; # in-org: no change
        *)
          # Off-org target: force --draft. Don't bother deduplicating if the
          # caller already passed --draft (or --draft=false, which gh doesn't
          # support as a real flag) — an extra --draft is harmless, and the
          # point is nothing the caller does can produce a non-draft PR here.
          printf '%s\0' "$@"
          printf -- '--draft\0'
          return 0
          ;;
      esac
    fi
  fi

  # printf with zero operands still runs its format string once, emitting a
  # single stray NUL for `"$@"` empty — guard so zero args truly produces
  # zero bytes of output, matching `mapfile -d ''`'s empty-array behavior.
  [[ "$#" -gt 0 ]] && printf '%s\0' "$@"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # --- Standalone-wrapper mode (executed directly, e.g. via the
  # ~/.local/bin/gh symlink) ---
  set -euo pipefail

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

  # Safe to skip all four checks when _GH_REVIEW_DONE is set: that only
  # happens when function mode already ran them before calling `command gh`
  # (which lands here). If a future change ever sets _GH_REVIEW_DONE before
  # running those checks in function mode, this skip becomes unsafe — keep
  # the two in lockstep.
  if [[ -z "${_GH_REVIEW_DONE:-}" ]]; then
    # Don't auto-switch identity while the user is managing accounts
    # directly, or for --help/-h — informational calls shouldn't mutate
    # global auth state.
    if [[ "${1:-}" != "auth" && "${_gh_wrapper_help}" != "1" ]]; then
      _gh_wrapper_sync_identity "$@" || exit 1
    fi
    _gh_wrapper_block_bypass "$@" || exit 1
    if [[ "${_gh_wrapper_help}" != "1" ]]; then
      _gh_wrapper_maybe_review strict "$@" || exit 1
      # Off-org `gh pr create` must land as a draft — hard, mechanical,
      # no opt-out. Rebuild the positional params from the (possibly
      # --draft-appended) output; a function can't reassign "$@" directly.
      # NUL-delimited via process substitution (mapfile -d '' requires it —
      # command substitution can't carry NUL bytes at all; bash discards
      # them outright, so the NUL contract is structurally impossible
      # through `$(...)`). `|| true` is just to satisfy shellcheck SC2312
      # (don't mask a pipeline component's exit status): the function
      # always returns 0, so there's no real status being discarded. Only
      # rebuild when there's at least one original arg.
      if [[ "$#" -gt 0 ]]; then
        mapfile -t -d '' _gh_wrapper_new_args < <(_gh_wrapper_force_draft_for_off_org "$@" || true)
        # The function is contractually guaranteed to emit at least as many
        # elements as it received (it only ever appends --draft, never
        # drops args). A short rebuild means the producer failed partway
        # through — trust nothing and refuse rather than silently exec'ing
        # gh with a truncated command line (which could drop --draft itself).
        if [[ "${#_gh_wrapper_new_args[@]}" -lt "$#" ]]; then
          echo "[gh] ERROR: internal arg rebuild truncated; refusing to proceed" >&2
          exit 1
        fi
        set -- "${_gh_wrapper_new_args[@]}"
      fi
    fi
  fi

  # Only needed for the final exec below — computed here (after the
  # _GH_REVIEW_DONE-guarded checks above) rather than unconditionally at the
  # top of this block, so we don't do a needless PATH scan before knowing
  # this call is going to pass those checks.
  REAL_GH="$(_gh_wrapper_find_real_gh)"
  # Defensive: _gh_wrapper_find_real_gh currently fails hard on lookup
  # failure (and set -e aborts the assignment), but if it ever returns 0
  # with empty output we'd otherwise exec "" "$@" and produce a confusing
  # low-level exec error. Check explicitly instead.
  if [[ -z "${REAL_GH}" ]]; then
    echo "[gh] ERROR: could not locate real gh binary on PATH" >&2
    exit 1
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
      _gh_wrapper_sync_identity "$@" || return 1
    fi

    _gh_wrapper_block_bypass "$@" || return 1

    if [[ "${help}" == "1" ]]; then
      # Set _GH_REVIEW_DONE so the ~/.local/bin/gh wrapper also skips review.
      _GH_REVIEW_DONE=1 command gh "$@"
      return $?
    fi

    _gh_wrapper_maybe_review warn "$@" || return 1

    # Off-org `gh pr create` must land as a draft — hard, mechanical, no
    # opt-out. Rebuild the positional params from the (possibly
    # --draft-appended) output; a function can't reassign "$@" directly.
    # NUL-delimited via process substitution — see the standalone-mode call
    # site above for why (embedded newlines in arg values, e.g. --body).
    # Only rebuild when there's at least one original arg.
    if [[ "$#" -gt 0 ]]; then
      local _gh_wrapper_new_args
      mapfile -t -d '' _gh_wrapper_new_args < <(_gh_wrapper_force_draft_for_off_org "$@" || true)
      # See the standalone-mode call site above: a short rebuild means the
      # producer failed partway through — refuse rather than silently
      # exec'ing gh with a truncated command line.
      if [[ "${#_gh_wrapper_new_args[@]}" -lt "$#" ]]; then
        echo "[gh] ERROR: internal arg rebuild truncated; refusing to proceed" >&2
        return 1
      fi
      set -- "${_gh_wrapper_new_args[@]}"
    fi

    # Run the real gh command. Set _GH_REVIEW_DONE so the ~/.local/bin/gh
    # wrapper (found again via `command gh`, since ~/.local/bin is early in
    # PATH) does not run the review a second time.
    _GH_REVIEW_DONE=1 command gh "$@"
  }
  # Escape hatch to the real gh binary, bypassing identity auto-switch and
  # the merge guard entirely — same idea as suclaude for the claude wrapper.
  # Resolved via _gh_wrapper_find_real_gh (a PATH scan skipping this file)
  # rather than a hardcoded path, since ~/.local/bin/gh (unlike claude) IS
  # the wrapper itself, not a separate layer over a fixed real binary.
  sugh() {
    local real_gh
    real_gh="$(_gh_wrapper_find_real_gh)" || return 1
    "${real_gh}" "$@"
  }
  # Export gh AND the helpers it calls: an exported function only carries
  # its own body into subshells, not functions it calls. Without exporting
  # these too, gh() would break in any subshell that inherits the exported
  # gh but didn't source this file (e.g. BASH_ENV unset/overridden there).
  export -f gh sugh _gh_wrapper_block_bypass _gh_wrapper_maybe_review _gh_wrapper_sync_identity _gh_wrapper_find_real_gh _gh_wrapper_resolve_owner _gh_wrapper_force_draft_for_off_org _gh_wrapper_is_beacon_context _gh_wrapper_beacon_dir_is_explicit
  export _gh_wrapper_review_script GH_WRAPPER_BEACON_DIR _GH_WRAPPER_BEACON_DIR_DEFAULT
fi
