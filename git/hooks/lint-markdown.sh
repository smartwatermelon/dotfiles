#!/usr/bin/env bash
# Markdown lint wrapper for the `markdownlint` pre-commit hook.
#
# Picks the config as standards/run-standards.sh does, runs markdownlint-cli2.
#
# cli2 applies nested configs and "ignores"; markdownlint-cli does not.
#
# No canonical+repo merge (#308): a root config replaces --config in cli2.

set -euo pipefail

CANONICAL="${MARKDOWNLINT_CANONICAL_CONFIG:-${HOME}/.config/markdownlint-cli/.markdownlint.json}"

# Config list shared with the shim; found beside this file's real path.
_self="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null)" || _self="${BASH_SOURCE[0]}"
_lib="${_self%/*}/lib-markdownlint-config.sh"
if [[ ! -f "${_lib}" ]]; then
  printf 'lint-markdown: %s is missing; cannot pick the config CI would\n' "${_lib}" >&2
  exit 1
fi
# shellcheck source=SCRIPTDIR/lib-markdownlint-config.sh
source "${_lib}"

main() {
  # pre-commit may call this with no files; a linter given none can exit non-zero.
  (($# > 0)) || exit 0

  if ! command -v markdownlint-cli2 >/dev/null 2>&1; then
    printf 'lint-markdown: needs markdownlint-cli2, which CI runs (brew install markdownlint-cli2)\n' >&2
    exit 1
  fi

  local cfg
  if cfg="$(_find_repo_config)"; then
    exec markdownlint-cli2 --fix --config "${cfg}" "$@"
  fi

  # Fresh machine (dotfiles not installed): a missing --config path fails the
  # commit, so lint on cli2's defaults and say so.
  if [[ ! -f "${CANONICAL}" ]]; then
    printf 'lint-markdown: canonical config not found at %s; using markdownlint defaults\n' \
      "${CANONICAL}" >&2
    exec markdownlint-cli2 --fix "$@"
  fi

  exec markdownlint-cli2 --fix --config "${CANONICAL}" "$@"
}

main "$@"
