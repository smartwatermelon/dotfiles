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

# Needs bash 4+. Under macOS bash 3.2, re-exec (executed) or delegate gh() (sourced) to a newer bash; with none, refuse to run gh.
if ((BASH_VERSINFO[0] < 4)); then
  _gh_wrapper_new_bash=""
  # Keg dirs first: they hold only bash, so putting one first on PATH cannot change which gh is found.
  for _gh_wrapper_candidate in /opt/homebrew/opt/bash/bin/bash /usr/local/opt/bash/bin/bash \
    /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "${_gh_wrapper_candidate}" ]]; then
      _gh_wrapper_new_bash="${_gh_wrapper_candidate}"
      break
    fi
  done
  if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ -n "${_gh_wrapper_new_bash}" ]]; then
      PATH="${_gh_wrapper_new_bash%/*}:${PATH}" exec "${_gh_wrapper_new_bash}" "${BASH_SOURCE[0]}" "$@"
    fi
    echo "[gh] ERROR: bash ${BASH_VERSION} is too old and no bash 4+ was found; refusing to run gh unguarded." >&2
    exit 1
  fi
  _gh_wrapper_self="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/${BASH_SOURCE[0]##*/}"
  gh() {
    if [[ -z "${_gh_wrapper_new_bash}" ]]; then
      echo "[gh] ERROR: bash ${BASH_VERSION} is too old and no bash 4+ was found; refusing to run gh unguarded." >&2
      return 1
    fi
    # Runs this file as a standalone wrapper, so every check in that path applies; its exit status is gh's.
    PATH="${_gh_wrapper_new_bash%/*}:${PATH}" "${_gh_wrapper_new_bash}" "${_gh_wrapper_self}" "$@"
    return $?
  }
  return 0
fi

# The App token minter beside this file's real path: ~/.local/bin/gh is a symlink (claude-config#659).
_gh_wrapper_app_minter="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null)" || _gh_wrapper_app_minter="${BASH_SOURCE[0]}"
_gh_wrapper_app_minter="${_gh_wrapper_app_minter%/*}/gh-app-token.sh"

# Deliberately NOT defaulted from ${HOME} here. This file is sourced once, but
# ${HOME} at source time is not necessarily ${HOME} at call time: anything that
# reassigns HOME afterwards -- test harnesses above all -- would still get the
# sourcing user's path and silently run the REAL hook instead of the mock under
# test. The variable is also exported below, so a stale value propagates into
# every child process, including test runners started from an interactive
# shell. Resolved per call by _gh_wrapper_review_script_path instead; set this
# variable explicitly to override the location.
: "${_gh_wrapper_review_script:=}"

# Resolve the pre-merge review script at call time.
#
# An explicit non-empty ${_gh_wrapper_review_script} wins, so callers (and
# tests) can point this anywhere. Otherwise the location is derived from the
# CURRENT ${HOME}, which is what makes a sandboxed HOME work.
_gh_wrapper_review_script_path() {
  if [[ -n "${_gh_wrapper_review_script}" ]]; then
    printf '%s\n' "${_gh_wrapper_review_script}"
  else
    printf '%s\n' "${HOME}/.claude/hooks/pre-merge-review.sh"
  fi
}

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
#
# `--owner X` (gh search, gh project, ...) names the owner too, and sits
# between the two: -R still wins, but a single --owner beats cwd, so
# `gh search issues --owner=nightowlstudiollc` resolves the same from a Beacon
# checkout as from anywhere else. A comma-separated owner list could span both
# identities, so it is ignored and cwd decides, as before.
#
# #391: URL argument > -R > GH_REPO > remote, as gh does. create/new/list/status take no URL: one there is a flag value.
_gh_wrapper_resolve_owner() {
  local target
  target="$(_gh_wrapper_resolve_target "$@")" || target=""
  [[ -z "${target}" ]] && return 0
  target="$(_gh_wrapper_spec_owner "${target}")" || target=""
  [[ -n "${target}" ]] && printf '%s\n' "${target}"
  return 0
}

# Prints the 1Password item if this call's repo is in gh-app-routes.conf (claude-config#659).

# 0 routed, 1 not, 2 malformed route or no minter. Owner-only targets name no repo: never routed.
_gh_wrapper_app_route() {
  local target
  target="$(_gh_wrapper_resolve_target "$@")" || target=""
  [[ -z "${target}" ]] && return 1
  if [[ ! -f "${_gh_wrapper_app_minter}" ]]; then
    echo "[gh] ERROR: App token minter missing: ${_gh_wrapper_app_minter}" >&2
    return 2
  fi
  "${BASH}" "${_gh_wrapper_app_minter}" route "${target}"
}

# The target behind _gh_wrapper_resolve_owner: owner/repo[/...], a remote URL, or a bare owner.
_gh_wrapper_resolve_target() {
  local repo_flag_value owner_flag_value skip_next="" arg remote_url owner
  local sub="" subsub=""
  local url_re='^(https?://)?(www\.)?github\.com/([^/?#]+)/[^/?#]+/(pull|issues)/[0-9]+'

  _gh_wrapper_find_subcommand "$@"
  if [[ ("${sub}" == "pr" || "${sub}" == "issue") && ! "${subsub}" =~ ^(create|new|list|ls|status)$ ]]; then
    # A URL after a value flag (--body URL) is that flag's text. pr ready has no value flag, so there any URL counts.
    local prev="" bool_flags=" --undo --squash --merge --rebase --auto --admin --disable-auto --delete-branch --web --comments -w -d -s "
    for arg in "$@"; do
      [[ "${arg}" == "--" ]] && break
      if [[ "${arg,,}" =~ ${url_re} ]] && [[ "${subsub}" == "ready" || "${prev}" != -* || "${prev}" == *=* ||
        "${prev}" == -R?* || "${bool_flags}" == *" ${prev} "* ]]; then
        arg="${arg#*[Gg][Ii][Tt][Hh][Uu][Bb].[Cc][Oo][Mm]/}"
        printf '%s\n' "${arg}"
        return 0
      fi
      prev="${arg}"
    done
  fi

  repo_flag_value=""
  owner_flag_value=""
  for arg in "$@"; do
    [[ "${arg}" == "--" ]] && break
    if [[ "${skip_next}" == "repo" ]]; then
      repo_flag_value="${arg}"
      break
    fi
    if [[ "${skip_next}" == "owner" ]]; then
      owner_flag_value="${arg}"
      skip_next=""
      continue
    fi
    case "${arg}" in
      -R | --repo) skip_next="repo" ;;
      --repo=*)
        repo_flag_value="${arg#--repo=}"
        break
        ;;
      -R*)
        repo_flag_value="${arg#-R}"
        break
        ;;
      --owner) skip_next="owner" ;;
      --owner=*) owner_flag_value="${arg#--owner=}" ;;
      *) ;;
    esac
  done

  # gh repo <sub> OWNER/REPO names the owner positionally (#330). rename takes
  # a new name; a bare REPO is left to cwd.
  # `repo list OWNER` names a bare owner (#422); a wrong token hides private repos.
  if [[ -z "${repo_flag_value}" && "${1:-}" == "repo" ]]; then
    # Flags taking a separate value, per subcommand (gh 2.x --help).
    local value_flags="" positional=1 bare_owner=0
    case "${2:-}" in
      list | ls)
        value_flags="-q --jq --json -l --language -L --limit -t --template --topic --visibility"
        bare_owner=1
        ;;
      create | new) value_flags="-d --description -g --gitignore -h --homepage
        -l --license -r --remote -s --source -t --team -p --template" ;;
      view) value_flags="-b --branch -q --jq --json -t --template" ;;
      clone) value_flags="-u --upstream-remote-name" ;;
      fork) value_flags="--fork-name --org --remote-name" ;;
      edit) value_flags="--add-topic --default-branch -d --description -h --homepage
        --remove-topic --squash-merge-commit-message --visibility" ;;
      sync) value_flags="-b --branch -s --source" ;;
      delete | archive | unarchive | set-default) ;;
      *) positional=0 ;;
    esac
    if [[ "${positional}" == "1" ]]; then
      skip_next=""
      for arg in "${@:3}"; do
        [[ "${arg}" == "--" ]] && break
        if [[ -n "${skip_next}" ]]; then
          skip_next=""
          continue
        fi
        case "${arg}" in
          -*)
            [[ " ${value_flags//$'\n'/ } " == *" ${arg} "* ]] && skip_next="value"
            ;;
          */*)
            repo_flag_value="${arg}"
            break
            ;;
          *)
            [[ "${bare_owner}" == "1" ]] && repo_flag_value="${arg}"
            break
            ;;
        esac
      done
    fi
  fi

  if [[ -z "${repo_flag_value}" && -n "${owner_flag_value}" && "${owner_flag_value}" != *,* ]]; then
    printf '%s\n' "${owner_flag_value}"
    return 0
  fi

  # gh api names its owner in the endpoint: repos/, orgs/ or users/ OWNER.
  # `{owner}` means cwd. claude-wrapper#126, dotfiles#396.
  if [[ -z "${repo_flag_value}" && "${1:-}" == "api" ]]; then
    # The ^ anchor keeps flag values like `-f k=v` from matching.
    local api_owner_re='^/?(repos|orgs|users)/([^/{}]+)(/|$)' api_repo_re='^/?repos/([^/{}]+/[^/{}?#]+)'
    for arg in "${@:2}"; do
      [[ "${arg}" == "--" ]] && break
      if [[ "${arg}" =~ ${api_repo_re} ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
      fi
      if [[ "${arg}" =~ ${api_owner_re} ]]; then
        printf '%s\n' "${BASH_REMATCH[2]}"
        return 0
      fi
    done
  fi

  if [[ -n "${repo_flag_value}" ]]; then
    owner="${repo_flag_value}"
  elif [[ -n "${GH_REPO:-}" ]]; then
    # After the api endpoint: GH_REPO only fills {owner}/{repo} there (gh api --help).
    owner="${GH_REPO}"
  else
    remote_url=$(command git config --get remote.origin.url 2>/dev/null)
    [[ -z "${remote_url}" ]] && return 0
    owner="${remote_url}"
  fi
  printf '%s\n' "${owner}"
}

# Owner of a repo spec: OWNER/REPO, HOST/OWNER/REPO (gh reads exactly three segments so), a URL, git@ remote, or bare OWNER.
_gh_wrapper_spec_owner() {
  local v="$1" rest
  if [[ "${v}" =~ ^(git@[^:]+:|[a-zA-Z]+://[^/]+/)(.*)$ ]]; then
    v="${BASH_REMATCH[2]}"
  else
    rest="${v#*/}"
    [[ "${v}" == */*/* && "${rest#*/}" != */* ]] && v="${rest}"
  fi
  printf '%s\n' "${v%%/*}"
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

# The keyring login gh will use: the `user:` under `github.com:` in hosts.yml.
# Empty when no host entry exists.
_gh_wrapper_keyring_login() {
  awk '/^github\.com:/{f=1} f && /^ *user:/{print $2; exit}' "${HOME}/.config/gh/hosts.yml" 2>/dev/null | tr -d "\"'"
}

# Every login the keyring holds for github.com, one per line: the keys of the
# `users:` block. Those keys sit one indent level deeper than `users:` itself,
# which is what separates them from siblings like `user:` and `git_protocol:`.
# Empty when the block is absent (older hosts.yml files omit it).
_gh_wrapper_keyring_users() {
  awk '
    /^github\.com:/ { host = 1; next }
    /^[^[:space:]]/ { host = 0; users = 0; login_indent = 0; next }
    host && match($0, /^[[:space:]]*users:[[:space:]]*$/) {
      users = 1
      login_indent = 0
      users_indent = index($0, "u") - 1
      next
    }
    users && match($0, /^[[:space:]]*[^[:space:]#][^:]*:/) {
      indent = match($0, /[^[:space:]]/) - 1
      if (indent <= users_indent) { users = 0; next }
      # A login key sits at the first indent level inside the block. Anything
      # deeper is that login`s own settings (oauth_token:, git_protocol:), not
      # another account.
      if (login_indent == 0) { login_indent = indent }
      if (indent != login_indent) { next }
      key = $0
      sub(/^[[:space:]]*/, "", key)
      sub(/:.*$/, "", key)
      print key
    }
  ' "${HOME}/.config/gh/hosts.yml" 2>/dev/null | tr -d "\"'"
}

# The login to hand `gh auth token --user`, which matches exact casing. Prefer
# the keyring's own casing, else `desired` unchanged.
_gh_wrapper_resolve_switch_target() {
  local desired="$1"
  local held_logins
  held_logins="$(_gh_wrapper_keyring_users)" || held_logins=""

  local held
  while IFS= read -r held; do
    [[ -z "${held}" ]] && continue
    if [[ "${held,,}" == "${desired,,}" ]]; then
      printf '%s' "${held}"
      return 0
    fi
  done <<<"${held_logins}"

  printf '%s' "${desired}"
}

# The environment variable holding the fine-grained token for `owner`, or
# nothing for an owner without one. claude-wrapper exports all three into an
# agent session (_load_owner_gh_tokens); functions.sh's my_issues/my_prs use
# the same names. The mapping is by resource owner, not by login.
_gh_wrapper_owner_token_var() {
  case "${1,,}" in
    smartwatermelon) printf '%s\n' GH_TOKEN_SWM ;;
    nightowlstudiollc) printf '%s\n' GH_TOKEN_NOS ;;
    twistedmelonman) printf '%s\n' GH_TOKEN_TWM ;;
    *) ;;
  esac
}

# Pure owner -> gh identity mapping. Prints "andrewmrich" or "twistedmelonman"
# on stdout. No gh calls, no writes to gh state; the only input beyond the
# argument is the current directory, read by _gh_wrapper_is_beacon_context for
# the Beacon fallback. Other scripts may source this file and call it.
# See the mapping notes above _gh_wrapper_sync_identity for precedence.
_gh_wrapper_identity_for_owner() {
  local owner="$1"

  # smartwatermelon is the ORG (2026-09 migration); nightowlstudiollc is the
  # other org; twistedmelonman is the personal account that owns both and
  # keeps the archived repos and forks. All three resolve to the person.
  #
  # Still asserted, not verified: nothing here confirms the twistedmelonman
  # gh account is actually authorized against either org's repos. A `gh auth
  # status` check cross-referencing the account's authorized orgs would
  # confirm it; left as a future enhancement rather than scope creep here.
  case "${owner,,}" in
    smartwatermelon | nightowlstudiollc | twistedmelonman) printf '%s\n' "twistedmelonman" ;;
    beacon-biosignals | andrewmrich) printf '%s\n' "andrewmrich" ;;
    *)
      if _gh_wrapper_is_beacon_context; then
        printf '%s\n' "andrewmrich"
      else
        printf '%s\n' "twistedmelonman"
      fi
      ;;
  esac
}

# No owner token fits (claude-wrapper#124): use TWM and warn, else fail.
# Returns 0 = not applicable, 1 = fail closed, 2 = fallback applied.
_gh_wrapper_scoped_fallback() {
  local why="$1"
  [[ -n "${GH_TOKEN:-}" || -n "${GITHUB_TOKEN:-}" ]] && return 0
  [[ -z "${GH_TOKEN_SWM:-}" && -z "${GH_TOKEN_NOS:-}" && -z "${GH_TOKEN_TWM:-}" ]] && return 0
  # Recovery Andrew named in dotfiles#374 for a GH_TOKEN_* that is not set.
  local refresh="[gh] Token missing: refresh it in 1Password, then restart through claude-wrapper."
  if [[ -z "${GH_TOKEN_TWM:-}" ]]; then
    echo "[gh] ERROR: ${why}, and GH_TOKEN_TWM is not set." >&2
    echo "[gh] Failing closed rather than using the full-scope keyring token." >&2
    echo "[gh] Fix: pass -R OWNER/REPO or run inside the repo, or set GH_TOKEN_TWM." >&2
    echo "${refresh}" >&2
    return 1
  fi
  echo "[gh] WARNING: ${why}; using GH_TOKEN_TWM instead of the keyring token." >&2
  if [[ "${why}" == *"which is not set" ]]; then
    echo "${refresh}" >&2
  else
    echo "[gh] Reaching this fallback means owner detection failed." >&2
  fi
  echo "[gh] Fix: pass -R OWNER/REPO or run inside the repo." >&2
  _gh_wrapper_token_var="GH_TOKEN_TWM"
  return 2
}

# gh has one active account per host (not per repo), unlike git+SSH which
# already resolves the right identity per remote via ~/.ssh/config host
# aliases. This keeps gh in sync with that same per-repo intent.
#
# Mapping, in precedence order:
#   1. Owners explicitly claimed by an identity win outright, in BOTH
#      directions — smartwatermelon/nightowlstudiollc/twistedmelonman ->
#      twistedmelonman, beacon-biosignals/andrewmrich -> andrewmrich. An
#      explicitly-owned repo means the same thing no matter which directory
#      you invoke gh from, preserving the cwd-independence established in
#      smartwatermelon/dotfiles#135.
#   2. Otherwise (an owner claimed by neither — a third-party org, an
#      upstream you've been added to), consult the Beacon-context heuristic:
#      checkout under the beacon dir, or forked from beacon-biosignals.
#   3. Otherwise, default to twistedmelonman. This is the personal-default
#      environment; Beacon work is the specifically-marked exception.
#
# Token selection (smartwatermelon/claude-wrapper#126). When the resolved owner
# has its own fine-grained token in the environment
# (see _gh_wrapper_owner_token_var), that token is used for this one call.
# This function is the only place that decides it: it records the chosen
# variable NAME in _gh_wrapper_token_var, and each mode applies it only to the
# real gh process -- never exported into the caller's shell. A fine-grained
# PAT binds to exactly one resource owner, so the launch token acting on any
# other owner is a 403 at best; selection replaces the old owner-mismatch
# refusal wherever a matching token exists.
_gh_wrapper_sync_identity() {
  local owner desired

  _gh_wrapper_token_var=""
  _gh_wrapper_keyring_token=""
  _gh_wrapper_app_token=""
  owner="$(_gh_wrapper_resolve_owner "$@")"
  if [[ -z "${owner}" ]]; then
    local fb_rc=0
    _gh_wrapper_scoped_fallback "no owner resolved" || fb_rc=$?
    [[ "${fb_rc}" -eq 1 ]] && return 1
    return 0
  fi

  # Routed repo: act as the GitHub App, ahead of every PAT, and never fall back to one.

  # Returning here skips `gh api user` below; an installation token has no user to answer it.
  local app_item="" route_rc=0
  app_item="$(_gh_wrapper_app_route "$@")" || route_rc=$?
  if [[ "${route_rc}" -eq 0 ]]; then
    if ! _gh_wrapper_app_token="$("${BASH}" "${_gh_wrapper_app_minter}" --item "${app_item}" "${owner}")" \
      || [[ -z "${_gh_wrapper_app_token}" ]]; then
      _gh_wrapper_app_token=""
      echo "[gh] ERROR: this repo is routed to a GitHub App (gh-app-routes.conf), but no App token could be minted." >&2
      echo "[gh] Failing closed: a routed repo never falls back to a personal token. Check: gh-app-token.sh check <repo>" >&2
      return 1
    fi
    _gh_wrapper_token_var="_gh_wrapper_app_token"
    return 0
  elif [[ "${route_rc}" -ne 1 ]]; then
    echo "[gh] ERROR: cannot tell whether this repo is routed to a GitHub App; failing closed." >&2
    return 1
  fi

  desired="$(_gh_wrapper_identity_for_owner "${owner}")"

  # gh reads GH_TOKEN, then GITHUB_TOKEN; check whichever it will use (#365).
  local env_token_var=""
  if [[ -n "${GH_TOKEN:-}" ]]; then
    env_token_var="GH_TOKEN"
  elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
    env_token_var="GITHUB_TOKEN"
  fi

  # The owner's own token, when one is set, is the answer outright: it was
  # issued for this owner, so there is no identity left to check and no
  # `gh api user` round-trip to pay.
  # GH_TOKEN need not be set: else `env -u GH_TOKEN` reaches the keyring (claude-wrapper#124).
  local owner_token_var
  owner_token_var="$(_gh_wrapper_owner_token_var "${owner}")"
  if [[ -n "${owner_token_var}" && -n "${!owner_token_var:-}" ]]; then
    _gh_wrapper_token_var="${owner_token_var}"
    return 0
  fi

  # No usable owner token (unmapped owner, or its variable unset): TWM, loudly.
  local fb_rc=0 fb_why="owner '${owner}' has no mapped token"
  [[ -n "${owner_token_var}" ]] && fb_why="owner '${owner}' maps to ${owner_token_var}, which is not set"
  _gh_wrapper_scoped_fallback "${fb_why}" || fb_rc=$?
  [[ "${fb_rc}" -eq 1 ]] && return 1
  [[ "${fb_rc}" -eq 2 ]] && return 0

  # No owner token to select (its variable is unset): GH_TOKEN is used as given. When
  # the token represents a different identity than the resolved owner needs,
  # fail closed instead of silently acting as the wrong account.
  #
  # CLAUDE_GH_TOKEN_LOGIN names the identity GH_TOKEN authenticates as. The
  # test fixture sets it directly. In production it is unset, so the `gh api
  # user` fallback below resolves it — one network call per invocation. See
  # Step 11: session-level caching is a known follow-up, deliberately not
  # built here.
  if [[ -n "${env_token_var}" ]]; then
    local token_login="${CLAUDE_GH_TOKEN_LOGIN:-}"
    # Why resolution failed, so the advice below can match the actual cause
    # instead of guessing "expired". Three paths reach the same dead end and
    # they need different fixes: no real gh on PATH, the API call failing
    # (expired/revoked), and the call succeeding with output that is not a
    # login (something on PATH answered as gh but is not gh).
    local unresolved_reason="api_failed"

    if [[ -z "${token_login}" ]]; then
      # NOT `command gh`: ~/.local/bin/gh is this same wrapper and precedes
      # the real binary in PATH, so `command` re-enters this function.
      # _gh_wrapper_find_real_gh scans PATH while skipping this file.
      local real_gh
      if real_gh="$(_gh_wrapper_find_real_gh)"; then
        # Exit status, not output emptiness, decides success here. `gh api`
        # writes its error body to STDOUT, so a rejected token yields
        # `{"message": "Bad credentials", ...}` — non-empty, and mistaken for a
        # login name by any check that only tests for emptiness. Discard the
        # output unless the call actually succeeded.
        local api_out
        if api_out="$(GH_TOKEN="${!env_token_var}" "${real_gh}" api user --jq .login 2>/dev/null)"; then
          token_login="${api_out}"
        else
          unresolved_reason="api_failed"
        fi
      else
        unresolved_reason="no_real_gh"
      fi
    fi

    # A login is a single GitHub username: alphanumerics and hyphens, nothing
    # else. Anything multi-line or punctuated is an error body that reached here
    # some other way, and must never be compared against `desired` as though it
    # named an identity.
    if [[ -n "${token_login}" && ! "${token_login}" =~ ^[A-Za-z0-9-]+$ ]]; then
      token_login=""
      # The call SUCCEEDED and returned something that is not a login, so the
      # token is not the suspect — whatever answered as `gh` is. A test suite
      # that stubs `gh` on PATH hits this, because the PATH scan below finds
      # the stub (smartwatermelon/scripts#177).
      unresolved_reason="bad_output"
    fi

    if [[ -z "${token_login}" ]]; then
      echo "[gh] ERROR: ${env_token_var} is set but its identity could not be resolved" >&2
      echo "[gh] Refusing to run: ${env_token_var} overrides the keyring identity, so the" >&2
      echo "[gh] identity check cannot be trusted." >&2

      # Never echo the captured output itself. A shadowing binary can print
      # anything, including a credential, and this goes to stderr in every
      # session; the resolved path is what identifies the culprit anyway.
      case "${unresolved_reason}" in
        bad_output)
          echo "[gh] The identity lookup SUCCEEDED but did not return a login name," >&2
          echo "[gh] so the token is probably fine — something on PATH is answering" >&2
          echo "[gh] as 'gh' but is not gh. Resolved to:" >&2
          echo "[gh]   ${real_gh:-<unknown>}" >&2
          echo "[gh] Fix: remove that entry from PATH. If it is a test stub, unset" >&2
          echo "[gh] ${env_token_var} for the test so this check is skipped." >&2
          echo "[gh] Inspect with: type -a gh" >&2
          ;;
        no_real_gh)
          echo "[gh] No real 'gh' binary was found in PATH (see the error above)," >&2
          echo "[gh] so the identity could not be checked at all." >&2
          echo "[gh] Fix: install gh, or repair PATH. Inspect with: type -a gh" >&2
          ;;
        *)
          echo "[gh] Most likely the token is expired or revoked. Check with:" >&2
          echo "[gh]   gh api -i user | grep -i token-expiration" >&2
          echo "[gh] Fix: rotate the token, or unset ${env_token_var} to use the keyring" >&2
          echo "[gh] identity." >&2
          ;;
      esac
      return 1
    fi

    if [[ "${token_login,,}" != "${desired,,}" ]]; then
      echo "[gh] ERROR: ${env_token_var} authenticates as '${token_login}' but repo owner '${owner}' requires '${desired}'" >&2
      echo "[gh] ${env_token_var} takes precedence over the keyring identity, so this would" >&2
      echo "[gh] run as the wrong identity. Failing closed." >&2
      echo "[gh] Fix: unset ${env_token_var} to use the keyring identity for this repo." >&2
      return 1
    fi
  fi

  # An env token decides the identity; no hosts.yml means no keyring to read.
  [[ -n "${env_token_var}" ]] && return 0
  local kr_login
  kr_login="$(_gh_wrapper_keyring_login)" || kr_login=""
  [[ -z "${kr_login}" ]] && return 0

  # Keyring token for this call only, never `gh auth switch`: shared hosts.yml races (#404).
  local target token=""
  target="$(_gh_wrapper_resolve_switch_target "${desired}")"
  if ! token="$(command gh auth token --hostname github.com --user "${target}" 2>/dev/null)" \
    || [[ -z "${token}" || "${token}" =~ [[:space:]] ]]; then
    echo "[gh] ERROR: no keyring token for '${target}' (repo owner: '${owner}')." >&2
    echo "[gh] To add it, run: gh auth login --hostname github.com (as '${target}')" >&2
    echo "[gh] Failing closed rather than acting on '${owner}' as the wrong identity." >&2
    return 1
  fi
  _gh_wrapper_keyring_token="${token}"
  _gh_wrapper_token_var="_gh_wrapper_keyring_token"
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
  local sub="" subsub=""
  # The subcommand, not $1: a global flag can come first, as in `gh -R o/r api ...`.
  _gh_wrapper_find_subcommand "$@"
  if [[ "${sub}" == "api" ]] && printf '%s\n' "$*" | grep -qE 'pulls/[0-9]+/merge([[:space:]]|$|[^[:alnum:]_])'; then
    echo "[gh] BLOCKED: Direct REST API PR merge bypasses pre-merge review and merge authorization." >&2
    echo "[gh] This endpoint skips pre-merge-review.sh and the merge-lock check." >&2
    echo "[gh] Use 'gh pr merge <number>' instead." >&2
    echo "[gh] If gh pr merge fails, report the failure and ask the human to merge manually." >&2
    return 1
  fi

  # #444: GraphQL mergePullRequest goes through the same query reader as #391, so a query in a file is checked too.
  if [[ "${sub}" == "api" ]]; then
    _gh_wrapper_block_graphql_pr_mutation "$@" || return 1
  fi

  _gh_wrapper_block_off_org_promotion "$@" || return 1

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
    local _review_script
    _review_script="$(_gh_wrapper_review_script_path)"
    if [[ -x "${_review_script}" ]]; then
      "${_review_script}" "$@" || return 1
    elif [[ "${missing_script_mode}" == "strict" ]]; then
      echo "[gh] ERROR: pre-merge review script not found or not executable: ${_review_script}" >&2
      echo "[gh] Refusing to proceed with an unguarded merge." >&2
      return 1
    else
      echo "[gh] Warning: pre-merge review script not found or not executable" >&2
      echo "[gh] Expected: ${_review_script}" >&2
      echo "[gh] Proceeding without review..." >&2
    fi
  fi
  return 0
}

# Sets the caller's `sub` and `subsub` to the first two non-flag words. Shared by both guards.
_gh_wrapper_find_subcommand() {
  local skip_next=0 arg
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
  return 0
}

# True (0) when $1 is one of the three owners this environment is scoped to.
_gh_wrapper_owner_in_org() {
  case "${1,,}" in
    smartwatermelon | nightowlstudiollc | twistedmelonman) return 0 ;;
    *) return 1 ;;
  esac
}

# Off-org guard (#339): refuses `gh pr ready` and an undrafted `gh api` POST to pulls. Returns 1 to block.
_gh_wrapper_block_off_org_promotion() {
  local sub="" subsub="" owner arg

  _gh_wrapper_find_subcommand "$@"

  if [[ "${sub}" == "pr" && "${subsub}" == "ready" ]]; then
    for arg in "$@"; do
      [[ "${arg}" == "--" ]] && break
      [[ "${arg}" == "--undo" ]] && return 0 # back to draft is allowed
    done
    owner="$(_gh_wrapper_resolve_owner "$@")"
    if [[ -n "${owner}" ]] && ! _gh_wrapper_owner_in_org "${owner}"; then
      echo "[gh] BLOCKED: 'gh pr ready' on off-org repo owner '${owner}'." >&2
      echo "[gh] Only the human promotes off-org PRs out of draft, via the GitHub UI." >&2
      return 1
    fi
    return 0
  fi

  if [[ "${sub}" == "api" ]]; then
    local endpoint="" method="" implicit_post=0 draft="" skip_next="" field seen_api=0
    local pulls_re='^/?repos/[^/]+/[^/]+/pulls/?(\?.*)?$'
    for arg in "$@"; do
      [[ "${arg}" == "--" ]] && break
      if [[ "${seen_api}" == "0" ]]; then
        [[ "${arg}" == "api" ]] && seen_api=1
        continue
      fi
      field=""
      case "${skip_next}" in
        method)
          method="${arg}"
          skip_next=""
          continue
          ;;
        field)
          field="${arg}"
          skip_next=""
          ;;
        skip)
          skip_next=""
          continue
          ;;
        *) ;;
      esac
      if [[ -z "${field}" ]]; then
        case "${arg}" in
          -X | --method) skip_next="method" ;;
          --method=*) method="${arg#--method=}" ;;
          -X?*) method="${arg#-X}" ;;
          -f | -F | --field | --raw-field)
            implicit_post=1
            skip_next="field"
            ;;
          --field=* | --raw-field=*)
            implicit_post=1
            field="${arg#*=}"
            ;;
          -f?* | -F?*)
            implicit_post=1
            field="${arg:2}"
            ;;
          --input)
            implicit_post=1
            draft="unknown" # body is in a file; draft=true cannot be verified
            skip_next="skip"
            ;;
          --input=*)
            implicit_post=1
            draft="unknown"
            ;;
          -H | --header | -q | --jq | -t | --template | --cache | -p | --preview | --hostname) skip_next="skip" ;;
          -*) ;;
          *) [[ -z "${endpoint}" ]] && endpoint="${arg}" ;;
        esac
      fi
      if [[ "${field}" == draft=* && "${draft}" != "unknown" ]]; then
        draft="${field#draft=}" # last draft field wins, as in gh
      fi
    done

    [[ "${endpoint}" =~ ${pulls_re} ]] || return 0
    method="${method^^}"
    if [[ "${method}" != "POST" && (-n "${method}" || "${implicit_post}" == "0") ]]; then
      return 0
    fi
    [[ "${draft}" == "true" ]] && return 0
    owner="$(_gh_wrapper_resolve_owner "$@")"
    if [[ -n "${owner}" ]] && ! _gh_wrapper_owner_in_org "${owner}"; then
      echo "[gh] BLOCKED: 'gh api' POST to ${endpoint} on off-org owner '${owner}' without draft=true." >&2
      echo "[gh] Off-org PRs must be created as drafts; only the human promotes them, via the GitHub UI." >&2
      echo "[gh] Pass '-F draft=true' as a field." >&2
      return 1
    fi
  fi

  return 0
}

# #391/#444: refuses GraphQL PR create, revert, mark-ready, merge and auto-merge, read from args, -F @file or --input; unreadable = refused.
_gh_wrapper_block_graphql_pr_mutation() {
  local arg skip_next="" field val pos=0 ep="" seen_api=0 f name="" why=""
  local -a files=() inputs=()
  local mut_re='(^|[^[:alnum:]_])(createPullRequest|revertPullRequest|markPullRequestReadyForReview|mergePullRequest|enablePullRequestAutoMerge)([^[:alnum:]_]|$)'
  for arg in "$@"; do
    [[ "${arg}" == "--" ]] && break
    if [[ "${seen_api}" == "0" ]]; then
      [[ "${arg}" == "api" ]] && seen_api=1
      continue
    fi
    field=""
    case "${skip_next}" in
      field) field="${arg}" ;;
      input) inputs+=("${arg}") ;;
      skip) ;;
      *)
        case "${arg}" in
          -F | --field) skip_next="field" ;;
          -f | --raw-field) skip_next="skip" ;;
          --input) skip_next="input" ;;
          --input=*) inputs+=("${arg#--input=}") ;;
          --field=*) field="${arg#*=}" ;;
          -F?*) field="${arg:2}" ;;
          -*) _gh_wrapper_api_value_flag "${arg}" && skip_next="skip" ;;
          *)
            pos=$((pos + 1))
            ep="${arg,,}"
            ;;
        esac
        [[ -n "${skip_next}" ]] && continue
        ;;
    esac
    skip_next=""
    val="${field#*=}"
    [[ "${field}" == *=* && "${val}" == @* ]] && files+=("${val#@}")
  done

  # One positional is the endpoint; zero or several (an unknown flag's value) cannot be told apart, so check anyway.
  [[ "${ep}" =~ ^https?://[^/]+(/.*)?$ ]] && ep="${BASH_REMATCH[1]}"
  ep="${ep%%\?*}"
  while [[ "${ep}" == */ ]]; do ep="${ep%/}"; done
  [[ "${pos}" == "1" && "${ep}" != "graphql" && "${ep}" != */graphql ]] && return 0

  if [[ "$*" =~ ${mut_re} ]]; then
    name="${BASH_REMATCH[2]}"
  fi
  for f in "${files[@]}" "${inputs[@]}"; do
    [[ -n "${name}" ]] && break
    if [[ "${f}" == "-" || ! -f "${f}" || ! -r "${f}" ]]; then
      why="query in '${f}' cannot be read (stdin or no such file)."
      break
    fi
    name="$(grep -oE "${mut_re}" -- "${f}" | head -n 1 | tr -cd '[:alnum:]')" || true
  done
  for f in "${inputs[@]}"; do
    [[ -n "${name}" || -n "${why}" ]] && break
    if grep -qF '\u' -- "${f}"; then
      why="--input '${f}' uses \\u escapes, which can hide a mutation name."
    fi
  done
  if [[ -n "${why}" ]]; then
    echo "[gh] BLOCKED: gh api GraphQL ${why}" >&2
    echo "[gh] It could merge a PR, which must go through 'gh pr merge <number>' and its pre-merge review." >&2
    echo "[gh] It could open or promote an off-org PR. Only the human promotes off-org PRs, via the GitHub UI." >&2
    return 1
  fi
  [[ -z "${name}" ]] && return 0
  if [[ "${name}" == "mergePullRequest" || "${name}" == "enablePullRequestAutoMerge" ]]; then
    echo "[gh] BLOCKED: GraphQL ${name} mutation bypasses pre-merge review and merge authorization." >&2
    echo "[gh] Use 'gh pr merge <number>' instead." >&2
    echo "[gh] If gh pr merge fails, report the failure and ask the human to merge manually." >&2
    return 1
  fi
  echo "[gh] BLOCKED: GraphQL ${name} names its target by node ID; the wrapper cannot prove the owner is in-org." >&2
  echo "[gh] Use 'gh pr create' or 'gh pr ready', which resolve the owner (off-org create is forced to draft)." >&2
  echo "[gh] Only the human promotes off-org PRs out of draft, via the GitHub UI." >&2
  return 1
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
  local sub="" subsub="" owner

  _gh_wrapper_find_subcommand "$@"

  # `pr new` is the alias of `pr create`.
  if [[ "${sub}" == "pr" && ("${subsub}" == "create" || "${subsub}" == "new") ]]; then
    owner="$(_gh_wrapper_resolve_owner "$@")"
    if [[ -n "${owner}" ]] && ! _gh_wrapper_owner_in_org "${owner}"; then
      # Off-org: force --draft. A duplicate --draft is harmless; the caller cannot opt out.
      printf '%s\0' "$@"
      printf -- '--draft\0'
      return 0
    fi
  fi

  # printf with zero operands still runs its format string once, emitting a
  # single stray NUL for `"$@"` empty — guard so zero args truly produces
  # zero bytes of output, matching `mapfile -d ''`'s empty-array behavior.
  [[ "$#" -gt 0 ]] && printf '%s\0' "$@"
  return 0
}

# --- label check (#323): attached labels must exist; list --label is a filter --

# owner/repo from a resolve_target value (URL, git@, HOST/o/r, o/r/pull/N). Nothing for a bare owner.
_gh_wrapper_label_repo() {
  local v="$1" rest
  if [[ "${v}" =~ ^(git@[^:]+:|[a-zA-Z]+://[^/]+/)(.*)$ ]]; then
    v="${BASH_REMATCH[2]}"
  else
    rest="${v#*/}"
    [[ "${v}" == */*/* && "${rest#*/}" != */* ]] && v="${rest}"
  fi
  [[ "${v}" == */* ]] || return 0
  rest="${v#*/}"
  rest="${rest%%/*}"
  rest="${rest%.git}"
  [[ -n "${v%%/*}" && -n "${rest}" ]] && printf '%s/%s\n' "${v%%/*}" "${rest}"
  return 0
}

# True when $1 and $2 (already lowercased) are at most one edit apart: one
# insert, delete, substitution, or swap of two adjacent characters.
_gh_wrapper_within_one_edit() {
  local a="$1" b="$2" t i=0
  if ((${#a} > ${#b})); then
    t="${a}"
    a="${b}"
    b="${t}"
  fi
  ((${#b} - ${#a} > 1)) && return 1
  while ((i < ${#a})) && [[ "${a:i:1}" == "${b:i:1}" ]]; do i=$((i + 1)); done
  if ((${#a} == ${#b})); then
    [[ "${a:i+1}" == "${b:i+1}" ]] && return 0
    [[ "${a:i:1}" == "${b:i+1:1}" && "${a:i+1:1}" == "${b:i:1}" && "${a:i+2}" == "${b:i+2}" ]] && return 0
    return 1
  fi
  [[ "${a:i}" == "${b:i+1}" ]]
}

# Up to five of the caller's `known` labels near $1: one edit apart, or one contains the other.
_gh_wrapper_label_near() {
  local want="${1,,}" k kl n=0
  for k in "${known[@]}"; do
    kl="${k,,}"
    if _gh_wrapper_within_one_edit "${want}" "${kl}" \
      || { ((${#want} >= 3 && ${#kl} >= 3)) && [[ "${kl}" == *"${want}"* || "${want}" == *"${kl}"* ]]; }; then
      printf '%s\n' "${k}"
      n=$((n + 1))
      ((n >= 5)) && break
    fi
  done
  return 0
}

# Whether to prompt: both stdin and stderr are terminals. Its own function so
# tests can stand in for a terminal.
_gh_wrapper_label_interactive() {
  [[ -t 0 && -t 2 ]]
}

# Run the real gh with the token _gh_wrapper_sync_identity selected, as the
# final dispatch does. $1 is the real gh path.
_gh_wrapper_real_gh_selected() {
  local real_gh="$1"
  shift
  if [[ -n "${_gh_wrapper_token_var:-}" ]]; then
    GH_TOKEN="${!_gh_wrapper_token_var}" "${real_gh}" "$@"
  else
    "${real_gh}" "$@"
  fi
}

# Prompt for missing label $1 in repo $2. Sets caller's `choice`: create, use:<label>, or abort (also on EOF).
_gh_wrapper_label_choose() {
  local label="$1" repo="$2" reply="" s i=0
  local -a near=()
  mapfile -t near < <(_gh_wrapper_label_near "${label}" || true)
  {
    echo "[gh] Label '${label}' does not exist in ${repo}."
    for s in "${near[@]}"; do
      i=$((i + 1))
      echo "[gh]   ${i}) use '${s}'"
    done
    echo "[gh]   c) create '${label}' in ${repo}"
    echo "[gh]   a) abort (default)"
    printf '[gh] Choice: '
  } >&2
  choice="abort"
  read -r reply || reply=""
  case "${reply}" in
    c | C) choice="create" ;;
    *)
      if [[ "${reply}" =~ ^[1-9]$ ]] && ((reply <= ${#near[@]})); then
        choice="use:${near[reply - 1]}"
      fi
      ;;
  esac
  return 0
}

# Missing label: prompt at a terminal, else abort listing valid ones. Never creates one unasked.

# Sets caller's _gh_wrapper_label_args (_rewritten=1 on a swap). 1 = abort.
_gh_wrapper_check_labels() {
  local sub="" subsub="" attach arg name want="" i k lc value item
  local -a argv=("$@") idx=() pre=() items=() labels=() missing=() known=() out_items=()
  local -A have=() seen=() repl=()
  _gh_wrapper_label_rewritten=0
  _gh_wrapper_label_args=("$@")

  _gh_wrapper_find_subcommand "$@"
  case "${sub}/${subsub}" in
    issue/create | issue/new | pr/create | pr/new) attach="-l --label" ;;
    issue/edit | pr/edit) attach="--add-label" ;;
    *) return 0 ;;
  esac
  # Flags of those four that take a value (gh 2.x --help), so a value is never
  # read as a flag.
  local value_flags="-R --repo -a --assignee --attach --blocked-by --blocking -b --body
    -F --body-file -m --milestone --parent -p --project --recover -T --template -t --title
    --type -B --base -H --head -r --reviewer --add-assignee --add-blocked-by --add-blocking
    --add-project --add-sub-issue --add-reviewer --remove-assignee --remove-blocked-by
    --remove-blocking --remove-label --remove-project --remove-sub-issue --remove-reviewer"
  value_flags=" ${value_flags//[[:space:]]/ } "

  # idx/pre: where each label value sits in argv, and the flag text before it
  # in that same token ("" when the value is a token of its own).
  for ((i = 0; i < ${#argv[@]}; i++)); do
    arg="${argv[i]}"
    [[ "${arg}" == "--" ]] && break
    if [[ "${want}" == "label" ]]; then
      idx+=("${i}")
      pre+=("")
      want=""
      continue
    fi
    if [[ "${want}" == "skip" ]]; then
      want=""
      continue
    fi
    name="${arg%%=*}"
    if [[ " ${attach} " == *" ${name} "* ]]; then
      if [[ "${arg}" == *=* ]]; then
        idx+=("${i}")
        pre+=("${name}=")
      else
        want="label"
      fi
    elif [[ "${attach}" == "-l "* && "${arg}" == -l?* ]]; then
      # pflag reads -lX and -l=X as the value X.
      idx+=("${i}")
      if [[ "${arg}" == -l=* ]]; then pre+=("-l="); else pre+=("-l"); fi
    elif [[ "${value_flags}" == *" ${arg} "* ]]; then
      want="skip"
    fi
  done
  [[ "${#idx[@]}" -eq 0 ]] && return 0

  # Repeated flags and comma lists both reach gh; split on commas, untrimmed,
  # as gh sends them. Deduplicated case-insensitively.
  for ((k = 0; k < ${#idx[@]}; k++)); do
    value="${argv[idx[k]]#"${pre[k]}"}"
    IFS=',' read -r -a items <<<"${value}"
    for item in "${items[@]}"; do
      [[ -z "${item}" || -n "${seen[${item,,}]:-}" ]] && continue
      seen["${item,,}"]=1
      labels+=("${item}")
    done
  done
  [[ "${#labels[@]}" -eq 0 ]] && return 0

  # Repo as token routing resolves it. Any lookup failure warns and dispatches: never less usable than plain gh.
  local target repo real_gh list rc=0
  target="$(_gh_wrapper_resolve_target "$@")" || target=""
  repo="$(_gh_wrapper_label_repo "${target}")"
  if [[ -z "${repo}" ]]; then
    echo "[gh] WARNING: cannot tell which repository to check labels in; passing the call to gh unchecked." >&2
    return 0
  fi
  if ! real_gh="$(_gh_wrapper_find_real_gh 2>/dev/null)"; then
    echo "[gh] WARNING: no real gh found to look up labels; passing the call to gh unchecked." >&2
    return 0
  fi
  list="$(_gh_wrapper_real_gh_selected "${real_gh}" label list -R "${repo}" --limit 500 \
    --json name --jq '.[].name' 2>/dev/null)" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    echo "[gh] WARNING: label lookup in ${repo} failed (exit ${rc}); passing the call to gh unchecked." >&2
    return 0
  fi
  [[ -n "${list}" ]] && mapfile -t known <<<"${list}"
  if [[ "${#known[@]}" -ge 500 ]]; then
    echo "[gh] WARNING: ${repo} has 500+ labels, more than one lookup returns; passing the call to gh unchecked." >&2
    return 0
  fi
  for item in "${known[@]}"; do have["${item,,}"]=1; done
  for item in "${labels[@]}"; do
    [[ -n "${have[${item,,}]:-}" ]] || missing+=("${item}")
  done
  [[ "${#missing[@]}" -eq 0 ]] && return 0

  if ! _gh_wrapper_label_interactive; then
    local valid="(none)" near
    [[ "${#known[@]}" -gt 0 ]] && valid="$(printf '%s, ' "${known[@]}")" && valid="${valid%, }"
    {
      echo "[gh] BLOCKED: ${sub} ${subsub}: label(s) not found in ${repo}: $(printf "'%s' " "${missing[@]}")"
      for item in "${missing[@]}"; do
        near="$(_gh_wrapper_label_near "${item}" | paste -sd ',' - | sed 's/,/, /g')"
        [[ -n "${near}" ]] && echo "[gh]   '${item}': did you mean ${near}?"
      done
      echo "[gh] Valid labels in ${repo}: ${valid}"
      echo "[gh] Fix the label name and re-run. Only a human creates a new label (gh label create, or run this at a terminal)."
    } >&2
    return 1
  fi

  local choice
  for item in "${missing[@]}"; do
    _gh_wrapper_label_choose "${item}" "${repo}"
    case "${choice}" in
      create)
        if ! _gh_wrapper_real_gh_selected "${real_gh}" label create "${item}" -R "${repo}" >&2; then
          echo "[gh] ERROR: could not create label '${item}' in ${repo}; aborting." >&2
          return 1
        fi
        ;;
      use:*) repl["${item,,}"]="${choice#use:}" ;;
      *)
        echo "[gh] Aborted: label '${item}' does not exist in ${repo}." >&2
        return 1
        ;;
    esac
  done
  [[ "${#repl[@]}" -eq 0 ]] && return 0

  # Put each chosen near match in place of the missing label, in its token.
  for ((k = 0; k < ${#idx[@]}; k++)); do
    value="${argv[idx[k]]#"${pre[k]}"}"
    IFS=',' read -r -a items <<<"${value}"
    out_items=()
    for item in "${items[@]}"; do
      lc="${item,,}"
      # An empty item (a,,b) cannot be an associative-array key.
      if [[ -n "${lc}" && -n "${repl[${lc}]:-}" ]]; then
        out_items+=("${repl[${lc}]}")
      else
        out_items+=("${item}")
      fi
    done
    value="$(
      IFS=','
      printf '%s' "${out_items[*]}"
    )"
    argv[idx[k]]="${pre[k]}${value}"
  done
  _gh_wrapper_label_args=("${argv[@]}")
  _gh_wrapper_label_rewritten=1
  return 0
}

# --- approval gate: gh api fields ----------------------------------------------
# Classify the fields of a `gh api` call for _gh_wrapper_approval_gate. Sets
# that function's locals `inline` and `files` (bash scoping is dynamic, so a
# callee sees its caller's locals); it is not meant to be called on its own.
#
# The one verifiable form is `-F/--field body=@<path>`: that makes gh read the
# value from the file, so the file's bytes are what gets posted. `-f` and
# `--raw-field` never expand `@`, so `-f body=@/x` posts the literal string and
# counts as inline. A GraphQL `query` that is a mutation setting a `body:`
# argument carries its text inline too. Fields not named body -- state, labels,
# titles -- are not prose and pass.
#
# NOT covered: `--input <json>`, which carries a body inside a JSON document.
# Blocking it outright would also block ruleset and protection writes that
# carry no prose. Same limit as hook-block-personify.sh.

# gh api flags whose next argument is a value, not the endpoint. Field flags
# (-f, -F) are left to each caller. Shared by both api walks.
_gh_wrapper_api_value_flag() {
  case "$1" in
    -X | --method | -H | --header | -q | --jq | -t | --template | --input | --cache | -p | --preview | --hostname) return 0 ;;
    *) return 1 ;;
  esac
}

_gh_wrapper_api_body_fields() {
  local arg flag="" field key val skip_next=0
  local gql_body_re='mutation.*[^[:alnum:]_]body[[:space:]]*:'
  for arg in "$@"; do
    [[ "${arg}" == "--" ]] && break
    if [[ "${skip_next}" == "1" ]]; then
      skip_next=0
      continue
    fi
    field=""
    if [[ -n "${flag}" ]]; then
      field="${arg}"
    elif _gh_wrapper_api_value_flag "${arg}"; then
      skip_next=1
    else
      case "${arg}" in
        -f | -F | --field | --raw-field)
          flag="${arg}"
          continue
          ;;
        --field=* | --raw-field=*)
          flag="${arg%%=*}"
          field="${arg#*=}"
          ;;
        -f?* | -F?*)
          flag="${arg:0:2}"
          field="${arg:2}"
          ;;
        *) ;;
      esac
    fi
    if [[ -n "${field}" ]]; then
      key="${field%%=*}"
      val="${field#*=}"
      if [[ "${field}" == *=* && "${key}" == "body" ]]; then
        if [[ ("${flag}" == "-F" || "${flag}" == "--field") && "${val}" == @* ]]; then
          files+=("${val#@}")
        else
          inline=1
        fi
      elif [[ "${key}" == "query" && "${val}" =~ ${gql_body_re} ]]; then
        inline=1
      fi
    fi
    flag=""
  done
  return 0
}

# --- approval gate: destination ------------------------------------------------
# Reduce a repository spelling to lowercase owner/name: a scheme, a leading
# github.com/, a trailing slash and .git are stripped. Prints nothing when the
# result is not exactly owner/name (another host, an empty part), and the
# caller blocks. Mirrors _norm_repo in claude-config's hook-block-personify.sh.
_gh_wrapper_norm_repo() {
  local v="${1,,}"
  v="${v#https://}"
  v="${v#http://}"
  v="${v#github.com/}"
  v="${v%/}"
  v="${v%.git}"
  [[ "${v}" =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ ]] && printf '%s\n' "${v}"
  return 0
}

# Work out which repository a gated gh call publishes to, so gate-review.sh
# check can route the text by destination (gate-rules.conf). Sets the caller's
# locals `dest_repo` (empty: the checkout gh runs in) and `also_cwd`, and
# returns 1 with the caller's `reason` set when the destination cannot be read.
# Takes the caller's `sub`, `subsub`, `api_pos`, `repo_args` and `url_args`.
#
# The forms read are the ones hook-block-personify.sh reads, so the two gates
# route a text the same way: -R/--repo, GH_REPO, a github.com URL given as the
# PR or issue argument, and gh api's repos/<owner>/<name> endpoint. Every form
# found must name the same repository; disagreement blocks rather than picking
# one. A URL is the destination only if it is the PR or issue argument, which
# this walk cannot tell from the value of a flag it does not know (a --title),
# so with no -R the checkout must route the text too (also_cwd). The same holds
# for gh api's {owner}/{repo}, which gh fills from the checkout.
_gh_wrapper_gate_destination() {
  local c n ep rest
  local -a cands=()
  dest_repo=""
  also_cwd=0
  [[ -n "${GH_REPO:-}" ]] && cands+=("${GH_REPO}")
  [[ "${#repo_args[@]}" -gt 0 ]] && cands+=("${repo_args[@]}")
  if [[ "${sub}" == "api" ]]; then
    # gh api takes one positional. Zero, or more (an unknown flag's value),
    # means no endpoint: block, never route by $PWD alone (#434).
    if [[ "${api_pos:-0}" != "1" ]]; then
      reason="cannot find the gh api endpoint (${api_pos:-0} positional arguments; gh api takes exactly one)"
      return 1
    fi
    ep="${subsub}"
    [[ "${ep}" =~ ^https?://[^/]+(/.*)$ ]] && ep="${BASH_REMATCH[1]}"
    ep="${ep#/}"
    case "${ep}" in
      repositories/*)
        reason="gh api repositories/<id> names the repository by number; use repos/<owner>/<name>"
        return 1
        ;;
      "repos/{owner}/{repo}"*) also_cwd=1 ;;
      repos/*/*)
        rest="${ep#repos/}"
        c="${rest%%/*}"
        rest="${rest#*/}"
        cands+=("${c}/${rest%%/*}")
        ;;
      repos/*)
        reason="cannot resolve the repository from '${ep}'"
        return 1
        ;;
      *) ;;
    esac
  fi
  for c in "${cands[@]}"; do
    n="$(_gh_wrapper_norm_repo "${c}")"
    if [[ -z "${n}" ]]; then
      reason="cannot resolve '${c}' to a single owner/name repository"
      return 1
    fi
    if [[ -n "${dest_repo}" && "${dest_repo}" != "${n}" ]]; then
      reason="the call names more than one repository (${dest_repo}, ${n}); name exactly one"
      return 1
    fi
    dest_repo="${n}"
  done
  # URLs last: with a -R, GH_REPO or endpoint repo already set, a URL only has
  # to agree with it.
  for c in "${url_args[@]}"; do
    rest="${c,,}"
    rest="${rest#*github.com/}"
    n="${rest%%/*}"
    rest="${rest#*/}"
    n="$(_gh_wrapper_norm_repo "${n}/${rest%%/*}")"
    if [[ -z "${n}" ]]; then
      reason="cannot resolve '${c}' to a single owner/name repository"
      return 1
    fi
    if [[ -n "${dest_repo}" && "${dest_repo}" != "${n}" ]]; then
      reason="the call names more than one repository (${dest_repo}, ${n}); name exactly one"
      return 1
    fi
    [[ "${#cands[@]}" -eq 0 ]] && also_cwd=1
    dest_repo="${n}"
  done
  [[ -n "${dest_repo}" ]] || also_cwd=0
  return 0
}

# --- approval gate: length cap kind --------------------------------------------
# The personify length-cap kind for a gated call, from its subcommand. A copy of
# the table in claude-config's hook-block-personify.sh (_gh_cap_kind and
# _api_cap_kind): the two must agree, so change them together. Copied rather
# than sourced so this wrapper does not depend on claude-config's internals.
#
#   pr create, pr edit         -> pr
#   issue create, issue edit   -> issue
#   pr comment, pr review,
#   issue comment              -> pr-comment
#   api repos/.../pulls/N/comments -> line-comment
#   any other api              -> pr-comment
#
# gh api is classified from the endpoint word alone, never from a body-file
# path, so a path cannot select a looser cap. Titles are not measured here: the
# wrapper serves Andrew's own gh calls, and title caps apply to the agent path.
# Takes the caller's `sub` and `subsub`.
_gh_wrapper_cap_kind() {
  local ep
  case "${sub}/${subsub}" in
    pr/create | pr/edit) printf 'pr\n' ;;
    issue/create | issue/edit) printf 'issue\n' ;;
    api/*)
      ep="${subsub}"
      [[ "${ep}" =~ ^https?://[^/]+(/.*)$ ]] && ep="${BASH_REMATCH[1]}"
      ep="${ep#/}"
      if [[ "${ep}" == repos/* && "${ep}" =~ /pulls/[0-9]+/comments ]]; then
        printf 'line-comment\n'
      else
        printf 'pr-comment\n'
      fi
      ;;
    *) printf 'pr-comment\n' ;;
  esac
}

# --- approval gate: exempt destination ----------------------------------------
# Exempt? Args as for check. Any failure: 1, full checks.
_gh_wrapper_dest_exempt() {
  local gate="$1" route
  [[ -x "${gate}" ]] || return 1
  # GraphQL names its target by node id: no route, never exempt.
  [[ "${sub}/${subsub}" == "api/graphql" ]] && return 1
  local -a args=(--dir "${PWD}")
  [[ -n "${dest_repo}" ]] && args+=(--repo "${dest_repo}")
  route="$("${gate}" route "${args[@]}" 2>/dev/null)" || return 1
  [[ "${route%%$'\t'*}" == "exempt" ]] || return 1
  if [[ "${also_cwd}" == "1" ]]; then
    route="$("${gate}" route --dir "${PWD}" 2>/dev/null)" || return 1
    [[ "${route%%$'\t'*}" == "exempt" ]] || return 1
  fi
  return 0
}

# --- approval gate -------------------------------------------------------------
# Refuse to write PR or issue body text unless Andrew has visually approved
# those exact bytes. Approval lives on disk in gate-review's approved/
# directory; this asks gate-review whether the body file hashes to something
# approved.
#
# An earlier version of this function read PERSONIFY_OK from the environment.
# That channel is DEAD and must not be reintroduced: the Bash tool runs in a
# process that does not inherit the interactive shell's environment, so an
# env-var ack is unsatisfiable by the human, not merely strict. Measured
# 2026-09-18. See hook-block-personify.sh for the full note.
#
# Manual-invocation half; ~/.claude/scripts/hook-block-personify.sh covers the
# Bash-tool path. Redundant by design, so neither one being bypassed lets text
# through. The rule enforced here is deliberately identical to the hook's, so
# the human learns one rule and not two:
#
#   --body-file/-F with an ABSOLUTE path -> verifiable, checked
#   --body/-b "inline text"              -> blocked, nothing to hash
#   a RELATIVE path or ~/... or $VAR/... -> blocked, resolved against a cwd
#       this function and gh may disagree about
#
# Gated destinations only: the route is asked first; exempt text passes in any form (#411).
#
# Each body's destination repository goes to check with it (see
# _gh_wrapper_gate_destination), and check routes it by gate-rules.conf: a
# Pangram-gated repository also needs a check record for the exact bytes.
#
# Each body is also measured against its length cap: check gets --kind from
# _gh_wrapper_cap_kind, so an approved body over the cap still blocks, and a
# machine without personify blocks (check reports a checker error).
#
# TITLES stay ungated -- one line by nature. A subcommand carrying no body flag
# passes, so `gh pr edit --add-label` and `gh pr review --approve` are unaffected.
#
# Fails CLOSED when gate-review.sh is absent, matching hook-block-personify.sh.
# A redundant pair whose halves disagree about the unverifiable case is not
# redundant. A machine without claude-config installed cannot write PR bodies
# through this wrapper; that is the intended outcome, not an oversight.
#
# `gh pr review` follows the same body rule as `gh pr edit`. `gh api` is gated
# when it sends a field named `body` or a GraphQL mutation with a body argument
# (claude-config#548); see _gh_wrapper_api_body_fields.
#
# Same arg walk as _gh_wrapper_force_draft_for_off_org so detection cannot drift.
#
# After `api` it skips flag values and counts positionals (#434). The
# force-draft walk acts on pr create only.
#
# Review routes, as in hook-block-personify.sh: pr create --draft/-d needs clean gate-lint, not approval.

# gh pr ready (not --undo) on a review route is blocked: Andrew clicks Ready for review in the GitHub UI.
_gh_wrapper_approval_gate() {
  local sub="" subsub="" skip_next=0 arg api_pos=0 prev="" last=""
  local body_file="" inline=0 want_path=0 want_repo=0 draft=0 undo=0
  local -a repo_args=() url_args=()

  for arg in "$@"; do
    [[ "${arg}" == "--" ]] && break
    prev="${last}"
    last="${arg}"
    if [[ "${skip_next}" == "1" ]]; then
      skip_next=0
      continue
    fi
    if [[ "${want_path}" == "1" ]]; then
      body_file="${arg}"
      want_path=0
      continue
    fi
    if [[ "${want_repo}" == "1" ]]; then
      repo_args+=("${arg}")
      want_repo=0
      continue
    fi
    # gh api: skip each flag's value, or `-X POST` reads POST as the endpoint
    # (#434). Here -F is --field, not --body-file.
    if [[ "${sub}" == "api" ]]; then
      case "${arg}" in
        -f | -F | --field | --raw-field)
          skip_next=1
          continue
          ;;
        *) ;;
      esac
      if _gh_wrapper_api_value_flag "${arg}"; then
        skip_next=1
        continue
      fi
    fi
    case "${arg}" in
      # A flag word only, never a flag's value: `-t -d` titles the PR "-d". Same list as the hook's _is_draft.
      --draft | -d | --draft=true)
        case "${prev}" in
          -t | --title | -b | --body | -F | --body-file | -B | --base | -H | --head | -R | --repo | -a | --assignee | \
            -l | --label | -m | --milestone | -p | --project | -r | --reviewer | -T | --template | --recover) ;;
          *) draft=1 ;;
        esac
        ;;
      --undo) undo=1 ;;
      -R | --repo) want_repo=1 ;;
      --hostname | --config-dir | --token) skip_next=1 ;;
      -b | --body) inline=1 ;;
      --body=* | -b=*) inline=1 ;;
      -F | --body-file) want_path=1 ;;
      --body-file=*) body_file="${arg#*=}" ;;
      -F*) body_file="${arg#-F}" ;;
      --repo=*) repo_args+=("${arg#*=}") ;;
      # gh (pflag) reads -Ro/n and -R=o/n as the value o/n.
      -R*)
        arg="${arg#-R}"
        repo_args+=("${arg#=}")
        ;;
      --*=*) ;;
      -*) ;;
      *)
        [[ "${sub}" == "api" ]] && api_pos=$((api_pos + 1))
        if [[ -z "${sub}" ]]; then
          sub="${arg}"
        elif [[ -z "${subsub}" ]]; then
          subsub="${arg}"
        elif [[ "${arg,,}" =~ ^(https?://)?github\.com/ ]]; then
          url_args+=("${arg}")
        fi
        ;;
    esac
  done

  local -a files=()
  local ready=0
  [[ "${sub}/${subsub}" == pr/create ]] || draft=0
  case "${sub}/${subsub}" in
    pr/create | pr/comment | pr/edit | pr/review | issue/create | issue/comment | issue/edit)
      [[ -n "${body_file}" ]] && files=("${body_file}")
      ;;
    # Back to draft publishes no text.
    pr/ready) [[ "${undo}" == "1" ]] && return 0 || ready=1 ;;
    api/*)
      # -F means --field here, not --body-file: discard the generic walk's
      # reading and classify the fields instead.
      inline=0
      _gh_wrapper_api_body_fields "$@"
      ;;
    *) return 0 ;;
  esac

  # No body flag at all: no prose is being written. Titles and labels pass.
  # --fill/-f is ungated on purpose: its body is commit text that already passed the gate (#355).
  if [[ "${ready}" == "0" && "${inline}" == "0" && "${#files[@]}" == "0" ]]; then
    return 0
  fi

  local gate="${HOME}/.claude/scripts/gate-review.sh"
  local reason=""

  # Time-boxed suspension: Andrew writes ~/.claude/gate-review/SUSPENDED by
  # hand, holding the last day it applies. gate-review.sh owns the parsing and
  # prints a notice when it lets a body through, so this layer and
  # hook-block-personify.sh cannot disagree about what counts. A missing
  # gate-review.sh is not a suspension; it falls through and blocks below. So
  # does a gate-review.sh from before `suspended` existed: it rejects the
  # unknown subcommand with exit 1, which reads as "not suspended". Its stderr
  # is shown only on success, so that older version's usage error does not
  # print on every gated call.
  local notice=""
  if [[ -x "${gate}" ]] && notice="$("${gate}" suspended 2>&1 >/dev/null)"; then
    [[ -n "${notice}" ]] && printf '%s\n' "${notice}" >&2
    return 0
  fi

  local dest_repo="" also_cwd=0 err="" lenblock="" lintblock=0 lrc kind
  local lint="${HOME}/.claude/scripts/gate-lint.sh"
  local -a dest=()
  kind="$(_gh_wrapper_cap_kind)"
  # Route first (#411): exempt passes in any form; an unreadable destination blocks.
  if ! _gh_wrapper_gate_destination; then
    {
      echo "[gh] 🛑 BLOCKED: ${sub} ${subsub}: cannot tell which repository this body goes to."
      echo "[gh]   reason: ${reason}"
    } >&2
    return 1
  fi
  _gh_wrapper_dest_exempt "${gate}" && return 0
  if [[ "${ready}" == "1" ]]; then
    {
      echo "[gh] 🛑 BLOCKED: gh pr ready on a review route. Andrew clicks Ready for review in the GitHub UI."
      echo "[gh]   A draft can still be pushed to and edited; gh pr ready --undo is allowed."
    } >&2
    return 1
  fi
  if [[ "${inline}" == "1" ]]; then
    reason="text given inline; only a file can be verified"
  else
    # check routes the text by destination (gate-rules.conf): a Pangram-gated
    # repository also needs a check record for these exact bytes.
    dest=(--kind "${kind}" --dir "${PWD}")
    [[ -n "${dest_repo}" ]] && dest+=(--repo "${dest_repo}")
    # Every named file must verify: an approved first body must not carry an
    # unapproved second one through.
    for body_file in "${files[@]}"; do
      err=""
      if [[ "${body_file}" != /* ]]; then
        reason="path '${body_file}' is not absolute; gh and this gate would resolve it differently"
      elif [[ ! -f "${body_file}" ]]; then
        reason="no such file: ${body_file}"
      elif [[ "${draft}" == "1" ]]; then
        # A draft publishes to the PR page only; clean lint stands in for approval until Ready.
        lintblock=1
        lrc=0
        if [[ ! -x "${lint}" ]]; then
          reason="gate-lint.sh missing at ${lint}; cannot lint ${body_file}"
        else
          err="$("${lint}" --mode block "${kind}" "${body_file}" 2>&1)" || lrc=$?
          [[ -n "${err}" ]] && printf '%s\n' "${err}" >&2
          err=""
          case "${lrc}" in
            0) ;;
            1) reason="lint errors in ${body_file}; a draft needs clean lint (approval not needed)" ;;
            *) reason="gate-lint could not run (exit ${lrc}), so this is not a verdict on the text" ;;
          esac
        fi
      elif [[ ! -x "${gate}" ]]; then
        reason="gate-review.sh missing at ${gate}; cannot verify"
      elif ! err="$("${gate}" check "${body_file}" "${dest[@]}" 2>&1)" \
        || { [[ "${also_cwd}" == "1" ]] && ! err="$("${gate}" check "${body_file}" --kind "${kind}" --dir "${PWD}" 2>&1)"; }; then
        reason="${err##*$'\n'}"
        [[ -n "${reason}" ]] || reason="the bytes in ${body_file} do not match anything approved"
        [[ "${reason}" == *"over length"* ]] && lenblock="over"
        [[ "${reason}" == *"length checker error"* ]] && lenblock="error"
      fi
      # Router notes (repo or author unresolved) stay visible. On a failure
      # the last line is the reason, printed in the block message below.
      if [[ -z "${reason}" && -n "${err}" ]]; then
        printf '%s\n' "${err}" >&2
      elif [[ "${err}" == *$'\n'* ]]; then
        printf '%s\n' "${err%$'\n'*}" >&2
      fi
      [[ -n "${reason}" ]] && break
    done
    [[ -n "${reason}" ]] || return 0
  fi

  if [[ "${lintblock}" == "1" ]]; then
    {
      echo "[gh] 🛑 BLOCKED: draft ${sub} ${subsub} body did not pass gate-lint."
      echo "[gh]"
      echo "[gh]   reason: ${reason}"
      echo "[gh]"
      echo "[gh] Fix the findings above and re-run the same command. A draft needs no approval."
    } >&2
    return 1
  fi

  if [[ "${lenblock}" == "over" ]]; then
    {
      echo "[gh] 🛑 BLOCKED: ${sub} ${subsub} body is over its length cap."
      echo "[gh]"
      echo "[gh]   reason: ${reason}"
      echo "[gh]"
      echo "[gh] Rewrite the body shorter, then stage, approve and re-run."
    } >&2
    return 1
  fi
  if [[ "${lenblock}" == "error" ]]; then
    {
      echo "[gh] 🛑 BLOCKED: ${sub} ${subsub} body: the length checker failed. This is not a verdict on the text."
      echo "[gh]"
      echo "[gh]   reason: ${reason}"
      echo "[gh]"
      echo "[gh] Fix the checker (is personify installed?) and re-run the same command."
    } >&2
    return 1
  fi

  # gate-review keeps approvals per repo and branch (claude-config#623).
  local rerun="gh ${sub} ${subsub} --title t --body-file ${HOME}/.claude/gate-review/approved/<repo>-<branch>/<label>"
  [[ "${sub}" == "api" ]] \
    && rerun="gh api ${subsub} -F body=@${HOME}/.claude/gate-review/approved/<repo>-<branch>/<label>"

  {
    echo "[gh] 🛑 BLOCKED: ${sub} ${subsub} body has not been visually approved."
    echo "[gh]"
    echo "[gh]   reason: ${reason}"
    echo "[gh]"
    echo "[gh] Every PR and issue body must be read and approved in the editor"
    echo "[gh] before it is written. To do that:"
    echo "[gh]"
    echo "[gh]   1. Write the body to a file."
    echo "[gh]   2. ${gate} stage <label> <file>"
    echo "[gh]   3. ${gate} open"
    echo "[gh]   4. Andrew reads the batch and types APPROVED in the STATUS line."
    echo "[gh]   5. Re-run against the APPROVED file, absolute path:"
    echo "[gh]        ${rerun}"
    echo "[gh]"
    echo "[gh]      Use the approved copy, not the file you staged: if he edited"
    echo "[gh]      the text in the editor, his edits are what he approved and"
    echo "[gh]      the original no longer matches."
    echo "[gh]"
    echo "[gh] Approval is his to give. Staging and opening on his behalf is fine;"
    echo "[gh] typing the word for him is not."
  } >&2
  return 1
}

# --- F4: scope-error hint ------------------------------------------------------
# On a missing scope, name the token and its PAT fix, never `env -u` (claude-wrapper#124). Detection is
# gh's own ScopesSuggestion text, so there is no command classifier to get
# wrong. Design: dev-env docs/superpowers/specs/2026-09-03-org-migration-design.md.

# Print the scope named in a captured stderr file, or nothing. The character
# class accepts either quote style, so the hint keeps working whichever one gh
# emits; pinning a single one would silently disable it if that ever changed.
# Measured against gh 2.x (2026-09), which uses "...".
_gh_wrapper_scope_from_file() {
  grep -oE "needs the [\"'][A-Za-z0-9:_]+[\"'] scope" "$1" 2>/dev/null \
    | head -1 | sed -E "s/needs the [\"']([^\"']+)[\"'] scope/\1/"
}

# Re-quote argv for display, replacing the VALUE of any flag that routinely
# carries a secret with <redacted>. The hint is printed to stderr, which lands
# in terminal scrollback, CI logs and transcripts — echoing `--body ghp_...`
# back would copy a live credential into all three. Redaction is by flag name,
# not by pattern-matching the value: guessing what a secret looks like fails
# open on every format not anticipated, whereas the flag says outright that
# whatever follows it is a value the caller chose to pass secretly.
#
# Flags covered (gh's real pairings: -b/--body, -F/--field, -f/--raw-field,
# -H/--header) in all three spellings pflag accepts: `--body VALUE` and
# `-b VALUE` (value in the next argument), `--body=VALUE` (value after `=`),
# and the stuck short form `-bVALUE` (value glued to the flag letter). A
# literal `--` ends flag parsing, as in the other argv scanners in this file.
#
# For the key=value flags (-f/-F/--field/--raw-field) only the part after the
# first `=` is redacted, so `-f body=SECRET` prints as `-f body=<redacted>`:
# the key names the API field and is not secret, and keeping it leaves the
# suggested command recognizable. A value with no `=` is redacted whole.
_gh_wrapper_redact_argv() {
  local out="" arg redact_next="" past_dashdash=0
  for arg in "$@"; do
    if [[ -n "${redact_next}" ]]; then
      out+="$(_gh_wrapper_redact_value "${redact_next}" "${arg}") "
      redact_next=""
      continue
    fi
    if [[ "${past_dashdash}" == "1" ]]; then
      out+="$(printf '%q ' "${arg}")"
      continue
    fi
    case "${arg}" in
      --)
        past_dashdash=1
        out+="-- "
        ;;
      -b | --body | -H | --header)
        redact_next=whole
        out+="$(printf '%q ' "${arg}")"
        ;;
      -f | -F | --field | --raw-field)
        redact_next=keyed
        out+="$(printf '%q ' "${arg}")"
        ;;
      --body=* | --header=*)
        # %q with no trailing space: the `=` must abut the flag name, and
        # `printf '%q '` would wedge a space in between.
        out+="$(printf '%q' "${arg%%=*}")=$(_gh_wrapper_redact_value whole "${arg#*=}") "
        ;;
      --field=* | --raw-field=*)
        out+="$(printf '%q' "${arg%%=*}")=$(_gh_wrapper_redact_value keyed "${arg#*=}") "
        ;;
      -b?* | -H?*)
        out+="${arg:0:2}$(_gh_wrapper_redact_value whole "${arg:2}") "
        ;;
      -f?* | -F?*)
        out+="${arg:0:2}$(_gh_wrapper_redact_value keyed "${arg:2}") "
        ;;
      *) out+="$(printf '%q ' "${arg}")" ;;
    esac
  done
  printf '%s' "${out% }"
}

# Redact one flag value. mode=whole replaces all of it; mode=keyed keeps a
# leading `key=` and replaces what follows (or the whole value if it has no
# `=`). The kept key is re-quoted so the result stays pasteable.
_gh_wrapper_redact_value() {
  local mode="$1" value="$2"
  if [[ "${mode}" == "keyed" && "${value}" == *=* ]]; then
    printf '%q=<redacted>' "${value%%=*}"
  else
    printf '<redacted>'
  fi
}

# Print the hint for `scope`, quoting the original argv back so the suggested
# command can be pasted verbatim (secret-bearing flag values excepted — see
# _gh_wrapper_redact_argv).
_gh_wrapper_print_scope_hint() {
  local scope="$1"
  shift
  local cmd
  cmd="$(_gh_wrapper_redact_argv "$@")"
  # gh reads GH_TOKEN, then GITHUB_TOKEN; the caller gets here only when one is set.
  local token_var="GH_TOKEN"
  if [[ -z "${GH_TOKEN:-}" ]]; then
    token_var="GITHUB_TOKEN"
  fi
  # Name the owner's variable when GH_TOKEN holds its value (function mode passes it as GH_TOKEN).
  local owner owner_var
  owner="$(_gh_wrapper_resolve_owner "$@")"
  if [[ -n "${owner}" ]]; then
    owner_var="$(_gh_wrapper_owner_token_var "${owner}")"
    if [[ -n "${owner_var}" && -n "${!owner_var:-}" && "${!owner_var}" == "${!token_var:-}" ]]; then
      token_var="${owner_var}"
    fi
  fi
  echo "[gh] ${token_var} lacks the '${scope}' scope." >&2
  echo "[gh] Fix: grant the missing permission on ${owner:-the repo owner}'s fine-grained PAT, then re-run:" >&2
  echo "[gh]   gh ${cmd}" >&2
  echo "[gh] How: smartwatermelon/dev-env docs/runbooks/fleet-probe-token-scopes.md." >&2
  echo "[gh] Only Andrew can change a PAT. Do not unset or override ${token_var} to reach the keyring token." >&2
}

# Run the real gh. stderr goes to the terminal live AND to a temp file; stdout
# is untouched. On non-zero exit, a scope error in the file triggers the hint.
# The real exit code is returned.
#
# Not `exec`: the hint needs gh's exit status and stderr after it returns.
# Only called when an env-var token is set (see the standalone branch): the
# tee pipe costs gh's stderr its TTY and can reorder stderr against stdout,
# which is acceptable in an agent session and not at a human's terminal.
_gh_wrapper_run_with_scope_hint() {
  local real_gh="$1"
  shift
  local errfile rc=0
  # No temp file means no detection, but the command itself must still run —
  # degrade to a plain passthrough rather than failing the call.
  if ! errfile="$(mktemp "${TMPDIR:-/tmp}/gh-wrapper-stderr.XXXXXX")"; then
    "${real_gh}" "$@"
    return $?
  fi
  # A signal that kills the wrapper mid-run skips the rm -f at the bottom and
  # leaves one temp file behind per interrupted run.
  #
  # RETURN alone does NOT fix that: measured, a RETURN trap does not fire when
  # the shell is killed by SIGTERM — the process dies without unwinding the
  # function. An explicit signal trap is required. RETURN is kept for the
  # ordinary paths (including the `return` below), and the signal handler
  # re-raises after cleanup so the caller still sees a signal death (128+n)
  # rather than a normal exit.
  #
  # The handler also forwards the signal to gh. Before F4 the wrapper exec'd
  # gh, so a signal aimed at "the gh process" hit gh. Now that pid is the
  # wrapper's; without forwarding, gh would run on as an orphan after the
  # wrapper died. Ctrl-C already reaches the whole foreground process group,
  # so this matters for a targeted kill (`timeout gh ...`, `kill <pid>`).
  #
  # gh runs in the BACKGROUND and the wrapper `wait`s for it. This is not
  # optional: bash defers a trapped signal until a foreground command
  # finishes (measured — a SIGTERM to the wrapper during a foreground
  # `gh | tee` pipeline was not acted on until gh exited on its own, so the
  # handler could neither forward nor clean up). Only `wait` returns at once
  # on a trapped signal, running the handler immediately. The explicit `<&0`
  # is defensive: only a job-control (interactive) shell gives a background
  # child /dev/null as stdin, and this path runs non-interactively — but the
  # function is exported, so it is kept correct for a sourced caller too.
  # Non-interactive bash starts background children with SIGINT ignored (Go
  # leaves an ignored signal ignored), so INT is forwarded as TERM. `kill` is
  # guarded because `set -e` applies inside the handler.
  #
  # stderr goes through a process substitution running tee: gh writes to a
  # dynamically allocated fd ({errfd}, so a repeat call in one shell cannot
  # clobber a still-open fd and orphan the previous tee), tee copies to the
  # file and the real stderr. gh gets the fd closed so it does not inherit
  # the write end. After gh exits the fd is closed and tee is waited for, so
  # the file is complete before it is read. tee buffers, so a PARTIAL-line
  # write to stderr — gh's interactive prompts, which deliberately omit the
  # trailing newline — can surface after stdout that was written later.
  # Whole lines are unaffected, and stdout bypasses the pipe entirely.
  local gh_pid="" tee_pid="" errfd=""
  trap 'rm -f "${errfile}"' RETURN
  trap '[[ -n "${gh_pid}" ]] && kill -TERM "${gh_pid}" 2>/dev/null; rm -f "${errfile}"; trap - TERM HUP INT; kill -s TERM $$' TERM HUP INT
  exec {errfd}> >(tee "${errfile}" >&2 || true)
  tee_pid=$!
  "${real_gh}" "$@" 2>&"${errfd}" {errfd}>&- <&0 &
  gh_pid=$!
  # `|| rc=$?` keeps `set -e` (standalone mode) from aborting on a failing gh
  # before rc is read.
  wait "${gh_pid}" || rc=$?
  gh_pid=""
  exec {errfd}>&-
  wait "${tee_pid}" 2>/dev/null || true
  if [[ "${rc}" -ne 0 ]]; then
    local scope
    scope="$(_gh_wrapper_scope_from_file "${errfile}")"
    if [[ -n "${scope}" ]]; then
      _gh_wrapper_print_scope_hint "${scope}" "$@"
    fi
    # No owner resolved means no token was selected: this ran with the
    # launch-directory GH_TOKEN, which may belong to another owner. An agent
    # that sees the failure tends to start trying the other GH_TOKEN_* values;
    # stop it instead. Same resolver as selection, so the two cannot disagree
    # on "no owner". The exit code is not changed.
    # smartwatermelon/claude-wrapper#126 decision 3.
    local hint_owner=""
    hint_owner="$(_gh_wrapper_resolve_owner "$@")" || hint_owner=""
    if [[ -n "${GH_TOKEN:-}" && -z "${hint_owner}" ]]; then
      echo "[gh] No repo owner could be resolved, so this ran with the launch-directory GH_TOKEN and failed. Stop and ask Andrew for help; do not guess a different token." >&2
    fi
  fi
  rm -f "${errfile}"
  return "${rc}"
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
  # Set by _gh_wrapper_sync_identity; applied just before gh runs, below.
  _gh_wrapper_token_var=""
  _gh_wrapper_keyring_token=""
  _gh_wrapper_app_token=""
  if [[ -z "${_GH_REVIEW_DONE:-}" ]]; then
    # No identity routing for `gh auth` (account management) or --help.
    if [[ "${1:-}" != "auth" && "${_gh_wrapper_help}" != "1" ]]; then
      _gh_wrapper_sync_identity "$@" || exit 1
    fi
    _gh_wrapper_block_bypass "$@" || exit 1

    _gh_wrapper_approval_gate "$@" || exit 1
    if [[ "${_gh_wrapper_help}" != "1" ]]; then
      _gh_wrapper_maybe_review strict "$@" || exit 1
      # Attached labels must exist (#323); a near match chosen at the prompt rewrites argv.
      _gh_wrapper_label_args=()
      _gh_wrapper_label_rewritten=0
      _gh_wrapper_check_labels "$@" || exit 1
      if [[ "${_gh_wrapper_label_rewritten}" == "1" ]]; then
        set -- "${_gh_wrapper_label_args[@]}"
      fi
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

  # Only needed for the final gh invocation below — computed here (after the
  # _GH_REVIEW_DONE-guarded checks above) rather than unconditionally at the
  # top of this block, so we don't do a needless PATH scan before knowing
  # this call is going to pass those checks.
  REAL_GH="$(_gh_wrapper_find_real_gh)"
  # Defensive: _gh_wrapper_find_real_gh currently fails hard on lookup
  # failure (and set -e aborts the assignment), but if it ever returns 0
  # with empty output we'd otherwise run "" "$@" and produce a confusing
  # low-level "command not found" error. Check explicitly instead.
  if [[ -z "${REAL_GH}" ]]; then
    echo "[gh] ERROR: could not locate real gh binary on PATH" >&2
    exit 1
  fi

  # Apply the token _gh_wrapper_sync_identity selected, for the real gh only.
  # Set here, after the review hook, so both modes hand that hook the same
  # token (function mode applies it only on its final `command gh`). Entered
  # from function mode (_GH_REVIEW_DONE), this is "" and GH_TOKEN already
  # carries the selection.
  if [[ -n "${_gh_wrapper_token_var}" ]]; then
    GH_TOKEN="${!_gh_wrapper_token_var}"
    export GH_TOKEN
  fi
  # A keyring token is no env-token override, so the scope hint has nothing to say.
  if [[ "${_gh_wrapper_token_var}" == "_gh_wrapper_keyring_token" || -n "${_GH_WRAPPER_KEYRING:-}" ]]; then
    unset _GH_WRAPPER_KEYRING
    exec "${REAL_GH}" "$@"
  fi

  # The F4 scope hint exists for one situation: an env-var token (GH_TOKEN, or
  # GITHUB_TOKEN as gh's fallback) is overriding the keyring and lacks a scope
  # the keyring token has. Only then is there anything to say beyond what gh
  # already prints (`gh auth refresh -s <scope>`). And the hint is for an
  # agent session, which cannot act on gh's own message: a human reading a
  # terminal can. So stderr is captured only when BOTH hold — an env token is
  # set AND stderr is not a terminal. Capturing costs gh its stderr TTY (colors,
  # and the interactive prompts of `gh auth login` / `gh pr create`, which
  # render on stderr) and lets tee reorder stderr against stdout; a human with
  # GH_TOKEN exported in an interactive shell must not pay that on every call.
  #
  # Otherwise, exec as before: gh owns the terminal outright and the wrapper
  # process is gone. Only this standalone path runs the hint — function mode
  # reaches it through `command gh`, which lands right here. If ~/.local/bin/gh
  # is not on PATH, no hint is printed; that is the documented limit.
  if [[ -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" ]] || [[ -t 2 ]]; then
    exec "${REAL_GH}" "$@"
  fi
  _gh_wrapper_rc=0
  _gh_wrapper_run_with_scope_hint "${REAL_GH}" "$@" || _gh_wrapper_rc=$?
  exit "${_gh_wrapper_rc}"
else
  # --- Function-definition mode (sourced from functions.sh) ---
  gh() {
    # Note whether this is a help request, but the REST/GraphQL bypass block
    # below must run regardless — `gh api pulls/123/merge --help` must not
    # escape it by appending --help.
    local help=0 arg
    # Local, so _gh_wrapper_sync_identity's selection (dynamic scope) lives
    # only as long as this call.
    local _gh_wrapper_token_var="" _gh_wrapper_keyring_token="" _gh_wrapper_app_token=""
    for arg in "$@"; do
      if [[ "${arg}" == "--help" || "${arg}" == "-h" ]]; then
        help=1
        break
      fi
    done

    # No identity routing for `gh auth` (account management) or --help.
    if [[ "${1:-}" != "auth" && "${help}" != "1" ]]; then
      _gh_wrapper_sync_identity "$@" || return 1
    fi

    _gh_wrapper_block_bypass "$@" || return 1

    _gh_wrapper_approval_gate "$@" || return 1

    if [[ "${help}" == "1" ]]; then
      # Set _GH_REVIEW_DONE so the ~/.local/bin/gh wrapper also skips review.
      _GH_REVIEW_DONE=1 command gh "$@"
      return $?
    fi

    _gh_wrapper_maybe_review warn "$@" || return 1

    # Attached labels must exist (#323); a near match chosen at the prompt rewrites argv.
    local -a _gh_wrapper_label_args=()
    local _gh_wrapper_label_rewritten=0
    _gh_wrapper_check_labels "$@" || return 1
    if [[ "${_gh_wrapper_label_rewritten}" == "1" ]]; then
      set -- "${_gh_wrapper_label_args[@]}"
    fi

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
    # PATH) does not run the review a second time. A selected token is
    # passed as a prefix assignment, so it reaches gh without changing the
    # caller's GH_TOKEN.
    if [[ "${_gh_wrapper_token_var}" == "_gh_wrapper_keyring_token" ]]; then
      GH_TOKEN="${_gh_wrapper_keyring_token}" _GH_WRAPPER_KEYRING=1 _GH_REVIEW_DONE=1 command gh "$@"
    elif [[ -n "${_gh_wrapper_token_var}" ]]; then
      GH_TOKEN="${!_gh_wrapper_token_var}" _GH_REVIEW_DONE=1 command gh "$@"
    else
      _GH_REVIEW_DONE=1 command gh "$@"
    fi
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
  export -f gh sugh _gh_wrapper_block_bypass _gh_wrapper_block_off_org_promotion _gh_wrapper_block_graphql_pr_mutation _gh_wrapper_spec_owner _gh_wrapper_find_subcommand _gh_wrapper_owner_in_org _gh_wrapper_approval_gate _gh_wrapper_api_value_flag _gh_wrapper_api_body_fields _gh_wrapper_norm_repo _gh_wrapper_gate_destination _gh_wrapper_dest_exempt _gh_wrapper_cap_kind _gh_wrapper_maybe_review _gh_wrapper_review_script_path _gh_wrapper_sync_identity _gh_wrapper_identity_for_owner _gh_wrapper_owner_token_var _gh_wrapper_find_real_gh _gh_wrapper_resolve_owner _gh_wrapper_resolve_target _gh_wrapper_app_route _gh_wrapper_force_draft_for_off_org _gh_wrapper_is_beacon_context _gh_wrapper_beacon_dir_is_explicit _gh_wrapper_keyring_login _gh_wrapper_keyring_users _gh_wrapper_resolve_switch_target _gh_wrapper_run_with_scope_hint _gh_wrapper_scope_from_file _gh_wrapper_print_scope_hint _gh_wrapper_redact_argv _gh_wrapper_redact_value _gh_wrapper_scoped_fallback _gh_wrapper_check_labels _gh_wrapper_label_repo _gh_wrapper_within_one_edit _gh_wrapper_label_near _gh_wrapper_label_interactive _gh_wrapper_real_gh_selected _gh_wrapper_label_choose
  export _gh_wrapper_review_script GH_WRAPPER_BEACON_DIR _GH_WRAPPER_BEACON_DIR_DEFAULT _gh_wrapper_app_minter
fi
