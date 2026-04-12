# ~/.config/bash/env.sh
#shellcheck shell=bash
# Environment variable configuration

# Load secret env vars
#shellcheck disable=SC2154
if [[ -f "${BASH_CONFIG_DIR}/secrets.sh" ]]; then
  #shellcheck source=/dev/null
  source "${BASH_CONFIG_DIR}/secrets.sh"
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
    eval "${BREW_SHELLENV}"
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
# Set CDPATH to include Developer directory (from previous .profile)
export CDPATH=".:${HOME}/Developer:${HOME}/Developer/clients:${HOME}/Developer/netlify"

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
