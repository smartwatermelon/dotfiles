#!/usr/bin/env bash
#shellcheck shell=bash
# Canonical config == github-workflows' copy; config list order == run-standards.sh.
# No upstream reachable: FAIL.
set -uo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANONICAL="${REPO_ROOT}/markdownlint-cli/.markdownlint.json"
LIB="${REPO_ROOT}/git/hooks/lib-markdownlint-config.sh"
RAW_BASE="https://raw.githubusercontent.com/smartwatermelon/github-workflows/main"

fail=0
_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT

if ! command -v jq >/dev/null; then
  _fail "jq is not installed; cannot compare the configs"
  exit 1
fi

# Sets UP_JSON and UP_STANDARDS to readable upstream files, or returns 1.
_resolve_upstream() {
  local dir
  for dir in "${MARKDOWNLINT_UPSTREAM_DIR:-}" "${HOME}/Developer/github-workflows"; do
    [[ -n "${dir}" ]] || continue
    if [[ -f "${dir}/standards/markdownlint.json" && -f "${dir}/standards/run-standards.sh" ]]; then
      UP_JSON="${dir}/standards/markdownlint.json"
      UP_STANDARDS="${dir}/standards/run-standards.sh"
      echo "  upstream: ${dir}"
      return 0
    fi
    # An explicit dir that is wrong is a setup error, not a reason to fall back.
    if [[ "${dir}" == "${MARKDOWNLINT_UPSTREAM_DIR:-}" ]]; then
      echo "  MARKDOWNLINT_UPSTREAM_DIR=${dir} has no standards/markdownlint.json + run-standards.sh" >&2
      return 1
    fi
  done
  UP_JSON="${TMPROOT}/markdownlint.json"
  UP_STANDARDS="${TMPROOT}/run-standards.sh"
  if curl -fsSL --max-time 30 -o "${UP_JSON}" "${RAW_BASE}/standards/markdownlint.json" \
    && curl -fsSL --max-time 30 -o "${UP_STANDARDS}" "${RAW_BASE}/standards/run-standards.sh"; then
    echo "  upstream: ${RAW_BASE}"
    return 0
  fi
  return 1
}

echo "-- resolve github-workflows upstream"
if ! _resolve_upstream; then
  _fail "no github-workflows copy: set MARKDOWNLINT_UPSTREAM_DIR, clone it to ~/Developer, or allow ${RAW_BASE}"
  exit 1
fi

echo "-- 1. canonical config equals CI's copy"
up="$(jq -S . "${UP_JSON}" 2>/dev/null)" || up=""
mine="$(jq -S . "${CANONICAL}" 2>/dev/null)" || mine=""
if [[ -z "${up}" || -z "${mine}" ]]; then
  _fail "could not parse ${UP_JSON} or ${CANONICAL}; that is not a match"
elif [[ "${up}" == "${mine}" ]]; then
  _pass "markdownlint-cli/.markdownlint.json == standards/markdownlint.json"
else
  _fail "markdownlint-cli/.markdownlint.json has drifted from github-workflows standards/markdownlint.json"
  diff -u <(echo "${up}") <(echo "${mine}") >&2 || true
fi

echo "-- 2. config filename order matches run-standards.sh"
loops="$(grep -E '^[[:space:]]*for c in \.markdownlint' "${UP_STANDARDS}" || true)"
n=0
[[ -z "${loops}" ]] || n="$(grep -c . <<<"${loops}")"
if [[ "${n}" -ne 1 ]]; then
  _fail "expected one 'for c in .markdownlint...' loop in run-standards.sh, found ${n}"
else
  ci_list="$(sed -E 's/^[[:space:]]*for c in //; s/;.*$//' <<<"${loops}" | tr -s ' ' '\n' | grep .)"
  # shellcheck source=SCRIPTDIR/../../git/hooks/lib-markdownlint-config.sh
  lib_list="$(source "${LIB}" && printf '%s\n' "${MARKDOWNLINT_REPO_CONFIGS[@]}")"
  if [[ -n "${lib_list}" && "${ci_list}" == "${lib_list}" ]]; then
    _pass "lib-markdownlint-config.sh order == run-standards.sh order"
  else
    _fail "lib-markdownlint-config.sh and run-standards.sh list different files or orders"
    diff -u <(echo "${ci_list}") <(echo "${lib_list}") >&2 || true
  fi
fi

echo "-- 3. one definition of the list"
for f in git/hooks/lint-markdown.sh bash/markdownlint-cli2-wrapper.sh; do
  if grep -q 'markdownlintrc' "${REPO_ROOT}/${f}"; then
    _fail "${f} carries its own copy of the config list"
  elif ! grep -q 'lib-markdownlint-config.sh' "${REPO_ROOT}/${f}"; then
    _fail "${f} does not source lib-markdownlint-config.sh"
  else
    _pass "${f} uses the shared list"
  fi
done

if ((fail)); then
  echo "FAIL: markdownlint config drift"
  exit 1
fi
echo "OK: markdownlint config drift"
