#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification that git/hooks/pre-push notices when its own file is
# rewritten while it is running.
# Run directly: bash bash/tests/test-hook-mutation-warning.sh
#
# Bash does not read a script into memory before running it: it reads a chunk,
# executes it, then returns to the FILE for the next chunk by byte offset. This
# hook is deployed as a symlink into a live working tree, so editing that file —
# or any checkout/rebase/reset that rewrites it — can make bash resume at a
# stale offset and report an error citing a line whose content does not match
# the message (smartwatermelon/dotfiles#274).
#
# The hook does not prevent that; it reports it, so the operator can tell a
# spurious failure from a real one. This test covers the reporting.
set -uo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${REPO_ROOT}/git/hooks/pre-push"

fail=0

_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

# ---------------------------------------------------------------
# Case 1: the detection is wired up
# ---------------------------------------------------------------
echo "Case: the mutation detector is installed and survives nested traps"

if grep -q '_warn_if_hook_mutated' "${HOOK}"; then
  _pass "the detector function is present"
else
  _fail "no _warn_if_hook_mutated in the hook (this is #274's reporting)"
fi

# The stamp must follow the symlink. Stamping "$0" would watch the symlink
# itself, whose mtime does not change when its target is rewritten — so the
# detector would never fire in the deployed configuration.
if grep -q 'readlink -f' "${HOOK}"; then
  _pass "the stamp resolves the symlink target"
else
  _fail "the stamp does not resolve the symlink — it would never fire when deployed"
fi

# Every EXIT trap must keep the detector. A bare `trap - EXIT` or a replacement
# trap would silently drop it for the rest of the run, which is exactly the
# window where #274 was observed.
bare_clears="$(grep -cE "^\s*trap - EXIT\s*$" "${HOOK}" || true)"
if ((bare_clears == 0)); then
  _pass "no bare 'trap - EXIT' drops the detector"
else
  _fail "${bare_clears} bare 'trap - EXIT' would disable the detector mid-run"
fi

# Count every trap that installs a handler on EXIT (with or without ERR), and
# require each to mention the detector. The two patterns must describe the same
# set, or the comparison is meaningless — hence the shared prefix.
exit_traps="$(grep -cE "^[[:space:]]*trap '[^']*' (ERR )?EXIT" "${HOOK}" || true)"
detector_traps="$(grep -cE "^[[:space:]]*trap '[^']*_warn_if_hook_mutated[^']*' (ERR )?EXIT" "${HOOK}" || true)"
if ((exit_traps > 0)) && ((exit_traps == detector_traps)); then
  _pass "all ${exit_traps} EXIT trap(s) retain the detector"
else
  _fail "${exit_traps} EXIT trap(s) but only ${detector_traps} retain the detector"
fi

# ---------------------------------------------------------------
# Case 2: behavioral — it fires on mutation, and only on mutation
# ---------------------------------------------------------------
# Exercised on a copy of the real hook, so the wiring under test is the shipped
# wiring rather than a restatement of it.
echo "Case: the warning fires on a mid-run rewrite, and not otherwise"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/hook-mutation-test.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

WARN_RE='EDITED WHILE IT WAS RUNNING'

# The hook runs Semgrep and AI reviews, which take minutes. Neither is needed to
# exercise the trap wiring, so the copy is truncated to the detector plus a
# short sleep — the window in which a rewrite lands.
build_probe() {
  local out="$1"
  # Take everything up to and including the top-level trap, then stop.
  sed -n '1,/^trap .\_warn_if_hook_mutated. ERR EXIT$/p' "${HOOK}" >"${out}"
  {
    echo 'echo probe-running'
    echo 'sleep 1'
    echo 'echo probe-done'
  } >>"${out}"
}

run_probe() {
  local path="$1" out="$2" mutate="$3"
  bash "${path}" >"${out}" 2>&1 &
  local pid=$!
  sleep 0.4
  if [[ "${mutate}" == "mutate" ]]; then
    printf '\n# appended mid-run\n' >>"${path}"
  fi
  wait "${pid}" 2>/dev/null || true
}

build_probe "${WORKDIR}/quiet.sh"
run_probe "${WORKDIR}/quiet.sh" "${WORKDIR}/quiet.log" no

build_probe "${WORKDIR}/noisy.sh"
run_probe "${WORKDIR}/noisy.sh" "${WORKDIR}/noisy.log" mutate

quiet_hits="$(grep -cE "${WARN_RE}" "${WORKDIR}/quiet.log" || true)"
noisy_hits="$(grep -cE "${WARN_RE}" "${WORKDIR}/noisy.log" || true)"

# The negative case first: a detector that always fires is as useless as one
# that never does.
if ((quiet_hits == 0)); then
  _pass "an untouched run stays silent (no false positive)"
else
  _fail "an untouched run warned ${quiet_hits} time(s) — false positive"
fi

if ((noisy_hits == 1)); then
  _pass "a rewritten run warns exactly once"
elif ((noisy_hits == 0)); then
  _fail "a rewritten run did NOT warn — the detector is not working"
else
  _fail "a rewritten run warned ${noisy_hits} times — the once-only guard failed"
fi

echo
if ((fail)); then
  echo "SOME CHECKS FAILED" >&2
  exit 1
fi
echo "test-hook-mutation-warning: all cases passed"
