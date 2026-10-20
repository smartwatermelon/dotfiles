#!/usr/bin/env bash
# ~/.config/bash/git-wrapper.sh
# shellcheck shell=bash
# Canonical implementation of the `git` post-init hook trigger: after a
# successful `git init` (including `-C <dir>` and `git init <dir>` forms),
# runs the newly-created repo's post-checkout hook with null-SHA init
# parameters, since `git init` itself never fires post-checkout the way
# `git clone`/`git checkout` do.
#
# Unlike gh-wrapper.sh, this file has only one invocation mode: sourced from
# functions.sh, defining git() as a bash function. It is NOT symlinked into
# ~/.local/bin — git's wrapper logic only matters when git init is run from
# a bash session that already has this file's guard/hook-trigger behavior
# loaded via BASH_ENV, and no external (non-bash) caller invoking the raw
# git binary directly creates a correctness or safety gap worth solving by
# shadowing the system git binary for every tool on the machine.

# Restore the shell's working directory without letting cd consult CDPATH
# (a non-empty CDPATH would make cd echo the resolved path to stdout on a
# CDPATH-resolved match, corrupting this wrapper's output-transparency
# guarantee). No-ops silently if dir is empty or no longer exists — this
# runs from an EXIT/RETURN-style trap where the original directory may have
# been removed out from under us. See smartwatermelon/dotfiles#176.
_git_wrapper_restore_dir() {
  local dir="${1:-}"
  [[ -z "${dir}" ]] && return 0
  CDPATH='' cd "${dir}" 2>/dev/null || true
}

# Make one branch-name segment: lowercase, spaces and "/" become "-", other
# characters outside [a-z0-9._-] are dropped.
_git_wrapper_slug() {
  local s
  s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  s="${s//\//-}"
  s="${s//[[:space:]]/-}"
  s="${s//[^a-z0-9._-]/}"

  # Squeeze runs of "-" and "." (git rejects ".."), then trim both ends
  while [[ "${s}" == *--* ]]; do s="${s//--/-}"; done
  while [[ "${s}" == *..* ]]; do s="${s//../.}"; done
  while [[ "${s}" == [-.]* ]]; do s="${s#?}"; done
  while [[ "${s}" == *[-.] ]]; do s="${s%?}"; done

  # Git also rejects a component ending in ".lock"
  [[ "${s}" == *.lock ]] && s="${s%.lock}-lock"
  printf '%s' "${s}"
}

# The App token minter beside this file's real path; ~/.config/bash links may lag (claude-config#659).
_git_wrapper_app_minter="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null)" || _git_wrapper_app_minter="${BASH_SOURCE[0]}"
_git_wrapper_app_minter="${_git_wrapper_app_minter%/*}/gh-app-token.sh"

# A push to a repo in gh-app-routes.conf goes over HTTPS as the GitHub App (claude-config#659).

# Sets the caller's _git_wrapper_push_cfg to the -c options for that; leaves it empty if unrouted.

# The remote's stored URL never changes: a one-call insteadOf maps it, and a credential helper supplies the token.

# Returns 1 to block: a routed push that cannot be made as the App never falls back to SSH as Andrew.
_git_wrapper_app_push() {
  local -a args=("$@") globals=() items=()
  local n=$# i=0 sub="" remote="" repo_opt="" branch="" urls="" url item repo rc is_name=0 routed=0 unrouted=0
  local minter="${_git_wrapper_app_minter:-}" rewrites="" got="" alias_val=""
  local -a alias_words=()
  _git_wrapper_push_cfg=()
  while ((i < n)); do
    case "${args[i]}" in
      -C | -c | --git-dir | --work-tree | --namespace | --config-env)
        globals+=("${args[i]}" "${args[i + 1]:-}")
        i=$((i + 2))
        ;;
      -*)
        globals+=("${args[i]}")
        i=$((i + 1))
        ;;
      *)
        sub="${args[i]}"
        i=$((i + 1))
        break
        ;;
    esac
  done
  # An alias that expands to push (alias.pp = push -u, or via another alias) is a push too. !shell aliases are not.
  local depth=0
  while [[ -n "${sub}" && "${sub}" != "push" ]] && ((depth < 10)); do
    depth=$((depth + 1))
    # git ignores aliases named like a builtin, so common builtins skip the config lookup.
    case "${sub}" in
      add | branch | cat-file | checkout | clone | commit | config | diff | fetch | for-each-ref | init | log | \
        ls-files | merge | pull | rebase | remote | reset | rev-list | rev-parse | show | stash | status | \
        switch | symbolic-ref | tag | worktree) break ;;
      *) ;;
    esac
    alias_val="$(command git ${globals[@]+"${globals[@]}"} config --get "alias.${sub}" 2>/dev/null)" || break
    [[ -n "${alias_val}" && "${alias_val}" != !* ]] || break
    read -r -a alias_words <<<"${alias_val}"
    args=("${alias_words[@]}" ${args[@]+"${args[@]:i}"})
    n=${#args[@]}
    sub="${args[0]}"
    i=1
  done
  [[ "${sub}" == "push" ]] || return 0
  # The first non-option is the repository; --repo only counts when none is given (git push --help).
  while ((i < n)); do
    case "${args[i]}" in
      --)
        remote="${args[i + 1]:-}"
        break
        ;;
      --repo) repo_opt="${args[i + 1]:-}" && i=$((i + 2)) ;;
      --repo=*) repo_opt="${args[i]#--repo=}" && i=$((i + 1)) ;;
      -o | --push-option | --receive-pack | --exec) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *)
        remote="${args[i]}"
        break
        ;;
    esac
  done
  [[ -z "${remote}" ]] && remote="${repo_opt}"
  if [[ -z "${remote}" ]]; then
    branch="$(command git ${globals[@]+"${globals[@]}"} symbolic-ref --quiet --short HEAD 2>/dev/null)" || branch=""
    remote="$(command git ${globals[@]+"${globals[@]}"} config --get "branch.${branch}.pushRemote" 2>/dev/null)" \
      || remote="$(command git ${globals[@]+"${globals[@]}"} config --get remote.pushDefault 2>/dev/null)" \
      || remote="$(command git ${globals[@]+"${globals[@]}"} config --get "branch.${branch}.remote" 2>/dev/null)" \
      || remote="origin"
  fi
  if command git ${globals[@]+"${globals[@]}"} config --get "remote.${remote}.url" >/dev/null 2>&1; then
    is_name=1
    if ! urls="$(command git ${globals[@]+"${globals[@]}"} remote get-url --push --all "${remote}")"; then
      echo "[git] ERROR: cannot read the push URLs of remote '${remote}'; refusing rather than guess the route." >&2
      return 1
    fi
  else
    urls="${remote}"
  fi
  [[ -n "${urls}" ]] || return 0
  if [[ ! -f "${minter}" ]]; then
    echo "[git] ERROR: App token minter missing (${minter}); cannot tell if this push is routed. Refusing." >&2
    return 1
  fi
  while IFS= read -r url; do
    [[ -z "${url}" ]] && continue
    rc=0
    item="$("${BASH}" "${minter}" route "${url}")" || rc=$?
    if ((rc == 1)); then
      unrouted=1
      continue
    elif ((rc != 0)); then
      echo "[git] ERROR: gh-app-routes.conf is malformed for ${url}; refusing to push." >&2
      return 1
    fi
    routed=1
    if ! repo="$("${BASH}" "${minter}" repo "${url}")"; then
      echo "[git] ERROR: routed URL ${url} names no github.com repo; refusing to push." >&2
      return 1
    fi
    # A second, different item on one remote counts as mixed below.
    if ((${#items[@]} == 0)); then
      items=("${item}")
    elif [[ "${items[0]}" != "${item}" ]]; then
      items+=("${item}")
    fi
    case "${url}" in
      https://github.com/*) ;;
      *) rewrites="${rewrites}url.https://github.com/${repo}.git.insteadOf=${url}"$'\n' ;;
    esac
  done <<<"${urls}"
  ((routed == 1)) || return 0
  if ((unrouted == 1 || ${#items[@]} != 1)); then
    echo "[git] ERROR: remote '${remote}' mixes GitHub App routes with other URLs; refusing to push." >&2
    return 1
  fi
  item="${items[0]}"
  if ! "${BASH}" "${minter}" ensure "${item}"; then
    echo "[git] ERROR: this push is routed to a GitHub App (gh-app-routes.conf), but no App token could be minted." >&2
    echo "[git] Failing closed: a routed push never falls back to SSH as Andrew." >&2
    return 1
  fi
  # Reset every inherited helper first: osxkeychain would answer with a stored personal credential.
  _git_wrapper_push_cfg=(-c credential.helper=
    -c "credential.helper=!$(printf '%q' "${BASH}") $(printf '%q' "${minter}") git-credential $(printf '%q' "${item}")"
    -c credential.useHttpPath=true -c core.askPass=)
  while IFS= read -r url; do
    [[ -n "${url}" ]] && _git_wrapper_push_cfg+=(-c "${url}")
  done <<<"${rewrites}"
  # Prove the rewrite took: every push URL must now be https://github.com, or the push would go as Andrew.
  if ((is_name == 1)); then
    got="$(command git ${globals[@]+"${globals[@]}"} "${_git_wrapper_push_cfg[@]}" remote get-url --push --all "${remote}")" || got=""
  else
    got="$(command git ${globals[@]+"${globals[@]}"} "${_git_wrapper_push_cfg[@]}" ls-remote --get-url "${remote}")" || got=""
    # ls-remote ignores pushInsteadOf, which a push to a literal URL applies: with any such rule, refuse.
    if command git ${globals[@]+"${globals[@]}"} config --get-regexp '^url\..*\.pushinsteadof$' >/dev/null 2>&1; then
      echo "[git] ERROR: a url.*.pushInsteadOf rule could redirect this routed push; push to a named remote." >&2
      _git_wrapper_push_cfg=()
      return 1
    fi
  fi
  while IFS= read -r url; do
    if [[ "${url}" != https://github.com/* ]]; then
      echo "[git] ERROR: routed push URL did not rewrite to https://github.com (got '${url}'); refusing." >&2
      _git_wrapper_push_cfg=()
      return 1
    fi
  done <<<"${got:-none}"
  echo "[git] Pushing as the GitHub App over HTTPS (gh-app-routes.conf: ${item})." >&2
}

git() {
  # Guard against recursive calls
  if [[ -n "${_GIT_WRAPPER_ACTIVE:-}" ]]; then
    command git "$@"
    return $?
  fi

  # git checkout -b 'feat(api)!: Add X' -> git checkout -b feat/api-add-x
  # Exact 3-arg checkout -b / switch -c only; git rejects ": " anyway.
  if (($# == 3)) \
    && { [[ "$1" == "checkout" && "$2" == "-b" ]] \
      || [[ "$1" == "switch" && "$2" == "-c" ]]; }; then
    local header_re='^([[:alnum:]_-]+)(\(([^)]*)\))?!?: (.*)$'
    if [[ "$3" =~ ${header_re} ]]; then
      local raw_type="${BASH_REMATCH[1]}"
      local raw_scope="${BASH_REMATCH[3]}"
      local raw_subject="${BASH_REMATCH[4]}"
      local branch_type branch_scope branch_subject
      branch_type="$(_git_wrapper_slug "${raw_type}")"
      branch_scope="$(_git_wrapper_slug "${raw_scope}")"
      branch_subject="$(_git_wrapper_slug "${raw_subject}")"

      # Rewrite "$@", not an array copy: bash 3.2 reads an empty one as unbound
      if [[ -n "${branch_type}" && -n "${branch_subject}" ]]; then
        set -- "$1" "$2" \
          "${branch_type}/${branch_scope:+${branch_scope}-}${branch_subject}"
      fi
    fi
  fi

  # A routed push runs as the GitHub App and returns here; see _git_wrapper_app_push.
  local -a _git_wrapper_push_cfg=()
  _git_wrapper_app_push "$@" || return 1
  if ((${#_git_wrapper_push_cfg[@]} > 0)); then
    GIT_TERMINAL_PROMPT=0 GIT_ASKPASS='' SSH_ASKPASS='' command git "${_git_wrapper_push_cfg[@]}" "$@"
    return $?
  fi

  # Run the real git command first
  command git "$@"
  local git_result=$?

  # Only proceed if command succeeded and was "git init"
  # Find subcommand, -C flag, and optional directory argument
  local is_init=false
  local init_dir=""
  local c_flag_dir=""
  local found_subcommand=false
  local next_is_c_arg=false
  local skip_next=false

  for arg in "$@"; do
    # Capture argument after -C flag
    if [[ "${next_is_c_arg}" == "true" ]]; then
      c_flag_dir="${arg}"
      next_is_c_arg=false
      continue
    fi

    # Drop the value of an option that takes it as a separate argument (see
    # the two option lists below)
    if [[ "${skip_next}" == "true" ]]; then
      skip_next=false
      continue
    fi

    if [[ "${found_subcommand}" == "false" ]]; then
      case "${arg}" in
        # git only supports "-C <path>" with space, not "-C<path>"
        -C)
          next_is_c_arg=true
          continue
          ;;
        # Separate-value global options, or `-c k=v init` reads k=v as the
        # subcommand (#394); --exec-path only takes =
        -c | --git-dir | --work-tree | --namespace | --config-env)
          skip_next=true
          continue
          ;;
        # Any other flag, including the single-token --opt=value form
        -*)
          continue
          ;;
        # Not a flag: the subcommand, handled below
        *) ;;
      esac

      # First non-flag is the subcommand
      [[ "${arg}" == "init" ]] && is_init=true
      found_subcommand=true
      continue
    fi

    # Only init's arguments matter past this point
    [[ "${is_init}" == "true" ]] || break

    case "${arg}" in
      # Separate-value init options, or `init -b main <dir>` reads main as
      # the target dir (#394); --shared only takes =
      -b | --initial-branch | --template | --separate-git-dir | --object-format | --ref-format)
        skip_next=true
        continue
        ;;
      # Any other flag, including the single-token --opt=value form
      -*)
        continue
        ;;
      # Not a flag: the directory, handled below
      *) ;;
    esac

    # First non-flag after "init" is the directory
    init_dir="${arg}"
    break
  done

  # Determine the target directory: -C flag takes precedence, then init_dir
  local target_dir=""
  if [[ -n "${c_flag_dir}" && -n "${init_dir}" ]]; then
    # Both -C and directory arg: combine them
    target_dir="${c_flag_dir}/${init_dir}"
  elif [[ -n "${c_flag_dir}" ]]; then
    # Just -C flag
    target_dir="${c_flag_dir}"
  elif [[ -n "${init_dir}" ]]; then
    # Just directory arg
    target_dir="${init_dir}"
  fi

  if ((git_result != 0)) || [[ "${is_init}" != "true" ]]; then
    return "${git_result}"
  fi

  # Set guard to prevent recursion in hooks
  # Exported so child processes (hooks) also bypass wrapper
  export _GIT_WRAPPER_ACTIVE=1

  # Save current directory if we need to change it
  local original_dir=""
  if [[ -n "${target_dir}" ]]; then
    original_dir=$(pwd)
  fi

  # Trap to cleanup guard and restore directory
  # Use ${var:-} for set -u safety — locals may be out of scope in inherited contexts
  # _git_wrapper_restore_dir (defined above) scopes out CDPATH for its cd so
  # it can never resolve via CDPATH search and echo the resolved path to
  # stdout, which would corrupt this wrapper's transparency guarantee (its
  # whole purpose is to pass git's own output through unmodified). See
  # smartwatermelon/dotfiles#176.
  trap 'unset _GIT_WRAPPER_ACTIVE; _git_wrapper_restore_dir "${original_dir:-}"' RETURN

  # If init created a repo in a different directory, cd there first
  # This makes git rev-parse work from inside the new repo
  if [[ -n "${target_dir}" ]]; then
    if ! CDPATH='' cd "${target_dir}" 2>/dev/null; then
      # init already succeeded; failing here stops a `set -e` caller over
      # a repo that exists, so warn and pass git's result through (#394)
      echo "Warning: cannot cd to ${target_dir}; skipping post-checkout hook" >&2
      return "${git_result}"
    fi
  fi

  # Let git tell us where the .git directory is
  # We're now inside the repo, so this returns ".git" (relative path)
  local git_dir
  git_dir=$(command git rev-parse --git-dir 2>/dev/null)

  if [[ -n "${git_dir}" ]]; then
    local post_checkout="${git_dir}/hooks/post-checkout"

    if [[ -x "${post_checkout}" ]]; then
      # Run hook with init parameters
      # Parameters: <prev-head> <new-head> <branch-checkout-flag>
      # Both SHAs are null since there are no commits yet after git init
      # Note: We're already in repo root, no need to cd again
      local null_sha="0000000000000000000000000000000000000000"
      if ! "${post_checkout}" "${null_sha}" "${null_sha}" 1; then
        echo "Warning: post-checkout hook execution failed" >&2
      fi
    fi
  fi

  return "${git_result}"
}
# Export git AND the helpers it calls: an exported function only carries its
# own body into subshells, not functions it calls. git()'s RETURN trap calls
# _git_wrapper_restore_dir, so a subshell that inherits the exported git but
# did not source this file dies with "_git_wrapper_restore_dir: command not
# found" (exit 127) the first time that trap fires. BASH_ENV normally hides
# this by re-sourcing config in non-interactive children — but it is set to a
# HOME-relative path, so any child with a rewritten HOME (the test suite's
# fixtures, for one) resolves it to nothing and the helper vanishes while the
# inherited git remains. Same reasoning, and the same fix, as gh-wrapper.sh.
export -f git _git_wrapper_restore_dir _git_wrapper_slug _git_wrapper_app_push # Exported - overrides system git command globally
export _git_wrapper_app_minter
