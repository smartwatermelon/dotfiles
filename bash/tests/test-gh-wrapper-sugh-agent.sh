#!/usr/bin/env bash
#shellcheck shell=bash
# sugh is defined in a plain shell and absent when CLAUDECODE is set, even if
# the parent exported it.
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

# ${BASH}, not PATH bash: macOS bash 3.2 makes the wrapper return early.
sugh_state() { # sugh_state <extra env assignments...>
  env -i PATH="/usr/bin:/bin" HOME="/tmp" "$@" \
    "${BASH}" --norc --noprofile -c "
      source '${WRAPPER}' >/dev/null 2>&1
      if declare -F sugh >/dev/null; then echo defined; else echo absent; fi
      env | grep -c '^BASH_FUNC_sugh%%' || true
    " 2>/dev/null | tr '\n' ' ' | sed 's/ $//'
}

echo "Case: plain shell defines and exports sugh"
got=$(sugh_state) || true
check "human shell" "defined 1" "${got}"

echo "Case: agent shell (CLAUDECODE=1) has no sugh"
got=$(sugh_state CLAUDECODE=1) || true
check "agent shell" "absent 0" "${got}"

echo "Case: agent shell drops a sugh exported by the launching terminal"
got=$(sugh_state CLAUDECODE=1 'BASH_FUNC_sugh%%=() {  echo bypass
}') || true
check "inherited export removed" "absent 0" "${got}"

echo
if [[ "${fail}" -eq 0 ]]; then
  echo "test-gh-wrapper-sugh-agent: all cases passed"
else
  echo "test-gh-wrapper-sugh-agent: FAILURES above"
fi
exit "${fail}"
