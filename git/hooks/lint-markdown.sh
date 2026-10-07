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

# CI's order exactly; keep in sync with standards/run-standards.sh.
_find_repo_config() {
  local c
  for c in .markdownlint-cli2.jsonc .markdownlint-cli2.yaml .markdownlint-cli2.cjs \
    .markdownlint.jsonc .markdownlint.json .markdownlint.yaml .markdownlint.yml .markdownlintrc; do
    if [[ -f "${c}" ]]; then
      printf '%s' "${c}"
      return 0
    fi
  done
  return 1
}

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
