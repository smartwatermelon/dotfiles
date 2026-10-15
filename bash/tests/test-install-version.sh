#!/usr/bin/env bash
#shellcheck shell=bash
# Tests install.sh's version lines (dev-env#72) by running only its
# Version block: install.sh deploys into ${HOME}.
set -euo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/git-env-isolation.sh
source "${REPO_ROOT}/bash/tests/lib/git-env-isolation.sh"

fail=0
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/install-version-test.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT
isolate_git_env "${WORKDIR}"

block="$(sed -n '/^# ── Version ──/,/^trap _report_version EXIT$/p' "${REPO_ROOT}/install.sh")"
if [[ "${block}" != *"trap _report_version EXIT"* ]]; then
  echo "FAIL: could not extract the Version block from install.sh" >&2
  exit 1
fi
printf '%s\n' "${block}" >"${WORKDIR}/block.sh"

fgit() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"; }
REPO="${WORKDIR}/repo"
fgit init -q --template= -b main "${REPO}"
: >"${REPO}/f"
fgit -C "${REPO}" add f
fgit -C "${REPO}" -c user.name=t -c user.email=t@t commit -qm one
fgit -C "${REPO}" tag v1.2.3

# Runs the block, then exits with $1. Sets out and rc.
run_block() {
  local code="$1" dry="$2"
  rc=0
  out="$(
    REPO_DIR="${REPO}" DRY_RUN="${dry}" XDG_STATE_HOME="${WORKDIR}/state" \
      bash -c '
        _info() { echo "INFO $*"; }
        _ok() { echo "OK $*"; }
        _warn() { echo "WARN $*"; }
        _err() { echo "ERR $*"; }
        source "$1"
        exit "$2"
      ' _ "${WORKDIR}/block.sh" "${code}" 2>&1
  )" || rc=$?
}

check_contains() {
  if [[ "$3" == *"$2"* ]]; then
    echo "  PASS: $1"
  else
    echo "  FAIL: $1 — [$2] not in [$3]"
    fail=1
  fi
}

check() {
  if [[ "$2" == "$3" ]]; then
    echo "  PASS: $1"
  else
    echo "  FAIL: $1 — expected [$2], got [$3]"
    fail=1
  fi
}

state="${WORKDIR}/state/dotfiles/version"
state_file() {
  if [[ -e "${state}" ]]; then echo present; else echo absent; fi
}

echo "Case: a dry run announces the version and records nothing"
run_block 0 true
check "status" "0" "${rc}"
check_contains "installing line" "INFO dotfiles: installing v1.2.3" "${out}"
check_contains "dry-run line" "INFO dotfiles: dry run of v1.2.3; nothing installed" "${out}"
present_or_absent="$(state_file)"
check "no state file" "absent" "${present_or_absent}"

echo "Case: a failed run reports the exit code and records nothing"
run_block 3 false
check "status kept" "3" "${rc}"
check_contains "failed line" "ERR dotfiles: install of v1.2.3 failed (exit 3)" "${out}"
present_or_absent="$(state_file)"
check "no state file" "absent" "${present_or_absent}"

echo "Case: a successful run reports and records the version"
run_block 0 false
check "status" "0" "${rc}"
check_contains "installed line" "OK dotfiles: installed v1.2.3" "${out}"
recorded="$(cat "${state}" 2>/dev/null || echo missing)"
check "state file" "v1.2.3" "${recorded}"

echo "Case: commits past the tag and local edits show in the version"
: >"${REPO}/g"
fgit -C "${REPO}" add g
fgit -C "${REPO}" -c user.name=t -c user.email=t@t commit -qm two
echo edit >>"${REPO}/f"
run_block 0 true
if [[ "${out}" =~ dotfiles:\ installing\ v1\.2\.3-1-g[0-9a-f]+-dirty ]]; then
  echo "  PASS: describe output"
else
  echo "  FAIL: describe output — got [${out}]"
  fail=1
fi

echo ""
if [[ "${fail}" -eq 0 ]]; then
  echo "ALL CHECKS PASSED"
else
  echo "SOME CHECKS FAILED"
fi
exit "${fail}"
