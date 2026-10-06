#!/usr/bin/env bash
#shellcheck shell=bash
# git/hooks/pre-commit runs the global config, then any repo-local one.
# Drives the real hook with a stub pre-commit.
set -euo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${REPO_ROOT}/git/hooks/pre-commit"

if [[ ! -f "${HOOK}" ]]; then
  echo "FAIL: hook not found at ${HOOK}" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Clear inherited GIT_DIR and friends first (dotfiles#239).
_tests_dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-env-isolation.sh
source "${_tests_dir}/lib/git-env-isolation.sh"
isolate_git_env "${WORK}"

REAL_GIT="$(command -v git)"

# Sandbox HOME: the hook's symlink repair then finds no lib and skips.
export HOME="${WORK}/home"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
mkdir -p "${HOME}"

GLOBAL_CONFIG="${HOME}/.config/pre-commit/config.yaml"
CALL_LOG="${WORK}/calls.log"

# Stub pre-commit logs its config and exits PC_GLOBAL_RC/PC_LOCAL_RC.
# Absolute-bash shebang: the hook's PATH holds only these stubs.
STUB_BIN="${WORK}/bin"
NOPC_BIN="${WORK}/bin-no-pre-commit"
mkdir -p "${STUB_BIN}" "${NOPC_BIN}"
ln -s "${REAL_GIT}" "${STUB_BIN}/git"
ln -s "${REAL_GIT}" "${NOPC_BIN}/git"
cat >"${STUB_BIN}/pre-commit" <<EOF
#!${BASH}
cfg="(default)"
while [[ \$# -gt 0 ]]; do
  if [[ "\$1" == "--config" ]]; then
    cfg="\$2"
    shift
  fi
  shift
done
if [[ "\${cfg}" == "${GLOBAL_CONFIG}" ]]; then
  echo "global" >>"${CALL_LOG}"
  exit "\${PC_GLOBAL_RC:-0}"
fi
echo "local:\${cfg}" >>"${CALL_LOG}"
exit "\${PC_LOCAL_RC:-0}"
EOF
chmod +x "${STUB_BIN}/pre-commit"

# Scratch repo on a non-protected branch, so the hook's branch check passes.
FIXTURE="${WORK}/repo"
"${REAL_GIT}" init -q -b work "${FIXTURE}"

# setup_case <global: yes|no> <local: yes|no>
setup_case() {
  rm -f "${CALL_LOG}" "${FIXTURE}/.pre-commit-config.yaml"
  rm -rf "${HOME}/.config"
  : >"${CALL_LOG}"
  if [[ "$1" == "yes" ]]; then
    mkdir -p "$(dirname "${GLOBAL_CONFIG}")"
    echo "repos: []" >"${GLOBAL_CONFIG}"
  fi
  if [[ "$2" == "yes" ]]; then
    echo "repos: []" >"${FIXTURE}/.pre-commit-config.yaml"
  fi
}

# run_hook <path-dir> [VAR=value ...]: runs the hook in the fixture, prints its
# combined output followed by "RC=<status>".
run_hook() {
  local path_dir="$1"
  shift
  local rc=0
  (cd "${FIXTURE}" && env PATH="${path_dir}" "$@" "${BASH}" "${HOOK}") 2>&1 || rc=$?
  echo "RC=${rc}"
}

calls() { tr '\n' ' ' <"${CALL_LOG}" | sed 's/ $//'; }

set +e
failures=0

check() {
  # $1: label  $2: expected-substring  $3: actual output  $4: want|wantnot
  local label="$1" needle="$2" actual="$3" mode="$4"
  if [[ "${mode}" == "want" ]]; then
    if grep -qF -- "${needle}" <<<"${actual}"; then
      echo "  PASS: ${label}"
    else
      echo "  FAIL: ${label} — expected to find '${needle}'"
      echo "${actual}" | sed 's/^/        /'
      failures=$((failures + 1))
    fi
  else
    if grep -qF -- "${needle}" <<<"${actual}"; then
      echo "  FAIL: ${label} — did not expect '${needle}'"
      echo "${actual}" | sed 's/^/        /'
      failures=$((failures + 1))
    else
      echo "  PASS: ${label}"
    fi
  fi
}

check_calls() {
  # $1: label  $2: exact expected call sequence
  local actual
  actual="$(calls)"
  if [[ "${actual}" == "$2" ]]; then
    echo "  PASS: $1"
  else
    echo "  FAIL: $1 — expected calls '$2', got '${actual}'"
    failures=$((failures + 1))
  fi
}

LOCAL_CALL="local:.pre-commit-config.yaml"

echo "Case A: global only, passes"
setup_case yes no
out="$(run_hook "${STUB_BIN}")"
check_calls "only the global config ran" "global"
check "commit allowed" "RC=0" "${out}" want

echo "Case B: global + local, both pass"
setup_case yes yes
out="$(run_hook "${STUB_BIN}")"
check_calls "global ran first, then local" "global ${LOCAL_CALL}"
check "commit allowed" "RC=0" "${out}" want

echo "Case C: global fails, local passes"
setup_case yes yes
out="$(run_hook "${STUB_BIN}" PC_GLOBAL_RC=1)"
check_calls "local still ran after the global failure" "global ${LOCAL_CALL}"
check "commit blocked" "RC=1" "${out}" want
check "summary names the global config" "FAILED: global-config." "${out}" want

echo "Case D: global passes, local fails"
setup_case yes yes
out="$(run_hook "${STUB_BIN}" PC_LOCAL_RC=1)"
check_calls "both configs ran" "global ${LOCAL_CALL}"
check "commit blocked" "RC=1" "${out}" want
check "summary names the local config" "FAILED: repo-local-config." "${out}" want

echo "Case E: both fail"
setup_case yes yes
out="$(run_hook "${STUB_BIN}" PC_GLOBAL_RC=1 PC_LOCAL_RC=1)"
check_calls "both configs ran" "global ${LOCAL_CALL}"
check "commit blocked" "RC=1" "${out}" want
check "summary names both" "FAILED: global-config repo-local-config." "${out}" want

echo "Case F: no config at all"
setup_case no no
out="$(run_hook "${STUB_BIN}")"
check_calls "pre-commit never ran" ""
check "original error kept" "ERROR: No config found" "${out}" want
check "commit blocked" "RC=1" "${out}" want

echo "Case G: local config only, global missing"
setup_case no yes
out="$(run_hook "${STUB_BIN}")"
check_calls "local did NOT run alone" ""
check "missing global reported" "ERROR: Global config not found" "${out}" want
check "commit blocked" "RC=1" "${out}" want

echo "Case H: pre-commit not installed"
setup_case yes yes
out="$(run_hook "${NOPC_BIN}")"
check_calls "pre-commit never ran" ""
check "original error kept" "'pre-commit' command not found in PATH" "${out}" want
check "commit blocked" "RC=1" "${out}" want

echo
if ((failures > 0)); then
  echo "FAILED: ${failures} assertion(s)"
  exit 1
fi
echo "PASSED: all assertions"
