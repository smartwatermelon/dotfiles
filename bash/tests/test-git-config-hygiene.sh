#!/usr/bin/env bash
#shellcheck shell=bash
# Guard against test-fixture values leaking into this checkout's real
# .git/config. Run directly:
# bash bash/tests/test-git-config-hygiene.sh
#
# Regression coverage for smartwatermelon/dotfiles#239: on 2026-08-24 this
# repo's .git/config was found holding `core.hooksPath=` (empty),
# `user.email=test@example.com`, and `user.name=Test`. The cause was never
# identified — the obvious suspects (test-pre-push-stale-ci.sh's setup_repo,
# and `git worktree remove`) were both tested and ruled out. A separate,
# confirmed escape had already put a `beacon-biosignals/forked-tool` remote
# in this repo via test-gh-wrapper-identity.sh before that test sandboxed
# HOME.
#
# Because the mechanism is unknown, this test detects rather than prevents:
# it asserts the checkout's local config is clean, so the next occurrence
# fails loudly in the suite (which runs on every push via .project-hooks/pre-push
# and in CI) no matter what writes it.
#
# The empty-hooksPath case is the one that actually mattered. An empty
# value does not mean "unset": git resolves it to `./`, the repo root. This
# repo has a `pre-commit/` *directory* there, so `[[ -x ./pre-commit ]]`
# succeeds while git still finds no executable file to run — Protocol 4's
# automatic review silently did not fire in this checkout.
set -euo pipefail

# Suite convention (bash/README.md, "Adding a test"): CDPATH makes `cd` echo
# its resolved path to stdout, which corrupts command substitution. Unset it
# once here so any `cd` added later is protected without per-call-site
# reasoning; the inline `CDPATH=''` below stays as a local belt-and-braces
# guard, matching test-allup-continue-state.sh and run-tests.sh.
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail=0

_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

# Read a local-scope value; empty output covers both "unset" and "set to
# empty", so the two are distinguished via --get-regexp where it matters.
_local_get() {
  git -C "${REPO_ROOT}" config --local --get "$1" 2>/dev/null || true
}

# True when the key exists in local scope at all, whatever its value. This
# is the check that catches `hooksPath = ` (present, empty) — `--get`
# returns nothing for it, which is indistinguishable from absent.
_local_has_key() {
  git -C "${REPO_ROOT}" config --local --get-regexp "^$1\$" >/dev/null 2>&1
}

echo "Case: no local git identity overrides"

# A local user.email/user.name in this repo is always wrong — identity comes
# from the global config. Fixture values are the specific worry, but any
# local override is worth failing on, since it silently re-authors commits.
if _local_has_key "user\.email"; then
  _bad_value=$(_local_get user.email)
  _fail "local user.email is set (${_bad_value}) — identity must come from global config"
else
  _pass "no local user.email"
fi

if _local_has_key "user\.name"; then
  _bad_value=$(_local_get user.name)
  _fail "local user.name is set (${_bad_value}) — identity must come from global config"
else
  _pass "no local user.name"
fi

echo "Case: core.hooksPath is not locally overridden"

# The #239 failure. An empty local value shadows the global hooks dir and
# resolves to the repo root, which disables every hook without erroring.
if _local_has_key "core\.hooksPath"; then
  _bad_value=$(_local_get core.hooksPath)
  _fail "local core.hooksPath is set ('${_bad_value}') — shadows the global hooks dir; unset it"
else
  _pass "no local core.hooksPath override"
fi

echo "Case: hooks actually resolve to an executable pre-commit"

# This assertion is machine-local, unlike the config checks above. It is
# meaningful only where this machine's shared hooks are actually deployed
# (via a global core.hooksPath). A CI runner has a fresh clone, no global
# git config, and no ~/.config/git/hooks — so .git/hooks holds only samples
# and there is nothing to assert. Skip there rather than fail, following
# the pattern test-path-order.sh uses for Homebrew-dependent checks.
#
# The precondition is "a global core.hooksPath is configured", not "$CI is
# set": that states the actual dependency, and it stays correct on a
# developer machine that has not run install.sh yet.
global_hooks_path="$(git config --global --get core.hooksPath 2>/dev/null || true)"

if [[ -z "${global_hooks_path}" ]]; then
  echo "  SKIP: no global core.hooksPath configured; shared hooks are not deployed here"
else
  # Resolving the key is not the same as the hook being runnable — a
  # same-named *directory* satisfies `[[ -x ]]`. Check for a regular file.
  hooks_dir="$(git -C "${REPO_ROOT}" rev-parse --git-path hooks)"
  case "${hooks_dir}" in
    /*) resolved_hooks="${hooks_dir}" ;;
    *) resolved_hooks="${REPO_ROOT}/${hooks_dir}" ;;
  esac

  if [[ -f "${resolved_hooks}/pre-commit" && -x "${resolved_hooks}/pre-commit" ]]; then
    _pass "pre-commit resolves to an executable file (${resolved_hooks})"
  else
    _fail "no executable pre-commit file at resolved hooks dir '${resolved_hooks}' — local review will not run"
  fi
fi

echo "Case: no unexpected remotes"

# test-gh-wrapper-identity.sh once added a beacon-biosignals/forked-tool
# `upstream` here. Only origin belongs in this repo.
while read -r remote; do
  [[ -z "${remote}" ]] && continue
  if [[ "${remote}" != "origin" ]]; then
    remote_url=$(git -C "${REPO_ROOT}" remote get-url "${remote}" 2>/dev/null || true)
    _fail "unexpected remote '${remote}' -> ${remote_url}"
  fi
done < <(git -C "${REPO_ROOT}" remote || true)

if git -C "${REPO_ROOT}" remote | grep -qx "origin"; then
  _pass "origin is present"
else
  _fail "origin remote is missing"
fi

# The loop above already fails once per offending remote, naming it and its
# URL. This block exists only to report the CLEAN case, so a passing run shows
# the assertion actually ran rather than skipping a zero-iteration loop. It
# deliberately does not _fail on a dirty run: a summary count adds a second
# FAIL line for a condition the loop has already reported in more useful
# detail (smartwatermelon/dotfiles#242).
#
# The `|| true` is load-bearing, not defensive habit: `grep -c` exits 1 when
# the count is zero — the clean case — which `set -e` would otherwise treat
# as a fatal error.
unexpected_count=$(git -C "${REPO_ROOT}" remote | grep -cvx "origin" || true)
if [[ "${unexpected_count}" -eq 0 ]]; then
  _pass "no remotes other than origin"
fi

echo
if [[ "${fail}" -eq 0 ]]; then
  echo "ALL CHECKS PASSED"
  exit 0
fi
echo "SOME CHECKS FAILED" >&2
exit 1
