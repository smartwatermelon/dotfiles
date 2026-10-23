#!/usr/bin/env bash
#shellcheck shell=bash
# gh-wrapper.sh must not use >(...): the Claude Code sandbox refuses it.
set -euo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAPPER="${REPO_ROOT}/bash/gh-wrapper.sh"

if [[ ! -f "${WRAPPER}" ]]; then
  echo "FAIL: ${WRAPPER} not found" >&2
  exit 1
fi

# Code lines only: comments may name the form when explaining why it is gone.
hits=$(grep -nE '>\(' "${WRAPPER}" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
if [[ -z "${hits}" ]]; then
  echo "  PASS: no >(...) in gh-wrapper.sh"
  echo "test-gh-wrapper-sandbox-compat: all cases passed"
  exit 0
fi
echo "  FAIL: >(...) found in gh-wrapper.sh:"
printf '%s\n' "${hits}"
echo "test-gh-wrapper-sandbox-compat: FAILURES above"
exit 1
