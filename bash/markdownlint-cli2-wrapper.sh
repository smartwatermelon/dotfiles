#!/usr/bin/env bash
# markdownlint-cli2 shim: a bare run gets the commit gate's config.
# shellcheck shell=bash
set -euo pipefail

_mdl_shim_name="markdownlint-cli2"
CANONICAL="${MARKDOWNLINT_CANONICAL_CONFIG:-${HOME}/.config/markdownlint-cli/.markdownlint.json}"

# Real path: ~/.local/bin and ~/.config/bash hold symlinks into the repo.
_mdl_shim_self="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null)" || _mdl_shim_self="${BASH_SOURCE[0]}"

# Another copy of this shim on PATH would exec this one back: stop the loop.
if [[ -n "${_MARKDOWNLINT_SHIM_ACTIVE:-}" ]]; then
  printf '%s (shim): re-entered from %s; another copy of the shim is on PATH ahead of the real binary\n' \
    "${_mdl_shim_name}" "${_MARKDOWNLINT_SHIM_ACTIVE}" >&2
  exit 126
fi

_mdl_shim_find_real() {
  local IFS=':'
  local dir candidate candidate_real
  for dir in ${PATH}; do
    [[ -n "${dir}" ]] || continue
    candidate="${dir}/${_mdl_shim_name}"
    if [[ -f "${candidate}" && -x "${candidate}" ]]; then
      candidate_real="$(realpath "${candidate}" 2>/dev/null || true)"
      if [[ -n "${candidate_real}" && "${candidate_real}" != "${_mdl_shim_self}" ]]; then
        printf '%s\n' "${candidate}"
        return 0
      fi
    fi
  done
  return 1
}

if ! _mdl_shim_real="$(_mdl_shim_find_real)"; then
  printf '%s (shim): no real %s found on PATH (brew install markdownlint-cli2)\n' \
    "${_mdl_shim_name}" "${_mdl_shim_name}" >&2
  exit 127
fi
export _MARKDOWNLINT_SHIM_ACTIVE="${_mdl_shim_self}"

_mdl_shim_passthrough() {
  exec "${_mdl_shim_real}" "$@"
}

(($# > 0)) || _mdl_shim_passthrough

for _mdl_shim_arg in "$@"; do
  case "${_mdl_shim_arg}" in
    --help | --config | --config=*) _mdl_shim_passthrough "$@" ;;
    *) ;;
  esac
done

# The config list is shared with lint-markdown.sh. Missing: warn, pass through.
_mdl_shim_lib="${_mdl_shim_self%/*}/../git/hooks/lib-markdownlint-config.sh"
if [[ ! -f "${_mdl_shim_lib}" ]]; then
  printf '%s (shim): %s is missing; running without the canonical config\n' \
    "${_mdl_shim_name}" "${_mdl_shim_lib}" >&2
  _mdl_shim_passthrough "$@"
fi
# shellcheck source=SCRIPTDIR/../git/hooks/lib-markdownlint-config.sh
source "${_mdl_shim_lib}"

if _find_repo_config >/dev/null; then
  _mdl_shim_passthrough "$@"
fi

if [[ ! -f "${CANONICAL}" ]]; then
  printf '%s (shim): canonical config not found at %s; using markdownlint defaults\n' \
    "${_mdl_shim_name}" "${CANONICAL}" >&2
  _mdl_shim_passthrough "$@"
fi

exec "${_mdl_shim_real}" --config "${CANONICAL}" "$@"
