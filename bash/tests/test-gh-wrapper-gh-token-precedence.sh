#!/usr/bin/env bash
# Regression test: _gh_wrapper_sync_identity must not report success when
# GH_TOKEN will override the identity it just switched to.
#
# KNOWN-BAD CASE: case 2 below passes against the CURRENT code, because the
# fail-closed check reads hosts.yml (its own output) rather than the auth gh
# will actually use. That inverted assertion is the bug this test pins.
set -uo pipefail
unset CDPATH

TESTS_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${TESTS_DIR}/../gh-wrapper.sh"

WORKDIR="/tmp/gh-token-precedence-test-$$"
mkdir -p "${WORKDIR}"
trap 'rm -rf "${WORKDIR}"' EXIT

GIT=/usr/bin/git
fail=0
_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

# Sandbox HOME so the fixture never reads or writes the real hosts.yml.
export HOME="${WORKDIR}/home"
mkdir -p "${HOME}/.config/gh"
cat >"${HOME}/.config/gh/hosts.yml" <<'YAML'
github.com:
    user: smartwatermelon
    oauth_token: fake
YAML

"${GIT}" init -q "${WORKDIR}/repo"
"${GIT}" -C "${WORKDIR}/repo" remote add origin \
  git@github.com:smartwatermelon/example.git

# The driver each case runs: source the wrapper from inside the fixture repo and
# call the function under test. Kept in a file rather than `bash -c` so the
# wrapper path needs no nested quoting.
RUNNER="${WORKDIR}/run-sync.sh"
cat >"${RUNNER}" <<RUNNER_EOF
cd "${WORKDIR}/repo" || exit 1
# shellcheck source=/dev/null
source "${WRAPPER}"
_gh_wrapper_sync_identity
RUNNER_EOF

# Run the driver in a clean child shell with the given VAR=VALUE assignments
# applied. \`env\` is what isolates the environment, so nothing is exported into
# a subshell whose scope is easy to misread.
_sync_under_env() {
  env -u GH_TOKEN -u CLAUDE_GH_TOKEN_LOGIN "$@" bash "${RUNNER}"
}

# Case 1: no GH_TOKEN -> sync succeeds, as it does today.

if _sync_under_env; then
  _pass "no GH_TOKEN: sync succeeds"
else
  _fail "no GH_TOKEN: sync should succeed"
fi

# Case 2: GH_TOKEN belonging to a DIFFERENT identity than the resolved owner
# maps to. Must fail closed. Fails against the current code, which passes.
if _sync_under_env GH_TOKEN="fake-token-for-andrewmrich" \
  CLAUDE_GH_TOKEN_LOGIN="andrewmrich"; then
  _fail "mismatched GH_TOKEN: silently ran as the wrong identity"
else
  _pass "mismatched GH_TOKEN: fails closed"
fi

# Case 3: GH_TOKEN matching the resolved identity -> proceeds.
if _sync_under_env GH_TOKEN="fake-token-for-smartwatermelon" \
  CLAUDE_GH_TOKEN_LOGIN="smartwatermelon"; then
  _pass "matching GH_TOKEN: proceeds"
else
  _fail "matching GH_TOKEN: should proceed"
fi

if [[ ${fail} -eq 0 ]]; then
  echo "test-gh-wrapper-gh-token-precedence.sh: all assertions passed"
  exit 0
fi
exit 1
