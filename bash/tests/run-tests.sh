#!/usr/bin/env bash
# Discover and run every test in bash/tests/.
#
# Each test file is a standalone executable that communicates purely through
# its exit code (0 = pass), printing its own PASS/FAIL lines as it goes. This
# runner therefore does not need to know anything about an individual test's
# internals: it invokes each one, streams its output, and aggregates the exit
# codes into a single verdict.
#
# Usage:
#   bash bash/tests/run-tests.sh              # run everything
#   bash bash/tests/run-tests.sh path-order   # run tests matching a substring
#
# Exits non-zero if any test fails, so it is usable as a CI step or a hook.
#
# Bash 4.4+ is required (some tests use `mapfile -d`, which does not exist in
# the bash 3.2 that macOS ships at /bin/bash). The check below fails loudly
# rather than letting those tests silently produce empty results and
# "pass" — see smartwatermelon/dotfiles#221.
set -uo pipefail

# CDPATH makes `cd` echo its resolved path to stdout, which would corrupt the
# command substitution below.
unset CDPATH

# Clear inherited git repository-selection state before running any test.
#
# This is the PRIMARY chokepoint for smartwatermelon/dotfiles#239, not merely
# defense in depth. `.project-hooks/pre-push` execs this runner from inside a git
# hook, and git exports GIT_DIR into a hook's environment when the hook runs from
# a linked worktree. Every test then inherited it, and GIT_DIR outranks both the
# working directory and `git -C`, so fixture writes landed in the worktree's
# administrative git directory — which shares the common config with the real
# checkout.
#
# The individual tests isolate themselves too, which is what protects a test run
# directly rather than through this runner. Clearing it here as well means a test
# added later without that guard is still contained.
_tests_dir_for_isolation="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-env-isolation.sh
source "${_tests_dir_for_isolation}/lib/git-env-isolation.sh"
isolate_git_env

TESTS_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  echo "ERROR: bash 4.4+ required, running ${BASH_VERSION}." >&2
  echo "       macOS ships bash 3.2 at /bin/bash; install bash 5 via Homebrew" >&2
  echo "       and run this with that interpreter." >&2
  exit 1
fi

# Optional substring filter, so a single test can be run without retyping its
# full path: `run-tests.sh path-order` runs test-path-order.sh.
filter="${1:-}"

# Bash expands a glob in sorted order already, so the run order is
# deterministic and reproducible without piping through `sort`. Nullglob so an
# empty tests directory yields an empty array rather than a literal glob
# pattern that would then be "run" as a nonexistent file.
shopt -s nullglob
all_tests=("${TESTS_DIR}"/test-*.sh)
shopt -u nullglob

tests=()
for t in "${all_tests[@]}"; do
  [[ -f "${t}" ]] || continue
  if [[ -n "${filter}" && "$(basename "${t}")" != *"${filter}"* ]]; then
    continue
  fi
  tests+=("${t}")
done

if ((${#tests[@]} == 0)); then
  if [[ -n "${filter}" ]]; then
    echo "ERROR: no tests in ${TESTS_DIR} match '${filter}'." >&2
  else
    echo "ERROR: no test-*.sh files found in ${TESTS_DIR}." >&2
  fi
  # An empty run must not look like success — a glob that silently matches
  # nothing is exactly how a test suite stops testing without anyone noticing.
  exit 1
fi

passed=()
failed=()

for test in "${tests[@]}"; do
  name="$(basename "${test}")"
  echo "=============================================================="
  echo "RUN  ${name}"
  echo "=============================================================="

  # Run each test in its own process so `set -e`, traps, exported variables
  # and cwd changes inside one test cannot leak into the next.
  #
  # "${BASH}", not a bare `bash`: the version check above only vets the
  # interpreter running THIS script. A bare `bash` resolves through PATH, which
  # on macOS can still find 3.2 — and a test using `mapfile -d` would then die
  # with "mapfile: command not found" despite the guard having passed. $BASH is
  # set by bash to the full path of the running interpreter, so the vetted one
  # propagates to every child.
  #
  # The contract this places on the CALLER: whichever bash you invoke this
  # runner with is the bash every test runs under. The guard above only
  # establishes a 4.4 floor, not that you got the interpreter you meant — so
  # invoke the runner explicitly:
  #
  #   "$(brew --prefix)/bin/bash" bash/tests/run-tests.sh
  #
  # rather than a bare `bash run-tests.sh`, whose PATH lookup could land on any
  # 4.4+ bash that happens to come first. Both current callers do this:
  # `.project-hooks/pre-push` resolves a Homebrew bash before exec'ing the runner, and
  # `.github/workflows/bash-tests.yml` installs bash 5 and invokes it by path.
  if "${BASH}" "${test}"; then
    passed+=("${name}")
    echo "--> PASS ${name}"
  else
    status=$?
    failed+=("${name}")
    echo "--> FAIL ${name} (exit ${status})"
  fi
  echo
done

echo "=============================================================="
echo "SUMMARY: ${#passed[@]} passed, ${#failed[@]} failed, ${#tests[@]} total"
echo "=============================================================="

for name in "${passed[@]}"; do
  echo "  PASS  ${name}"
done
for name in "${failed[@]}"; do
  echo "  FAIL  ${name}"
done

if ((${#failed[@]} > 0)); then
  exit 1
fi
exit 0
