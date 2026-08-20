# ~/.config/bash/env.sh
#shellcheck shell=bash
# Environment variable configuration

# Load secret env vars
#
# 1Password CLI tokens (OP_SERVICE_ACCOUNT_TOKEN, GH_TOKEN) are injected
# exclusively by claude-wrapper at CCCLI launch. Interactive shells started
# outside claude-wrapper will have neither token set and must run `op signin`
# (or use `opp()` from functions.sh) for 1Password CLI auth.
#shellcheck disable=SC2154
if [[ -f "${BASH_CONFIG_DIR}/secrets.sh" ]]; then
  #shellcheck source=/dev/null
  source "${BASH_CONFIG_DIR}/secrets.sh"
fi

# Canonical location of the work (Beacon) checkout root. Single source of
# truth for every consumer that needs to know where work repos live:
# gh-wrapper.sh's identity auto-switch (GH_WRAPPER_BEACON_DIR), install.sh's
# beacon-config warnings, and the CDPATH entry below.
#
# Exported so non-interactive shells and standalone scripts inherit it.
# Consumers that can run WITHOUT this file having been sourced — install.sh
# (which never sources env.sh) and gh-wrapper.sh in standalone-wrapper mode
# (LaunchAgents/cron/GUI apps with a stripped environment) — must still spell
# the fallback default themselves via ${BEACON_WORKDIR:-...}, so the value is
# defined in one place but never depends on load order to be correct.
#
# Assigned with := so an explicit override from the environment wins.
: "${BEACON_WORKDIR:=${HOME}/Developer/beacon-biosignals}"
export BEACON_WORKDIR

# Load work-specific (Beacon) env vars — untracked, machine-local.
# See bash/beacon.sh.example for the template; install.sh warns if
# ${BEACON_WORKDIR} exists but this file doesn't.
if [[ -f "${BASH_CONFIG_DIR}/beacon.sh" ]]; then
  #shellcheck source=/dev/null
  source "${BASH_CONFIG_DIR}/beacon.sh"
fi

# Silence macOS Bash deprecation warning
export BASH_SILENCE_DEPRECATION_WARNING=1

# Timeout wrapper for shell startup commands
# Prevents indefinite hangs if brew/nvm are slow or unresponsive
# Usage: _with_timeout <seconds> <command> [args...]
# Returns: command exit code, or 124 if timeout occurred
_with_timeout() {
  local timeout_seconds="$1"
  shift

  if command -v timeout &>/dev/null; then
    # timeout command available (from coreutils via Homebrew)
    timeout "${timeout_seconds}" "$@"
  else
    # timeout not available, run without timeout
    # Still provide protection by logging start time
    local start_time end_time duration
    start_time=$(date +%s)
    "$@"
    local result=$?
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    if ((duration > timeout_seconds)); then
      echo "[WARN] Command took ${duration}s (longer than ${timeout_seconds}s timeout)" >&2
      return 124 # Return standard timeout exit code for consistency
    fi
    return "${result}"
  fi
}

# Homebrew setup
# Evaluate Homebrew environment (prioritizing current settings)
if command -v brew &>/dev/null; then
  if [[ $(type -t _profile_time) == "function" ]] && [[ "$-" == *i* ]]; then
    _pf_start=$(date +%s.%N)
  fi

  # Use timeout to prevent indefinite hangs (5s should be more than enough)
  BREW_SHELLENV="$(_with_timeout 5 brew shellenv)"
  _brew_exit=$?
  if [[ ${_brew_exit} -ne 0 ]]; then
    if [[ ${_brew_exit} -eq 124 ]]; then
      echo "[ERROR] brew shellenv timed out after 5s, skipping Homebrew setup" >&2
    else
      echo "[WARN] brew shellenv failed (exit ${_brew_exit}), skipping Homebrew setup" >&2
    fi
    BREW_SHELLENV=""
  fi
  unset _brew_exit

  # Validate brew shellenv output before eval (security: prevent arbitrary code execution)
  # Note: brew shellenv legitimately uses eval and $() for path_helper
  if [[ -z "${BREW_SHELLENV}" ]]; then
    echo "[WARN] brew shellenv returned empty output, skipping" >&2
  elif ! grep -q "^export HOMEBREW_" <<<"${BREW_SHELLENV}"; then
    echo "[WARN] brew shellenv output doesn't match expected format, skipping" >&2
    echo "[WARN] Output: ${BREW_SHELLENV:0:100}..." >&2
  elif grep -qE '(`|;rm |;curl |;wget |/dev/tcp)' <<<"${BREW_SHELLENV}"; then
    echo "[ERROR] brew shellenv contains suspicious patterns, refusing to eval" >&2
    echo "[ERROR] Output: ${BREW_SHELLENV}" >&2
  else
    # PATH is intentionally dropped here — path.sh owns PATH construction
    # separately. MANPATH and INFOPATH are also intentionally dropped:
    # Homebrew's installer writes /etc/manpaths.d/homebrew at install time,
    # which macOS's man command reads automatically, so man pages for
    # Homebrew-installed tools still resolve without MANPATH being set. If a
    # machine was bootstrapped in a way that skipped that step, man pages
    # could go missing silently.
    eval "$(grep -vE '^export (PATH|MANPATH|INFOPATH)=' <<<"${BREW_SHELLENV}")"
  fi
  if [[ $(type -t _profile_time) == "function" ]] && [[ "$-" == *i* ]]; then
    _pf_end=$(date +%s.%N)
    _pf_duration=$(awk "BEGIN {printf \"%.3f\", ${_pf_end} - ${_pf_start}}")
    if (($(awk "BEGIN {print (${_pf_duration} > 1.0)}"))); then
      echo "[PROFILE] brew shellenv took ${_pf_duration}s" >&2
    fi
    unset _pf_start _pf_end _pf_duration
  fi
fi
export HOMEBREW_DOWNLOAD_CONCURRENCY=auto

# Set Homebrew Git prefix
if command -v brew &>/dev/null; then
  export HOMEBREW_GIT_PREFIX
  if [[ $(type -t _profile_time) == "function" ]] && [[ "$-" == *i* ]]; then
    _pf_start=$(date +%s.%N)
  fi

  # Use timeout to prevent indefinite hangs (3s should be enough for prefix lookup)
  # Fallback to default location if brew --prefix fails or times out
  HOMEBREW_GIT_PREFIX=$(_with_timeout 3 brew --prefix git 2>/dev/null) || HOMEBREW_GIT_PREFIX="$(_get_homebrew_root)/opt/git"
  if [[ $(type -t _profile_time) == "function" ]] && [[ "$-" == *i* ]]; then
    _pf_end=$(date +%s.%N)
    _pf_duration=$(awk "BEGIN {printf \"%.3f\", ${_pf_end} - ${_pf_start}}")
    if (($(awk "BEGIN {print (${_pf_duration} > 1.0)}"))); then
      echo "[PROFILE] brew --prefix git took ${_pf_duration}s" >&2
    fi
    unset _pf_start _pf_end _pf_duration
  fi
fi

# Ruby configuration (only if Homebrew Ruby is installed)
# Note: PATH modifications moved to path.sh
HOMEBREW_ROOT=$(_get_homebrew_root)
if command -v ruby &>/dev/null && [[ -d "${HOMEBREW_ROOT}/opt/ruby/bin" ]]; then
  export LDFLAGS="-L${HOMEBREW_ROOT}/opt/ruby/lib"
  export CPPFLAGS="-I${HOMEBREW_ROOT}/opt/ruby/include"
fi

# NPM configuration
if command -v npm &>/dev/null; then
  export NPM_CONFIG_USERCONFIG="${HOME}/.config/npm/npmrc"
fi

# Set default editor with fallback
if command -v vim &>/dev/null; then
  export EDITOR="vim"
elif command -v vi &>/dev/null; then
  export EDITOR="vi"
else
  export EDITOR="nano"
fi

# Directory navigation
# Set CDPATH to include Developer directory (from previous .profile).
# Deliberately omits "." as the first entry: when cd resolves via CDPATH
# (even a "." entry), bash's cd builtin echoes the resolved path to
# stdout as a side effect — this silently corrupts any script's
# `cd -- "$dir" && pwd` idiom (a very common pattern) by duplicating the
# captured output whenever the script is invoked with a relative path.
# Without "." here, cd only consults CDPATH for paths that aren't already
# resolvable relative to $PWD, which is the behavior actually wanted.
#
# IMPORTANT — this only protects the "$PWD-relative" case. If a script
# invoked with this file already sourced does `cd somename` where
# "somename" happens to match one of the CDPATH entries above by bare
# name (not the current directory), bash's cd builtin still resolves it
# via CDPATH search and still echoes the resolved absolute path to
# stdout — "." being absent from CDPATH does not prevent this. CDPATH is
# meant purely as an interactive-shell convenience; any script or
# function in this repo (or elsewhere) that does a `cd` and cares about
# stdout being clean — e.g. `x=$(cd "$dir" && pwd)` — MUST NOT rely on
# CDPATH being unset by the caller. Instead, either `unset CDPATH` at the
# top of the script (see bash/tests/*.sh for the established pattern) or
# scope it out per-invocation with `CDPATH='' cd -- "$dir"`.
export CDPATH="${HOME}/Developer:${HOME}/Developer/clients:${HOME}/Developer/netlify"

# Append the work (Beacon) checkout root, but only on machines where it
# actually exists — a CDPATH entry pointing at a missing directory is dead
# weight that bash stats on every CDPATH-resolved cd. Appended last so work
# repos never shadow a same-named personal repo under ~/Developer.
if [[ -d "${BEACON_WORKDIR}" ]]; then
  export CDPATH="${CDPATH}:${BEACON_WORKDIR}"
fi

# Set correct terminal type for SSH sessions with color support
export TERM=xterm-256color

# shfmt parameters
export SHFMT_OPTS="-d -i 2 -ci -bn"
export SHFMT_WRITE_OPTS="-i 2 -ci -bn -w"

# Optional: Set locale
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

# Android SDK configuration
# Note: ANDROID_HOME and PATH modifications moved to path.sh

# Java for Android (only if installed)
if [[ -d /Library/Java/JavaVirtualMachines/zulu-17.jdk/Contents/Home ]]; then
  export JAVA_HOME=/Library/Java/JavaVirtualMachines/zulu-17.jdk/Contents/Home
fi

# Claude Code configuration
export CLAUDE_CONFIG_DIR="${HOME}/.claude"

# mas update disable
export MAS_UPDATE_DISABLE=true
