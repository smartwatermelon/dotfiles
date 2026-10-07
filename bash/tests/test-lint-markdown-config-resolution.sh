#!/usr/bin/env bash
#shellcheck shell=bash
# lint-markdown.sh picks CI's config and reaches CI's verdict.
#
# The old merged config passed files CI failed.
set -uo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${REPO_ROOT}/git/hooks/lint-markdown.sh"

fail=0
_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

if ! command -v markdownlint-cli2 >/dev/null; then
  echo "SKIP: markdownlint-cli2 not installed"
  exit 0
fi

TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT

# A canonical fixture, not the real ~/.config one: the test asserts the
# resolution, not whatever the developer's machine carries.
CANONICAL="${TMPROOT}/canonical.json"
printf '{"default": true, "MD013": false, "MD041": false, "MD060": false}\n' >"${CANONICAL}"

# A terraform-docs-style table: MD060 rejects it, and --fix cannot repair it.
_write_case() {
  local dir="$1"
  mkdir -p "${dir}"
  printf '%s\n' '# Doc' '' '| Name | Type |' '|------|---------|' '| a | b |' >"${dir}/README.md"
}

_hook() { (cd "$1" && MARKDOWNLINT_CANONICAL_CONFIG="$2" bash "${HOOK}" "${@:3}" 2>&1); }

echo "-- no repo config: canonical applies"
c="${TMPROOT}/canonical-only"
_write_case "${c}"
rc=0
out="$(_hook "${c}" "${CANONICAL}" README.md)" || rc=$?
if [[ "${rc}" -eq 0 ]]; then _pass "canonical MD060 disable applies"; else _fail "rc=${rc}: ${out}"; fi

echo "-- repo config: used alone, same verdict as CI"
r="${TMPROOT}/repo-config"
_write_case "${r}"
printf '{"default": true, "MD013": false}\n' >"${r}/.markdownlint.json"
ci_rc=0
(cd "${r}" && markdownlint-cli2 --config .markdownlint.json README.md >/dev/null 2>&1) || ci_rc=$?
rc=0
out="$(_hook "${r}" "${CANONICAL}" README.md)" || rc=$?
if [[ "${ci_rc}" -ne 0 ]]; then _pass "CI's command fails this file (MD060)"; else _fail "fixture does not trip CI, so the next check proves nothing"; fi
if [[ "${rc}" -eq "${ci_rc}" ]] && grep -q MD060 <<<"${out}"; then
  _pass "hook matches CI (rc=${rc}, MD060)"
else
  _fail "hook rc=${rc}, CI rc=${ci_rc}: ${out}"
fi

echo "-- both kinds present: same config and verdict as CI"
# MD060 fires here even under the cli2 config (cli2 0.23.3); compare to CI.
b="${TMPROOT}/both"
_write_case "${b}"
printf '{"default": true, "MD013": false}\n' >"${b}/.markdownlint.json"
printf '{"config": {"default": true, "MD013": false, "MD060": false}}\n' >"${b}/.markdownlint-cli2.jsonc"
ci_rc=0
(cd "${b}" && markdownlint-cli2 --config .markdownlint-cli2.jsonc README.md >/dev/null 2>&1) || ci_rc=$?
rc=0
out="$(_hook "${b}" "${CANONICAL}" README.md)" || rc=$?
if [[ "${rc}" -eq "${ci_rc}" ]]; then _pass "hook matches CI (rc=${rc})"; else _fail "hook rc=${rc}, CI rc=${ci_rc}: ${out}"; fi

echo "-- missing canonical, no repo config: warns and still lints"
m="${TMPROOT}/missing"
mkdir -p "${m}"
printf 'not a heading\n\n# Later\n' >"${m}/bad.md"
rc=0
out="$(_hook "${m}" "${TMPROOT}/does-not-exist.json" bad.md)" || rc=$?
if grep -q 'canonical config not found' <<<"${out}"; then _pass "warns"; else _fail "no warning: ${out}"; fi
if [[ "${rc}" -ne 0 ]] && grep -q MD041 <<<"${out}"; then _pass "defaults still lint"; else _fail "silent pass (rc=${rc})"; fi

echo "-- no files: exits clean"
rc=0
out="$(_hook "${TMPROOT}" "${CANONICAL}")" || rc=$?
if [[ "${rc}" -eq 0 ]]; then _pass "exit 0"; else _fail "rc=${rc}: ${out}"; fi

exit "${fail}"
