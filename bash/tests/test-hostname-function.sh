#!/usr/bin/env bash
#shellcheck shell=bash
# Tests `hostname` (functions.sh). Stubs replace sudo and the real
# hostname, so no system state changes.
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

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Extract the function through bash's own parser. HOME points at an empty
# directory so functions.sh does not source the real gh wrapper.
_fn_src="$(HOME="${WORK}" bash --norc --noprofile -c '
  source "$1" >/dev/null 2>&1 || exit 1
  declare -f hostname
' _ "${REPO_ROOT}/bash/functions.sh")"
if [[ -z "${_fn_src}" ]]; then
  echo "FAIL: could not extract hostname from functions.sh" >&2
  exit 1
fi
eval "${_fn_src}"

SUDO_LOG="${WORK}/sudo.log"
HN_LOG="${WORK}/hostname.log"
SUDO_STUB="${WORK}/sudo-stub"
HN_STUB="${WORK}/hostname-stub"
cat >"${SUDO_STUB}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${HN_TEST_SUDO_LOG}"
if [[ -n "${HN_TEST_FAIL_ON:-}" && "$*" == *"${HN_TEST_FAIL_ON}"* ]]; then
  exit 5
fi
exit 0
EOF
cat >"${HN_STUB}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${HN_TEST_HN_LOG}"
echo "stub-host"
EOF
chmod +x "${SUDO_STUB}" "${HN_STUB}"
export _HOSTNAME_SUDO_BIN="${SUDO_STUB}" _HOSTNAME_BIN="${HN_STUB}"
export HN_TEST_SUDO_LOG="${SUDO_LOG}" HN_TEST_HN_LOG="${HN_LOG}"

reset_logs() {
  : >"${SUDO_LOG}"
  : >"${HN_LOG}"
}

echo "Test 1: no arguments runs the real hostname, no sudo"
reset_logs
out="$(hostname)"
check "prints real name" "stub-host" "${out}"
check "real hostname argv" "" "$(<"${HN_LOG}")"
mapfile -t hn_calls <"${HN_LOG}"
check "hostname called once" "1" "${#hn_calls[@]}"
check "sudo not run" "" "$(<"${SUDO_LOG}")"

echo "Test 2: a flag first passes through to the real hostname"
reset_logs
hostname -s >/dev/null
check "flag argv" "-s" "$(<"${HN_LOG}")"
check "sudo not run" "" "$(<"${SUDO_LOG}")"

echo "Test 3: a name sets all four values, then flushes the cache"
reset_logs
rc=0
hostname newbox || rc=$?
check "exit 0" "0" "${rc}"
expected="scutil --set HostName newbox
scutil --set LocalHostName newbox
scutil --set ComputerName newbox
${HN_STUB} newbox
dscacheutil -flushcache"
check "sudo calls in order" "${expected}" "$(<"${SUDO_LOG}")"

echo "Test 4: a failed step stops the rest and returns its status"
reset_logs
rc=0
HN_TEST_FAIL_ON="LocalHostName" hostname newbox || rc=$?
check "exit status 5" "5" "${rc}"
check "stops after failure" "scutil --set HostName newbox
scutil --set LocalHostName newbox" "$(<"${SUDO_LOG}")"

echo "Test 5: bad input prints usage, returns 2, runs nothing"
for args in "a b" "my.box" "my_box" "box-" "box;id"; do
  reset_logs
  rc=0
  # Split on spaces so "a b" arrives as two arguments.
  read -r -a argv <<<"${args}"
  err="$(hostname "${argv[@]}" 2>&1 >/dev/null)" || rc=$?
  check "[${args}] returns 2" "2" "${rc}"
  check "[${args}] usage on stderr" "usage: hostname [<name>] (letters, digits, hyphens)" "${err}"
  check "[${args}] sudo not run" "" "$(<"${SUDO_LOG}")"
done

echo "Test 6: a name with inner hyphens is accepted"
reset_logs
rc=0
hostname my-box-2 || rc=$?
check "exit 0" "0" "${rc}"
read -r first_call <"${SUDO_LOG}"
check "first call" "scutil --set HostName my-box-2" "${first_call}"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "All hostname tests passed."
