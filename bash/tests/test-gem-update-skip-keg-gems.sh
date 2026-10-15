#!/usr/bin/env bash
#shellcheck shell=bash
# _gem_update skips gems the Homebrew ruby keg ships.
# ruby and gem are stubbed.
set -euo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

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

_fn_src="$(bash --norc --noprofile -c '
  source "$1" >/dev/null 2>&1 || exit 1
  declare -f _gem_update
' _ "${REPO_ROOT}/bash/functions.sh")"
if [[ -z "${_fn_src}" ]]; then
  echo "FAIL: could not extract _gem_update from functions.sh" >&2
  exit 1
fi

export HOME="/tmp/gem-update-keg-test-home-$$"
mkdir -p "${HOME}"
trap 'rm -rf "${HOME}"' EXIT

# Runs _gem_update with stubbed ruby/gem in a separate bash process.
driver="${HOME}/driver.sh"
cat >"${driver}" <<'EOF'
_notif() { :; }
_update_log() { cat >/dev/null; }
ruby() { [[ -n "${RUBY_OUT}" ]] && printf '%s\n' "${RUBY_OUT}"; return "${RUBY_RC}"; }
gem() { echo "$*" >>"${CALLS}"; }
eval "${FN_SRC}"
rc=0
_gem_update || rc=$?
cat "${CALLS}"
echo "rc=${rc}"
EOF

# $1: what the ruby filter prints; $2: its exit code.
# Prints the recorded `gem` calls, then "rc=<exit>".
run_case() {
  local calls="${HOME}/gem-calls"
  : >"${calls}"
  RUBY_OUT="$1" RUBY_RC="$2" CALLS="${calls}" FN_SRC="${_fn_src}" \
    "${BASH}" --norc --noprofile "${driver}"
}

echo "Case: only the names the filter returns are updated"
out="$(run_case $'foo\nbar' 0)"
update_call="$(grep '^update ' <<<"${out}" || true)"
check "gem update gets the filtered names" \
  "update --no-document --verbose foo bar" "${update_call}"
check "exit 0" "rc=0" "${out##*$'\n'}"

echo "Case: nothing outdated outside the keg"
out="$(run_case "" 0)"
check "no gem call at all (a bare gem update means every gem)" \
  "rc=0" "${out}"

echo "Case: the filter itself fails"
out="$(run_case "" 3)"
check "failure propagated, gem not called" "rc=3" "${out}"

echo
if [[ "${fail}" -eq 0 ]]; then
  echo "test-gem-update-skip-keg-gems: all cases passed"
else
  echo "test-gem-update-skip-keg-gems: FAILURES above"
fi
exit "${fail}"
