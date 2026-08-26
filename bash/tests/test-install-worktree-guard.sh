#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification that install.sh's repository guard accepts a linked
# worktree. Run directly: bash bash/tests/test-install-worktree-guard.sh
#
# A linked worktree's `.git` is a FILE containing a `gitdir:` pointer, not a
# directory. install.sh originally tested `[[ -d "${REPO_DIR}/.git" ]]`, which
# is false for that file, so a legitimate worktree was rejected as "not a git
# repository" (smartwatermelon/dotfiles#254). The failure was invisible from
# the main checkout, which is where the suite is normally run and where CI
# runs — this test closes that blind spot by exercising the worktree case
# directly.
#
# The guard is tested in isolation rather than by running install.sh itself:
# install.sh performs real symlink deployment into ${HOME}, which a test must
# never trigger. The guard's source line is extracted and evaluated against
# both repository shapes.
set -euo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Clear inherited git repository-selection state before touching any fixture.
# A hook invoked from a linked worktree exports GIT_DIR, which outranks both
# the working directory and `git -C` (smartwatermelon/dotfiles#239).
_tests_dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-env-isolation.sh
source "${_tests_dir}/lib/git-env-isolation.sh"
isolate_git_env

fail=0

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/install-worktree-test.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

# ---------------------------------------------------------------
# Case 1: the guard in install.sh resolves both repository shapes
# ---------------------------------------------------------------
echo "Case: install.sh repository guard accepts both repo shapes"

# Extract the guard's condition rather than restating it here. A hand-copied
# duplicate would keep passing after install.sh regressed, which is exactly
# the failure mode this test exists to catch.
# Match the guard as CODE, not as any line mentioning it. The explanatory
# comment above the guard also contains "rev-parse --git-dir", so an unanchored
# grep reported the guard present even after it had been reverted to the
# broken `-d` form — the check was matching its own documentation. Anchoring
# on the `if !` opener excludes comment lines, whose first non-blank character
# is always "#".
guard_line="$(grep -nE '^[[:space:]]*if ! git -C .* rev-parse --git-dir' "${REPO_ROOT}/install.sh" | head -1)"
if [[ -z "${guard_line}" ]]; then
  _fail "install.sh no longer guards with 'git rev-parse --git-dir'"
  echo "        A '[[ -d .git ]]' style guard rejects linked worktrees (#254)." >&2
  echo "SOME CHECKS FAILED" >&2
  exit 1
fi
_pass "install.sh guards with 'git rev-parse --git-dir'"

# Assert the -d form is gone, so a regression cannot reintroduce it alongside.
# The pattern is assembled from a variable rather than written as a
# single-quoted literal containing a dollar sign, which shellcheck reads as an
# unexpanded expression (SC2016) even when a literal is what is wanted.
dollar='$'
legacy_guard="! -d \"${dollar}{REPO_DIR}/.git\""
if grep -qF "${legacy_guard}" "${REPO_ROOT}/install.sh"; then
  _fail "install.sh still contains the '-d .git' guard that rejects worktrees"
fi

# ---------------------------------------------------------------
# Case 2: the guard's behavior on a real worktree vs a real checkout
# ---------------------------------------------------------------
echo "Case: guard condition evaluated against real repositories"

# A normal checkout.
MAIN_REPO="${WORKDIR}/main"
mkdir -p "${MAIN_REPO}"
(
  cd "${MAIN_REPO}" || exit 1
  /usr/bin/git -c core.hooksPath= -c init.templateDir= init -q -b main
  /usr/bin/git config core.hooksPath ""
  /usr/bin/git -c core.hooksPath= -c user.email=test@example.com -c user.name=Test \
    commit -q --allow-empty -m "test: init"
)

# A linked worktree off it.
LINKED="${WORKDIR}/linked"
(
  cd "${MAIN_REPO}" || exit 1
  /usr/bin/git -c core.hooksPath= worktree add -q --detach "${LINKED}" >/dev/null 2>&1
)

# Precondition: the fixture must actually produce the shape under test.
# Without this the case could pass while testing nothing (#256 class).
if [[ ! -e "${LINKED}/.git" ]]; then
  _fail "fixture produced no linked worktree — nothing was tested"
  echo "SOME CHECKS FAILED" >&2
  exit 1
fi
if [[ -d "${LINKED}/.git" ]]; then
  _fail "fixture's worktree .git is a directory, not the file form under test"
  echo "SOME CHECKS FAILED" >&2
  exit 1
fi
_pass "fixture worktree has the .git-as-file shape"

# The guard itself, applied to each shape.
# Bare `git`, deliberately — install.sh calls bare `git` too, so this exercises
# the same resolution path the guard actually takes rather than a stricter one.
# The fixture setup above uses /usr/bin/git because it must build a specific
# repository shape regardless of what is on PATH; the guard check must instead
# mirror production.
#
# Verified that the two agree here: this repo's git wrapper special-cases only
# `init` and otherwise delegates through `command git "$@"`, so bare `git` and
# /usr/bin/git return the same verdict for `rev-parse --git-dir` on both a
# normal checkout and a linked worktree (smartwatermelon/dotfiles#258).
guard_accepts() {
  local dir="$1"
  git -C "${dir}" rev-parse --git-dir >/dev/null 2>&1
}

if guard_accepts "${MAIN_REPO}"; then
  _pass "guard accepts a normal checkout"
else
  _fail "guard rejects a normal checkout"
fi

if guard_accepts "${LINKED}"; then
  _pass "guard accepts a linked worktree"
else
  _fail "guard rejects a linked worktree (this is #254)"
fi

# The negative case: a plain directory must still be rejected, so the fix
# did not simply loosen the guard into accepting anything.
NOT_A_REPO="${WORKDIR}/not-a-repo"
mkdir -p "${NOT_A_REPO}"
if guard_accepts "${NOT_A_REPO}"; then
  _fail "guard accepts a non-repository directory — too permissive"
else
  _pass "guard still rejects a non-repository directory"
fi

# And an entry named .git that does not resolve to a repository, which is the
# case `[[ -e .git ]]` would wrongly admit.
BOGUS="${WORKDIR}/bogus"
mkdir -p "${BOGUS}"
echo "gitdir: /nonexistent/path/to/nowhere" >"${BOGUS}/.git"
if guard_accepts "${BOGUS}"; then
  _fail "guard accepts a .git file pointing nowhere — too permissive"
else
  _pass "guard rejects a .git file that resolves to no repository"
fi

echo
if ((fail)); then
  echo "SOME CHECKS FAILED" >&2
  exit 1
fi
echo "test-install-worktree-guard: all cases passed"
