# ~/.config/bash/.bash_profile
#shellcheck shell=bash
# Entry point for bash configuration
# This file should be symlinked from ~/.bash_profile

# DIAGNOSTIC: Timing function to identify slow operations
# Requires: macOS Sequoia (15.0+) or FreeBSD 14.1+ for date %N support
_profile_time() {
  # Skip profiling for non-interactive shells (e.g., CCCLI commands)
  if [[ "$-" != *i* ]]; then
    shift # Remove label
    "$@"  # Execute command without profiling
    return
  fi

  local start end duration label
  label="$1"
  start=$(date +%s.%N)
  shift
  "$@"
  end=$(date +%s.%N)
  duration=$(awk "BEGIN {printf \"%.3f\", ${end} - ${start}}")
  if (($(awk "BEGIN {print (${duration} > 1.0)}"))); then
    echo "[PROFILE] ${label} took ${duration}s" >&2
  fi
}

# Determine the real path of this file (works with symlinks)
if [[ -n "${BASH_SOURCE[0]}" ]]; then
  # For Bash
  CONFIG_FILE="$(realpath "${BASH_SOURCE[0]}")"
  CONFIG_DIR="$(dirname "${CONFIG_FILE}")"
else
  # Fallback if realpath fails or we're in a different shell
  CONFIG_DIR="${HOME}/.config/bash"
fi

# Create config directory if it doesn't exist
if [[ ! -d "${CONFIG_DIR}" ]]; then
  mkdir -p "${CONFIG_DIR}"
fi

# Source main configuration file
if [[ -f "${CONFIG_DIR}/main.sh" ]]; then
  _profile_time "main.sh" source "${CONFIG_DIR}/main.sh"
fi

# For backward compatibility with scripts that might rely on .bashrc
if [[ -f "${HOME}/.bashrc" ]] && [[ "${BASH_SOURCE[0]}" != "${HOME}/.bashrc" ]]; then
  #shellcheck source=/dev/null
  source "${HOME}/.bashrc"
fi

# NVM (Node Version Manager) setup
# Note: NVM loading can be slow (~1-2s). If it causes issues:
#   - Check NVM installation: ${HOME}/.nvm/
#   - Comment out these lines to disable NVM temporarily
#   - Use _profile_time output to measure actual load time
export NVM_DIR="${HOME}/.nvm"
#shellcheck source=/dev/null
if [[ -s "${NVM_DIR}/nvm.sh" ]]; then
  _profile_time "NVM loading" source "${NVM_DIR}/nvm.sh"
fi
#shellcheck source=/dev/null
if [[ -s "${NVM_DIR}/bash_completion" ]]; then
  _profile_time "NVM bash_completion" source "${NVM_DIR}/bash_completion"
fi
