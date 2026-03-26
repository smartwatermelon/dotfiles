# ~/.config/bash/path.sh
#shellcheck shell=bash
# Consolidated PATH management
#
# PATH Search Order (left-to-right, first match wins):
# 1. User binaries (highest priority) - ~/.local/bin, maestro
# 2. Language-specific tools - Ruby, Gem executables
# 3. Homebrew system tools - sbin
# 4. System defaults - /usr/local/bin, /usr/bin, /bin, /usr/sbin, /sbin
# 5. Android SDK tools (lowest priority) - emulator, platform-tools
#
# Prepending adds to the BEGINNING (higher priority, searched first)
# Appending adds to the END (lower priority, searched last)

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Prepend to PATH, ensuring it's at the front (moves existing entry if needed)
# macOS path_helper pre-populates PATH from /etc/paths.d, often placing user
# directories after system ones. This function corrects that ordering.
_prepend_path_once() {
  local dir="$1"
  [[ -d "${dir}" ]] || return 0

  # Remove existing entry (if any) before prepending
  if [[ "${PATH}" == "${dir}" ]]; then
    export PATH="${dir}"
    return 0
  fi
  PATH="${PATH/#${dir}:/}"
  PATH="${PATH//:${dir}:/:}"
  PATH="${PATH/%:${dir}/}"

  export PATH="${dir}:${PATH}"
}

# Append to PATH only if not already present (prevents duplicates)
_append_path_once() {
  local dir="$1"
  if [[ -d "${dir}" ]] && [[ ":${PATH}:" != *":${dir}:"* ]]; then
    export PATH="${PATH}:${dir}"
  fi
}

# ============================================================================
# PREPEND ORDER (reverse of priority - lowest priority prepended first)
# ============================================================================
# When prepending to PATH, the LAST item prepended has HIGHEST priority.
# Therefore, we must prepend in REVERSE order of desired priority.

# ============================================================================
# STEP 1: Prepend Homebrew System Tools (Priority 3 - Lower)
# ============================================================================

# Homebrew sbin (for system tools like nginx, unbound, postgresql)
# Note: brew shellenv may already add this via path_helper
HOMEBREW_ROOT=$(_get_homebrew_root)
_prepend_path_once "${HOMEBREW_ROOT}/sbin"

# ============================================================================
# STEP 2: Prepend Language-Specific Tools (Priority 2 - Medium)
# ============================================================================

# Ruby and Gem executables (only if Homebrew Ruby is installed)
if command -v ruby &>/dev/null; then
  # Ruby bin directory (prepended first, so lower priority than gem executables)
  _prepend_path_once "${HOMEBREW_ROOT}/opt/ruby/bin"

  # Gem executables (prepended last, so higher priority than ruby bin)
  if [[ $(type -t _profile_time) == "function" ]] && [[ "$-" == *i* ]]; then
    _pf_start=$(date +%s.%N)
  fi
  GEM_EXE_DIR="$(ruby -e 'puts Gem.bindir' 2>/dev/null)"
  if [[ $(type -t _profile_time) == "function" ]] && [[ "$-" == *i* ]]; then
    _pf_end=$(date +%s.%N)
    _pf_duration=$(awk "BEGIN {printf \"%.3f\", ${_pf_end} - ${_pf_start}}")
    if (($(awk "BEGIN {print (${_pf_duration} > 1.0)}"))); then
      echo "[PROFILE] ruby Gem.bindir took ${_pf_duration}s" >&2
    fi
    unset _pf_start _pf_end _pf_duration
  fi
  _prepend_path_once "${GEM_EXE_DIR}"

  # Cleanup temporary variable
  unset GEM_EXE_DIR
fi

# Bun JavaScript runtime
if [[ -d "${HOME}/.bun/bin" ]]; then
  _prepend_path_once "${HOME}/.bun/bin"
fi

# ============================================================================
# STEP 3: Prepend User Binaries (Priority 1 - Highest)
# ============================================================================

# User local binaries (prepended LAST, so HIGHEST priority)
# Note: Maestro is symlinked from ~/.maestro/bin/maestro to ~/.local/bin/maestro
_prepend_path_once "${HOME}/.local/bin"

# ============================================================================
# PRIORITY 4: System Defaults
# ============================================================================
# Already in PATH from system login (/usr/local/bin, /usr/bin, /bin, etc.)
# No modifications needed

# ============================================================================
# PRIORITY 5: Android SDK Tools (Append - Lowest Priority)
# ============================================================================

# Android SDK (only if installed)
if [[ -d "${HOME}/Library/Android/sdk" ]]; then
  export ANDROID_HOME="${HOME}/Library/Android/sdk"
  _append_path_once "${ANDROID_HOME}/emulator"
  _append_path_once "${ANDROID_HOME}/platform-tools"
fi
