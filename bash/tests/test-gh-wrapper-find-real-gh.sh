#!/usr/bin/env bash
#shellcheck shell=bash
# sugh's real-gh finder must skip the wrapper, also in a child shell that imported it via export -f.
set -euo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAPPER="${REPO_ROOT}/bash/gh-wrapper.sh"

fail=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "  PASS: ${label}"
  else
    echo "  FAIL: ${label} — expected [${expected}], got [${actual}]"
    fail=1
  fi
}

if [[ ! -f "${WRAPPER}" ]]; then
  echo "FAIL: ${WRAPPER} not found" >&2
  exit 1
fi

# mktemp under ${TMPDIR}: the Claude Code sandbox refuses writes to /tmp.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/gh-find-real-gh-test.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
# A wrapper symlink first on PATH, as ~/.local/bin/gh is, then a stand-in real gh.
mkdir -p "${TMP}/wrapbin" "${TMP}/realbin"
ln -s "${WRAPPER}" "${TMP}/wrapbin/gh"
printf '#!/bin/sh\necho real-gh "$@"\n' >"${TMP}/realbin/gh"
chmod +x "${TMP}/realbin/gh"
TEST_PATH="${TMP}/wrapbin:${TMP}/realbin:/usr/bin:/bin"
REAL="${TMP}/realbin/gh"

# ${BASH}, not PATH bash: bash 3.2 makes the wrapper return early.
# in_sourced_shell <cmd>: run <cmd> where the wrapper was sourced.
in_sourced_shell() {
  env -i PATH="${TEST_PATH}" HOME="${TMP}" "${BASH}" --norc --noprofile -c "
    source '${WRAPPER}' >/dev/null 2>&1
    $1
  " 2>/dev/null
}

# in_child_shell <cmd>: run <cmd> in a child that has only the exports, like a new tab.
in_child_shell() {
  in_sourced_shell "'${BASH}' --norc --noprofile -c '$1'"
}

echo "Case: sourcing shell finds the real gh"
got=$(in_sourced_shell '_gh_wrapper_find_real_gh') || true
check "sourcing shell" "${REAL}" "${got}"

echo "Case: child shell with imported functions finds the real gh"
got=$(in_child_shell _gh_wrapper_find_real_gh) || true
check "child shell" "${REAL}" "${got}"

echo "Case: sugh in a child shell runs the real gh"
got=$(in_child_shell "sugh --version") || true
check "child sugh" "real-gh --version" "${got}"

echo "Case: child shell with no wrapper path refuses instead of returning the wrapper"
got=$(in_child_shell "unset _gh_wrapper_real_self; _gh_wrapper_find_real_gh; echo rc=\$?") || true
check "no path to skip" "rc=1" "${got}"

if [[ "${fail}" == "0" ]]; then
  echo "test-gh-wrapper-find-real-gh: all cases passed"
else
  echo "test-gh-wrapper-find-real-gh: FAILURES above"
  exit 1
fi
