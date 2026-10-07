#!/usr/bin/env bash
#shellcheck shell=bash
# pre-commit/config.yaml: semgrep-secrets skips test files (matched like pre-commit's re.search).
set -euo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG="${REPO_ROOT}/pre-commit/config.yaml"

fail=0
_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

# The exclude line directly under the semgrep-secrets hook, up to the next hook id.
regex="$(awk '/id: semgrep-secrets/{p=1} p && /^ *exclude: '"'"'/{print; exit} p && /id: / && !/semgrep-secrets/{exit}' "${CONFIG}" \
  | sed -E "s/^ *exclude: '(.*)'$/\1/")"
if [[ -z "${regex}" ]]; then
  echo "FAIL: no single-quoted exclude under semgrep-secrets in ${CONFIG}" >&2
  exit 1
fi

# matches PATH: exit 0 when the regex excludes PATH.
matches() {
  python3 -c 'import re, sys; sys.exit(0 if re.search(sys.argv[1], sys.argv[2]) else 1)' "${regex}" "$1"
}

echo "-- test files are excluded from the secret scan"
for p in \
  scripts/tests/test-hook-block-secret-leak.sh \
  hooks/tests/fixtures/required-kebab-tax.json \
  workers/valuation-api/src/utils/__tests__/jwt-validator.test.ts \
  src/auth.test.ts src/auth.spec.tsx lib/x.test.mjs \
  test/helpers.js spec/x.rb \
  test-redact.sh test_parse.py parse_test.py tests.bats; do
  if matches "${p}"; then _pass "${p}"; else _fail "${p} should be excluded"; fi
done

echo "-- everything else is still scanned"
for p in \
  docs/BETA-EXIT-RUNBOOK.md \
  scripts/hook-block-secret-leak.py \
  src/latest.ts src/contest.ts src/attestation.js \
  config/testing.yml .env.test \
  scripts/run-tests.sh mytests/x.sh protest/x.sh; do
  if matches "${p}"; then _fail "${p} should be scanned"; else _pass "${p}"; fi
done

echo "-- flake8 ignores E203 (black writes x[a : b])"
if grep -qE -- '--extend-ignore=[^"]*E203' "${CONFIG}"; then _pass "E203 in --extend-ignore"; else _fail "E203 missing from --extend-ignore"; fi

exit "${fail}"
