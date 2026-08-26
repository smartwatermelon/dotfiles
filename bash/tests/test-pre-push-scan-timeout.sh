#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification of the pre-push hook's bounded command runner.
# Run directly: bash bash/tests/test-pre-push-scan-timeout.sh
#
# The hook's Semgrep stage reaches the network. Unbounded, a slow or
# unreachable backend blocks a push indefinitely instead of degrading — first
# observed as the test suite appearing to hang when run from a linked
# worktree, where no warm Semgrep cache exists
# (smartwatermelon/dotfiles#251). The same stall can hit a real push on a slow
# network, so the bound lives in the hook itself.
#
# run_bounded is extracted from the hook and driven directly. Both of its
# implementations are exercised: GNU `timeout` when present, and the watchdog
# fallback for stock macOS, which ships no `timeout` (it arrives with Homebrew
# coreutils). Testing only whichever one this machine happens to have would
# leave the other silently unverified.
# `set -e` guards fixture setup, where a failing mktemp/chmod must abort loudly
# rather than let the cases run against a half-built fixture and report
# confusing results. It is lifted before the behavioral cases below, which
# deliberately capture non-zero exits from run_bounded and would otherwise
# abort the script on the first expected failure.
set -euo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${REPO_ROOT}/git/hooks/pre-push"

fail=0
case_out=""

_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

# Extract the runner through bash's own parser rather than slicing the hook
# with a text pattern, following test-allup-continue-state.sh
# (smartwatermelon/dotfiles#208).
#
# A `sed '/start/,/^}/p'` range would stop at the first column-0 `}`. That is
# correct only while no line inside run_bounded's body is itself a bare `}` —
# a nested block or case arm closing at column 0 would truncate the extraction
# mid-function, and brace counting cannot tell the two apart either. Asking
# bash is the only approach immune to how the source happens to be formatted.
#
# The hook runs its checks at source time, so it cannot be sourced directly.
# The function's text is isolated first, parsed in a clean subshell, and then
# reprinted by `declare -f` — so what this test drives is what bash parsed,
# not what a regex guessed at.
# Brace-balance from the function header to its true close, so the slice ends at
# run_bounded's own `}` regardless of indentation — unlike a
# `sed '/start/,/^}/p'` range, which stops at the first column-0 `}` and would
# truncate mid-function if a nested block ever closed there.
#
# Comments are stripped before counting. Counting raw characters treats a `{` in
# a comment or URL as structure, which skews the depth and makes the slice
# over-run into whatever follows the function
# (smartwatermelon/dotfiles#260). Verified against a body carrying
# `# see https://example.com/{path`, which over-ran before this and does not now.
#
# The stripping is only for the COUNT; the printed lines are the originals, so
# the extracted body is byte-identical to the source.
#
# `sub(/#.*/, "")` also strips a `#` inside a quoted string, which would
# under-count a brace that really is structure. That is the safe direction: it
# can only end the slice early, and bash then fails to parse the truncation, so
# the guards below report which stage failed rather than the test running on a
# partial function. Verified by hiding an unbalanced `}` in a string inside
# run_bounded: the test fails with an explicit message naming the extraction.
# A shell-accurate tokenizer is not worth writing here. bash then parses it and
# `declare -f` reprints it, so what the cases drive is a function bash accepted,
# not a region awk guessed at.
_raw_body="$(awk '
  /^run_bounded\(\)/ { collecting = 1 }
  collecting {
    print
    counted = $0
    sub(/#.*/, "", counted)
    n = gsub(/\{/, "{", counted); depth += n
    n = gsub(/\}/, "}", counted); depth -= n
    if (depth == 0 && seen_open) { exit }
    if (depth > 0) { seen_open = 1 }
  }
' "${HOOK}")"

# `|| RUNNER_SRC=""`, because a bare command-substitution assignment that exits
# non-zero would abort the script under `set -e` — silently, before the
# diagnostic guards below could say why. A truncated slice must produce an
# explanation, not an empty exit 1.
RUNNER_SRC="$(bash --norc --noprofile -c '
  eval "$1" || exit 1
  declare -f run_bounded
' _ "${_raw_body}" 2>/dev/null)" || RUNNER_SRC=""

if [[ -n "${RUNNER_SRC}" ]]; then
  _timeout_default="$(grep -E '^SEMGREP_TIMEOUT_SECS=' "${HOOK}" | head -1)" || _timeout_default=""
  RUNNER_SRC="$(printf '%s\n%s\n' "${_timeout_default}" "${RUNNER_SRC}")"
fi

if [[ -z "${RUNNER_SRC}" ]]; then
  echo "FAIL: could not extract run_bounded from ${HOOK}" >&2
  echo "      (it may have been renamed or removed — the Semgrep scan would" >&2
  echo "       then be unbounded again, which is #251)" >&2
  exit 1
fi
# Guard against a partial extraction that would silently under-test.
if [[ "${RUNNER_SRC}" != *"run_bounded"* ]]; then
  echo "FAIL: extracted block does not define run_bounded()" >&2
  exit 1
fi
# Guard against a partial extraction that would silently under-test: the
# parsed body must retain the 124 expiry normalization the cases assert on.
if [[ "${RUNNER_SRC}" != *"124"* ]]; then
  echo "FAIL: extracted run_bounded lacks the 124 expiry normalization" >&2
  echo "      (extraction truncated, or the expiry contract changed)" >&2
  exit 1
fi

# Confirm the hook actually ROUTES its scans through the runner. A runner that
# exists but is not called leaves the scan unbounded while this test reports
# green — the defect class that made #251 invisible in the first place.
echo "Case: the hook routes its Semgrep scans through the bounded runner"
scan_calls="$(grep -cE '^[[:space:]]*(if ! )?run_bounded .* semgrep ' "${HOOK}")"
if ((scan_calls >= 2)); then
  _pass "both the token and fallback scans call run_bounded (${scan_calls} sites)"
else
  _fail "expected 2 bounded semgrep call sites, found ${scan_calls}"
fi
if grep -qE '^[[:space:]]*semgrep (ci|scan|")' "${HOOK}"; then
  _fail "an unbounded bare 'semgrep' invocation remains in the hook"
else
  _pass "no unbounded bare 'semgrep' invocation remains"
fi

# ---------------------------------------------------------------
# Behavioral cases, run against both implementations
# ---------------------------------------------------------------
# force_fallback=1 shadows `command -v` so run_bounded cannot find
# timeout/gtimeout and must take its watchdog branch.
#
# The driver is written to a file rather than passed as a single-quoted `-c`
# string. A quoted script body containing parameter expansions is read as an
# unexpanded expression (SC2016) by the linter, and this repo resolves such
# findings rather than suppressing them.
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/pre-push-timeout-test.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

DRIVER="${WORKDIR}/driver.sh"
cat >"${DRIVER}" <<'DRIVER_EOF'
#!/usr/bin/env bash
# Args: <force_fallback> <budget_secs> <command...>
force_fallback="$1"
secs="$2"
shift 2

source "${RUNNER_FILE}"

if [[ "${force_fallback}" == "1" ]]; then
  command() {
    if [[ "$1" == "-v" && ( "$2" == "timeout" || "$2" == "gtimeout" ) ]]; then
      return 1
    fi
    builtin command "$@"
  }
fi

start=${SECONDS}
run_bounded "${secs}" "$@"
rc=$?
echo "${rc} $((SECONDS - start))"
DRIVER_EOF
chmod +x "${DRIVER}"

RUNNER_FILE="${WORKDIR}/runner.sh"
printf '%s\n' "${RUNNER_SRC}" >"${RUNNER_FILE}"
export RUNNER_FILE

TEST_BASH="${BASH:-bash}"

run_case() {
  "${TEST_BASH}" "${DRIVER}" "$@"
}

# Fixture setup is complete. The cases below assert on non-zero exit codes as
# their subject matter, so `-e` must not apply to them.
set +e

for mode in timeout fallback; do
  force=0
  label="GNU timeout"
  if [[ "${mode}" == "fallback" ]]; then
    force=1
    label="watchdog fallback"
  fi

  echo "Case: run_bounded behavior — ${label}"

  # A command that outlives its budget is terminated and reported as 124,
  # matching coreutils' expiry convention.
  case_out="$(run_case "${force}" 3 sleep 60)"
  read -r rc elapsed <<<"${case_out}"
  if [[ "${rc}" == "124" ]]; then
    _pass "${label}: an over-budget command exits 124"
  else
    _fail "${label}: over-budget command exited ${rc}, expected 124"
  fi
  # The assertion is "bounded", not "bounded precisely". The ceiling is well
  # clear of the 3s budget plus SIGKILL escalation, but far below the 60s the
  # command would run unbounded — so a loaded runner cannot flake it, while a
  # genuinely unbounded run still fails. `SECONDS` has 1-second granularity,
  # which the margin absorbs.
  if ((elapsed <= 20)); then
    _pass "${label}: terminated near the budget (${elapsed}s of a 60s command)"
  else
    _fail "${label}: took ${elapsed}s for a 3s budget — not actually bounded"
  fi

  # Success and failure statuses must pass through untouched, or the hook
  # would misread a clean scan as an infrastructure error and vice versa.
  case_out="$(run_case "${force}" 10 true)"
  read -r rc _ <<<"${case_out}"
  if [[ "${rc}" == "0" ]]; then
    _pass "${label}: a successful command still reports 0"
  else
    _fail "${label}: successful command reported ${rc}, expected 0"
  fi

  case_out="$(run_case "${force}" 10 false)"
  read -r rc _ <<<"${case_out}"
  if [[ "${rc}" == "1" ]]; then
    _pass "${label}: a failing command's status passes through"
  else
    _fail "${label}: failing command reported ${rc}, expected 1"
  fi

  # An under-budget command must return as soon as it finishes rather than
  # waiting out the whole budget.
  case_out="$(run_case "${force}" 30 sleep 2)"
  read -r rc elapsed <<<"${case_out}"
  # The point is that the watchdog does not hold the budget open after the
  # command finishes. Anything comfortably under 30s proves that; the margin is
  # sized so shell overhead on a saturated runner cannot flake it.
  if [[ "${rc}" == "0" ]] && ((elapsed < 25)); then
    _pass "${label}: returns when the command finishes (${elapsed}s of a 30s budget)"
  else
    _fail "${label}: exit ${rc} after ${elapsed}s — expected 0 in well under 30s"
  fi
done

# ---------------------------------------------------------------
# The SIGKILL escalation branch
# ---------------------------------------------------------------
# The cases above all terminate on SIGTERM, so the grace loop exits early and
# the `kill -KILL` line never runs. That left the escalation branch with no
# coverage at all: a future edit could break it and every test would still pass
# (smartwatermelon/dotfiles#262).
#
# A command that IGNORES SIGTERM forces the escalation. It must still be
# terminated, and within the grace budget rather than running to its own length.
echo "Case: run_bounded escalates to SIGKILL for a SIGTERM-ignoring command"

IGNORER="${WORKDIR}/ignores-sigterm.sh"
cat >"${IGNORER}" <<'IGNORER_EOF'
#!/usr/bin/env bash
# Survives SIGTERM; only SIGKILL can stop this.
#
# The `sleep` runs in the foreground, so killing this script tears it down with
# it. Verified by sampling `pgrep -f "sleep 60"` across a full run: the count
# rises during each case and returns to zero between them, with none left
# behind at the end.
trap '' TERM
sleep 60
IGNORER_EOF
chmod +x "${IGNORER}"

for mode in timeout fallback; do
  force=0
  label="GNU timeout"
  if [[ "${mode}" == "fallback" ]]; then
    force=1
    label="watchdog fallback"
  fi

  case_out="$(run_case "${force}" 2 "${IGNORER}")"
  read -r rc elapsed <<<"${case_out}"

  # GNU timeout reports 124 on expiry; the fallback normalizes SIGKILL's 137 to
  # 124 itself. Either way the caller must see the expiry code.
  if [[ "${rc}" == "124" ]]; then
    _pass "${label}: a SIGTERM-ignoring command is still reported as expired"
  else
    _fail "${label}: SIGTERM-ignoring command exited ${rc}, expected 124"
  fi

  # The escalation must actually land. Unterminated, the command runs 60s.
  if ((elapsed <= 20)); then
    _pass "${label}: escalation killed it in ${elapsed}s, not its full 60s"
  else
    _fail "${label}: took ${elapsed}s — the SIGKILL escalation did not land"
  fi
done

# ---------------------------------------------------------------
# A signal death inside the budget is not an expiry
# ---------------------------------------------------------------
# The fallback used to relabel any 143/137 as 124, so a command killed by an
# external SIGTERM well inside its budget was reported as a timeout
# (smartwatermelon/dotfiles#266).
#
# The fixture signals ITSELF rather than the test hunting for the process with
# pkill. Both `pkill -f "sleep N"` and `pkill -x -n sleep` were tried and are
# unreliable here: -f also matches the driver shells, which carry the command in
# their own argv, and -n races against the test's own helper sleeps. A
# self-signalling fixture needs no process discovery at all, so the case cannot
# flake on which process the pattern happened to match.
echo "Case: an external signal inside the budget is not reported as expiry"

SELF_SIGNALLER="${WORKDIR}/self-sigterm.sh"
cat >"${SELF_SIGNALLER}" <<'SIGNALLER_EOF'
#!/usr/bin/env bash
# Dies by SIGTERM after 1s, well inside any budget this case uses. Stands in for
# any external kill — an operator, an OOM reaper, a parent tearing down.
sleep 1
kill -TERM $$
sleep 30
SIGNALLER_EOF
chmod +x "${SELF_SIGNALLER}"

case_out="$(run_case 1 30 "${SELF_SIGNALLER}")"
read -r rc elapsed <<<"${case_out}"

if [[ "${rc}" == "143" ]]; then
  _pass "watchdog fallback: a SIGTERM inside the budget reports 143, not the expiry code"
elif [[ "${rc}" == "124" ]]; then
  _fail "watchdog fallback: a signal death was mislabelled as an expiry (124)"
else
  _fail "watchdog fallback: signal death reported ${rc}, expected 143"
fi

if ((elapsed < 15)); then
  _pass "watchdog fallback: returned on the signal (${elapsed}s), not at the 30s budget"
else
  _fail "watchdog fallback: took ${elapsed}s — did not return on the signal"
fi

echo
if ((fail)); then
  echo "SOME CHECKS FAILED" >&2
  exit 1
fi
echo "test-pre-push-scan-timeout: all cases passed"
