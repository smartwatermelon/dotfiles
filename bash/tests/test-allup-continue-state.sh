#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification of the `updates`/`allup` resume state machine.
# Run directly: bash bash/tests/test-allup-continue-state.sh
#
# `updates` records the failing step so `--continue` can resume instead of
# re-running steps that already succeeded. `allup --continue` additionally
# skips the network-bound repo pulls. That skip is only safe if allup can
# tell its own recorded failure from one left by a bare `updates` run —
# otherwise a `updates` failure would silently turn the next
# `allup --continue` into a no-pull run, quietly dropping the repo sync that
# is the whole point of allup.
#
# The state file is therefore "<step> <entrypoint>". This test covers the
# parsing of that format, including legacy untagged files written before the
# tag existed, which must resume the correct step but must NOT be claimed by
# allup as its own.
set -euo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail=0

WORKDIR="$(mktemp -d "/tmp/allup-continue-test.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

# Pull the function under test out of functions.sh by name rather than
# sourcing the whole file, which would run interactive-shell setup.
_UPDATES_STATE_FILE="${WORKDIR}/updates.progress"
_fn_src="$(sed -n '/^_updates_state_entrypoint() {/,/^}/p' "${REPO_ROOT}/bash/functions.sh")"
if [[ -z "${_fn_src}" ]]; then
  echo "FAIL: could not extract _updates_state_entrypoint from functions.sh" >&2
  exit 1
fi
eval "${_fn_src}"

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "  PASS: ${label}"
  else
    echo "  FAIL: ${label} — expected [${expected}], got [${actual}]"
    fail=1
  fi
}

# The step is always field 1 — this is what `updates --continue` resumes from.
# The entrypoint is field 2, absent in legacy files; a missing tag must make
# the helper return non-zero so callers fall back to "not mine". Both are read
# into `got` on their own line so no command substitution masks a status.
read_step() {
  got="$(awk 'NR==1{print $1}' "${_UPDATES_STATE_FILE}")"
}

read_entrypoint() {
  if ! got="$(_updates_state_entrypoint)"; then
    got="<none>"
  fi
}

echo "Case: no state file at all"
rm -f "${_UPDATES_STATE_FILE}"
read_entrypoint
check "entrypoint unavailable" "<none>" "${got}"

echo "Case: failure tagged by allup"
echo "_gem_update allup" >"${_UPDATES_STATE_FILE}"
read_step
check "step parses" "_gem_update" "${got}"
read_entrypoint
check "entrypoint is allup" "allup" "${got}"

echo "Case: failure tagged by a bare updates run"
echo "_gem_update updates" >"${_UPDATES_STATE_FILE}"
read_step
check "step parses" "_gem_update" "${got}"
read_entrypoint
check "entrypoint is updates (allup must not claim it)" "updates" "${got}"

echo "Case: legacy untagged state file (written before the tag existed)"
echo "_gem_update" >"${_UPDATES_STATE_FILE}"
read_step
check "step still parses, so resume works" "_gem_update" "${got}"
read_entrypoint
check "entrypoint unavailable, so allup runs pulls" "<none>" "${got}"

echo "Case: trailing whitespace does not create a phantom tag"
printf '_gem_update \n' >"${_UPDATES_STATE_FILE}"
read_step
check "step parses" "_gem_update" "${got}"
read_entrypoint
check "entrypoint unavailable" "<none>" "${got}"

# Guard the two install.sh contracts allup depends on: --sync must exist, and
# it must be rejected alongside --repair rather than silently doing both.
echo "Case: install.sh --sync/--repair contract"
for repo in "${REPO_ROOT}" "${HOME}/Developer/claude-config"; do
  script="${repo}/install.sh"
  [[ -f "${script}" ]] || continue
  name="$(basename "${repo}")"
  if grep -q -- '--sync) SYNC_ONLY=true ;;\|--sync)    SYNC_ONLY=true ;;' "${script}"; then
    echo "  PASS: ${name}/install.sh accepts --sync"
  else
    echo "  FAIL: ${name}/install.sh does not accept --sync"
    fail=1
  fi
  if "${script}" --repair --sync >/dev/null 2>&1; then
    echo "  FAIL: ${name}/install.sh allowed --repair --sync together"
    fail=1
  else
    echo "  PASS: ${name}/install.sh rejects --repair --sync"
  fi
done

echo ""
if [[ "${fail}" -eq 0 ]]; then
  echo "ALL CHECKS PASSED"
else
  echo "SOME CHECKS FAILED"
fi
exit "${fail}"
