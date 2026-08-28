#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification for git/hooks/pre-push's review/scan diff base.
# Run directly: bash bash/tests/test-pre-push-base-ref.sh
#
# Regression coverage for #284: the hook diffed against the LOCAL `main` ref.
# Nothing in a feature-branch workflow updates local `main` — `git fetch`
# moves the remote-tracking ref `origin/main`, not `main` — so in a long
# session local `main` silently lags behind. When it does, `main...HEAD`
# includes already-merged-upstream commits the pusher never touched, and the
# full-diff reviewer blocks the push on findings in code outside the PR.
#
# The fix prefers `origin/main` when that ref exists, falling back to local
# `main` otherwise (fresh clones, forks with a differently-named remote).
# Same guard shape as the Semgrep baseline at run_static_analysis().
#
# Strategy: the hook auto-executes every check top-to-bottom when run (it is
# not designed to be sourced and cherry-picked), so each case below runs it
# as a real subprocess against a scratch repo whose refs are posed to
# reproduce the drift, with mocked gh/semgrep/run-review.sh on PATH. The
# review mock records the diff it was handed, which is the actual assertion
# target: what the reviewer SEES is the bug, not what the hook exits.
set -uo pipefail

unset CDPATH

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${REPO_ROOT}/git/hooks/pre-push"

fail=0

WORKDIR="/tmp/pre-push-base-ref-test-$$"
mkdir -p "${WORKDIR}"
trap 'rm -rf "${WORKDIR}"' EXIT

# Clear inherited git repository-selection state before touching any fixture.
# A hook invoked from a linked worktree exports GIT_DIR, which outranks both the
# working directory and `git -C`, so without this the scratch repos below are
# silently redirected at the real checkout (smartwatermelon/dotfiles#239).
_tests_dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-env-isolation.sh
source "${_tests_dir}/lib/git-env-isolation.sh"
isolate_git_env "${WORKDIR}"

# Build a repo reproducing #284's exact shape:
#
#   main (local)  -> stale, at the branch point
#   origin/main   -> advanced by an unrelated upstream commit
#   feature       -> the pusher's work, WITH that upstream merged in
#
# The merge is load-bearing, and the issue's root-cause section understates
# it. `main...HEAD` is a SYMMETRIC range: it diffs from the merge-base, not
# from main's tip. While local main is merely a stale ancestor of
# origin/main, the merge-base with feature is the same commit either way and
# both bases give an identical diff — stale-but-ancestor drift is harmless on
# its own. It is the `Merge branch 'main' into ...` commit (issue step 5)
# that pulls the upstream commit into the branch's history, moving the
# merge-base against stale local main backwards relative to origin/main and
# dragging already-merged upstream files into the range.
#
# So `main...HEAD` spans the unrelated upstream file plus the pusher's;
# `origin/main...HEAD` spans only the pusher's.
setup_drifted_repo() {
  local dir="$1"
  mkdir -p "${dir}"
  (
    cd "${dir}" || exit 1
    /usr/bin/git -c core.hooksPath= -c init.templateDir= init -q -b main
    /usr/bin/git config core.hooksPath ""
    /usr/bin/git config user.email "test@example.com"
    /usr/bin/git config user.name "Test"

    printf 'base\n' >base.txt
    /usr/bin/git add base.txt
    /usr/bin/git commit -q -m "test: base"

    # The pusher's branch, cut from the shared base.
    /usr/bin/git checkout -q -b feature
    printf 'mine\n' >mine.txt
    /usr/bin/git add mine.txt
    /usr/bin/git commit -q -m "test: my own work"

    # Upstream advances on main while the session sits on the feature branch.
    # Committed on a detached head so LOCAL main stays where it was — this is
    # the drift, and it is what a real `git fetch` produces.
    /usr/bin/git checkout -q --detach main
    printf 'theirs\n' >upstream.txt
    /usr/bin/git add upstream.txt
    /usr/bin/git commit -q -m "test: unrelated upstream work"
    /usr/bin/git update-ref refs/remotes/origin/main HEAD
    local upstream_sha
    upstream_sha=$(/usr/bin/git rev-parse HEAD)

    # The branch merges that upstream work in, then carries on. Without this
    # the fixture does not reproduce the bug at all.
    /usr/bin/git checkout -q feature
    /usr/bin/git merge -q --no-edit "${upstream_sha}" \
      -m "Merge branch 'main' into feature"
    printf 'more\n' >mine2.txt
    /usr/bin/git add mine2.txt
    /usr/bin/git commit -q -m "test: more of my own work"
  )
}

# Mocked run-review.sh: records the diff piped to it, then exits clean.
# The recorded diff is the assertion target.
write_mock_review() {
  local home_dir="$1" capture="$2"
  mkdir -p "${home_dir}/.claude/hooks"
  cat >"${home_dir}/.claude/hooks/run-review.sh" <<MOCK_EOF
#!/usr/bin/env bash
cat >"${capture}"
echo "VERDICT: PASS"
exit 0
MOCK_EOF
  chmod +x "${home_dir}/.claude/hooks/run-review.sh"
}

write_mock_bin() {
  local bin_dir="$1"
  mkdir -p "${bin_dir}"
  # Clean scan, no findings, no network.
  cat >"${bin_dir}/semgrep" <<'MOCK_EOF'
#!/usr/bin/env bash
exit 0
MOCK_EOF
  # No PR exists for this scratch branch; the review-iteration check no-ops.
  cat >"${bin_dir}/gh" <<'MOCK_EOF'
#!/usr/bin/env bash
exit 1
MOCK_EOF
  chmod +x "${bin_dir}/semgrep" "${bin_dir}/gh"
}

run_hook() {
  local repo_dir="$1" bin_dir="$2" home_dir="$3"
  local sha
  sha=$(cd "${repo_dir}" && /usr/bin/git rev-parse HEAD)
  (
    cd "${repo_dir}" || exit 1
    export PATH="${bin_dir}:${PATH}"
    export HOME="${home_dir}"
    export CLAUDECODE=1
    export STRICT_PREPUSH=1
    unset POSTPUSH_LOOP
    printf 'refs/heads/feature %s refs/heads/feature deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' "${sha}" \
      | bash "${HOOK}" origin git@example.com:test/test.git </dev/stdin \
        >"${home_dir}/hook.log" 2>&1
  )
}

# ---------------------------------------------------------------
# Case 1: local main is stale -> the reviewer must NOT see the
# unrelated upstream file. This is #284 itself.
# ---------------------------------------------------------------
REPO1="${WORKDIR}/repo1"
BIN1="${WORKDIR}/bin1"
HOME1="${WORKDIR}/home1"
CAPTURE1="${WORKDIR}/review-diff-1.txt"
setup_drifted_repo "${REPO1}"
write_mock_bin "${BIN1}"
write_mock_review "${HOME1}" "${CAPTURE1}"

run_hook "${REPO1}" "${BIN1}" "${HOME1}"

if [[ ! -f "${CAPTURE1}" ]]; then
  echo "FAIL: review never ran — cannot assert diff scope"
  cat "${HOME1}/hook.log"
  fail=1
else
  saw_mine=0
  saw_upstream=0
  grep -q 'mine\.txt' "${CAPTURE1}" && saw_mine=1
  grep -q 'upstream\.txt' "${CAPTURE1}" && saw_upstream=1

  if [[ ${saw_mine} -eq 1 && ${saw_upstream} -eq 0 ]]; then
    echo "PASS: stale local main — reviewer saw only the branch's own changes"
  else
    echo "FAIL: diff scope wrong (mine.txt=${saw_mine} upstream.txt=${saw_upstream})"
    echo "      expected mine.txt=1 upstream.txt=0"
    echo "      #284: hook diffed against stale local main, pulling in"
    echo "      already-merged upstream code the pusher never touched."
    fail=1
  fi
fi

# ---------------------------------------------------------------
# Case 2: no origin/main at all (fresh clone, fork with a
# differently-named remote) -> must fall back to local main and
# still review, not skip silently.
# ---------------------------------------------------------------
REPO2="${WORKDIR}/repo2"
BIN2="${WORKDIR}/bin2"
HOME2="${WORKDIR}/home2"
CAPTURE2="${WORKDIR}/review-diff-2.txt"
setup_drifted_repo "${REPO2}"
(cd "${REPO2}" && /usr/bin/git update-ref -d refs/remotes/origin/main)
write_mock_bin "${BIN2}"
write_mock_review "${HOME2}" "${CAPTURE2}"

run_hook "${REPO2}" "${BIN2}" "${HOME2}"

if [[ -f "${CAPTURE2}" ]] && grep -q 'mine\.txt' "${CAPTURE2}"; then
  echo "PASS: absent origin/main — fell back to local main and still reviewed"
else
  echo "FAIL: absent origin/main — review did not run or missed the branch diff"
  cat "${HOME2}/hook.log"
  fail=1
fi

# ---------------------------------------------------------------
# Case 3: local main already up to date with origin/main -> the
# fix must not change correct behaviour.
# ---------------------------------------------------------------
REPO3="${WORKDIR}/repo3"
BIN3="${WORKDIR}/bin3"
HOME3="${WORKDIR}/home3"
CAPTURE3="${WORKDIR}/review-diff-3.txt"
setup_drifted_repo "${REPO3}"
(cd "${REPO3}" && /usr/bin/git update-ref refs/heads/main refs/remotes/origin/main)
write_mock_bin "${BIN3}"
write_mock_review "${HOME3}" "${CAPTURE3}"

run_hook "${REPO3}" "${BIN3}" "${HOME3}"

if [[ -f "${CAPTURE3}" ]] \
  && grep -q 'mine\.txt' "${CAPTURE3}" \
  && ! grep -q 'upstream\.txt' "${CAPTURE3}"; then
  echo "PASS: fresh local main — scope unchanged"
else
  echo "FAIL: fresh local main — scope regressed"
  cat "${HOME3}/hook.log"
  fail=1
fi

echo ""
if [[ ${fail} -eq 0 ]]; then
  echo "All base-ref tests passed"
else
  echo "Base-ref tests FAILED"
fi
exit "${fail}"
