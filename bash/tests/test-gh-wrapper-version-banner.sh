#!/usr/bin/env bash
#shellcheck shell=bash
# gh --version prints real gh's output plus one gh-wrapper line; sugh prints no such line.
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
TMP="$(mktemp -d "${TMPDIR:-/tmp}/gh-version-banner-test.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
# The wrapper symlink first on PATH, as ~/.local/bin/gh is, then a stand-in real gh.
mkdir -p "${TMP}/wrapbin" "${TMP}/realbin"
ln -s "${WRAPPER}" "${TMP}/wrapbin/gh"
printf '#!/bin/sh\necho "gh version 9.9.9 $*"\n' >"${TMP}/realbin/gh"
chmod +x "${TMP}/realbin/gh"
REAL="${TMP}/realbin/gh"
TEST_ENV=(env -i PATH="${TMP}/wrapbin:${TMP}/realbin:/usr/bin:/bin" HOME="${TMP}")

# Run from the temp dir: inside a repo, identity routing would act on its remote.
cd "${TMP}"

lines() { tr '\n' '|' | sed 's/|$//'; }

echo "Case: standalone gh --version adds the wrapper line"
got=$("${TEST_ENV[@]}" "${TMP}/wrapbin/gh" --version 2>/dev/null | lines) || true
check "standalone --version" "gh version 9.9.9 --version|gh-wrapper: active (standalone mode), real gh: ${REAL}" "${got}"

echo "Case: gh version (subcommand) adds the wrapper line"
got=$("${TEST_ENV[@]}" "${TMP}/wrapbin/gh" version 2>/dev/null | lines) || true
check "standalone version" "gh version 9.9.9 version|gh-wrapper: active (standalone mode), real gh: ${REAL}" "${got}"

echo "Case: function-mode gh --version reports function mode"
# ${BASH}, not PATH bash: bash 3.2 makes the wrapper return early.
got=$("${TEST_ENV[@]}" "${BASH}" --norc --noprofile -c "source '${WRAPPER}' >/dev/null 2>&1; gh --version" 2>/dev/null | lines) || true
check "function --version" "gh version 9.9.9 --version|gh-wrapper: active (function mode), real gh: ${REAL}" "${got}"

echo "Case: sugh --version has no wrapper line"
got=$("${TEST_ENV[@]}" "${BASH}" --norc --noprofile -c "source '${WRAPPER}' >/dev/null 2>&1; sugh --version" 2>/dev/null | lines) || true
check "sugh --version" "gh version 9.9.9 --version" "${got}"

echo "Case: --version with other args passes through unchanged"
got=$("${TEST_ENV[@]}" "${TMP}/wrapbin/gh" --version --x 2>/dev/null | lines) || true
check "extra args" "gh version 9.9.9 --version --x" "${got}"

if [[ "${fail}" == "0" ]]; then
  echo "test-gh-wrapper-version-banner: all cases passed"
else
  echo "test-gh-wrapper-version-banner: FAILURES above"
  exit 1
fi
