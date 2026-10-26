#!/usr/bin/env bash
#shellcheck shell=bash
# Function-mode gh pr merge: fail closed and ignore the review override under CLAUDECODE. Stubbed gh.
set -uo pipefail
unset CDPATH

TESTS_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${TESTS_DIR}/../gh-wrapper.sh"
# shellcheck source=lib/git-env-isolation.sh
source "${TESTS_DIR}/lib/git-env-isolation.sh"
isolate_git_env

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gh-review-fail-closed.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

fail=0
_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

# Stub real gh: logs every call. `command gh` in gh() finds it first on PATH.
GH_LOG="${WORKDIR}/gh.log"
STUB_DIR="${WORKDIR}/stub-bin"
mkdir -p "${STUB_DIR}"
cat >"${STUB_DIR}/gh" <<STUB_EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${GH_LOG}"
exit 0
STUB_EOF
chmod +x "${STUB_DIR}/gh"

# Review stubs: each logs its own name, then exits with its RC variable.
REVIEW_LOG="${WORKDIR}/review.log"
HOME_WITH="${WORKDIR}/home-with-review"
HOME_WITHOUT="${WORKDIR}/home-without-review"
mkdir -p "${HOME_WITH}/.claude/hooks" "${HOME_WITHOUT}"
HOME_REVIEW="${HOME_WITH}/.claude/hooks/pre-merge-review.sh"
cat >"${HOME_REVIEW}" <<STUB_EOF
#!/usr/bin/env bash
echo home-review >>"${REVIEW_LOG}"
exit "\${HOME_REVIEW_RC:-0}"
STUB_EOF
chmod +x "${HOME_REVIEW}"
OVERRIDE_REVIEW="${WORKDIR}/override-review.sh"
cat >"${OVERRIDE_REVIEW}" <<STUB_EOF
#!/usr/bin/env bash
echo override-review >>"${REVIEW_LOG}"
exit 0
STUB_EOF
chmod +x "${OVERRIDE_REVIEW}"

# Function-mode driver: source the wrapper, then replace the helpers that
# would talk to GitHub. The review path under test is left untouched.
FN_DRIVER="${WORKDIR}/fn-driver.sh"
{
  printf 'source %q\n' "${WRAPPER}"
  cat <<'DRIVER_EOF'
_gh_wrapper_sync_identity() { return 0; }
_gh_wrapper_check_labels() { return 0; }
gh "$@"
DRIVER_EOF
} >"${FN_DRIVER}"

RUN_DIR="${WORKDIR}/not-a-repo"
mkdir -p "${RUN_DIR}"

# run_merge <claude:1|-> <override|-> <home>: gh pr merge 5 in env -i. Sets RC, ERR. REVIEW_RC: HOME stub rc.
run_merge() {
  local claude="$1" override="$2" home="$3"
  : >"${GH_LOG}"
  : >"${REVIEW_LOG}"
  local -a envv=(env -i PATH="${STUB_DIR}:/usr/bin:/bin" HOME="${home}" TMPDIR="${WORKDIR}"
    HOME_REVIEW_RC="${REVIEW_RC:-0}")
  [[ "${claude}" == "1" ]] && envv+=(CLAUDECODE=1)
  [[ "${override}" != "-" ]] && envv+=(_gh_wrapper_review_script="${override}")
  RC=0
  ERR="$(cd "${RUN_DIR}" && "${envv[@]}" "${BASH}" --noprofile --norc "${FN_DRIVER}" pr merge 5 2>&1 >/dev/null)" || RC=$?
}
gh_called() { [[ -s "${GH_LOG}" ]]; }
reviewed_by() { grep -qx "$1" "${REVIEW_LOG}"; }
# One-line state for a FAIL message: was gh called, which reviews ran.
state() {
  local called=no reviews
  gh_called && called=yes
  reviews="$(tr '\n' ' ' <"${REVIEW_LOG}")"
  printf 'gh called=%s, reviews=%s' "${called}" "${reviews}"
}

echo "Case 1: Claude, review script missing -> refuse, real gh not called"
run_merge 1 - "${HOME_WITHOUT}"
if [[ "${RC}" -ne 0 ]] && ! gh_called && [[ "${ERR}" == *"Refusing to proceed"* ]]; then
  _pass "missing review script fails closed under CLAUDECODE"
else
  _fail "missing review script under CLAUDECODE: rc=${RC}, $(state || true), err=${ERR}"
fi

echo "Case 2: Claude, override=/usr/bin/true, no review script -> refuse"
run_merge 1 /usr/bin/true "${HOME_WITHOUT}"
if [[ "${RC}" -ne 0 ]] && ! gh_called; then
  _pass "/usr/bin/true override is ignored under CLAUDECODE"
else
  _fail "/usr/bin/true override under CLAUDECODE: rc=${RC}, $(state || true)"
fi

echo "Case 3: Claude, override set, HOME review rejects -> HOME review runs, override does not"
REVIEW_RC=1 run_merge 1 "${OVERRIDE_REVIEW}" "${HOME_WITH}"
if [[ "${RC}" -ne 0 ]] && ! gh_called && reviewed_by home-review && ! reviewed_by override-review; then
  _pass "override ignored; the HOME review script ran and its refusal held"
else
  _fail "override under CLAUDECODE: rc=${RC}, $(state || true)"
fi

echo "Case 4: Claude, HOME review passes -> merge proceeds"
run_merge 1 - "${HOME_WITH}"
if [[ "${RC}" -eq 0 ]] && gh_called && reviewed_by home-review; then
  _pass "reviewed merge still reaches gh under CLAUDECODE"
else
  _fail "reviewed merge under CLAUDECODE: rc=${RC}, $(state || true)"
fi

echo "Case 5: no Claude, review script missing -> warn and proceed (unchanged)"
run_merge - - "${HOME_WITHOUT}"
if [[ "${RC}" -eq 0 ]] && gh_called && [[ "${ERR}" == *"Proceeding without review"* ]]; then
  _pass "interactive shell keeps warn-and-proceed"
else
  _fail "interactive missing script: rc=${RC}, $(state || true), err=${ERR}"
fi

echo "Case 6: no Claude, override set -> override runs (unchanged)"
run_merge - "${OVERRIDE_REVIEW}" "${HOME_WITH}"
if [[ "${RC}" -eq 0 ]] && gh_called && reviewed_by override-review && ! reviewed_by home-review; then
  _pass "interactive shell honors the override"
else
  _fail "interactive override: rc=${RC}, $(state || true)"
fi

echo "Case 7: Claude, non-merge command -> no review, gh called"
: >"${GH_LOG}"
RC=0
(cd "${RUN_DIR}" && env -i PATH="${STUB_DIR}:/usr/bin:/bin" HOME="${HOME_WITHOUT}" TMPDIR="${WORKDIR}" CLAUDECODE=1 \
  "${BASH}" --noprofile --norc "${FN_DRIVER}" pr view 5 >/dev/null 2>&1) || RC=$?
if [[ "${RC}" -eq 0 ]] && gh_called; then
  _pass "non-merge commands are not affected by the missing review script"
else
  _fail "pr view under CLAUDECODE: rc=${RC}"
fi

if ((fail == 0)); then
  echo "test-gh-wrapper-review-fail-closed: all cases passed"
fi
exit "${fail}"
