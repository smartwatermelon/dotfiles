# ~/.config/bash/functions.sh
#shellcheck shell=bash
# Shell functions

# Command-line entry point to pre-commit linter
lint() {
  local cfg="${HOME}/.config/pre-commit/config.yaml"

  # Check if config file exists
  if [[ ! -f "${cfg}" ]]; then
    echo "Error: Pre-commit config not found at ${cfg}" >&2
    return 1
  fi

  # Check if we're in a git repository
  local in_git_repo=false
  if git rev-parse --is-inside-work-tree &>/dev/null; then
    in_git_repo=true
  fi

  if [[ $# -eq 0 ]]; then
    # No arguments → run on all files
    if [[ "${in_git_repo}" == "true" ]]; then
      pre-commit run --all-files --config "${cfg}"
      return $?
    else
      echo "Error: --all-files requires being in a git repository" >&2
      echo "Usage: lint <file1> [file2] ... (specify files when outside git repo)" >&2
      return 1
    fi
  fi

  # Arguments given → expand globs and get absolute paths
  local files=()
  shopt -s nullglob globstar
  for f in "$@"; do
    # following ${f} should NOT be quoted (SC2066)
    for g in ${f}; do
      if [[ -f "${g}" ]]; then
        # Convert to absolute path to handle temp directory operations
        files+=("$(realpath "${g}")")
      fi
    done
  done
  shopt -u nullglob globstar

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "No files matched the patterns: $*" >&2
    return 1
  fi

  if [[ "${in_git_repo}" == "true" ]]; then
    # In git repo - run directly
    pre-commit run --files "${files[@]}" --config "${cfg}"
    return $?
  else
    # Not in git repo - create temporary git repo
    local temp_dir
    temp_dir=$(mktemp -d)
    local result=0
    local original_dir
    original_dir=$(pwd)

    # Cleanup function
    # Use ${var:-} for set -u safety — locals are out of scope when EXIT trap fires
    cleanup_temp_repo() {
      cd "${original_dir:-}" 2>/dev/null || true
      rm -rf "${temp_dir:-}"
      trap - EXIT # Unset trap
    }
    trap cleanup_temp_repo EXIT

    # Initialize git repo in temp directory
    cd "${temp_dir}" || {
      echo "Error: Failed to enter temp directory" >&2
      return 1
    }

    git init --quiet || {
      echo "Error: Failed to initialize git repo" >&2
      return 1
    }

    # Configure git user (required for some hooks)
    git config user.name "lint-function"
    git config user.email "lint@example.com"

    # Copy files to temp repo and create relative path mapping
    local temp_files=()
    local file_mapping=()
    for file in "${files[@]}"; do
      local basename
      basename=$(basename "${file}")
      local temp_file="${temp_dir}/${basename}"

      # Handle filename conflicts by appending numbers
      local counter=1
      while [[ -f "${temp_file}" ]]; do
        local name="${basename%.*}"
        local ext="${basename##*.}"
        if [[ "${name}" == "${basename}" ]]; then
          # No extension
          temp_file="${temp_dir}/${basename}_${counter}"
        else
          temp_file="${temp_dir}/${name}_${counter}.${ext}"
        fi
        ((counter += 1))
      done

      cp -p "${file}" "${temp_file}" || {
        echo "Error: Failed to copy ${file}" >&2
        return 1
      }

      temp_files+=("$(basename "${temp_file}")")
      file_mapping+=("${temp_file}:${file}")
    done

    # Stage files (required by some hooks)
    git add .

    # Run pre-commit on the files
    pre-commit run --files "${temp_files[@]}" --config "${cfg}" || result=$?

    # Copy modified files back to original locations
    for mapping in "${file_mapping[@]}"; do
      local temp_file="${mapping%%:*}"
      local orig_file="${mapping##*:}"

      if [[ -f "${temp_file}" && "${temp_file}" -nt "${orig_file}" ]]; then
        echo "Copying fixes back to ${orig_file}"
        cp -p "${temp_file}" "${orig_file}"
      fi
    done

    # Cleanup and return to original directory
    cleanup_temp_repo
    return "${result}"
  fi
}
# Not exported - interactive command only

# Get Homebrew root based on installation location
_get_homebrew_root() {
  if [[ -d /opt/homebrew ]]; then
    echo "/opt/homebrew"
  else
    echo "/usr/local"
  fi
}
export -f _get_homebrew_root # Exported - may be used by subscripts

# Brew cask
cask() {
  brew "$@" --cask
}
# Not exported - interactive command only

# Remove quarantine attribute from files (macOS)
vax() {
  if [[ -z "$1" ]]; then
    echo "Usage: vax <file>" >&2
    return 1
  fi

  if [[ ! -e "$1" ]]; then
    echo "Error: File not found: $1" >&2
    return 1
  fi

  xattr -v -d com.apple.quarantine "$1"
}
# Not exported - interactive command only

# History search function
# Searches bash history for specified pattern(s)
hgrep() {
  local pattern="$1"

  if [[ -z "${pattern}" ]]; then
    echo "Usage: hgrep <pattern>"
    return 1
  fi

  # Use history command and pipe to grep with highlighting
  H="$(history)"
  grep --color=auto "${pattern}" <<<"${H}"
}
# Not exported - interactive command only

# Get name of parent script into variable
_what_is_this() {
  export THIS
  THIS=$(basename "${0}" 2>/dev/null || echo "script")
}
# Not exported - internal helper

# Send notification
_notif() {
  [[ -z "$1" ]] && return 0
  MSG="$1"
  _what_is_this

  # Always echo to terminal (important for seeing progress in output)
  echo "${THIS}: ${MSG}"

  # Also send desktop notification if tools available (skipped in SSH sessions)
  if command -v terminal-notifier &>/dev/null && command -v timeout &>/dev/null; then
    echo "${MSG}" | timeout 1 terminal-notifier -title "${THIS}" 2>/dev/null
  fi
}
# Not exported - internal helper

# Kill duplicate processes
# Safely kills other instances of a named process
# Usage: _kill_clones [process_name]
#   If no argument provided, uses ${THIS} from _what_is_this
_kill_clones() {
  local process_name="${1:-${THIS}}"
  local this_pid=$$

  # Safety check: refuse to kill critical system processes
  case "${process_name}" in
    bash | sh | zsh | fish | tcsh | csh | ksh | "" | "-bash" | "-sh" | "-zsh")
      echo "Error: _kill_clones refuses to kill shell processes: '${process_name}'" >&2
      return 1
      ;;
    *)
      # Process name is safe to kill
      ;;
  esac

  # Safety check: verify we're in a script context, not interactive shell
  if [[ "${process_name}" == "-"* ]] || [[ -z "${process_name}" ]]; then
    echo "Error: _kill_clones should only be used in scripts, not interactive shells" >&2
    return 1
  fi

  # Find and kill matching processes (excluding this one)
  local killed_count=0
  while IFS= read -r pid; do
    if [[ "${pid}" != "${this_pid}" ]] && [[ -n "${pid}" ]]; then
      _notif "killing ${pid}..."
      kill "${pid}" 2>/dev/null && ((killed_count += 1))
    fi
  done < <(pgrep -fl "${process_name}" | grep -v tail | awk '{print $1}' || true)

  if [[ ${killed_count} -gt 0 ]]; then
    _notif "Killed ${killed_count} clone(s) of ${process_name}"
  fi

  return 0
}
# Not exported - internal helper

# ============================================================================
# Package Manager Update Functions
# ============================================================================
# All update functions are exported to allow independent invocation
# (e.g., "_npm_update" to update only npm, "updates" to update all)
# Each function is self-sufficient: creates log directory, rotates log, handles errors

# Log rotation handled by logrotate (configured in /opt/homebrew/etc/logrotate.d/local-state-logs)
# Runs daily at 06:25 AM via launchd service (homebrew.mxcl.logrotate)

# Write update output to log file; also echo to terminal during interactive runs
# Prevents duplicate log entries when stdout is already redirected to the log
# (e.g. via LaunchAgent StandardOutPath)
_update_log() {
  if [[ -t 1 ]]; then
    tee -a "${HOME}/.local/state/updates.out"
  else
    cat >>"${HOME}/.local/state/updates.out"
  fi
}
# Not exported - internal helper

# Update Homebrew packages
# Package managers provide their own network error diagnostics, so no pre-check needed
_homebrew_update() {
  mkdir -p "${HOME}/.local/state" || return $?

  local timestamp output result
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  _notif "Updating Homebrew..."
  # Note: tee failures are acceptable - output is shown to user even if logging fails
  echo "=== homebrew update ${timestamp} ===" | _update_log

  output=$(brew update --verbose 2>&1)
  result=$?
  echo "${output}" | _update_log
  if [[ "${result}" -ne 0 ]]; then
    _notif "brew update failed (exit ${result})"
    return "${result}"
  fi

  output=$(brew upgrade --verbose 2>&1)
  result=$?
  echo "${output}" | _update_log
  if [[ "${result}" -ne 0 ]]; then
    _notif "brew upgrade failed (exit ${result})"
    return "${result}"
  fi

  output=$(brew cleanup --prune=all -s 2>&1)
  result=$?
  echo "${output}" | _update_log
  if [[ "${result}" -ne 0 ]]; then
    _notif "brew cleanup failed (exit ${result})"
    return "${result}"
  fi

  # brew doctor often returns non-zero for warnings; log but don't fail
  output=$(brew doctor 2>&1)
  result=$?
  echo "${output}" | _update_log
  if [[ "${result}" -eq 0 ]]; then
    _notif "Homebrew update completed successfully"
  else
    _notif "Homebrew update completed with warnings (check log)"
  fi

  return 0
}
# Not exported - internal helper

# Update global npm packages
# Returns 0 (success) if npm is not installed to allow graceful degradation
_npm_update() {
  if ! command -v npm &>/dev/null; then
    _notif "npm not found, skipping"
    return 0 # Not an error - npm is optional
  fi

  mkdir -p "${HOME}/.local/state" || return $?

  local timestamp output result
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  _notif "Updating npm packages..."
  echo "=== npm update ${timestamp} ===" | _update_log

  output=$(npm update -g --verbose 2>&1)
  result=$?
  echo "${output}" | _update_log

  if [[ "${result}" -eq 0 ]]; then
    _notif "npm update completed"
  else
    _notif "npm update failed (exit ${result})"
  fi
  return "${result}"
}
# Not exported - internal helper

# Update pipx packages
# Returns 0 (success) if pipx is not installed to allow graceful degradation
_pipx_update() {
  if ! command -v pipx &>/dev/null; then
    _notif "pipx not found, skipping"
    return 0 # Not an error - pipx is optional
  fi

  mkdir -p "${HOME}/.local/state" || return $?

  local timestamp output result
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  _notif "Updating pipx packages..."
  echo "=== pipx update ${timestamp} ===" | _update_log

  output=$(pipx upgrade-all --verbose 2>&1)
  result=$?
  echo "${output}" | _update_log

  if [[ "${result}" -eq 0 ]]; then
    _notif "pipx update completed"
  else
    _notif "pipx update failed (exit ${result})"
  fi
  return "${result}"
}
# Not exported - internal helper

# Update Ruby gems
# Returns 0 (success) if gem is not installed to allow graceful degradation
_gem_update() {
  if ! command -v gem &>/dev/null; then
    _notif "gem not found, skipping"
    return 0 # Not an error - gem is optional
  fi

  mkdir -p "${HOME}/.local/state" || return $?

  local timestamp output result
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  _notif "Updating Ruby gems..."
  echo "=== gem update ${timestamp} ===" | _update_log

  output=$(gem update --verbose 2>&1)
  result=$?
  echo "${output}" | _update_log

  if [[ "${result}" -ne 0 ]]; then
    _notif "gem update failed (exit ${result})"
    return "${result}"
  fi

  # gem cleanup is non-critical - warn on failure but don't fail overall
  output=$(gem cleanup --verbose 2>&1)
  local cleanup_result=$?
  echo "${output}" | _update_log

  if [[ "${cleanup_result}" -eq 0 ]]; then
    _notif "gem update and cleanup completed"
  else
    _notif "gem update succeeded, but cleanup failed (exit ${cleanup_result}) - check log"
  fi

  return 0 # Return success since update succeeded (cleanup failure is non-critical)
}
# Not exported - internal helper

# Update macOS system software
# Prompts for admin credentials via system dialog if needed
# Returns non-zero on failure (fail-fast)
_softwareupdate() {
  if ! command -v softwareupdate &>/dev/null; then
    _notif "softwareupdate not found, skipping"
    return 0 # Not an error - macOS-specific tool
  fi

  mkdir -p "${HOME}/.local/state" || return $?

  local timestamp output result
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  _notif "Updating macOS system software..."
  echo "=== softwareupdate ${timestamp} ===" | _update_log

  # Run softwareupdate without sudo - it will prompt for admin credentials if needed
  # Use pipefail to capture exit code, run directly to preserve TTY for auth prompts
  (
    set -o pipefail
    softwareupdate -i -a 2>&1 | _update_log
  )
  result=$?

  if [[ "${result}" -ne 0 ]]; then
    _notif "softwareupdate failed (exit ${result})"
    return "${result}" # Fail-fast
  else
    _notif "softwareupdate completed"
    return 0
  fi
}
# Not exported - internal helper

# Update Mac App Store applications
# Returns 0 (success) if mas is not installed to allow graceful degradation
# Fails fast if mas upgrade fails (including authentication issues)
_mas_update() {
  if ! command -v mas &>/dev/null; then
    _notif "mas not found, skipping"
    return 0 # Not an error - mas is optional
  fi

  mkdir -p "${HOME}/.local/state" || return $?

  local timestamp output result
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  _notif "Updating Mac App Store apps..."
  echo "=== mas update ${timestamp} ===" | _update_log

  # Note: mas account doesn't work on macOS 12+
  # Let mas upgrade fail naturally if not authenticated
  output=$(mas upgrade 2>&1)
  result=$?
  echo "${output}" | _update_log

  if [[ "${result}" -ne 0 ]]; then
    _notif "mas upgrade failed (exit ${result}) - check App Store authentication"
    return "${result}" # Fail-fast
  else
    _notif "mas upgrade completed"
    return 0
  fi
}
# Not exported - internal helper

# Update Claude Code CLI
# Returns 0 (success) if claude is not installed to allow graceful degradation
# Respects DISABLE_AUTOUPDATER=1 in ~/.claude/settings.json
_claude_update() {
  if ! command -v claude &>/dev/null; then
    _notif "claude not found, skipping"
    return 0 # Not an error - claude is optional
  fi

  # Check if autoupdater is disabled via settings
  local settings_file="${HOME}/.claude/settings.json"
  if [[ -f "${settings_file}" ]]; then
    if command -v jq &>/dev/null; then
      local disabled
      disabled=$(jq -r '.env.DISABLE_AUTOUPDATER // ""' "${settings_file}" 2>/dev/null)
      if [[ "${disabled}" == "1" ]]; then
        _notif "claude update disabled via settings, skipping"
        return 0
      fi
    else
      _notif "Warning: jq not installed, cannot check DISABLE_AUTOUPDATER setting"
    fi
  fi

  mkdir -p "${HOME}/.local/state" || return $?

  local timestamp binary_output binary_result
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  _notif "Updating Claude Code..."
  echo "=== claude update ${timestamp} ===" | _update_log

  binary_output=$(claude update 2>&1)
  binary_result=$?
  echo "${binary_output}" | _update_log

  if [[ "${binary_result}" -eq 0 ]]; then
    _notif "claude update completed"
  else
    _notif "claude update failed (exit ${binary_result})"
    return "${binary_result}"
  fi

  # Update git-sourced Claude Code components (skills, hooks, etc.)
  # Best-effort — failure here does not affect the binary update result.
  local tools_script="${HOME}/.claude/scripts/update-tools.sh"
  if [[ -x "${tools_script}" ]]; then
    _notif "Updating Claude Code tools..."
    local tools_output tools_result
    tools_output=$("${tools_script}" 2>&1)
    tools_result=$?
    echo "${tools_output}" | _update_log
    if [[ "${tools_result}" -eq 0 ]]; then
      _notif "claude tools update completed"
    else
      _notif "claude tools update failed (exit ${tools_result})"
    fi
  fi

  return "${binary_result}"
}
# Not exported - internal helper

# Orchestrate all system updates
# Each updater function is self-sufficient and creates its own log directory
updates() {
  _notif "Starting system updates..."

  # Run updates in order: Homebrew first (updates other package managers)
  # Fail fast: stop on first failure
  _homebrew_update || return $?
  _softwareupdate || return $?
  _mas_update || return $?
  _npm_update || return $?
  _pipx_update || return $?
  _gem_update || return $?
  _claude_update || return $?

  _notif "All updates completed successfully"
  return 0
}
# Not exported - interactive command only

# Extract compressed files (handles multiple formats)
extract() {
  if [[ -f "$1" ]]; then
    case "$1" in
      *.tar.bz2) tar xjf "$1" ;;
      *.tar.gz) tar xzf "$1" ;;
      *.tar.xz) tar xJf "$1" ;;
      *.bz2) bunzip2 "$1" ;;
      *.rar) unrar x "$1" ;;
      *.gz) gunzip "$1" ;;
      *.tar) tar xf "$1" ;;
      *.tbz2) tar xjf "$1" ;;
      *.tgz) tar xzf "$1" ;;
      *.zip) unzip "$1" ;;
      *.Z) uncompress "$1" ;;
      *.7z) 7z x "$1" ;;
      *) echo "'$1' cannot be extracted via extract()" ;;
    esac
  else
    echo "'$1' is not a valid file"
  fi
}

# Create a new directory and enter it
mkcd() {
  mkdir -p "$1" && cd "$1" || return
}
# Not exported - interactive command only

# Jump to git repository root
cdroot() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null)
  if [[ -n "${root}" ]]; then
    cd "${root}" || return
  else
    echo "Not in a git repository" >&2
    return 1
  fi
}
# Not exported - interactive command only

# Create and cd into a dated directory
mkdate() {
  local dir="${1:-$(date +%Y-%m-%d)}"
  mkdir -p "${dir}" && cd "${dir}" || return
}
# Not exported - interactive command only

# Toggle or set liquidprompt display mode
# Usage: lp_mode [single|multi|toggle]
# Default: toggle (when no argument provided)
lp_mode() {
  # Check if liquidprompt is loaded
  if ! type -t lp_theme &>/dev/null; then
    echo "Error: liquidprompt is not loaded" >&2
    return 1
  fi

  local mode="${1:-toggle}"

  case "${mode}" in
    single)
      LP_MARK_PREFIX=" "
      echo "Switched to single-line prompt"
      ;;
    multi | multiline)
      LP_MARK_PREFIX=$'\n'
      echo "Switched to multi-line prompt"
      ;;
    toggle)
      if [[ "${LP_MARK_PREFIX}" == " " ]]; then
        LP_MARK_PREFIX=$'\n'
        echo "Switched to multi-line prompt"
      else
        LP_MARK_PREFIX=" "
        echo "Switched to single-line prompt"
      fi
      ;;
    *)
      echo "Usage: lp_mode [single|multi|toggle]" >&2
      echo "  single   - Single-line prompt (default)" >&2
      echo "  multi    - Multi-line prompt ($ on own line)" >&2
      echo "  toggle   - Toggle between modes (default when no argument)" >&2
      return 1
      ;;
  esac
}
# Not exported - interactive command only

# ============================================================================
# Git CLI Wrapper
# ============================================================================
# Intercepts `git init` to trigger automatic .claude/ infrastructure creation
# All other git commands pass through unchanged
#
# SIMPLIFIED: Uses git rev-parse to find repo location, eliminating complex
# argument parsing. The init.templateDir already copies hooks, we just need
# to trigger post-checkout.

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
  trap 'unset _GIT_WRAPPER_ACTIVE; [[ -n "${original_dir:-}" ]] && cd "${original_dir:-}" 2>/dev/null || true' RETURN

  # If init created a repo in a different directory, cd there first
  # This makes git rev-parse work from inside the new repo
  if [[ -n "${target_dir}" ]]; then
    if ! cd "${target_dir}" 2>/dev/null; then
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

# ============================================================================
# GitHub CLI Wrapper
# ============================================================================
# Intercepts `gh pr merge` to run pre-merge review
# All other gh commands pass through unchanged

gh() {
  local review_script="${HOME}/.claude/hooks/pre-merge-review.sh"

  # Block: gh api .../pulls/{number}/merge (REST API merge bypass)
  # Block: gh api graphql with mergePullRequest mutation (GraphQL bypass)
  #
  # IMPORTANT: These checks run BEFORE the --help early-return below so that
  # `gh api .../pulls/NNN/merge --help` cannot bypass this defense by
  # appending --help to the command.
  #
  # This is the shell-wrapper layer; the Claude Code PreToolUse hook
  # (hook-block-api-merge.sh) is the primary layer.
  #
  # Suffix boundary prevents false positives on paths like pulls/NNN/merge_status.
  # If gh pr merge fails: report the failure, ask the human to merge manually.
  if [[ "$1" == "api" ]] && printf '%s\n' "$*" | grep -qE 'pulls/[0-9]+/merge([[:space:]]|$|[^[:alnum:]_])'; then
    echo "[gh] BLOCKED: Direct REST API PR merge bypasses pre-merge review and merge authorization." >&2
    echo "[gh] This endpoint skips pre-merge-review.sh and the merge-lock check." >&2
    echo "[gh] Use 'gh pr merge <number>' instead." >&2
    echo "[gh] If gh pr merge fails, report the failure and ask the human to merge manually." >&2
    return 1
  fi

  if [[ "$1" == "api" ]] && printf '%s\n' "$*" | grep -qE 'graphql.*mergePullRequest[[:space:]]*\('; then
    echo "[gh] BLOCKED: GraphQL mergePullRequest mutation bypasses pre-merge review and merge authorization." >&2
    echo "[gh] Use 'gh pr merge <number>' instead." >&2
    echo "[gh] If gh pr merge fails, report the failure and ask the human to merge manually." >&2
    return 1
  fi

  # Pass help requests directly to the real gh — no review needed.
  # Set _GH_REVIEW_DONE so ~/.local/bin/gh wrapper also skips review.
  for arg in "$@"; do
    if [[ "${arg}" == "--help" || "${arg}" == "-h" ]]; then
      _GH_REVIEW_DONE=1 command gh "$@"
      return $?
    fi
  done

  # Intercept: gh [global-flags] pr merge [...]
  # Parse past known two-token global flags (flag + separate value) to find the
  # actual positional subcommand. This handles both the standard form:
  #   gh pr merge NNN
  # and the global-flag bypass form:
  #   gh -R owner/repo pr merge NNN
  local _gh_sub="" _gh_subsub="" _gh_skip_next=0
  for _gh_arg in "$@"; do
    if [[ "${_gh_skip_next}" == "1" ]]; then
      _gh_skip_next=0
      continue
    fi
    case "${_gh_arg}" in
      -R | --repo | --hostname | --config-dir | --token) _gh_skip_next=1 ;;
      --*=*) ;; # --flag=value: single token, no separate value to skip
      -*) ;;    # other single-token flags: skip
      *)
        if [[ -z "${_gh_sub}" ]]; then
          _gh_sub="${_gh_arg}"
        else
          _gh_subsub="${_gh_arg}"
          break
        fi
        ;;
    esac
  done
  if [[ "${_gh_sub}" == "pr" && "${_gh_subsub}" == "merge" ]]; then
    if [[ -x "${review_script}" ]]; then
      "${review_script}" "$@" || return 1
    else
      echo "[gh] Warning: pre-merge review script not found or not executable" >&2
      echo "[gh] Expected: ${review_script}" >&2
      echo "[gh] Proceeding without review..." >&2
    fi
  fi

  # Run the real gh command. Set _GH_REVIEW_DONE so ~/.local/bin/gh wrapper
  # does not run the review a second time (prevents double review).
  _GH_REVIEW_DONE=1 command gh "$@"
}
export -f gh # Exported - overrides system gh command globally

# ============================================================================
# gpush — Push, create PR, wait for CI, merge, and clean up in one command
# ============================================================================
# Usage: gpush [--no-merge]
#   --no-merge  Stop after CI passes (don't authorize or merge)
#
# Not exported — user-facing convenience function only

gpush() {
  # Validate arguments
  case "${1:-}" in
    --no-merge) ;;
    "") ;;
    *)
      echo "Usage: gpush [--no-merge]" >&2
      return 1
      ;;
  esac

  local no_merge=false
  if [[ "${1:-}" == "--no-merge" ]]; then
    no_merge=true
  fi

  local GREEN='\033[0;32m'
  local RED='\033[0;31m'
  local BLUE='\033[0;34m'
  local NC='\033[0m'

  # Step 1: Guard — refuse to run on main/master
  local branch
  branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
  if [[ -z "${branch}" || "${branch}" == "main" || "${branch}" == "master" ]]; then
    echo -e "${RED}[gpush]${NC} Refusing to run on ${branch:-detached HEAD}. Create a branch first." >&2
    return 1
  fi
  echo -e "${BLUE}[gpush]${NC} Branch: ${branch}"

  # Step 2: Push
  echo -e "${BLUE}[gpush]${NC} Pushing to origin..."
  if ! git push -u origin HEAD; then
    echo -e "${RED}[gpush]${NC} Push failed." >&2
    return 1
  fi

  # Step 3: Create PR (or detect existing one)
  local pr_number=""
  local pr_output
  echo -e "${BLUE}[gpush]${NC} Creating PR..."
  if pr_output=$(gh pr create --fill 2>&1); then
    # Extract PR number from URL in output (last line is typically the URL)
    pr_number=$(echo "${pr_output}" | grep -oE '/pull/[0-9]+' | tail -1 | grep -oE '[0-9]+')
    if [[ -z "${pr_number}" ]]; then
      echo -e "${RED}[gpush]${NC} Could not parse PR number from create output." >&2
      echo "${pr_output}" >&2
      return 1
    fi
    echo -e "${GREEN}[gpush]${NC} Created PR #${pr_number}"
  else
    # PR may already exist
    if echo "${pr_output}" | grep -qi "already exists"; then
      pr_number=$(gh pr view --json number -q .number 2>/dev/null)
      if [[ -n "${pr_number}" ]]; then
        echo -e "${BLUE}[gpush]${NC} PR #${pr_number} already exists, continuing"
      fi
    fi
    if [[ -z "${pr_number}" ]]; then
      echo -e "${RED}[gpush]${NC} Failed to create PR:" >&2
      echo "${pr_output}" >&2
      return 1
    fi
  fi

  # Step 4: Watch CI (use gh run watch — gh pr checks fails with PAT errors)
  # Anchor on the pushed commit SHA to avoid watching a stale run from a prior push
  local head_sha
  head_sha=$(git rev-parse HEAD)
  echo -e "${BLUE}[gpush]${NC} Waiting for CI run on ${head_sha:0:7}..."
  local run_id=""
  local attempts=0
  while [[ -z "${run_id}" && ${attempts} -lt 15 ]]; do
    run_id=$(gh run list --branch "${branch}" --commit "${head_sha}" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || true)
    if [[ -z "${run_id}" ]]; then
      ((attempts += 1))
      sleep 2
    fi
  done
  if [[ -z "${run_id}" ]]; then
    echo -e "${RED}[gpush]${NC} No CI run found for ${head_sha:0:7} after 30s. Check GitHub Actions." >&2
    return 1
  fi
  echo -e "${BLUE}[gpush]${NC} Watching CI run ${run_id} for PR #${pr_number}..."
  if ! gh run watch "${run_id}" --exit-status; then
    echo -e "${RED}[gpush]${NC} CI failed. Fix and re-run gpush." >&2
    return 1
  fi
  echo -e "${GREEN}[gpush]${NC} CI passed"

  if [[ "${no_merge}" == true ]]; then
    echo -e "${GREEN}[gpush]${NC} --no-merge: stopping after CI. PR #${pr_number} is ready."
    return 0
  fi

  # Step 5: Confirm and authorize merge
  local confirm
  echo ""
  read -r -p "[gpush] Merge PR #${pr_number}? [y/N] " confirm
  if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}[gpush]${NC} Merge cancelled. PR #${pr_number} is ready for manual merge."
    return 0
  fi

  if ! command -v merge-lock &>/dev/null; then
    echo -e "${RED}[gpush]${NC} merge-lock not found on PATH." >&2
    return 1
  fi
  if ! merge-lock auth "${pr_number}" "gpush"; then
    echo -e "${RED}[gpush]${NC} merge-lock authorization failed." >&2
    return 1
  fi

  # Step 6: Merge (goes through gh wrapper → pre-merge-review.sh)
  echo -e "${BLUE}[gpush]${NC} Merging PR #${pr_number}..."
  if ! gh pr merge "${pr_number}" --squash --delete-branch; then
    echo -e "${RED}[gpush]${NC} Merge failed. Check pre-merge review output above." >&2
    return 1
  fi
  echo -e "${GREEN}[gpush]${NC} PR #${pr_number} merged"

  # Step 7: Cleanup — handle each step independently
  local default_branch
  default_branch=$(git remote show origin 2>/dev/null | awk '/HEAD branch/ {print $NF}')
  default_branch="${default_branch:-main}"
  echo -e "${BLUE}[gpush]${NC} Cleaning up..."
  if ! git switch "${default_branch}"; then
    echo -e "${RED}[gpush]${NC} Failed to switch to ${default_branch}." >&2
    return 1
  fi
  if ! git pull; then
    echo -e "${RED}[gpush]${NC} Failed to pull ${default_branch}. Run 'git pull' manually." >&2
    return 1
  fi
  git branch -D "${branch}" 2>/dev/null || true
  echo -e "${GREEN}[gpush]${NC} Done. Back on ${default_branch}."
}

# ============================================================================
# 1Password Helper
# ============================================================================
# opp — run op as personal account, bypassing the service account token.
# In interactive shells, OP_SERVICE_ACCOUNT_TOKEN is not set so this is
# equivalent to plain op. Inside CCCLI sessions (where the wrapper has set
# OP_SERVICE_ACCOUNT_TOKEN), this provides Personal vault access.

opp() {
  (
    unset OP_SERVICE_ACCOUNT_TOKEN
    if ! op whoami &>/dev/null; then
      op signin
    fi
    op "$@"
  )
}
export -f opp # Exported - available inside CCCLI sessions
