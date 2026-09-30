#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification for git/hooks/lint-length.sh, the `length-caps`
# pre-commit hook. Run directly: bash bash/tests/test-lint-length.sh
#
# The hook reads the STAGED diff and fails when a code comment or docstring it
# adds is over personify's cap. These cases run it in throwaway repos under a
# sandboxed HOME, so neither the live ~/.claude, ~/.config nor the global
# core.hooksPath is consulted. The checker is personify's real length_check.py:
# a stub would encode what this test's author believed --diff does.
#
# PERSONIFY_DIR names a personify checkout or install holding
# scripts/length_check.py; without it the installed one is asked for, before
# HOME is sandboxed. With neither, the cases are skipped rather than faked.
set -euo pipefail

unset CDPATH

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_tests_dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-env-isolation.sh
source "${_tests_dir}/lib/git-env-isolation.sh"
isolate_git_env

HOOK="${REPO_ROOT}/git/hooks/lint-length.sh"

REAL_PERSONIFY="${PERSONIFY_DIR:-}"
if [[ -z "${REAL_PERSONIFY}" && -x "${HOME}/.claude/scripts/gate-review.sh" ]]; then
  REAL_PERSONIFY="$("${HOME}/.claude/scripts/gate-review.sh" personify-path 2>/dev/null)" || REAL_PERSONIFY=""
fi
if [[ -z "${REAL_PERSONIFY}" || ! -f "${REAL_PERSONIFY}/scripts/length_check.py" ]]; then
  echo "SKIP: no personify length_check.py (set PERSONIFY_DIR to a checkout)"
  exit 0
fi

SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT
export HOME="${SANDBOX}/home"
export GIT_CONFIG_NOSYSTEM=1
unset CLAUDE_CONFIG_DIR
mkdir -p "${HOME}/.claude/scripts" "${SANDBOX}/personify/scripts"
cp "${REAL_PERSONIFY}/scripts/length_check.py" "${SANDBOX}/personify/scripts/length_check.py"

# A gate-review.sh that answers personify-path from a file, so one case can make
# the lookup fail the way the real one does when personify is absent.
cat >"${HOME}/.claude/scripts/gate-review.sh" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "personify-path" && -f "${SANDBOX}/no-personify" ]]; then
  echo "personify is not installed (stub)" >&2
  exit 1
fi
[[ "\$1" == "personify-path" ]] && { echo "${SANDBOX}/personify"; exit 0; }
exit 2
STUB
chmod +x "${HOME}/.claude/scripts/gate-review.sh"

fail=0
OUT=""
RC=0

C100="$(printf 'c%.0s' $(seq 1 98))"
C150="$(printf 'c%.0s' $(seq 1 148))"
C300="$(printf 'c%.0s' $(seq 1 300))"

new_repo() {
  local r="${SANDBOX}/repo-$1"
  git init -q "${r}"
  git -C "${r}" config user.email t@example.com
  git -C "${r}" config user.name t
  git -C "${r}" config commit.gpgsign false
  printf 'x = 1\n' >"${r}/base.py"
  git -C "${r}" add base.py
  git -C "${r}" commit -q -m base
  printf '%s\n' "${r}"
}

# run_hook <repo> [dir under repo]: sets OUT (stdout and stderr) and RC.
run_hook() {
  local r="$1" d="${2:-}"
  RC=0
  OUT="$(cd "${r}/${d}" && bash "${HOOK}" 2>&1)" || RC=$?
}

expect() {
  local label="$1" want_rc="$2" want_text="${3:-}"
  if [[ "${RC}" != "${want_rc}" ]]; then
    echo "FAIL: ${label} — expected rc=${want_rc}, got rc=${RC}; output: ${OUT}"
    fail=1
  elif [[ -n "${want_text}" && "${OUT}" != *"${want_text}"* ]]; then
    echo "FAIL: ${label} — output lacks '${want_text}': ${OUT}"
    fail=1
  else
    echo "PASS: ${label}"
  fi
}

stage() { # <repo> <file> <content>
  printf '%s' "$3" >"$1/$2"
  git -C "$1" add "$2"
}

# --- the caps ---------------------------------------------------------------
R="$(new_repo over)"
stage "${R}" a.py "# ${C150}"$'\nx = 2\n'
run_hook "${R}"
expect "staged 150-char comment fails and names path:line" 1 "a.py:1:"

R="$(new_repo under)"
stage "${R}" a.py "# ${C100}"$'\nx = 2\n'
run_hook "${R}"
expect "staged 100-char comment passes" 0

R="$(new_repo docstring)"
stage "${R}" a.py "def f():"$'\n'"    \"\"\"${C300}\"\"\""$'\n'"    return 1"$'\n'
run_hook "${R}"
expect "staged 300-char docstring (cap 280) fails" 1 "a.py:"

R="$(new_repo nothing)"
run_hook "${R}"
expect "nothing staged passes" 0

# An over-cap comment already in the file is not this commit's.
R="$(new_repo unchanged)"
stage "${R}" old.py "# ${C150}"$'\nx = 1\n'
git -C "${R}" commit -q -m old
printf 'x = 2\n' >>"${R}/old.py"
git -C "${R}" add old.py
run_hook "${R}"
expect "unchanged over-cap comment in an edited file passes" 0

R="$(new_repo rename)"
stage "${R}" old.py "# ${C150}"$'\nx = 1\n'
git -C "${R}" commit -q -m old
git -C "${R}" mv old.py new.py
run_hook "${R}"
expect "renamed file's unchanged comment passes" 0

R="$(new_repo subdir)"
mkdir "${R}/sub"
stage "${R}" sub/a.py "# ${C150}"$'\nx = 2\n'
run_hook "${R}" sub
expect "run from a subdirectory still fails" 1 "sub/a.py:1:"

# --- personify missing: fail closed, message shown ---------------------------
R="$(new_repo nopersonify)"
stage "${R}" a.py "# ${C100}"$'\nx = 2\n'
: >"${SANDBOX}/no-personify"
run_hook "${R}"
expect "personify not found fails" 1 "personify is not installed"
if [[ "${OUT}" == *"SKIP=length-caps"* ]]; then
  echo "PASS: failure message names the human bypass"
else
  echo "FAIL: failure message names the human bypass — got: ${OUT}"
  fail=1
fi
R2="$(new_repo nopersonify-empty)"
run_hook "${R2}"
expect "nothing staged passes even without personify" 0
rm -f "${SANDBOX}/no-personify"

# --- merge, cherry-pick, revert in progress: not checked ---------------------
for head in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
  R="$(new_repo "${head}")"
  stage "${R}" a.py "# ${C150}"$'\nx = 2\n'
  run_hook "${R}"
  expect "${head} absent: still checked (control)" 1
  git -C "${R}" rev-parse HEAD >"$(git -C "${R}" rev-parse --absolute-git-dir)/${head}"
  run_hook "${R}"
  expect "${head} present: passes unchecked" 0
done

# --- user diff config cannot change the result -------------------------------
R="$(new_repo noprefix)"
git -C "${R}" config diff.noprefix true
git -C "${R}" config diff.mnemonicPrefix true
git -C "${R}" config diff.external "echo external-diff-output"
stage "${R}" a.py "# ${C150}"$'\nx = 2\n'
run_hook "${R}"
expect "diff.noprefix, mnemonicPrefix and external set: still fails" 1 "a.py:1:"
R="$(new_repo noprefix-ok)"
git -C "${R}" config diff.noprefix true
git -C "${R}" config diff.external "echo external-diff-output"
stage "${R}" a.py "# ${C100}"$'\nx = 2\n'
run_hook "${R}"
expect "diff.noprefix and external set: a short comment still passes" 0
R="$(new_repo norenames)"
git -C "${R}" config diff.renames false
stage "${R}" old.py "# ${C150}"$'\nx = 1\n'
git -C "${R}" commit -q -m old
git -C "${R}" mv old.py new.py
run_hook "${R}"
expect "diff.renames=false: a renamed file's comment still passes" 0

# --- per-file bypass: length-caps=off in .gitattributes ----------------------
R="$(new_repo bypass)"
printf 'vendor/** length-caps=off\nlicense.py length-caps=off\n' >"${R}/.gitattributes"
git -C "${R}" add .gitattributes
mkdir "${R}/vendor"
stage "${R}" vendor/lib.py "# ${C150}"$'\nx = 2\n'
stage "${R}" license.py "# ${C150}"$'\n'
run_hook "${R}"
expect "files marked length-caps=off pass" 0
stage "${R}" other.py "# ${C150}"$'\nx = 2\n'
run_hook "${R}"
expect "an unmarked file beside them still fails" 1 "other.py:1:"
if [[ "${OUT}" != *"vendor/lib.py:"* && "${OUT}" != *"license.py:"* ]]; then
  echo "PASS: marked files have no findings in the failure"
else
  echo "FAIL: marked files have no findings in the failure — got: ${OUT}"
  fail=1
fi
R="$(new_repo bypass-on)"
printf '*.py length-caps=on\n' >"${R}/.gitattributes"
git -C "${R}" add .gitattributes
stage "${R}" a.py "# ${C150}"$'\nx = 2\n'
run_hook "${R}"
expect "length-caps=on does not exempt" 1 "a.py:1:"
R="$(new_repo bypass-sub)"
printf 'vendor/** length-caps=off\n' >"${R}/.gitattributes"
git -C "${R}" add .gitattributes
mkdir "${R}/vendor"
stage "${R}" vendor/lib.py "# ${C150}"$'\nx = 2\n'
run_hook "${R}" vendor
expect "bypass applies when run from a subdirectory" 0
R="$(new_repo bypass-odd-name)"
printf 'odd*.py length-caps=off\n' >"${R}/.gitattributes"
git -C "${R}" add .gitattributes
stage "${R}" "odd name.py" "# ${C150}"$'\nx = 2\n'
run_hook "${R}"
expect "bypass handles a path with a space" 0

# --- bypass hardening: only tracked .gitattributes counts ----------------------
R="$(new_repo info-attr)"
printf 'other.py length-caps=off\n' >"${R}/.git/info/attributes"
stage "${R}" a.py "# ${C100}"$'\nx = 2\n'
run_hook "${R}"
expect "info/attributes setting length-caps fails the hook" 1 "tracked .gitattributes"
R="$(new_repo info-attr-other)"
printf '*.md text\n' >"${R}/.git/info/attributes"
stage "${R}" a.py "# ${C100}"$'\nx = 2\n'
run_hook "${R}"
expect "info/attributes without length-caps is fine" 0

R="$(new_repo attrfile)"
printf '* length-caps=off\n' >"${SANDBOX}/global-attrs"
git -C "${R}" config core.attributesFile "${SANDBOX}/global-attrs"
stage "${R}" a.py "# ${C150}"$'\nx = 2\n'
run_hook "${R}"
expect "core.attributesFile exemption is ignored: file still checked" 1 "a.py:1:"

for pat in '*' '**' '**/*'; do
  R="$(new_repo "star-${#pat}-${pat//[^a-z]/}")"
  printf '%s length-caps=off\n' "${pat}" >"${R}/.gitattributes"
  git -C "${R}" add .gitattributes
  stage "${R}" a.py "# ${C100}"$'\nx = 2\n'
  run_hook "${R}"
  expect "tracked '${pat} length-caps=off' is refused" 1 "exempts every file"
done
R="$(new_repo star-unstaged-wt)"
printf '* length-caps=off\n' >"${R}/.gitattributes"
stage "${R}" a.py "# ${C150}"$'\nx = 2\n'
run_hook "${R}"
expect "untracked working-tree .gitattributes is not honored" 1 "a.py:1:"

R="$(new_repo skipped-line)"
printf 'vendor/** length-caps=off\n' >"${R}/.gitattributes"
git -C "${R}" add .gitattributes
mkdir "${R}/vendor"
stage "${R}" vendor/lib.py "# ${C150}"$'\nx = 2\n'
run_hook "${R}"
expect "per-path exemption passes and prints the skipped line" 0 "length-caps: skipped vendor/lib.py (length-caps=off in .gitattributes)"

# --- failure messages: human bypass only ---------------------------------------
R="$(new_repo msg)"
stage "${R}" a.py "# ${C150}"$'\nx = 2\n'
run_hook "${R}"
expect "over-cap message names the human bypass" 1 "SKIP=length-caps"
if [[ "${OUT}" == *".gitattributes"* ]]; then
  echo "FAIL: over-cap message must not mention .gitattributes — got: ${OUT}"
  fail=1
else
  echo "PASS: over-cap message does not mention .gitattributes"
fi

# gate-review.sh absent
R="$(new_repo nogate)"
stage "${R}" a.py "# ${C100}"$'\nx = 2\n'
mv "${HOME}/.claude/scripts/gate-review.sh" "${HOME}/.claude/scripts/gate-review.sh.hidden"
run_hook "${R}"
mv "${HOME}/.claude/scripts/gate-review.sh.hidden" "${HOME}/.claude/scripts/gate-review.sh"
expect "gate-review.sh absent fails closed and names the bypass" 1 "SKIP=length-caps"

# checker exit other than 0/1 is labelled
R="$(new_repo checker-err)"
stage "${R}" a.py "# ${C100}"$'\nx = 2\n'
cp "${SANDBOX}/personify/scripts/length_check.py" "${SANDBOX}/length_check.py.real"
printf 'import sys\nsys.exit(5)\n' >"${SANDBOX}/personify/scripts/length_check.py"
run_hook "${R}"
cp "${SANDBOX}/length_check.py.real" "${SANDBOX}/personify/scripts/length_check.py"
expect "silent checker exit 5 is labelled" 5 "checker error (exit 5), not a verdict on the text"
if [[ "${OUT}" == *"SKIP=length-caps"* ]]; then
  echo "PASS: checker error names the human bypass"
else
  echo "FAIL: checker error names the human bypass — got: ${OUT}"
  fail=1
fi

if [[ "${fail}" == "0" ]]; then
  echo "All lint-length checks passed."
else
  echo "lint-length checks FAILED."
fi
exit "${fail}"
