#!/usr/bin/env bash
#shellcheck shell=bash
# pre-commit hook: beacon-biosignals repos run only BEACON_KEEP_HOOKS globally. A stub pre-commit logs SKIP.
set -euo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${REPO_ROOT}/git/hooks/pre-commit"
REAL_CONFIG="${REPO_ROOT}/pre-commit/config.yaml"

for f in "${HOOK}" "${REAL_CONFIG}"; do
  if [[ ! -f "${f}" ]]; then
    echo "FAIL: not found: ${f}" >&2
    exit 1
  fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Clear inherited GIT_DIR and friends first (dotfiles#239).
_tests_dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-env-isolation.sh
source "${_tests_dir}/lib/git-env-isolation.sh"
isolate_git_env "${WORK}"

# type -P, not command -v: an exported git function would give the bare word.
REAL_GIT="$(type -P git)"

# Sandbox HOME: the hook's symlink repair then finds no lib and skips.
export HOME="${WORK}/home"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
mkdir -p "${HOME}/.config/pre-commit"

GLOBAL_CONFIG="${HOME}/.config/pre-commit/config.yaml"
CALL_LOG="${WORK}/calls.log"

# Stub pre-commit logs "<pass> SKIP=[<value>]". The hook's PATH holds only
# these stubs, so the hook must not need any other external command.
STUB_BIN="${WORK}/bin"
mkdir -p "${STUB_BIN}"
ln -s "${REAL_GIT}" "${STUB_BIN}/git"
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
pass="local"
[[ "\${cfg}" == "${GLOBAL_CONFIG}" ]] && pass="global"
echo "\${pass} SKIP=[\${SKIP-}]" >>"${CALL_LOG}"
exit 0
EOF
chmod +x "${STUB_BIN}/pre-commit"

FIXTURE="${WORK}/repo"
"${REAL_GIT}" init -q -b work "${FIXTURE}"

# A small global config. The commented "- id: commented-out" line and the
# quoted id check the parser; neither may be treated wrongly.
write_small_config() {
  cat >"${GLOBAL_CONFIG}" <<'EOF'
repos:
  - repo: local
    hooks:
      - id: semgrep-secrets
        name: "secrets"
      - id: flake8
      # - id: commented-out
      - id: "length-caps"
      - id: zizmor
EOF
}

# setup_case <origin-url|none> [local: yes|no]
setup_case() {
  : >"${CALL_LOG}"
  rm -f "${FIXTURE}/.pre-commit-config.yaml"
  "${REAL_GIT}" -C "${FIXTURE}" remote remove origin 2>/dev/null || true
  if [[ "$1" != "none" ]]; then
    "${REAL_GIT}" -C "${FIXTURE}" remote add origin "$1"
  fi
  if [[ "${2:-no}" == "yes" ]]; then
    echo "repos: []" >"${FIXTURE}/.pre-commit-config.yaml"
  fi
}

# run_hook [VAR=value ...]: prints the hook's combined output, then "RC=<n>".
run_hook() {
  local rc=0
  (cd "${FIXTURE}" && env -u SKIP PATH="${STUB_BIN}" "$@" "${BASH}" "${HOOK}") 2>&1 || rc=$?
  echo "RC=${rc}"
}

calls() { tr '\n' '|' <"${CALL_LOG}" | sed 's/|$//'; }

set +e
failures=0

expect_calls() {
  local actual
  actual="$(calls)"
  if [[ "${actual}" == "$2" ]]; then
    echo "  PASS: $1"
  else
    echo "  FAIL: $1 — expected '$2', got '${actual}'"
    failures=$((failures + 1))
  fi
}

expect_out() {
  # $1 label  $2 needle  $3 output  $4 want|wantnot
  local found=no
  grep -qF -- "$2" <<<"$3" && found=yes
  if [[ ("$4" == "want" && "${found}" == "yes") || ("$4" == "wantnot" && "${found}" == "no") ]]; then
    echo "  PASS: $1"
  else
    echo "  FAIL: $1 — $4 '$2'"
    echo "$3" | sed 's/^/        /'
    failures=$((failures + 1))
  fi
}

write_small_config
BEACON_SKIP="flake8,zizmor"

echo "Case A: beacon-biosignals origin (ssh)"
setup_case git@github.com:beacon-biosignals/platform-hq.git
out="$(run_hook)"
expect_calls "global pass skips all but the kept hooks" "global SKIP=[${BEACON_SKIP}]"
expect_out "commit allowed" "RC=0" "${out}" want
expect_out "says why" "beacon-biosignals repo" "${out}" want

echo "Case B: beacon-biosignals origin (https, mixed case, no .git)"
setup_case https://github.com/Beacon-Biosignals/infra
run_hook >/dev/null
expect_calls "owner match is case-insensitive" "global SKIP=[${BEACON_SKIP}]"

echo "Case C: other owner"
setup_case git@github.com:smartwatermelon/dotfiles.git
out="$(run_hook)"
expect_calls "global pass skips nothing" "global SKIP=[]"
expect_out "no beacon note" "beacon-biosignals repo" "${out}" wantnot

echo "Case D: owner that only starts with beacon-biosignals"
setup_case git@github.com:beacon-biosignals-labs/x.git
run_hook >/dev/null
expect_calls "prefix is not a match" "global SKIP=[]"

echo "Case E: no origin"
setup_case none
run_hook >/dev/null
expect_calls "global pass skips nothing" "global SKIP=[]"

echo "Case F: non-GitHub host with a beacon-biosignals path"
setup_case git@gitlab.com:beacon-biosignals/x.git
run_hook >/dev/null
expect_calls "only github.com counts" "global SKIP=[]"

echo "Case G: beacon origin, caller SKIP, repo-local config"
setup_case git@github.com:beacon-biosignals/platform-datastore.git yes
run_hook SKIP=mine >/dev/null
expect_calls "caller SKIP kept; local pass sees only the caller's SKIP" \
  "global SKIP=[mine,${BEACON_SKIP}]|local SKIP=[mine]"

echo "Case H: the real global config, beacon origin"
cp "${REAL_CONFIG}" "${GLOBAL_CONFIG}"
setup_case git@github.com:beacon-biosignals/platform-hq.git
run_hook >/dev/null
skip_list="$(calls)"
skip_list="${skip_list#global SKIP=[}"
skip_list=",${skip_list%]},"
for id in zizmor flake8 yamllint prettier; do
  expect_out "real config: ${id} is skipped" ",${id}," "${skip_list}" want
done
for id in semgrep-secrets length-caps; do
  expect_out "real config: ${id} still runs" ",${id}," "${skip_list}" wantnot
done

echo
if ((failures > 0)); then
  echo "FAILED: ${failures} assertion(s)"
  exit 1
fi
echo "PASSED: all assertions"
