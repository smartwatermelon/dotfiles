# ~/.config/bash/completion.sh
#shellcheck shell=bash
# Tab completion configuration

# Only run in interactive shells with readline support
if ! [[ -t 1 && "$-" == *i* && -n "${PS1:-}" ]]; then
  return
fi

# Basic tab completion settings (from previous .profile)
bind "set completion-ignore-case on"
bind "set completion-map-case on"
bind "set show-all-if-ambiguous on"
bind "set menu-complete-display-prefix on"

# Set up Homebrew completion (from current profile)
if command -v brew &>/dev/null; then
  # Use timeout to prevent indefinite hangs (3s should be enough)
  HOMEBREW_PREFIX="$(_with_timeout 3 brew --prefix 2>/dev/null)"
  _brew_exit=$?
  if [[ ${_brew_exit} -ne 0 || -z "${HOMEBREW_PREFIX}" ]]; then
    # Fallback to default location if brew --prefix fails or times out
    HOMEBREW_PREFIX="$(_get_homebrew_root)"
  fi
  unset _brew_exit

  # Main bash completion script
  if [[ -r "${HOMEBREW_PREFIX}/etc/profile.d/bash_completion.sh" ]]; then
    #shellcheck source=/dev/null
    source "${HOMEBREW_PREFIX}/etc/profile.d/bash_completion.sh"
  # Individual completion scripts
  elif [[ -d "${HOMEBREW_PREFIX}/etc/bash_completion.d" ]]; then
    for COMPLETION in "${HOMEBREW_PREFIX}/etc/bash_completion.d/"*; do
      #shellcheck source=/dev/null
      [[ -r "${COMPLETION}" ]] && source "${COMPLETION}"
    done
  fi

  # Brew completion (explicit load to ensure _brew function is available)
  if [[ -f "${HOMEBREW_PREFIX}/completions/bash/brew" ]]; then
    #shellcheck source=/dev/null
    source "${HOMEBREW_PREFIX}/completions/bash/brew"
  fi

  # Git completion (from previous .profile)
  if [[ -n "${HOMEBREW_GIT_PREFIX:-}" ]] && [[ -f "${HOMEBREW_GIT_PREFIX}/etc/bash_completion.d/git-completion.bash" ]]; then
    #shellcheck source=/dev/null
    source "${HOMEBREW_GIT_PREFIX}/etc/bash_completion.d/git-completion.bash"
  fi

  # Provide brew completion for cask alias/function
  # This allows 'cask install PACKAGE' to autocomplete like 'brew install --cask PACKAGE'
  if declare -f _brew &>/dev/null; then
    _cask_complete() {
      local line=${COMP_LINE}

      # Transform 'cask' command to 'brew' for completion
      COMP_LINE=${line/cask/brew}
      COMP_WORDS[0]=brew

      # Call brew's completion function
      _brew

      return 0
    }

    # Register completion function for cask
    complete -o bashdefault -o default -F _cask_complete cask
  fi
fi

# pipx completion
if command -v register-python-argcomplete &>/dev/null \
  && _pipx_ac="$(register-python-argcomplete pipx)"; then
  eval "${_pipx_ac}"
fi
unset _pipx_ac

# eas completion
# `eas autocomplete:script` starts Node (~80 ms) per shell, so cache its
# output; regenerate when eas is newer.
if _eas_bin="$(command -v eas)"; then
  _eas_ac_cache="${XDG_CACHE_HOME:-${HOME}/.cache}/eas/autocomplete.bash"
  if [[ ! -s "${_eas_ac_cache}" || "${_eas_bin}" -nt "${_eas_ac_cache}" ]]; then
    mkdir -p "${_eas_ac_cache%/*}"
    # Per-process temp file: shells opening together must not share one.
    if eas autocomplete:script bash 2>/dev/null >"${_eas_ac_cache}.tmp.$$"; then
      mv -f "${_eas_ac_cache}.tmp.$$" "${_eas_ac_cache}"
    else
      rm -f "${_eas_ac_cache}.tmp.$$"
    fi
  fi
  #shellcheck source=/dev/null
  [[ -s "${_eas_ac_cache}" ]] && source "${_eas_ac_cache}"
  unset _eas_ac_cache
fi
unset _eas_bin

# asana-cli completion
# Cached like eas. Its documented setup fails in 1.0.1, so build into a
# temp ASANA_CLI_CACHE_DIR.
if _asana_bin="$(command -v asana-cli)"; then
  _asana_ac_cache="${XDG_CACHE_HOME:-${HOME}/.cache}/asana-cli/autocomplete.bash"
  if [[ ! -s "${_asana_ac_cache}" || "${_asana_bin}" -nt "${_asana_ac_cache}" ]]; then
    mkdir -p "${_asana_ac_cache%/*}"
    # Per-process temp dir: shells opening together must not share one.
    _asana_ac_tmp="${_asana_ac_cache}.tmp.$$"
    if ASANA_CLI_CACHE_DIR="${_asana_ac_tmp}" asana-cli autocomplete --refresh-cache &>/dev/null \
      && [[ -s "${_asana_ac_tmp}/autocomplete/functions/bash/asana-cli.bash" ]]; then
      mv -f "${_asana_ac_tmp}/autocomplete/functions/bash/asana-cli.bash" "${_asana_ac_cache}"
    fi
    # Delete only this shell's own temp dir, by its exact name pattern.
    case "${_asana_ac_tmp}" in
      */asana-cli/autocomplete.bash.tmp.[0-9]*) rm -rf "${_asana_ac_tmp}" ;;
      *) echo "completion.sh: refusing to delete unexpected path ${_asana_ac_tmp}" >&2 ;;
    esac
    unset _asana_ac_tmp
  fi
  #shellcheck source=/dev/null
  [[ -s "${_asana_ac_cache}" ]] && source "${_asana_ac_cache}"
  unset _asana_ac_cache
fi
unset _asana_bin
