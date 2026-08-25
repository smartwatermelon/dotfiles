#!/usr/bin/env bash
# shellcheck shell=bash
# Standalone verification that git/template/hooks/post-checkout records a
# tracking policy for the .claude/ scaffold it creates, only in repos that are
# genuinely fresh, and never at the cost of failing the git command that
# invoked it.
# Run directly: bash bash/tests/test-post-checkout-gitignore.sh
#
# Regression coverage for smartwatermelon/dotfiles#220: the hook used to copy
# .claude/ into every fresh clone/init while saying nothing about whether the
# result should be tracked, producing an arbitrary tracked/ignored split across
# repos. It now records `.claude/` as ignored, subject to four guards:
#
#   0. fresh clone/init only  -- post-checkout also fires with $3 == 1 on
#      `git checkout -b` and on `git worktree add`. prev_head ($1) is the null SHA
#      on clone/init but a real commit on a branch switch; a linked worktree
#      also reports the null SHA, so it is excluded by comparing --git-dir
#      against --git-common-dir.
#   1. already tracked        -- skip (gitignore does not affect tracked files)
#   2. already ignored        -- skip, checking .gitignore AND
#      .git/info/exclude via `git check-ignore`
#   3. tracked .gitignore     -- write to .git/info/exclude instead, so a
#      fresh clone is not left holding a modified tracked file
#
# Because this hook is global via core.hooksPath and fires on every clone,
# init and branch switch on this machine, the cases below drive it through
# REAL git commands (clone, checkout -b, worktree add) wherever the behavior
# under test is a property of how git invokes the hook, not just of the
# hook's internal logic. Everything runs in a disposable temp tree under a
# trap and never touches a real repository.
set -euo pipefail

unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK_SRC="${REPO_ROOT}/git/template/hooks/post-checkout"

WORKDIR="/tmp/post-checkout-gitignore-test-$$"
mkdir -p "${WORKDIR}"
trap 'rm -rf "${WORKDIR}"' EXIT

# Inherited git environment variables would silently redirect every git call
# below at the ambient repo instead of the scratch fixtures -- GIT_INDEX_FILE
# in particular makes `git ls-files` report the caller's staged paths, which
# fires the already-tracked guard in repos that track nothing.
#
# This test's hand-rolled unset list predates the shared helper and was the
# precedent for it (smartwatermelon/dotfiles#239). It now delegates, so the list
# is maintained in one place and derived from `git rev-parse --local-env-vars`
# rather than hardcoded here.
_tests_dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-env-isolation.sh
source "${_tests_dir}/lib/git-env-isolation.sh"
isolate_git_env "${WORKDIR}"

# GIT_CONFIG_GLOBAL / GIT_CONFIG_SYSTEM are NOT repository-selection variables,
# so the helper deliberately leaves them alone. This test wants them gone as
# well, to keep the developer's real ~/.gitconfig out of the fixtures.
unset GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM

# Minimal stand-in for git/template/.claude-template, so the test never
# depends on (or writes through symlinks into) the deployed template.
TEMPLATE_DIR="${WORKDIR}/template"
mkdir -p "${TEMPLATE_DIR}/.claude-template/hooks/extensions"
echo "# fixture" >"${TEMPLATE_DIR}/.claude-template/README.md"

# A core.hooksPath dir holding the hook under test, so real git commands
# resolve it the way they do on this machine.
HOOKS_DIR="${WORKDIR}/hookspath"
mkdir -p "${HOOKS_DIR}"
cp "${HOOK_SRC}" "${HOOKS_DIR}/post-checkout"
chmod +x "${HOOKS_DIR}/post-checkout"

# Applied to every real git command that should resolve the hook under test.
GIT_OPTS=(-c "core.hooksPath=${HOOKS_DIR}" -c "init.templateDir=${TEMPLATE_DIR}")

fail=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "PASS: ${desc}"
  else
    echo "FAIL: ${desc} -- expected '${expected}', got '${actual}'"
    fail=1
  fi
}

# Build an origin repo with one commit. $2, if given, is committed as the
# repo's .gitignore (making it a *tracked* .gitignore).
make_origin() {
  local dir="${WORKDIR}/$1" ignore_line="${2:-}"
  git -c init.templateDir="" init -q -b main "${dir}"
  git -C "${dir}" config user.email t@t.com
  git -C "${dir}" config user.name t
  if [[ -n "${ignore_line}" ]]; then
    printf '%s\n' "${ignore_line}" >"${dir}/.gitignore"
  fi
  echo hi >"${dir}/a.txt"
  git -C "${dir}" add -A
  git -C "${dir}" -c core.hooksPath="" commit -q -m "chore: fixture"
  printf '%s' "${dir}"
}

# Count `.claude/` entries in a file (0 when the file is absent).
count_entries() {
  local file="$1" n=0
  [[ -f "${file}" ]] || {
    printf '0'
    return 0
  }
  n=$(grep -c '^\.claude/$' "${file}") || n=0
  printf '%s' "${n}"
}

exists() {
  local flag="$1" path="$2"
  if [[ "${flag}" == "-d" && -d "${path}" ]]; then
    printf 'yes'
  elif [[ "${flag}" == "-f" && -f "${path}" ]]; then
    printf 'yes'
  else
    printf 'no'
  fi
}

# Invoke the hook directly with git's initial-checkout arguments. Captures and
# RETURNS the exit code: a post-checkout that exits non-zero makes `git clone`
# itself fail after the files have landed, so every case asserts on this.
run_hook() {
  local dir="$1" prev="${2:-0000000000000000000000000000000000000000}"
  local rc=0
  (
    cd "${dir}"
    GIT_CONFIG_COUNT=1 \
      GIT_CONFIG_KEY_0="core.hooksPath" \
      GIT_CONFIG_VALUE_0="" \
      "${HOOKS_DIR}/post-checkout" \
      "${prev}" \
      1111111111111111111111111111111111111111 \
      1 >/dev/null 2>&1
  ) || rc=$?
  printf '%s' "${rc}"
}

actual=""
rc=""

# --- Case A: real `git clone`, origin without a tracked .gitignore ---------
# The baseline case the issue is about: a fresh clone records the policy.
origin_a="$(make_origin origin-a)"
clone_a="${WORKDIR}/clone-a"
rc=0
git "${GIT_OPTS[@]}" clone -q "${origin_a}" "${clone_a}" >/dev/null 2>&1 || rc=$?
assert_eq "real clone: git clone itself succeeds" "0" "${rc}"
actual="$(exists -d "${clone_a}/.claude")"
assert_eq "real clone: .claude/ scaffolded" "yes" "${actual}"
actual="$(count_entries "${clone_a}/.gitignore")"
assert_eq "real clone: .gitignore gains exactly one .claude/ entry" "1" "${actual}"

# --- Case B: real `git clone`, origin WITH a tracked .gitignore -----------
# Rewriting a committed .gitignore would leave every clone holding a modified
# tracked file. The entry goes to .git/info/exclude instead and the clone
# stays clean, while .claude/ still ends up ignored.
origin_b="$(make_origin origin-b "node_modules/")"
clone_b="${WORKDIR}/clone-b"
rc=0
git "${GIT_OPTS[@]}" clone -q "${origin_b}" "${clone_b}" >/dev/null 2>&1 || rc=$?
assert_eq "tracked .gitignore: git clone itself succeeds" "0" "${rc}"
actual="$(count_entries "${clone_b}/.gitignore")"
assert_eq "tracked .gitignore: committed file left untouched" "0" "${actual}"
actual="$(count_entries "${clone_b}/.git/info/exclude")"
assert_eq "tracked .gitignore: entry lands in .git/info/exclude" "1" "${actual}"
actual="$(git -C "${clone_b}" status --porcelain)"
assert_eq "tracked .gitignore: clone left with a clean tree" "" "${actual}"
rc=0
git -C "${clone_b}" check-ignore -q ".claude/" || rc=$?
assert_eq "tracked .gitignore: .claude/ is genuinely ignored" "0" "${rc}"

# --- Case C: `git checkout -b` in an established repo ---------------------
# Guard 0a. prev_head is a real commit here, so the hook must not write --
# this repo already had its chance to decide.
origin_c="$(make_origin origin-c "node_modules/")"
rc=0
git -C "${origin_c}" "${GIT_OPTS[@]}" checkout -q -b feature >/dev/null 2>&1 || rc=$?
assert_eq "branch switch: git checkout itself succeeds" "0" "${rc}"
actual="$(count_entries "${origin_c}/.gitignore")"
assert_eq "branch switch: established repo's .gitignore untouched" "0" "${actual}"
actual="$(git -C "${origin_c}" status --porcelain -- .gitignore)"
assert_eq "branch switch: .gitignore not left modified" "" "${actual}"
actual="$(count_entries "${origin_c}/.git/info/exclude")"
assert_eq "branch switch: nothing written to .git/info/exclude either" "0" "${actual}"

# --- Case D: a new linked worktree of an established repo -----------------
# Guard 0b. A linked worktree reports the null SHA just like a clone, and its
# .claude/ is absent because the parent repo ignores it -- so without the
# git-dir/common-dir comparison the hook would rewrite a real repo's tracked,
# committed .gitignore.
worktree_parent="${clone_b}"
mkdir -p "${worktree_parent}/.claude/worktrees"
rc=0
git -C "${worktree_parent}" "${GIT_OPTS[@]}" \
  worktree add -q ".claude/worktrees/wt1" -b wt1 >/dev/null 2>&1 || rc=$?
assert_eq "linked worktree: the git command itself succeeds" "0" "${rc}"
wt1="${worktree_parent}/.claude/worktrees/wt1"
actual="$(count_entries "${wt1}/.gitignore")"
assert_eq "linked worktree: parent repo's tracked .gitignore untouched" "0" "${actual}"
actual="$(git -C "${wt1}" status --porcelain -- .gitignore)"
assert_eq "linked worktree: .gitignore not left modified" "" "${actual}"
# The worktree's excludes live in the parent repo's common git dir; Case B
# already put exactly one entry there, so a write here would make it two.
actual="$(count_entries "${worktree_parent}/.git/info/exclude")"
assert_eq "linked worktree: parent's .git/info/exclude not appended to" "1" "${actual}"

# --- Case D2: worktree of an established repo with NO .claude/ policy ------
# Guard 0b in isolation. In Case D the parent (a clone) already carried an
# info/exclude entry, so guard 2 would have caught the worktree anyway. The
# case guard 0b uniquely covers is an established repo that predates this
# hook and has no .claude/ policy at all -- the majority of the 27 surveyed
# repos. Without guard 0b, adding a worktree there silently writes an ignore
# entry into a repo that never asked for one.
origin_d2="$(make_origin origin-d2 "node_modules/")"
mkdir -p "${origin_d2}/.claude/worktrees"
rc=0
git -C "${origin_d2}" "${GIT_OPTS[@]}" \
  worktree add -q ".claude/worktrees/wt2" -b wt2 >/dev/null 2>&1 || rc=$?
assert_eq "worktree of established repo: the git command succeeds" "0" "${rc}"
actual="$(count_entries "${origin_d2}/.git/info/exclude")"
assert_eq "worktree of established repo: nothing written to info/exclude" "0" "${actual}"
actual="$(count_entries "${origin_d2}/.gitignore")"
assert_eq "worktree of established repo: tracked .gitignore untouched" "0" "${actual}"

# --- Case E: already-tracked .claude/ is left alone ------------------------
# Guard 1. gitignore has no effect on tracked files, so writing the line here
# would make the repo claim a policy it isn't following.
repo_e="${WORKDIR}/repo-e"
git -c init.templateDir="" init -q -b main "${repo_e}"
git -C "${repo_e}" config init.templateDir "${TEMPLATE_DIR}"
git -C "${repo_e}" config user.email t@t.com
git -C "${repo_e}" config user.name t
mkdir -p "${repo_e}/.claude"
echo tracked >"${repo_e}/.claude/settings.json"
git -C "${repo_e}" add .claude/settings.json
# The hook no-ops when .claude/ exists, so drop the working copy while leaving
# the index entry: the guard must key on the index, not on the directory.
rm -rf "${repo_e:?}/.claude"
rc="$(run_hook "${repo_e}")"
assert_eq "already tracked: hook exits 0" "0" "${rc}"
actual="$(count_entries "${repo_e}/.gitignore")"
assert_eq "already tracked: no .claude/ entry written" "0" "${actual}"
actual="$(exists -f "${repo_e}/.gitignore")"
assert_eq "already tracked: no .gitignore created" "no" "${actual}"

# --- Case F: already ignored via .gitignore --------------------------------
# Guard 2, .gitignore arm.
repo_f="${WORKDIR}/repo-f"
git -c init.templateDir="" init -q -b main "${repo_f}"
git -C "${repo_f}" config init.templateDir "${TEMPLATE_DIR}"
printf '.claude/\n' >"${repo_f}/.gitignore"
rc="$(run_hook "${repo_f}")"
assert_eq "already ignored via .gitignore: hook exits 0" "0" "${rc}"
actual="$(count_entries "${repo_f}/.gitignore")"
assert_eq "already ignored via .gitignore: entry not duplicated" "1" "${actual}"

# --- Case G: already ignored via .git/info/exclude -------------------------
# Guard 2, info/exclude arm. The live case (smartwatermelon/homebrew-tap): a
# repo that deliberately kept the decision local. Appending to .gitignore here
# would promote a private hold to a shared committed policy, and grepping
# .gitignore alone would miss it and do exactly that.
repo_g="${WORKDIR}/repo-g"
git -c init.templateDir="" init -q -b main "${repo_g}"
git -C "${repo_g}" config init.templateDir "${TEMPLATE_DIR}"
mkdir -p "${repo_g}/.git/info"
printf '.claude/\n' >>"${repo_g}/.git/info/exclude"
rc="$(run_hook "${repo_g}")"
assert_eq "already ignored via info/exclude: hook exits 0" "0" "${rc}"
actual="$(exists -f "${repo_g}/.gitignore")"
assert_eq "already ignored via info/exclude: no .gitignore created" "no" "${actual}"

# --- Case H: running twice does not duplicate the entry --------------------
repo_h="${WORKDIR}/repo-h"
git -c init.templateDir="" init -q -b main "${repo_h}"
git -C "${repo_h}" config init.templateDir "${TEMPLATE_DIR}"
run_hook "${repo_h}" >/dev/null
rm -rf "${repo_h:?}/.claude"
rc="$(run_hook "${repo_h}")"
assert_eq "second run: hook exits 0" "0" "${rc}"
actual="$(count_entries "${repo_h}/.gitignore")"
assert_eq "second run: still exactly one .claude/ entry" "1" "${actual}"

# --- Case I: existing .gitignore with no trailing newline ------------------
# A blind append would splice .claude/ onto the end of the last entry,
# silently changing an unrelated pattern.
repo_i="${WORKDIR}/repo-i"
git -c init.templateDir="" init -q -b main "${repo_i}"
git -C "${repo_i}" config init.templateDir "${TEMPLATE_DIR}"
printf 'node_modules/' >"${repo_i}/.gitignore"
rc="$(run_hook "${repo_i}")"
assert_eq "no trailing newline: hook exits 0" "0" "${rc}"
actual="$(count_entries "${repo_i}/.gitignore")"
assert_eq "no trailing newline: .claude/ lands on its own line" "1" "${actual}"
actual=0
actual=$(grep -c '^node_modules/$' "${repo_i}/.gitignore") || actual=0
assert_eq "no trailing newline: existing entry not corrupted" "1" "${actual}"

# --- Case J: unwritable .gitignore does not fail the hook ------------------
# A non-zero post-checkout makes `git clone` exit 1 *after* the files have
# landed, so an un-writable target must be skipped, not fatal.
repo_j="${WORKDIR}/repo-j"
git -c init.templateDir="" init -q -b main "${repo_j}"
git -C "${repo_j}" config init.templateDir "${TEMPLATE_DIR}"
printf 'node_modules/\n' >"${repo_j}/.gitignore"
chmod 0444 "${repo_j}/.gitignore"
rc="$(run_hook "${repo_j}")"
chmod 0644 "${repo_j}/.gitignore"
assert_eq "read-only .gitignore: hook still exits 0" "0" "${rc}"
actual="$(count_entries "${repo_j}/.gitignore")"
assert_eq "read-only .gitignore: left untouched" "0" "${actual}"

# --- Case K: dangling .gitignore symlink does not fail the hook ------------
# -e follows symlinks, so a dangling link reports neither -e nor -w; without
# an explicit -L check the append is attempted and aborts under `set -e`.
repo_k="${WORKDIR}/repo-k"
git -c init.templateDir="" init -q -b main "${repo_k}"
git -C "${repo_k}" config init.templateDir "${TEMPLATE_DIR}"
ln -s "${WORKDIR}/definitely-not-here" "${repo_k}/.gitignore"
rc="$(run_hook "${repo_k}")"
assert_eq "dangling .gitignore symlink: hook still exits 0" "0" "${rc}"
actual="$(exists -f "${repo_k}/.gitignore")"
assert_eq "dangling .gitignore symlink: not materialized" "no" "${actual}"

# --- Case L: an unwritable target must not fail the git command ------------
# Exercises the `|| return 0` on the writes themselves: with a read-only
# .git/info/exclude and a tracked .gitignore, there is nowhere to write, and
# the hook must still exit 0 rather than abort under `set -e` and take the
# whole `git clone` down with it.
origin_l="$(make_origin origin-l "node_modules/")"
repo_l="${WORKDIR}/repo-l"
git -c init.templateDir="" -c core.hooksPath="" clone -q "${origin_l}" "${repo_l}" >/dev/null 2>&1
git -C "${repo_l}" config init.templateDir "${TEMPLATE_DIR}"
rm -rf "${repo_l:?}/.claude"
mkdir -p "${repo_l}/.git/info"
: >"${repo_l}/.git/info/exclude"
chmod 0444 "${repo_l}/.git/info/exclude"
rc="$(run_hook "${repo_l}")"
chmod 0644 "${repo_l}/.git/info/exclude"
assert_eq "unwritable info/exclude: hook still exits 0" "0" "${rc}"
actual="$(count_entries "${repo_l}/.git/info/exclude")"
assert_eq "unwritable info/exclude: nothing written" "0" "${actual}"
actual="$(count_entries "${repo_l}/.gitignore")"
assert_eq "unwritable info/exclude: tracked .gitignore untouched" "0" "${actual}"

if [[ "${fail}" -eq 1 ]]; then
  echo "FAILED"
  exit 1
fi
echo "All post-checkout gitignore tests passed"
