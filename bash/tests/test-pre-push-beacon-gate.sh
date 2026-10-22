#!/usr/bin/env bash
#shellcheck shell=bash
# Verification for git/hooks/pre-push's run_beacon_text_gate.
# Run directly: bash bash/tests/test-pre-push-beacon-gate.sh

# The hook runs top to bottom, so each case runs it as a subprocess, as test-pre-push-stale-ci.sh does.

# gh and semgrep are mocks. gate-review.sh and gate-route.sh are the real ones, copied into a sandbox HOME.

# gate-lint is a stub that judges by a marker; comment extraction uses the real personify length_check.py.

# PRE_PUSH_HOOK runs the cases against another copy of the hook, e.g. origin/main's, as a known-bad control.
set -uo pipefail

unset CDPATH

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${PRE_PUSH_HOOK:-${REPO_ROOT}/git/hooks/pre-push}"

fail=0

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

_tests_dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-env-isolation.sh
source "${_tests_dir}/lib/git-env-isolation.sh"
isolate_git_env "${WORKDIR}"

REAL_GATE="${GATE_REVIEW_SH:-${HOME}/.claude/scripts/gate-review.sh}"
REAL_ROUTE="$(dirname "${REAL_GATE}")/gate-route.sh"
if [[ ! -x "${REAL_GATE}" || ! -x "${REAL_ROUTE}" ]] || ! grep -q '_cmd_route' "${REAL_GATE}"; then
  echo "SKIP: no gate-review.sh with a route subcommand at ${REAL_GATE}"
  exit 0
fi
PERSONIFY="$("${REAL_GATE}" personify-path 2>/dev/null || true)"
if [[ -z "${PERSONIFY}" || ! -f "${PERSONIFY}/scripts/length_check.py" ]]; then
  echo "SKIP: personify's length_check.py not found"
  exit 0
fi

SANDBOX="${WORKDIR}/home"
mkdir -p "${SANDBOX}/.claude/scripts" "${SANDBOX}/.claude/plugins" "${SANDBOX}/.config"
cp "${REAL_GATE}" "${SANDBOX}/.claude/scripts/gate-review.sh"
cp "${REAL_ROUTE}" "${SANDBOX}/.claude/scripts/gate-route.sh"
cat >"${SANDBOX}/.claude/scripts/gate-lint.sh" <<'STUB'
#!/usr/bin/env bash
grep -q LINTBAD "${!#}" && { echo 'gate-lint: error Andrew.Marker line 1: LINTBAD'; exit 1; }
exit 0
STUB
chmod +x "${SANDBOX}/.claude/scripts/gate-lint.sh"
printf '{"plugins":{"personify@personify":[{"installPath":"%s"}]}}\n' "${PERSONIFY}" \
  >"${SANDBOX}/.claude/plugins/installed_plugins.json"

export HOME="${SANDBOX}"
export CLAUDE_CONFIG_DIR="${SANDBOX}/.claude"
export GATE_REVIEW_DIR="${SANDBOX}/.claude/gate-review"
export GATE_RULES_FILE="${SANDBOX}/gate-rules.conf"
export GH_WRAPPER_LIB="${REPO_ROOT}/bash/gh-wrapper.sh"
export XDG_CONFIG_HOME="${SANDBOX}/.config"
unset GH_REPO CLAUDECODE POSTPUSH_LOOP
mkdir -p "${GATE_REVIEW_DIR}/pending" "${GATE_REVIEW_DIR}/approved"
printf '%s\n' 'owner=smartwatermelon exempt' '* review' >"${GATE_RULES_FILE}"

BIN="${WORKDIR}/bin"
mkdir -p "${BIN}"
GH_LOG="${WORKDIR}/gh.log"
PR_JSON="${WORKDIR}/pr.json"
# gh pr view --json isDraft,...: the PR state in PR_JSON, or exit 1 when it is absent (no PR).
cat >"${BIN}/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${GH_LOG}"
if [[ "\$1 \$2" == "pr view" && "\$*" == *isDraft* ]]; then
  [[ -f "${PR_JSON}" ]] || { echo 'no pull requests found' >&2; exit 1; }
  cat "${PR_JSON}"
  exit 0
fi
if [[ "\$1 \$2" == "pr view" ]]; then
  echo '{"number":7,"reviewDecision":null,"reviews":[],"statusCheckRollup":[]}'
fi
exit 0
EOF
chmod +x "${BIN}/gh"
printf '#!/usr/bin/env bash\nexit 0\n' >"${BIN}/semgrep"
chmod +x "${BIN}/semgrep"

# A main commit, then a feature commit adding a shell comment, a doc line and a commit message.
REPO="${WORKDIR}/repo"
mkdir -p "${REPO}"
(
  cd "${REPO}" || exit 1
  git -c core.hooksPath= -c init.templateDir= init -q -b main
  git config core.hooksPath ""
  git config user.email "test@example.com"
  git config user.name "Test"
  git commit -q --allow-empty -m "test: init"
  git checkout -q -b feature
  printf '#!/usr/bin/env bash\n# Retries the fetch once on a timeout.\necho hi\n' >run.sh
  printf 'The tool now retries once.\n' >NOTES.md
  git add run.sh NOTES.md
  git commit -q -m "feat: retry the fetch once"
) || exit 1
TIP="$(git -C "${REPO}" rev-parse HEAD)"
TEXT_FILE="$(git -C "${REPO}" rev-parse --absolute-git-dir)/pre-push-beacon-text.txt"

OUT="${WORKDIR}/out.log"
# Runs the hook for a new-branch push of feature to the remote URL $1.
run_hook() {
  (
    cd "${REPO}" || exit 1
    export PATH="${BIN}:${PATH}"
    printf 'refs/heads/feature %s refs/heads/feature %s\n' "${TIP}" 0000000000000000000000000000000000000000 \
      | bash "${HOOK}" origin "$1" >"${OUT}" 2>&1
  )
}

# expect <label> <0|1 exit> <grep pattern or empty>
expect() {
  local label="$1" want="$2" pat="$3" got="$4"
  if [[ "${got}" == "${want}" ]] && { [[ -z "${pat}" ]] || grep -q -- "${pat}" "${OUT}"; }; then
    echo "PASS: ${label}"
  else
    echo "FAIL: ${label} (exit ${got}, wanted ${want}, pattern '${pat}')"
    sed 's/^/    /' "${OUT}"
    fail=1
  fi
}

BEACON=git@github.com:beacon-biosignals/x.git
READY='{"isDraft":false,"state":"OPEN"}'

# Known-bad control first: ready PR on a review route, text unapproved, must block.
printf '%s\n' "${READY}" >"${PR_JSON}"
rc=0
run_hook "${BEACON}" || rc=1
expect "ready PR, unapproved text: blocked" 1 "nobody has approved" "${rc}"
if [[ -f "${TEXT_FILE}" ]] && grep -q 'feat: retry the fetch once' "${TEXT_FILE}" \
  && grep -q 'Retries the fetch once on a timeout.' "${TEXT_FILE}" \
  && grep -q 'The tool now retries once.' "${TEXT_FILE}" && ! grep -q 'echo hi' "${TEXT_FILE}"; then
  echo "PASS: text file has the commit message, the comment and the doc line, and no code"
else
  echo "FAIL: text file content — $(cat "${TEXT_FILE}" 2>/dev/null)"
  fail=1
fi

# Approve those exact bytes, as a human typing APPROVED in the editor produces.
if [[ -f "${TEXT_FILE}" ]]; then
  cp "${TEXT_FILE}" "${GATE_REVIEW_DIR}/approved/beacon-text"
fi
rc=0
run_hook "${BEACON}" || rc=1
expect "ready PR, approved text: passes" 0 "text approved" "${rc}"
rm -f "${GATE_REVIEW_DIR}/approved/beacon-text"

printf '{"isDraft":true,"state":"OPEN"}\n' >"${PR_JSON}"
rc=0
run_hook "${BEACON}" || rc=1
expect "draft PR: skipped" 0 "is a draft; skipped" "${rc}"

rm -f "${PR_JSON}"
rc=0
run_hook "${BEACON}" || rc=1
expect "no PR: skipped with a note" 0 "no open PR found" "${rc}"

printf '{"isDraft":false,"state":"MERGED"}\n' >"${PR_JSON}"
rc=0
run_hook "${BEACON}" || rc=1
expect "merged PR: skipped" 0 "no open PR found" "${rc}"

# Exempt remote: skipped before gh is asked about the PR.
printf '%s\n' "${READY}" >"${PR_JSON}"
: >"${GH_LOG}"
rc=0
run_hook git@github.com:smartwatermelon/x.git || rc=1
expect "exempt remote, ready PR, unapproved: passes" 0 "" "${rc}"
if grep -q isDraft "${GH_LOG}"; then
  echo "FAIL: exempt remote still asked gh about the PR"
  fail=1
else
  echo "PASS: exempt remote never asks gh about the PR"
fi

# Lint runs before approval: findings block even when the text is approved.
(
  cd "${REPO}" || exit 1
  git commit -q --amend -m "feat: retry the fetch once LINTBAD"
) || exit 1
TIP="$(git -C "${REPO}" rev-parse HEAD)"
rc=0
run_hook "${BEACON}" || rc=1
expect "ready PR, lint findings: blocked" 1 "gate-lint found errors" "${rc}"

if [[ "${fail}" == "0" ]]; then
  echo "All pre-push Beacon gate checks passed."
else
  echo "Pre-push Beacon gate checks FAILED."
fi
exit "${fail}"
