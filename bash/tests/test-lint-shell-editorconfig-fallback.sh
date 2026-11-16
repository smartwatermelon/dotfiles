#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification that git/hooks/lint-shell.sh does not impose a
# formatting style on a repo that never chose one.
# Run directly: bash bash/tests/test-lint-shell-editorconfig-fallback.sh
#
# shfmt only consults .editorconfig when given no formatting flags. The hook
# used to fall back to `-i 2 -ci -bn` (Google shell style) whenever a repo had
# no .editorconfig. That style puts binary operators at the START of a
# continuation line; plain `shfmt -i 2 -ci` — what a repo's CI most likely runs
# — puts them at the END. The two reject each other, so the hook rewrote files
# into the exact form CI failed on, reported "Auto-fixed", and pointed the
# blame at the committer (smartwatermelon/dotfiles#290).
#
# The fix: no .editorconfig means the repo has stated no preference, so the
# hook reports formatting drift as an advisory and writes nothing. A repo that
# HAS an .editorconfig still gets auto-fixed, per its own stated style.
set -uo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${REPO_ROOT}/git/hooks/lint-shell.sh"

fail=0

_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

if ! command -v shfmt >/dev/null; then
  echo "SKIP: shfmt not installed"
  exit 0
fi

# The fallback must not live above /tmp: the hook walks upward to / looking for
# an .editorconfig, so a stray one in a parent directory would silently make
# the no-editorconfig cases test the wrong path. Verify the assumption instead
# of trusting it.
TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT

_probe="${TMPROOT}"
_stray=""
while true; do
  [[ -f "${_probe}/.editorconfig" ]] && _stray="${_probe}/.editorconfig"
  [[ "${_probe}" == "/" ]] && break
  _probe="$(dirname "${_probe}")"
done
if [[ -n "${_stray}" ]]; then
  echo "SKIP: a stray .editorconfig above the tmpdir (${_stray}) would void these cases"
  exit 0
fi

# A file in CI style: `&&` at end of line, which is what plain `shfmt -i 2 -ci`
# produces and what the old -bn fallback would have rewritten.
# The quoted heredoc delimiter keeps ${x} literal: this is fixture text to be
# written to disk, not an expansion in this test.
_write_ci_style() {
  cat >"$1" <<'FIXTURE'
#!/usr/bin/env bash
x=1
if [[ "${x}" == "1" ]] &&
  ((x > 0)); then
  echo hi
fi
FIXTURE
  chmod +x "$1"
}

# ---------------------------------------------------------------
# Case 1: no .editorconfig -> advise, never rewrite
# ---------------------------------------------------------------
echo "Case: a repo with no .editorconfig keeps its own formatting"

d1="${TMPROOT}/no-editorconfig"
mkdir -p "${d1}"
_write_ci_style "${d1}/script.sh"
before="$(cksum <"${d1}/script.sh")"

out1="$(bash "${HOOK}" "${d1}/script.sh" 2>&1)"
rc1=$?
after="$(cksum <"${d1}/script.sh")"

if [[ "${before}" == "${after}" ]]; then
  _pass "the file was not rewritten"
else
  _fail "the hook rewrote a file in a repo that stated no format (this is #290)"
fi

# The regression that made #290 expensive: the rewrite produced exactly the
# form the repo's CI rejects. Assert against CI's invocation directly.
if shfmt -i 2 -ci -d "${d1}/script.sh" >/dev/null 2>&1; then
  _pass "the file still satisfies a plain 'shfmt -i 2 -ci' CI check"
else
  _fail "the hook left a file that CI's 'shfmt -i 2 -ci' would reject"
fi

if [[ ${rc1} -eq 0 ]]; then
  _pass "a formatting advisory alone does not block the commit"
else
  _fail "the advisory blocked the commit (exit ${rc1}); it must be informational"
fi

if grep -qi 'advisory' <<<"${out1}"; then
  _pass "the drift is still reported to the author"
else
  _fail "no advisory shown; the drift became invisible instead of non-blocking"
fi

# "Auto-fixed" over an untouched file is the false claim that sent #290's
# diagnosis at the committer rather than the hook.
if grep -q 'Auto-fixed' <<<"${out1}"; then
  _fail "the hook claimed 'Auto-fixed' while changing nothing"
else
  _pass "the hook does not claim to have fixed anything"
fi

# ---------------------------------------------------------------
# Case 2: shellcheck findings still surface on the advisory path
# ---------------------------------------------------------------
# The advisory branch must not short-circuit the rest of the per-file loop.
echo "Case: the advisory path still reports shellcheck findings"

d2="${TMPROOT}/shellcheck-too"
mkdir -p "${d2}"
cat >"${d2}/bad.sh" <<'FIXTURE'
#!/usr/bin/env bash
if [[ a == a ]] &&
  ((1 > 0)); then
  echo hi
fi
FIXTURE
chmod +x "${d2}/bad.sh"

out2="$(bash "${HOOK}" "${d2}/bad.sh" 2>&1)"
rc2=$?

if [[ ${rc2} -ne 0 ]] && grep -q 'SC2050' <<<"${out2}"; then
  _pass "a real shellcheck finding still blocks, alongside the advisory"
else
  _fail "shellcheck findings were lost on the no-editorconfig path"
fi

# ---------------------------------------------------------------
# Case 3: an .editorconfig still drives auto-formatting
# ---------------------------------------------------------------
# The fix must relax the fallback WITHOUT disabling the feature for repos that
# did state a preference.
echo "Case: a repo with an .editorconfig is still auto-formatted"

d3="${TMPROOT}/has-editorconfig"
mkdir -p "${d3}"
printf '%s\n' \
  'root = true' \
  '[*.sh]' \
  'indent_style = space' \
  'indent_size = 2' \
  'switch_case_indent = true' \
  'binary_next_line = true' >"${d3}/.editorconfig"
_write_ci_style "${d3}/script.sh"

out3="$(bash "${HOOK}" "${d3}/script.sh" 2>&1)"

if grep -q 'Auto-fixed' <<<"${out3}"; then
  _pass "the file was auto-formatted per the repo's own .editorconfig"
else
  _fail "an .editorconfig repo was not auto-formatted; the fix over-reached"
fi

# binary_next_line = true is the style this repo states, so the operator must
# have MOVED to the start of the continuation line.
if grep -qE '^\s+&&' "${d3}/script.sh"; then
  _pass "the .editorconfig's binary_next_line was honored"
else
  _fail "the .editorconfig was found but its style was not applied"
fi

# Cases 3b-3e: a web-only .editorconfig gave shfmt no shell keys, so it
# re-indented 4-space scripts to tabs.
_write_four_space() {
  printf '%s\n' '#!/usr/bin/env bash' 'f() {' '    echo hi' '}' 'f' >"$1"
  chmod +x "$1"
}
_write_web_only_editorconfig() {
  printf '%s\n' 'root = true' '[*]' 'charset = utf-8' 'insert_final_newline = true' \
    '[*.{yml,yaml}]' 'indent_style = space' 'indent_size = 2' \
    '[package.json]' 'indent_size = 2' '[Makefile]' 'indent_style = tab' \
    '[src/**.ts]' 'indent_size = 4' >"$1"
}

echo "Case: an .editorconfig with no shell section leaves scripts alone"
d3b="${TMPROOT}/web-only-editorconfig"
mkdir -p "${d3b}"
_write_web_only_editorconfig "${d3b}/.editorconfig"
_write_four_space "${d3b}/script.sh"
before="$(cksum <"${d3b}/script.sh")"
out3b="$(bash "${HOOK}" "${d3b}/script.sh" 2>&1)"
rc3b=$?
after="$(cksum <"${d3b}/script.sh")"
if [[ "${after}" == "${before}" ]]; then
  _pass "the 4-space script was not re-indented to tabs"
else
  _fail "the hook applied shfmt's tab default under a web-only .editorconfig"
fi
if [[ ${rc3b} -eq 0 ]] && grep -qi 'advisory' <<<"${out3b}"; then
  _pass "the drift is an advisory and does not block"
else
  _fail "expected a non-blocking advisory (exit ${rc3b})"
fi

echo "Case: an extension-less section still states a shell style"
d3c="${TMPROOT}/hook-name-section"
mkdir -p "${d3c}"
printf '%s\n' 'root = true' '[{pre-commit,commit-msg}]' 'indent_style = space' 'indent_size = 2' \
  >"${d3c}/.editorconfig"
_write_four_space "${d3c}/pre-commit"
out3c="$(bash "${HOOK}" "${d3c}/pre-commit" 2>&1)"
if grep -q 'Auto-fixed' <<<"${out3c}" && grep -qE '^  echo hi$' "${d3c}/pre-commit"; then
  _pass "the hook-name section was honored (2-space indent)"
else
  _fail "an extension-less section was not treated as a shell style"
fi

echo "Case: a root = true file with no shell style ends the search"
d3d="${TMPROOT}/root-stops"
mkdir -p "${d3d}/sub"
printf '%s\n' 'root = true' '[*.sh]' 'indent_style = space' 'indent_size = 2' >"${d3d}/.editorconfig"
_write_web_only_editorconfig "${d3d}/sub/.editorconfig"
_write_four_space "${d3d}/sub/script.sh"
before="$(cksum <"${d3d}/sub/script.sh")"
bash "${HOOK}" "${d3d}/sub/script.sh" >/dev/null 2>&1
after="$(cksum <"${d3d}/sub/script.sh")"
if [[ "${after}" == "${before}" ]]; then
  _pass "the parent's [*.sh] did not apply past root = true"
else
  _fail "the search continued past a root = true .editorconfig"
fi

echo "Case: a non-root file with no shell style defers to its parent"
d3e="${TMPROOT}/parent-applies"
mkdir -p "${d3e}/sub"
printf '%s\n' 'root = true' '[*.sh]' 'indent_style = space' 'indent_size = 2' >"${d3e}/.editorconfig"
printf '%s\n' '[*.md]' 'indent_size = 4' >"${d3e}/sub/.editorconfig"
_write_four_space "${d3e}/sub/script.sh"
bash "${HOOK}" "${d3e}/sub/script.sh" >/dev/null 2>&1
if grep -qE '^  echo hi$' "${d3e}/sub/script.sh"; then
  _pass "the parent's [*.sh] style was applied"
else
  _fail "a non-root .editorconfig hid the parent's shell style"
fi

# ---------------------------------------------------------------
# Case 4: dotfiles states its own preference
# ---------------------------------------------------------------
# dotfiles has no .editorconfig historically, so it inherited the -bn fallback.
# With the fallback gone, the style it already uses has to be written down or
# this repo silently drops to shfmt's tab default.
echo "Case: dotfiles declares its own shell style"

if [[ -f "${REPO_ROOT}/.editorconfig" ]]; then
  _pass "dotfiles has an .editorconfig"
  if grep -q 'binary_next_line' "${REPO_ROOT}/.editorconfig"; then
    _pass "it pins binary_next_line, matching the existing code"
  else
    _fail "no binary_next_line; dotfiles' own scripts would churn"
  fi
else
  _fail "dotfiles has no .editorconfig; it now falls back to shfmt defaults"
fi

echo
if [[ ${fail} -eq 0 ]]; then
  echo "PASS: lint-shell.sh defers to each repo's stated format"
else
  echo "FAIL: see above" >&2
fi
exit "${fail}"
