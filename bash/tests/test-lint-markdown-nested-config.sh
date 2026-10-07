#!/usr/bin/env bash
#shellcheck shell=bash
# lint-markdown.sh applies nested configs as CI's cli2 does (kebab-tax#1286).
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

for tool in markdownlint markdownlint-cli2; do
  if ! command -v "${tool}" >/dev/null; then
    echo "SKIP: ${tool} not installed"
    exit 0
  fi
done

TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT

CANONICAL="${TMPROOT}/canonical.json"
printf '{"default": true, "MD013": false, "MD036": false}\n' >"${CANONICAL}"

# MD036 (emphasis as a heading) is not auto-fixable, so --fix cannot hide it.
_write_case() {
  local dir="$1"
  mkdir -p "${dir}/sub"
  printf '%s\n' '# Doc' '' '**Step 1: Install**' '' 'Text.' >"${dir}/sub/plan.md"
  printf '{"default": true}\n' >"${dir}/sub/.markdownlint.json"
}

echo "-- known-bad: markdownlint-cli (the old hook) ignores the nested config"
kb="${TMPROOT}/known-bad"
_write_case "${kb}"
if (cd "${kb}" && markdownlint --config "${CANONICAL}" sub/plan.md >/dev/null 2>&1); then
  _pass "known-bad reproduces"
else
  _fail "known-bad did NOT reproduce, so the cases below prove nothing"
  exit 1
fi

echo "-- no repo config: the hook applies the nested config"
c="${TMPROOT}/case"
_write_case "${c}"
rc=0
out="$(cd "${c}" && MARKDOWNLINT_CANONICAL_CONFIG="${CANONICAL}" bash "${HOOK}" sub/plan.md 2>&1)" || rc=$?
if [[ "${rc}" -ne 0 ]] && grep -q 'sub/plan.md.*MD036' <<<"${out}"; then
  _pass "reports MD036 under the nested config"
else
  _fail "nested config not applied (rc=${rc}): ${out}"
fi

echo "-- repo root config: the hook still applies the nested config"
m="${TMPROOT}/root-config"
_write_case "${m}"
printf '{"default": true, "MD013": false, "MD036": false}\n' >"${m}/.markdownlint.json"
rc=0
out="$(cd "${m}" && MARKDOWNLINT_CANONICAL_CONFIG="${CANONICAL}" bash "${HOOK}" sub/plan.md 2>&1)" || rc=$?
if [[ "${rc}" -ne 0 ]] && grep -q 'sub/plan.md.*MD036' <<<"${out}"; then
  _pass "reports MD036 with a repo root config"
else
  _fail "nested config not applied under a repo root config (rc=${rc}): ${out}"
fi

echo "-- control: without the nested config the canonical disable holds"
n="${TMPROOT}/control"
_write_case "${n}"
rm "${n}/sub/.markdownlint.json"
rc=0
out="$(cd "${n}" && MARKDOWNLINT_CANONICAL_CONFIG="${CANONICAL}" bash "${HOOK}" sub/plan.md 2>&1)" || rc=$?
if [[ "${rc}" -eq 0 ]]; then _pass "canonical MD036 disable applies"; else _fail "control blocked (rc=${rc}): ${out}"; fi

exit "${fail}"
