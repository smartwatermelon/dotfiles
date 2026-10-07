#!/usr/bin/env bash
#shellcheck shell=bash
# lint-shell.sh blocks info findings as CI's -S info does (kebab-tax#1286).
set -uo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${REPO_ROOT}/git/hooks/lint-shell.sh"

fail=0
_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

for tool in shellcheck shfmt; do
  if ! command -v "${tool}" >/dev/null; then
    echo "SKIP: ${tool} not installed"
    exit 0
  fi
done

TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT

# A fixture rc, not ~/.config or ~/.shellcheckrc: the test asserts the hook's
# severity, not whatever the developer's machine carries.
RC="${TMPROOT}/shellcheckrc"
printf 'disable=SC2310\n' >"${RC}"

# SC2329 (shellcheck 0.11) needs a returning function and an explicit `exit`.
c="${TMPROOT}/case"
mkdir -p "${c}"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'is_ready() {' '  return 0' '}' 'echo "finished"' 'exit 0' \
  >"${c}/unused.sh"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'echo "finished"' >"${c}/clean.sh"
chmod +x "${c}/unused.sh" "${c}/clean.sh"

echo "-- known-bad: --severity=warning (the old hook) passes SC2329"
# Captured, not piped: grep -q exits early, shellcheck takes SIGPIPE, and
# pipefail turns a match into a failure.
info_out="$(shellcheck --rcfile "${RC}" --severity=info "${c}/unused.sh" 2>&1)" || true
if shellcheck --rcfile "${RC}" --severity=warning --exclude=SC2312 "${c}/unused.sh" >/dev/null 2>&1 \
  && grep -q SC2329 <<<"${info_out}"; then
  _pass "known-bad reproduces"
else
  _fail "known-bad did NOT reproduce, so the cases below prove nothing"
  exit 1
fi

echo "-- the hook blocks the info finding"
rc=0
out="$(cd "${c}" && SHELLCHECK_CANONICAL_CONFIG="${RC}" "${BASH}" "${HOOK}" unused.sh 2>&1)" || rc=$?
if [[ "${rc}" -ne 0 ]]; then _pass "exits non-zero"; else _fail "exit 0 despite SC2329"; fi
if grep -q SC2329 <<<"${out}"; then _pass "reports SC2329"; else _fail "SC2329 not reported"; fi

echo "-- control: a clean file still passes"
rc=0
out="$(cd "${c}" && SHELLCHECK_CANONICAL_CONFIG="${RC}" "${BASH}" "${HOOK}" clean.sh 2>&1)" || rc=$?
if [[ "${rc}" -eq 0 ]]; then _pass "clean file passes"; else _fail "clean file blocked (rc=${rc}): ${out}"; fi

exit "${fail}"
