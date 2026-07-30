# ~/.config/bash/path.sh
#shellcheck shell=bash
# Consolidated PATH management — this file is the ONLY place PATH priority
# is decided. env.sh does not touch PATH.
#
# _path_tiers below is the final PATH order, highest priority first.
# Read top-to-bottom: that IS the resulting search order. No mental
# simulation of prepend calls required.

# Prepend to PATH, ensuring it's at the front (moves existing entry if needed)
# macOS path_helper pre-populates PATH from /etc/paths.d, often placing user
# directories after system ones. This function corrects that ordering.
#
# Not called by the tier construction below (that builds PATH directly via
# _path_tiers so the whole order is visible in one place, not accumulated
# via repeated prepend calls). Kept available for one-off/interactive use
# (e.g. a tool installer script that needs to prepend its own bin dir after
# path.sh has already run).
_prepend_path_once() {
  local dir="$1"
  [[ -d "${dir}" ]] || return 0

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
# EXPLICIT PATH ORDER — highest priority first
# ============================================================================

HOMEBREW_ROOT=$(_get_homebrew_root)

GEM_EXE_DIR=""
if command -v ruby &>/dev/null; then
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
fi

# Written highest-priority-first. The loop below does a single forward
# pass, appending each existing directory to a new prefix in this exact
# order, then puts that prefix in front of whatever's left of the old
# PATH. Array order above IS the resulting PATH order — read top to
# bottom, no need to simulate anything.
_path_tiers=(
  "${HOME}/.local/bin"
  "${GEM_EXE_DIR}"
  "${HOME}/.bun/bin"
  "${HOME}/.asdf/shims"
  "${HOMEBREW_ROOT}/opt/ruby/bin"
  "${HOMEBREW_ROOT}/bin"
  "${HOMEBREW_ROOT}/sbin"
)

_new_path=""
for _dir in "${_path_tiers[@]}"; do
  [[ -n "${_dir}" && -d "${_dir}" ]] || continue
  # Strip ALL existing occurrences first so it isn't duplicated below.
  # Looped (not a single pass) so 3+ consecutive duplicate entries are
  # fully collapsed, not just reduced by one.
  while [[ ":${PATH}:" == *":${_dir}:"* ]]; do
    PATH="${PATH//:${_dir}:/:}"
    PATH="${PATH/#${_dir}:/}"
    PATH="${PATH/%:${_dir}/}"
    if [[ "${PATH}" == "${_dir}" ]]; then
      export PATH=""
    fi
  done
  _new_path="${_new_path:+${_new_path}:}${_dir}"
done
export PATH="${_new_path}${_new_path:+${PATH:+:}}${PATH}"
unset _path_tiers _dir _new_path GEM_EXE_DIR

# ============================================================================
# LOWEST PRIORITY — appended, not prepended
# ============================================================================

# Android SDK (only if installed)
if [[ -d "${HOME}/Library/Android/sdk" ]]; then
  export ANDROID_HOME="${HOME}/Library/Android/sdk"
  _append_path_once "${ANDROID_HOME}/emulator"
  _append_path_once "${ANDROID_HOME}/platform-tools"
fi
