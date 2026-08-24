#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification for bash/gpush-wrapper.sh's argument validation
# and main-branch guard. Run directly: bash bash/tests/test-gpush-wrapper-guard.sh
#
# Regression coverage for the gpush()->gpush-wrapper.sh extraction: gpush
# must still reject unknown flags and refuse to run on main/master/detached
# HEAD, without touching real git remotes or GitHub state.
set -uo pipefail

unset CDPATH

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Clear inherited git repository-selection state before touching any fixture.
# A hook invoked from a linked worktree exports GIT_DIR, which outranks both the
# working directory and `git -C`, so without this the scratch repos below are
# silently redirected at the real checkout (smartwatermelon/dotfiles#239).
_tests_dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-env-isolation.sh
source "${_tests_dir}/lib/git-env-isolation.sh"
isolate_git_env

export BASH_CONFIG_DIR="${REPO_ROOT}/bash"

#shellcheck source=/dev/null
source "${BASH_CONFIG_DIR}/gpush-wrapper.sh"

fail=0

assert_fails() {
  local desc="$1"
  shift
  if "$@" >/tmp/gpush-test-out-$$ 2>&1; then
    echo "FAIL: ${desc} — expected non-zero exit, got 0"
    fail=1
  else
    echo "PASS: ${desc}"
  fi
  rm -f "/tmp/gpush-test-out-$$"
}

# Case 1: unknown flag rejected
assert_fails "gpush --bogus-flag rejected" gpush --bogus-flag

# Case 2: refuses to run on main — use real git repo and real main branch
WORKDIR="/tmp/gpush-wrapper-guard-test-$$"
mkdir -p "${WORKDIR}"
trap 'rm -rf "${WORKDIR}"' EXIT
(cd "${WORKDIR}" && /usr/bin/git init -q -b main && /usr/bin/git commit -q --allow-empty -m init)

# The capture file lives INSIDE WORKDIR rather than in /tmp under its own
# "$$". The subshell below expands "$$" to the SUBSHELL's pid, so a /tmp path
# built there could never be named by the outer shell's cleanup — that
# mismatch leaked a file per run. Keeping it under WORKDIR means the existing
# EXIT trap removes it, whatever pid produced it.
main_out_file="${WORKDIR}/gpush-main-output"

main_test_output=$(/bin/bash -c '
  cd "'"${WORKDIR}"'" || exit 1
  out_file="'"${main_out_file}"'"
  #shellcheck source=/dev/null
  source "'"${BASH_CONFIG_DIR}"'/gpush-wrapper.sh"
  if gpush >"${out_file}" 2>&1; then
    echo "FAIL: gpush on main branch — expected non-zero exit, got 0"
    exit 1
  fi
  if grep -q "Refusing to run on main" "${out_file}"; then
    echo "PASS: gpush on main branch refuses with expected message"
    exit 0
  fi
  echo "FAIL: gpush on main branch — wrong error message"
  cat "${out_file}"
  exit 1
' 2>&1)

main_exit=$?
echo "${main_test_output}"
if [[ ${main_exit} -ne 0 ]]; then
  fail=1
fi

# Case 3: refuses to run on detached HEAD — use real git repo and real detached HEAD
# Use a separate temp directory to avoid interference from main repo's git wrappers
detached_test_output=$(/bin/bash -c '
  tmpwork=$(mktemp -d)
  cd "${tmpwork}" || exit 1
  trap "rm -rf ${tmpwork}" RETURN

  # Use /usr/bin/git to bypass any wrapper functions
  /usr/bin/git init -q -b main
  /usr/bin/git commit -q --allow-empty -m "init"

  # Get the SHA of the first commit
  first_commit=$(/usr/bin/git rev-list --max-parents=0 HEAD)

  # Create a second commit
  /usr/bin/git commit -q --allow-empty -m "second"

  # Checkout the first commit to create real detached HEAD
  /usr/bin/git checkout -q --detach "${first_commit}"

  #shellcheck source=/dev/null
  source "'"${BASH_CONFIG_DIR}"'/gpush-wrapper.sh"

  gpush_output=$(gpush 2>&1)
  gpush_exit=$?

  if [[ ${gpush_exit} -eq 0 ]]; then
    echo "FAIL: gpush on detached HEAD — expected non-zero exit, got 0"
    exit 1
  elif echo "${gpush_output}" | grep -q "Refusing to run on.*detached HEAD"; then
    echo "PASS: gpush on detached HEAD refuses with expected message"
    exit 0
  else
    echo "FAIL: gpush on detached HEAD — wrong error message"
    echo "${gpush_output}"
    exit 1
  fi
' 2>&1)

detached_exit=$?
echo "${detached_test_output}"
if [[ ${detached_exit} -ne 0 ]]; then
  fail=1
fi

if [[ "${fail}" -eq 1 ]]; then
  echo "FAILED"
  exit 1
fi
echo "All gpush-wrapper guard tests passed"
