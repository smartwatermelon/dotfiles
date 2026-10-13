#!/usr/bin/env bash
#shellcheck shell=bash
# Every _gh_wrapper_* helper must be exported, or gh() breaks in a child shell.
# The list comes from the file itself.
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

defs=$(grep -oE '^[[:space:]]*_gh_wrapper_[a-z_]+\(\)' "${WRAPPER}" || true)
defs=$(tr -d ' ()' <<<"${defs}")
defs=$(sort -u <<<"${defs}")
HELPERS=()
[[ -n "${defs}" ]] && mapfile -t HELPERS <<<"${defs}"

echo "Case: the wrapper defines helpers at all"
# An empty list would pass vacuously.
if [[ "${#HELPERS[@]}" -gt 0 ]]; then
  check "found _gh_wrapper_* definitions" "yes" "yes"
else
  check "found _gh_wrapper_* definitions" "yes" "none"
fi

echo "Case: every defined helper crosses a process boundary"
# env -i hides the parent's exports. ${BASH}, not PATH bash: macOS bash 3.2
# makes the wrapper return early.
exported=$(env -i PATH="/usr/bin:/bin" HOME="/tmp" \
  "${BASH}" --norc --noprofile -c "
    source '${WRAPPER}' >/dev/null 2>&1
    env | grep -oE '^BASH_FUNC__gh_wrapper_[a-z_]+' | sed 's/^BASH_FUNC_//' | sort -u
  " 2>/dev/null || true)
for _helper in "${HELPERS[@]}"; do
  if grep -qx "${_helper}" <<<"${exported}"; then
    check "${_helper} is exported" "1" "1"
  else
    check "${_helper} is exported" "1" "0"
  fi
done

echo "Case: gh itself is still exported"
got=$(env -i PATH="/usr/bin:/bin" HOME="/tmp" \
  "${BASH}" --norc --noprofile -c "
    source '${WRAPPER}' >/dev/null 2>&1
    env | grep -c '^BASH_FUNC_gh%%' || true
  " 2>/dev/null | tr -d '[:space:]')
[[ -n "${got}" ]] || got="0"
check "gh is exported" "1" "${got}"

echo
if [[ "${fail}" -eq 0 ]]; then
  echo "test-gh-wrapper-helper-export: all cases passed"
else
  echo "test-gh-wrapper-helper-export: FAILURES above"
fi
exit "${fail}"
