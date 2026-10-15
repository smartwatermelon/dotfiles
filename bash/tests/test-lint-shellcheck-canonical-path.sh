#!/usr/bin/env bash
#shellcheck shell=bash
# lint-shellcheck.sh finds the canonical rc where install.sh deploys it.
set -uo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESOLVER="${REPO_ROOT}/git/hooks/lint-shellcheck.sh"

fail=0
_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT

# Mirror the deployed layout: install.sh links each file in shellcheck/ into
# ~/.config/shellcheck/ under its own name.
fake_home="${TMPROOT}/home"
mkdir -p "${fake_home}/.config/shellcheck"
for f in "${REPO_ROOT}"/shellcheck/*; do
  ln -s "${f}" "${fake_home}/.config/shellcheck/${f##*/}"
done

# A directory outside any repo, so no repo-root .shellcheckrc is found.
work="${TMPROOT}/work"
mkdir -p "${work}"

echo "Case: canonical rc resolves on an installed machine"
rc=0
out="$(cd "${work}" && env -u SHELLCHECK_CANONICAL_CONFIG HOME="${fake_home}" \
  GIT_CEILING_DIRECTORIES="${TMPROOT}" "${BASH}" "${RESOLVER}" 2>&1)" || rc=$?
if [[ "${rc}" -eq 0 && "${out}" == "${fake_home}/.config/shellcheck/"* && -f "${out}" ]]; then
  _pass "resolver printed the deployed canonical rc: ${out}"
else
  _fail "expected a deployed rc path, got rc=${rc}: ${out}"
fi

exit "${fail}"
