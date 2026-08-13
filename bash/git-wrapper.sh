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

git() {
  # Guard against recursive calls
  if [[ -n "${_GIT_WRAPPER_ACTIVE:-}" ]]; then
    command git "$@"
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

  for arg in "$@"; do
    # Capture argument after -C flag
    if [[ "${next_is_c_arg}" == "true" ]]; then
      c_flag_dir="${arg}"
      next_is_c_arg=false
      continue
    fi

    # Check for -C flag (git only supports "-C <path>" with space, not "-C<path>")
    if [[ "${arg}" == "-C" ]]; then
      next_is_c_arg=true
      continue
    fi

    # Skip other flags
    if [[ "${arg}" == -* ]]; then
      continue
    fi

    # First non-flag is the subcommand
    if [[ "${found_subcommand}" == "false" ]]; then
      [[ "${arg}" == "init" ]] && is_init=true
      found_subcommand=true
      continue
    fi

    # Second non-flag (after "init") is the directory
    if [[ "${is_init}" == "true" && -z "${init_dir}" ]]; then
      init_dir="${arg}"
      break
    fi
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
      echo "Error: Cannot cd to ${target_dir}" >&2
      return 1 # Return failure, not git_result
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
export -f git # Exported - overrides system git command globally
