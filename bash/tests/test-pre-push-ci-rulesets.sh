#!/usr/bin/env bash
#shellcheck shell=bash
# Tests pre-push's Semgrep CI-ruleset stage; semgrep and run_bounded are stubs.
set -euo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${REPO_ROOT}/git/hooks/pre-push"

fail=0
_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

# The hook runs checks when sourced, so slice the functions out as
# test-pre-push-scan-timeout.sh does.
_raw_body="$(awk '
  /^(_ci_semgrep_rulesets|run_ci_ruleset_scan)\(\)/ { collecting = 1 }
  collecting {
    print
    counted = $0
    sub(/#.*/, "", counted)
    n = gsub(/\{/, "{", counted); depth += n
    n = gsub(/\}/, "}", counted); depth -= n
    if (depth == 0 && seen_open) { collecting = 0; seen_open = 0; next }
    if (depth > 0) { seen_open = 1 }
  }
' "${HOOK}")"
FUNCS="$(bash --norc --noprofile -c '
  eval "$1" || exit 1
  declare -f _ci_semgrep_rulesets run_ci_ruleset_scan
' _ "${_raw_body}" 2>/dev/null)" || FUNCS=""
DEFAULTS="$(grep -E '^SEMGREP_CI_DEFAULT_RULESETS=' "${HOOK}" | head -1)" || DEFAULTS=""
if [[ "${FUNCS}" != *"_ci_semgrep_rulesets"* || "${FUNCS}" != *"run_ci_ruleset_scan"* || -z "${DEFAULTS}" ]]; then
  echo "FAIL: could not extract the CI-ruleset functions from ${HOOK}" >&2
  exit 1
fi

echo "Case: the hook calls the stage"
if grep -qE '^run_ci_ruleset_scan$' "${HOOK}"; then
  _pass "run_ci_ruleset_scan is called at top level"
else
  _fail "run_ci_ruleset_scan is defined but never called"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pre-push-ci-rulesets.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
LIB="${WORK}/lib.sh"
printf '%s\n%s\n' "${DEFAULTS}" "${FUNCS}" >"${LIB}"

CALLER='jobs:
  semgrep:
    uses: smartwatermelon/github-workflows/.github/workflows/semgrep-scan.yml@semgrep-scan-v1'

# Args: <name> <workflow file content, or "" for no workflows dir>
mkcase() {
  local d="${WORK}/$1"
  mkdir -p "${d}"
  if [[ -n "$2" ]]; then
    mkdir -p "${d}/.github/workflows"
    printf '%s\n' "$2" >"${d}/.github/workflows/semgrep-scan.yml"
  fi
  printf '%s' "${d}"
}

# Prints "<rc>|<rulesets joined by spaces>".
rulesets_of() {
  local out rc=0
  out="$(bash --norc --noprofile -c 'source "$1"; _ci_semgrep_rulesets "$2/.github/workflows"' _ "${LIB}" "$1" 2>/dev/null)" || rc=$?
  out="${out//$'\n'/ }"
  printf '%s|%s' "${rc}" "${out}"
}

expect() {
  local label="$1" want="$2" got="$3"
  if [[ "${got}" == "${want}" ]]; then
    _pass "${label}"
  else
    _fail "${label}: want '${want}', got '${got}'"
  fi
}

echo "Case: how the rulesets are found"
d="$(mkcase none '')"
got="$(rulesets_of "${d}")"
expect "no workflows dir: nothing" "0|" "${got}"
d="$(mkcase dflt "${CALLER}
    # rulesets: p/default p/javascript")"
got="$(rulesets_of "${d}")"
expect "caller with only a commented rulesets line: the defaults" "0|p/default p/javascript p/python p/ruby p/typescript" "${got}"
d="$(mkcase own "${CALLER}
    with:
      rulesets: \"p/python p/default\"  # trimmed")"
got="$(rulesets_of "${d}")"
expect "caller's own rulesets replace the defaults" "0|p/default p/python" "${got}"
d="$(mkcase cmt '#    uses: smartwatermelon/github-workflows/.github/workflows/semgrep-scan.yml@semgrep-scan-v1')"
got="$(rulesets_of "${d}")"
expect "commented-out caller: nothing" "0|" "${got}"
d="$(mkcase blk "${CALLER}
    with:
      rulesets: |
        p/default")"
got="$(rulesets_of "${d}")"
expect "block scalar rulesets: refused" "2|" "${got}"
d="$(mkcase bad "${CALLER}
    with:
      rulesets: p/default;touch")"
got="$(rulesets_of "${d}")"
expect "invalid config name: refused" "2|" "${got}"

# run_bounded records its args and returns STUB_RC; semgrep need only exist.
mkdir -p "${WORK}/bin"
printf '#!/bin/sh\nexit 0\n' >"${WORK}/bin/semgrep"
chmod +x "${WORK}/bin/semgrep"
DRIVER="${WORK}/driver.sh"
cat >"${DRIVER}" <<'EOF'
#!/usr/bin/env bash
source "${LIB}"
SEMGREP_TIMEOUT_SECS=5
log() { :; }
log_success() { :; }
log_warning() { :; }
strict_noninteractive_block() { return 1; }
run_bounded() { shift; printf '%s\n' "$*" >"${ARGS_FILE}"; return "${STUB_RC}"; }
cd "$1" || exit 99
run_ci_ruleset_scan
echo "returned"
EOF

scan() {
  local dir="$1" rc="$2" out
  rm -f "${WORK}/args"
  out="$(PATH="${WORK}/bin:${PATH}" LIB="${LIB}" ARGS_FILE="${WORK}/args" STUB_RC="${rc}" \
    bash --norc --noprofile "${DRIVER}" "${dir}" 2>/dev/null)" && printf 'exit0:%s' "${out}" || printf 'exit%s:%s' "$?" "${out}"
}

echo "Case: the scan blocks on findings"
repo="$(mkcase scanrepo "${CALLER}")"
git -C "${repo}" init -q --template=
got="$(scan "${repo}" 1)"
expect "findings (semgrep exit 1) block the push" "exit1:" "${got}"
got="$(scan "${repo}" 0)"
expect "clean scan continues" "exit0:returned" "${got}"
args="$(cat "${WORK}/args" 2>/dev/null)" || args=""
if [[ "${args}" == "semgrep scan --error "*"--config p/default "*" ." ]]; then
  _pass "scan runs with --error and --config p/default"
else
  _fail "unexpected scan arguments: '${args}'"
fi
got="$(scan "${repo}" 2)"
expect "infra failure is advisory outside strict mode" "exit0:returned" "${got}"
got="$(scan "${WORK}/blk" 0)"
expect "unreadable rulesets block the push" "exit1:" "${got}"
rm -f "${WORK}/args"
got="$(scan "${WORK}/none" 1)"
expect "no caller: no scan" "exit0:returned" "${got}"
if [[ -e "${WORK}/args" ]]; then
  _fail "semgrep ran in a repo with no semgrep-scan caller"
else
  _pass "semgrep not run in a repo with no caller"
fi

if ((fail)); then
  echo "FAILED" >&2
  exit 1
fi
echo "All CI-ruleset parity checks passed."
