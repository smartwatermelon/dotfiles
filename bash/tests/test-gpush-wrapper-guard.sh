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

# Case 2: other invalid first argument rejected
assert_fails "gpush --invalid-flag rejected" bash -c 'source '"${BASH_CONFIG_DIR}"'/gpush-wrapper.sh; gpush --invalid-flag'

# Case 3: refuses to run on main — stub `git symbolic-ref` to report main
WORKDIR="/tmp/gpush-wrapper-guard-test-$$"
mkdir -p "${WORKDIR}"
trap 'rm -rf "${WORKDIR}"' EXIT
(cd "${WORKDIR}" && command git init -q -b main && command git commit -q --allow-empty -m init)

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

# Case 4: refuses to run on detached HEAD — test using git mock via PATH
# Since creating a real detached HEAD is complex with git wrappers, we use
# PATH-based mocking to intercept both bare git and command git calls.
detached_test_output=$(/bin/bash -c '
  tmpdir=$(mktemp -d)
  cat > "${tmpdir}/git" << '"'"'EOF'"'"'
#!/bin/bash
if [[ "$1" == "symbolic-ref" ]] && [[ "$2" == "--short" ]]; then
  exit 1  # Simulates detached HEAD detection failure
fi
exec /usr/bin/git "$@"
EOF
  chmod +x "${tmpdir}/git"
  export PATH="${tmpdir}:${PATH}"

  source "'"${BASH_CONFIG_DIR}"'/gpush-wrapper.sh"

  gpush_output=$(gpush 2>&1)
  gpush_exit=$?
  rm -rf "${tmpdir}"

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
