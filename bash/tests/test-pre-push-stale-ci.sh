#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification for git/hooks/pre-push's check_pr_review_iteration()
# staleness detection. Run directly: bash bash/tests/test-pre-push-stale-ci.sh
#
# Regression coverage for #169: statusCheckRollup necessarily reflects the
# PR's CURRENT remote head commit, not the commit this invocation of the
# hook is about to push (GitHub hasn't run CI on it yet). The hook must not
# hard-block on CI failures that belong to a commit other than the one being
# pushed — see git/hooks/pre-push, check_pr_review_iteration().
#
# Strategy: the hook auto-executes every check top-to-bottom when run (it is
# not designed to be sourced and cherry-picked), so each case below runs it
# as a real subprocess: a scratch git repo, a mocked `gh` on PATH that
# returns controlled JSON, and controlled stdin in the git pre-push hook's
# standard format (<local ref> <local sha1> <remote ref> <remote sha1>).
set -uo pipefail

unset CDPATH

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${REPO_ROOT}/git/hooks/pre-push"

fail=0

# ---------------------------------------------------------------
# Shared scratch repo + mock gh setup
# ---------------------------------------------------------------
WORKDIR="/tmp/pre-push-stale-ci-test-$$"
mkdir -p "${WORKDIR}"
trap 'rm -rf "${WORKDIR}"' EXIT

# Isolate from this machine's global git hooks/templates (this repo sets
# core.hooksPath / init.templateDir globally) — scratch test repos must not
# inherit real commit-msg / pre-commit enforcement.
setup_repo() {
  local dir="$1"
  mkdir -p "${dir}"
  (
    cd "${dir}" || exit 1
    /usr/bin/git -c core.hooksPath= -c init.templateDir= init -q -b main
    /usr/bin/git config core.hooksPath ""
    /usr/bin/git config user.email "test@example.com"
    /usr/bin/git config user.name "Test"
    /usr/bin/git commit -q --allow-empty -m "test: init"
    /usr/bin/git checkout -q -b feature
    /usr/bin/git commit -q --allow-empty -m "test: feature commit"
  )
}

# Mocked gh: `gh pr view --json ...` returns canned JSON depending on
# GH_MOCK_JSON env var. Any other gh subcommand is a harmless no-op.
write_mock_gh() {
  local bin_dir="$1" json_var_file="$2"
  cat >"${bin_dir}/gh" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "pr" && "\$2" == "view" ]]; then
  cat "${json_var_file}"
  exit 0
fi
exit 0
EOF
  chmod +x "${bin_dir}/gh"
}

# Run the hook as a subprocess with a controlled PATH (mock gh first),
# controlled stdin (pre-push protocol line), and non-interactive strict mode
# forced on so the CI-failure path actually attempts to block.
run_hook() {
  local repo_dir="$1" local_sha="$2" bin_dir="$3"
  (
    cd "${repo_dir}" || exit 1
    export PATH="${bin_dir}:${PATH}"
    export CLAUDECODE=1
    export STRICT_PREPUSH=1
    unset POSTPUSH_LOOP
    printf 'refs/heads/feature %s refs/heads/feature deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' "${local_sha}" \
      | bash "${HOOK}" origin git@example.com:test/test.git </dev/stdin >"${WORKDIR}/out.log" 2>&1
  )
}

# ---------------------------------------------------------------
# Case 1: statusCheckRollup SHA matches the commit being pushed,
# and has real failures -> must still hard-block.
# ---------------------------------------------------------------
REPO1="${WORKDIR}/repo1"
BIN1="${WORKDIR}/bin1"
mkdir -p "${BIN1}"
setup_repo "${REPO1}"
PUSHED_SHA_1=$(cd "${REPO1}" && /usr/bin/git rev-parse HEAD)

JSON1="${WORKDIR}/gh1.json"
cat >"${JSON1}" <<EOF
{"number":42,"reviewDecision":null,"reviews":[],"statusCheckRollup":[{"name":"docker","conclusion":"FAILURE"}],"headRefOid":"${PUSHED_SHA_1}"}
EOF
write_mock_gh "${BIN1}" "${JSON1}"

run_hook "${REPO1}" "${PUSHED_SHA_1}" "${BIN1}"
exit1=$?
out1=$(cat "${WORKDIR}/out.log")

if [[ ${exit1} -ne 0 ]] && echo "${out1}" | grep -q "failing CI check"; then
  echo "PASS: matching-SHA CI failures still hard-block"
else
  echo "FAIL: matching-SHA CI failures did not block as expected (exit=${exit1})"
  echo "${out1}"
  fail=1
fi

if echo "${out1}" | grep -qi "not the commit\|stale"; then
  echo "FAIL: matching-SHA case incorrectly labeled as stale"
  fail=1
else
  echo "PASS: matching-SHA case not mislabeled as stale"
fi

# ---------------------------------------------------------------
# Case 2: statusCheckRollup SHA differs from the commit being
# pushed (stale-by-construction) -> must NOT hard-block, and the
# message must make clear the failures are against the old commit.
# ---------------------------------------------------------------
REPO2="${WORKDIR}/repo2"
BIN2="${WORKDIR}/bin2"
mkdir -p "${BIN2}"
setup_repo "${REPO2}"
PUSHED_SHA_2=$(cd "${REPO2}" && /usr/bin/git rev-parse HEAD)
OLD_SHA_2="1111111111111111111111111111111111111"

JSON2="${WORKDIR}/gh2.json"
cat >"${JSON2}" <<EOF
{"number":42,"reviewDecision":null,"reviews":[],"statusCheckRollup":[{"name":"docker","conclusion":"FAILURE"}],"headRefOid":"${OLD_SHA_2}"}
EOF
write_mock_gh "${BIN2}" "${JSON2}"

run_hook "${REPO2}" "${PUSHED_SHA_2}" "${BIN2}"
exit2=$?
out2=$(cat "${WORKDIR}/out.log")

if [[ ${exit2} -eq 0 ]]; then
  echo "PASS: stale-SHA CI failures do not hard-block"
else
  echo "FAIL: stale-SHA CI failures incorrectly blocked the push (exit=${exit2})"
  echo "${out2}"
  fail=1
fi

if echo "${out2}" | grep -qi "not the commit you're\|currently on the remote"; then
  echo "PASS: stale-SHA case message explicitly disclaims staleness"
else
  echo "FAIL: stale-SHA case message does not explain staleness"
  echo "${out2}"
  fail=1
fi

# ---------------------------------------------------------------
# Case 3: statusCheckRollup SHA matches, no failures -> clean pass,
# no Protocol 4 checkpoint triggered at all.
# ---------------------------------------------------------------
REPO3="${WORKDIR}/repo3"
BIN3="${WORKDIR}/bin3"
mkdir -p "${BIN3}"
setup_repo "${REPO3}"
PUSHED_SHA_3=$(cd "${REPO3}" && /usr/bin/git rev-parse HEAD)

JSON3="${WORKDIR}/gh3.json"
cat >"${JSON3}" <<EOF
{"number":42,"reviewDecision":null,"reviews":[],"statusCheckRollup":[{"name":"docker","conclusion":"SUCCESS"}],"headRefOid":"${PUSHED_SHA_3}"}
EOF
write_mock_gh "${BIN3}" "${JSON3}"

run_hook "${REPO3}" "${PUSHED_SHA_3}" "${BIN3}"
exit3=$?
out3=$(cat "${WORKDIR}/out.log")

if [[ ${exit3} -eq 0 ]] && ! echo "${out3}" | grep -q "PROTOCOL 4 CHECKPOINT"; then
  echo "PASS: clean CI (matching SHA) does not trigger Protocol 4 checkpoint"
else
  echo "FAIL: clean CI case unexpectedly blocked or triggered checkpoint (exit=${exit3})"
  echo "${out3}"
  fail=1
fi

if [[ "${fail}" -eq 1 ]]; then
  echo "FAILED"
  exit 1
fi
echo "All pre-push stale-CI tests passed"
