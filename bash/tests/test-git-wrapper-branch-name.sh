#!/usr/bin/env bash
# shellcheck shell=bash
# Tests git-wrapper.sh's 'type: subject' -> type/subject branch names.
set -euo pipefail

unset CDPATH

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export BASH_CONFIG_DIR="${REPO_ROOT}/bash"

WORKDIR="/tmp/git-wrapper-branch-name-test-$$"
mkdir -p "${WORKDIR}"
trap 'rm -rf "${WORKDIR}"' EXIT

# Clear inherited git repository-selection state before touching any fixture
# (smartwatermelon/dotfiles#239).
_tests_dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-env-isolation.sh
source "${_tests_dir}/lib/git-env-isolation.sh"
isolate_git_env "${WORKDIR}"

unset _GIT_WRAPPER_ACTIVE

# Disable init.templateDir; see test-git-wrapper-init-hook.sh for why.
_git_version="$(command git --version | awk '{print $3}')"
_git_major="${_git_version%%.*}"
_git_rest="${_git_version#*.}"
_git_minor="${_git_rest%%.*}"
if ((_git_major < 2 || (_git_major == 2 && _git_minor < 31))); then
  echo "FAIL: git ${_git_version} is too old for this test (needs 2.31+)." >&2
  exit 1
fi

export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="init.templateDir"
export GIT_CONFIG_VALUE_0=""

#shellcheck source=/dev/null
source "${BASH_CONFIG_DIR}/git-wrapper.sh"

fail=0
case_num=0

# Run `git <args>` in a fresh repo; expected is a branch or "FAIL".
assert_branch() {
  local desc="$1" expected="$2"
  shift 2
  ((case_num += 1))
  local repo="${WORKDIR}/repo${case_num}"
  command git init -q -b main "${repo}"
  local rc=0
  (cd "${repo}" && git "$@") >/dev/null 2>&1 || rc=$?
  local actual
  actual="$(command git -C "${repo}" symbolic-ref --short HEAD)"
  if [[ "${expected}" == "FAIL" ]]; then
    if [[ "${rc}" -ne 0 && "${actual}" == "main" ]]; then
      echo "PASS: ${desc}"
    else
      echo "FAIL: ${desc} — expected git to reject; rc=${rc} branch='${actual}'"
      fail=1
    fi
  elif [[ "${rc}" -eq 0 && "${actual}" == "${expected}" ]]; then
    echo "PASS: ${desc}"
  else
    echo "FAIL: ${desc} — expected '${expected}'; rc=${rc} branch='${actual}'"
    fail=1
  fi
}

assert_branch "checkout -b translates 'type: subject'" "feat/do-the-new-thing" \
  checkout -b 'feat: do the new thing'
assert_branch "switch -c translates 'type: subject'" "fix/correct-the-widget" \
  switch -c 'fix: correct the widget'
assert_branch "a plain branch name passes through" "plain-branch" \
  checkout -b plain-branch
assert_branch "extra flags disable translation" "FAIL" \
  checkout -q -b 'feat: with flag'
assert_branch "a scope joins the subject" "feat/api-add-endpoint" \
  checkout -b 'feat(api): add endpoint'
assert_branch "a breaking '!' is dropped" "feat/drop-v1" \
  checkout -b 'feat!: drop v1'
assert_branch "scope and '!' together" "feat/api-drop-v1" \
  switch -c 'feat(api)!: drop v1'
assert_branch "an empty scope is dropped" "feat/x" \
  checkout -b 'feat(): x'
assert_branch "whitespace is trimmed and squeezed" "docs/two-spaces" \
  checkout -b 'docs:   two  spaces '
assert_branch "everything is lowercased" "feat/mixed-case" \
  checkout -b 'Feat(): Mixed CASE'
assert_branch "a second ': ' is cleaned" "fix/handle-a-b" \
  checkout -b 'fix: handle a: b'
assert_branch "characters git rejects are dropped" "fix/what-why" \
  checkout -b "fix: what? why* ~^[\\"
assert_branch "'/' and '..' cannot nest or break the ref" "fix/a-b.c" \
  checkout -b 'fix: a/b..c.'
assert_branch "a trailing '.lock' is made valid" "fix/update-foo-lock" \
  checkout -b 'fix: update foo.lock'
assert_branch "an apostrophe is dropped" "fix/users-path" \
  checkout -b "fix: user's path"
assert_branch "a subject that cleans to nothing is left to git" "FAIL" \
  checkout -b 'feat: ?!*'
assert_branch "no space after the colon is not a header" "FAIL" \
  checkout -b 'feat:x y'

# Same translation under macOS /bin/bash 3.2 (no ${s,,}; older =~ and globs)
bash32_script="${WORKDIR}/bash32.sh"
cat >"${bash32_script}" <<'EOF'
set -u
source "$1"
command git init -q -b main "$2"
cd "$2" || exit 1
git checkout -b 'Feat(API)!: Drop  v1?' >/dev/null 2>&1
command git symbolic-ref --short HEAD
EOF
if [[ -x /bin/bash ]]; then
  out="$(/bin/bash "${bash32_script}" "${BASH_CONFIG_DIR}/git-wrapper.sh" \
    "${WORKDIR}/repo-bash32" 2>&1)" || true
  if [[ "${out}" == "feat/api-drop-v1" ]]; then
    echo "PASS: translation under /bin/bash"
  else
    echo "FAIL: translation under /bin/bash — got '${out}'"
    fail=1
  fi
fi

# Zero-argument git under set -u: git prints usage and exits 1. The wrapper
# must return that, not abort the shell on an unbound expansion.
noargs_script="${WORKDIR}/noargs.sh"
cat >"${noargs_script}" <<'EOF'
set -u
source "$1"
git >/dev/null 2>&1
echo "rc=$?"
EOF
for sh in "${BASH}" /bin/bash; do
  [[ -x "${sh}" ]] || continue
  rc=0
  out="$("${sh}" "${noargs_script}" "${BASH_CONFIG_DIR}/git-wrapper.sh" 2>&1)" || rc=$?
  if [[ "${rc}" -eq 0 && "${out}" == "rc=1" ]]; then
    echo "PASS: zero-argument git under set -u (${sh})"
  else
    echo "FAIL: zero-argument git under set -u (${sh}) — shell rc=${rc} out='${out}'"
    fail=1
  fi
done

if [[ "${fail}" -eq 1 ]]; then
  echo "FAILED"
  exit 1
fi
echo "All git-wrapper branch-name tests passed"
