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

# Case 2: too many arguments rejected
assert_fails "gpush --no-merge extra-arg rejected" bash -c 'source '"${BASH_CONFIG_DIR}"'/gpush-wrapper.sh; gpush --no-merge extra-arg'

# Case 3: refuses to run on main — use real git repo and real main branch
WORKDIR="/tmp/gpush-wrapper-guard-test-$$"
mkdir -p "${WORKDIR}"
trap 'rm -rf "${WORKDIR}"' EXIT
(cd "${WORKDIR}" && /usr/bin/git init -q -b main && /usr/bin/git commit -q --allow-empty -m init)

main_test_output=$(/bin/bash -c '
  cd "'"${WORKDIR}"'" || exit 1
  #shellcheck source=/dev/null
  source "'"${BASH_CONFIG_DIR}"'/gpush-wrapper.sh"
  if gpush >/tmp/gpush-test-main-$$ 2>&1; then
    echo "FAIL: gpush on main branch — expected non-zero exit, got 0"
    exit 1
  else
    if grep -q "Refusing to run on main" /tmp/gpush-test-main-$$; then
      echo "PASS: gpush on main branch refuses with expected message"
      exit 0
    else
      echo "FAIL: gpush on main branch — wrong error message"
      cat /tmp/gpush-test-main-$$
      exit 1
    fi
  fi
  rm -f "/tmp/gpush-test-main-$$"
' 2>&1)

main_exit=$?
echo "${main_test_output}"
if [[ ${main_exit} -ne 0 ]]; then
  fail=1
fi
rm -f "/tmp/gpush-test-main-$$"

# Case 4: refuses to run on detached HEAD — use real git repo and real detached HEAD
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
