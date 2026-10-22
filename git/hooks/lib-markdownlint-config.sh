#!/usr/bin/env bash
# shellcheck shell=bash
# Repo markdownlint config names, in run-standards.sh order (drift-tested).
# Sourced by lint-markdown.sh and the shim.

MARKDOWNLINT_REPO_CONFIGS=(
  .markdownlint-cli2.jsonc
  .markdownlint-cli2.yaml
  .markdownlint-cli2.cjs
  .markdownlint.jsonc
  .markdownlint.json
  .markdownlint.yaml
  .markdownlint.yml
  .markdownlintrc
)

_find_repo_config() {
  local c
  for c in "${MARKDOWNLINT_REPO_CONFIGS[@]}"; do
    if [[ -f "${c}" ]]; then
      printf '%s' "${c}"
      return 0
    fi
  done
  return 1
}
