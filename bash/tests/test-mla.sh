#!/usr/bin/env bash
#shellcheck shell=bash
# Tests `mla` (functions.sh). merge-lock grants real approvals, so a stub
# stands in for it through _MLA_MERGE_LOCK_BIN.
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
  declare -f mla
' _ "${REPO_ROOT}/bash/functions.sh")"
if [[ -z "${_fn_src}" ]]; then
  echo "FAIL: could not extract mla from functions.sh" >&2
  exit 1
fi
eval "${_fn_src}"

LOG="${WORK}/merge-lock.log"
STUB="${WORK}/merge-lock-stub"
cat >"${STUB}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MLA_TEST_LOG}"
exit "${MLA_TEST_RC:-0}"
EOF
chmod +x "${STUB}"
export _MLA_MERGE_LOCK_BIN="${STUB}" MLA_TEST_LOG="${LOG}"

echo "Test 1: mla <N> runs merge-lock auth <N> ok"
: >"${LOG}"
rc=0
mla 824 || rc=$?
check "exit 0" "0" "${rc}"
check "exact argv" "auth 824 ok" "$(<"${LOG}")"

echo "Test 2: bad input prints usage, returns 2, runs nothing"
for args in "" "abc" "824 ok" "82a" "-1" "824;id"; do
  : >"${LOG}"
  rc=0
  # Split on spaces so "824 ok" arrives as two arguments.
  read -r -a argv <<<"${args}"
  err="$(mla "${argv[@]}" 2>&1 >/dev/null)" || rc=$?
  check "[${args}] returns 2" "2" "${rc}"
  check "[${args}] usage on stderr" "usage: mla <PR number>" "${err}"
  check "[${args}] merge-lock not run" "" "$(<"${LOG}")"
done

echo "Test 3: merge-lock failure is passed through"
rc=0
MLA_TEST_RC=3 mla 824 || rc=$?
check "exit status 3" "3" "${rc}"

echo "Test 4: no mla alias left in aliases.sh"
check "alias removed" "0" "$(grep -c "^[[:space:]]*alias mla=" "${REPO_ROOT}/bash/aliases.sh" || true)"

if [[ "${fail}" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "All mla tests passed."
