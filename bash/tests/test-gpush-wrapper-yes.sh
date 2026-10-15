#!/usr/bin/env bash
#shellcheck shell=bash
# Tests gpush --yes/-y (#418): skips only the merge question. PATH stubs, no real git/gh.
set -uo pipefail

unset CDPATH

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAPPER="${GPUSH_WRAPPER:-${REPO_ROOT}/bash/gpush-wrapper.sh}"

fail=0
pass() { echo "PASS: $1"; }
bad() {
  echo "FAIL: $1"
  fail=1
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/gpush-yes-test.XXXXXX")" || exit 1
trap 'rm -rf "${TMP}"' EXIT
STUBS="${TMP}/bin"
LOG="${TMP}/calls.log"
mkdir -p "${STUBS}"

stub() { # stub <name>; the script body arrives on stdin
  local name="$1"
  {
    echo '#!/usr/bin/env bash'
    cat
  } >"${STUBS}/${name}"
  chmod +x "${STUBS}/${name}"
}

stub git <<'STUB'
case "$1" in
  symbolic-ref) echo feature-branch ;;
  rev-parse) echo 0123456789abcdef0123456789abcdef01234567 ;;
  remote) echo "  HEAD branch: main" ;;
  *) ;;
esac
exit 0
STUB
stub gh <<'STUB'
echo "gh $*" >>"${GPUSH_TEST_LOG}"
case "$1 $2" in
  "pr create") echo "https://github.com/o/r/pull/7" ;;
  "run list") printf "99\tCI\n" ;;
  "run view") echo success ;;
esac
exit 0
STUB
stub merge-lock <<'STUB'
echo "merge-lock $*" >>"${GPUSH_TEST_LOG}"
exit "${GPUSH_TEST_LOCK_RC:-0}"
STUB
stub timeout <<'STUB'
shift
exec "$@"
STUB
stub sleep <<'STUB'
exit 0
STUB

# run_gpush <stdin-text> <args...>; sets OUT, RC. The call log is reset each run.
run_gpush() {
  local input="$1"
  shift
  : >"${LOG}"
  # env -i: exported functions (the real gh wrapper) must not shadow stubs
  OUT="$(printf '%s' "${input}" | env -i PATH="${STUBS}:/usr/bin:/bin" HOME="${TMP}" \
    GPUSH_TEST_LOG="${LOG}" GPUSH_TEST_LOCK_RC="${LOCK_RC:-0}" \
    "${BASH}" "${WRAPPER}" "$@" 2>&1)"
  RC=$?
}
logged() { grep -q -- "$1" "${LOG}"; }

# 1. Baseline (no flag): answering "n" must not call merge-lock or merge.
LOCK_RC=0
run_gpush $'n\n'
if ! logged "merge-lock" && ! logged "pr merge"; then
  pass "no flag + answer n: no merge-lock, no merge"
else
  bad "no flag + answer n reached merge-lock or merge"
fi

# 2. --yes with EMPTY stdin: no prompt needed; lock step, then merge.
for flag in --yes -y; do
  LOCK_RC=0
  run_gpush "" "${flag}"
  if [[ ${RC} -eq 0 ]] && logged "merge-lock auth 7 gpush" && logged "pr merge 7 --squash --delete-branch"; then
    pass "${flag}: merges without a prompt, through the merge-lock step"
  else
    bad "${flag}: expected merge-lock then gh pr merge (rc=${RC})"
    echo "${OUT}" | sed 's/^/    /'
  fi
done

# 3. --yes does not bypass the lock: a failed lock step must stop the merge.
LOCK_RC=1
run_gpush "" --yes
if [[ ${RC} -ne 0 ]] && logged "merge-lock" && ! logged "pr merge"; then
  pass "--yes with a failed merge-lock step: no merge, non-zero exit"
else
  bad "--yes bypassed a failed merge-lock step (rc=${RC})"
fi

# 4. --yes plus --no-merge (either order): stop after CI.
LOCK_RC=0
run_gpush "" --yes --no-merge
if [[ ${RC} -eq 0 ]] && ! logged "merge-lock" && ! logged "pr merge"; then
  pass "--yes --no-merge: --no-merge wins, no lock, no merge"
else
  bad "--yes --no-merge: merged or locked despite --no-merge (rc=${RC})"
fi
run_gpush "" --no-merge --yes
if [[ ${RC} -eq 0 ]] && ! logged "merge-lock" && ! logged "pr merge"; then
  pass "--no-merge --yes: --no-merge wins, no lock, no merge"
else
  bad "--no-merge --yes: merged or locked despite --no-merge (rc=${RC})"
fi

# 5. Unknown flags are still rejected, alone or next to --yes.
run_gpush "" --bogus
if [[ ${RC} -ne 0 ]] && ! logged "pr create"; then
  pass "--bogus rejected before any work"
else
  bad "--bogus was not rejected (rc=${RC})"
fi
if grep -q -- "--yes" <<<"${OUT}"; then
  pass "usage line mentions --yes"
else
  bad "usage line omits --yes"
fi
run_gpush "" --yes --bogus
if [[ ${RC} -ne 0 ]] && ! logged "pr create"; then
  pass "--yes --bogus rejected before any work"
else
  bad "--yes --bogus was not rejected (rc=${RC})"
fi

exit "${fail}"
