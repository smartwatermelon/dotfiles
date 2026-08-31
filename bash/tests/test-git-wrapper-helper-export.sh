#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification that git-wrapper.sh exports the helpers git() calls.
# Run directly: bash bash/tests/test-git-wrapper-helper-export.sh
#
# `export -f git` carries only git()'s own body across a process boundary, not
# the functions its body calls. git() arms a RETURN trap that calls
# _git_wrapper_restore_dir, so a child process that inherits the exported git
# without sourcing this file dies with
#
#   environment: line 73: _git_wrapper_restore_dir: command not found
#
# the first time that trap fires — exit 127, which fails the whole suite.
#
# BASH_ENV normally masks this: it re-sources the shell config in
# non-interactive children, which redefines the helper. But BASH_ENV is set to
# a HOME-relative path (`~/.config/bash/functions.sh`), so any child with a
# rewritten HOME resolves it to a file that does not exist, silently skips the
# re-source, and is left with the inherited git and no helper. The test suite's
# own fixtures rewrite HOME, which is how this surfaced: it broke a push while
# every test passed when run directly.
#
# gh-wrapper.sh already exports its whole helper set for exactly this reason
# (see its export comment). This test pins the same property for git-wrapper.sh.
set -euo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAPPER="${REPO_ROOT}/bash/git-wrapper.sh"

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

# Every helper git() reaches at runtime must survive the process boundary.
# Add to this list if git() grows another callee.
REQUIRED_EXPORTS=(_git_wrapper_restore_dir)

echo "Case: helpers cross a process boundary with the exported git"
# env -i so nothing is inherited from the shell running this test: the only
# way a name can appear in the child is if the wrapper exported it. Without
# this the parent's own environment satisfies the check and it proves nothing
# (the file is symlinked into ~/.config, so an edit is live immediately and a
# careless check reads the fix back to itself).
for _helper in "${REQUIRED_EXPORTS[@]}"; do
  got=$(env -i PATH="/usr/bin:/bin" HOME="/tmp" \
    bash --norc --noprofile -c "
      source '${WRAPPER}' >/dev/null 2>&1
      env | grep -c '^BASH_FUNC_${_helper}' || true
    " 2>/dev/null | tr -d '[:space:]')
  [[ -n "${got}" ]] || got="0"
  check "${_helper} is exported" "1" "${got}"
done

echo "Case: git itself is still exported"
got=$(env -i PATH="/usr/bin:/bin" HOME="/tmp" \
  bash --norc --noprofile -c "
    source '${WRAPPER}' >/dev/null 2>&1
    env | grep -c '^BASH_FUNC_git' || true
  " 2>/dev/null | tr -d '[:space:]')
[[ -n "${got}" ]] || got="0"
check "git is exported" "1" "${got}"

echo "Case: the RETURN trap survives in a child that cannot re-source config"
# The behavioral end of the property: inherit the exported git in a child with
# no BASH_ENV, run the code path that arms the trap (git -C <dir> sets
# original_dir), and require silence. Under the unfixed wrapper this prints
# "_git_wrapper_restore_dir: command not found".
trap_out=$(env -i PATH="/usr/bin:/bin:/opt/homebrew/bin" HOME="/tmp" \
  bash --norc --noprofile -c "
    source '${WRAPPER}' >/dev/null 2>&1
    _d=\$(mktemp -d)
    bash --norc --noprofile -c \"git -C '\${_d}' init -q\" 2>&1
    rm -rf \"\${_d}\"
  " 2>&1 || true)

if printf '%s' "${trap_out}" | grep -q 'command not found'; then
  check "no 'command not found' from the inherited trap" "clean" "saw: ${trap_out}"
else
  check "no 'command not found' from the inherited trap" "clean" "clean"
fi

echo
if [[ "${fail}" -eq 0 ]]; then
  echo "test-git-wrapper-helper-export: all cases passed"
else
  echo "test-git-wrapper-helper-export: FAILURES above"
fi
exit "${fail}"
