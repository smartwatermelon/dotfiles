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
  local out_file
  # A failed mktemp would leave out_file empty, redirecting the diagnostic to a
  # file named "" and silently discarding the output this helper exists to
  # capture (smartwatermelon/dotfiles#250).
  if ! out_file="$(mktemp "${TMPDIR:-/tmp}/gpush-test-out.XXXXXX")" || [[ -z "${out_file}" ]]; then
    echo "FAIL: ${desc} — mktemp failed, cannot capture output" >&2
    fail=1
    return 1
  fi
  if "$@" >"${out_file}" 2>&1; then
    echo "FAIL: ${desc} — expected non-zero exit, got 0"
    # Print what the command actually emitted; without this the diagnostic
    # for an unexpected success is silently dropped.
    sed 's/^/    /' "${out_file}"
    fail=1
  else
    echo "PASS: ${desc}"
  fi
  rm -f "${out_file}"
}

# Case 1: unknown flag rejected
assert_fails "gpush --bogus-flag rejected" gpush --bogus-flag

# Case 2: refuses to run on main — use real git repo and real main branch
WORKDIR="/tmp/gpush-wrapper-guard-test-$$"
mkdir -p "${WORKDIR}"
trap 'rm -rf "${WORKDIR}"' EXIT
# Isolated from this machine ambient hooks/templates for the same reason as
# Case 3 below: the global pre-commit hook this repo installs blocks commits to
# main, so an unisolated fixture silently ends up with no commits at all
# (smartwatermelon/dotfiles#256).
(
  cd "${WORKDIR}" || exit 1
  /usr/bin/git -c core.hooksPath= -c init.templateDir= init -q -b main
  # An EMPTY core.hooksPath, not `--unset`. Verified empirically: with
  # core.hooksPath="" git runs no hooks at all — neither the global ones nor a
  # local .git/hooks/pre-commit that exits non-zero. `--unset` would instead
  # fall back to the global core.hooksPath this repo installs, reintroducing
  # the very blocking hook the fixture needs neutralized. The `-c` above covers
  # only the init call, so the value is persisted here for later commands.
  /usr/bin/git config core.hooksPath ""
  /usr/bin/git -c user.email=test@example.com -c user.name=Test \
    commit -q --allow-empty -m init
)

# Assert the fixture actually reached the state under test, rather than
# assuming it. Case 2 refuses on main whether or not a commit exists, so
# without this the case could keep passing over an empty repository.
if ! /usr/bin/git -C "${WORKDIR}" rev-parse --verify -q HEAD >/dev/null; then
  echo "FAIL: Case 2 fixture produced no commit — nothing was tested"
  exit 1
fi
case2_branch="$(/usr/bin/git -C "${WORKDIR}" symbolic-ref --short HEAD)" || case2_branch=""
if [[ "${case2_branch}" != "main" ]]; then
  echo "FAIL: Case 2 fixture is not on main — nothing was tested"
  exit 1
fi

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
#
# This case previously reported PASS while testing nothing
# (smartwatermelon/dotfiles#256). Three separate defects stacked up:
#
#   1. No hook isolation. This repo's install.sh sets a GLOBAL core.hooksPath
#      whose pre-commit hook blocks commits to main, so the fixture's `commit`
#      was refused, `rev-list` found no HEAD, and the detach never happened.
#   2. `trap ... RETURN` in a `bash -c` top level (not a function) never fires,
#      so the temp dir leaked — the same class as the Case 2 leak fixed in #255.
#   3. The assertion could not tell a real detached HEAD from a fake one. After
#      sourcing gpush-wrapper.sh, a bare `git` resolves to this repo's git
#      WRAPPER, not /usr/bin/git. The wrapper left `git symbolic-ref` returning
#      empty, so gpush printed "Refusing to run on detached HEAD" while HEAD was
#      still on main — and the grep matched. The case passed on a message that
#      described a state the fixture had never reached.
#
# The fixture is therefore isolated from ambient hooks/templates, and the
# preconditions are ASSERTED rather than assumed: a test for detached-HEAD
# behavior must confirm the HEAD is actually detached before asserting on the
# message, or it is only testing its own string matching.
detached_test_output=$(/bin/bash -c '
  tmpwork=$(mktemp -d) || exit 1
  cd "${tmpwork}" || exit 1
  # EXIT, not RETURN: this is a script top level, not a function, so a RETURN
  # trap never fires and the directory leaks.
  trap "rm -rf \"${tmpwork}\"" EXIT

  # Neutralize this machine ambient git hooks and templates. Without this the
  # global pre-commit hook refuses the commit below and the whole fixture
  # collapses silently.
  git_isolated() {
    /usr/bin/git -c core.hooksPath= -c init.templateDir= \
      -c user.email=test@example.com -c user.name=Test "$@"
  }

  git_isolated init -q -b main
  git_isolated config core.hooksPath ""
  git_isolated commit -q --allow-empty -m "init"

  first_commit=$(git_isolated rev-list --max-parents=0 HEAD)
  if [[ -z "${first_commit}" ]]; then
    echo "FAIL: fixture produced no commit — nothing was tested"
    exit 1
  fi

  git_isolated commit -q --allow-empty -m "second"
  git_isolated checkout -q --detach "${first_commit}"

  # The substantive precondition. Assert against /usr/bin/git explicitly: a
  # bare `git` would resolve to this repo git wrapper once gpush-wrapper.sh is
  # sourced below, and the wrapper is exactly what faked this state before.
  if /usr/bin/git symbolic-ref -q HEAD >/dev/null 2>&1; then
    echo "FAIL: HEAD is not detached — the fixture never reached the state under test"
    exit 1
  fi

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
