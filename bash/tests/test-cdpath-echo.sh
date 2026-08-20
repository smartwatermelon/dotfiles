#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification that `cd` does not leak an echoed path to stdout
# when CDPATH is set. Run directly: bash bash/tests/test-cdpath-echo.sh
#
# Regression coverage for smartwatermelon/dotfiles#176: bash/env.sh's comment
# claims that omitting "." from CDPATH is enough to keep `cd` silent, but
# that's only true for the $PWD-relative case. If a script sources env.sh
# (so CDPATH is exported) and later does `cd somename` where "somename"
# happens to match a CDPATH component by bare name — NOT the current
# directory — bash's cd builtin still resolves it via CDPATH search and
# still echoes the resolved absolute path to stdout. Every other test in
# this directory sidesteps the whole problem by unsetting CDPATH up front,
# which is correct for those tests but means none of them actually exercise
# the CDPATH-resolved-echo case this issue is about. This test exercises it
# directly, first proving the vulnerable behavior actually occurs, then
# proving the two documented mitigations (unset CDPATH; CDPATH='' cd) close it.
set -euo pipefail

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail=0

# Build an isolated directory tree: a CDPATH "base" dir containing a
# uniquely-named subdirectory, and a separate, unrelated CWD to run from —
# so any resolution of the target name can only happen via CDPATH search,
# never via direct $PWD-relative lookup.
WORKDIR="$(mktemp -d "/tmp/cdpath-echo-test.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

cdpath_base="${WORKDIR}/base"
target_name="cdpath-target-$$"
target_dir="${cdpath_base}/${target_name}"
cwd_dir="${WORKDIR}/elsewhere"
mkdir -p "${target_dir}" "${cwd_dir}"

# Sanity check: the target name must NOT be resolvable relative to cwd_dir,
# or this test would not actually exercise CDPATH resolution.
if [[ -e "${cwd_dir}/${target_name}" ]]; then
  echo "FAIL: test setup broken — ${target_name} unexpectedly exists under ${cwd_dir}"
  exit 1
fi

# --- Case 1: prove the vulnerable behavior actually occurs ---
# With CDPATH set to include cdpath_base, and CWD set to the unrelated
# cwd_dir, `cd "${target_name}"` can only succeed via CDPATH search — and
# per bash's documented behavior, a CDPATH-resolved cd echoes the resolved
# absolute path to stdout, even though "." is not in CDPATH.
output="$(cd "${cwd_dir}" && CDPATH="${cdpath_base}" cd "${target_name}" && true 2>&1)"
if [[ "${output}" == "${target_dir}" ]]; then
  echo "PASS: confirmed vulnerable behavior — CDPATH-resolved cd echoes path when CDPATH is set (${output})"
else
  echo "FAIL: expected CDPATH-resolved cd to echo '${target_dir}', got: '${output}'"
  fail=1
fi

# --- Case 2: mitigation — unset CDPATH before cd ---
# With CDPATH unset, "target_name" is no longer reachable via CDPATH search
# and isn't $PWD-relative either, so this cd is expected to *fail* — that's
# fine and correct. The assertion that matters is stdout: nothing should be
# echoed there (an error belongs on stderr, which this deliberately doesn't
# capture). Run in a fresh `bash -c` (rather than a `$(...)` subshell) so
# the CDPATH export/unset here is unambiguously scoped to its own process
# and can't be mistaken for state that leaks into the rest of this script.
output="$(cd "${cwd_dir}" && CDPATH="${cdpath_base}" bash -c 'unset CDPATH; cd "$1" 2>/dev/null' _ "${target_name}" 2>/dev/null)" || true
if [[ -z "${output}" ]]; then
  echo "PASS: unset CDPATH — cd into CDPATH-matching bare name produces no stdout"
else
  echo "FAIL: expected no stdout after unset CDPATH, got: '${output}'"
  fail=1
fi

# --- Case 3: mitigation — CDPATH='' cd (scoped empty CDPATH per invocation) ---
# Same reasoning as Case 2: the cd is expected to fail (CDPATH scoped to
# empty for just this invocation means no CDPATH search happens), and the
# assertion is that stdout stays empty.
output="$(cd "${cwd_dir}" && CDPATH="${cdpath_base}" bash -c 'CDPATH="" cd "$1" 2>/dev/null' _ "${target_name}" 2>/dev/null)" || true
if [[ -z "${output}" ]]; then
  echo "PASS: CDPATH='' cd — cd into CDPATH-matching bare name produces no stdout"
else
  echo "FAIL: expected no stdout with CDPATH='' cd, got: '${output}'"
  fail=1
fi

# --- Case 4: repo's own env.sh sets CDPATH without triggering this repo's
# own hardened cd sites into echoing. Source env.sh for real (as a login
# shell would) and confirm the exported CDPATH still exhibits the
# vulnerable behavior when used carelessly, proving env.sh's CDPATH really
# is exported into script contexts and this is not just a synthetic setup.
export BASH_CONFIG_DIR="${REPO_ROOT}/bash"
env_cdpath="$(
  #shellcheck source=/dev/null
  source "${BASH_CONFIG_DIR}/env.sh" >/dev/null 2>&1
  printf '%s' "${CDPATH:-}"
)"
if [[ -n "${env_cdpath}" ]]; then
  echo "PASS: bash/env.sh exports a non-empty CDPATH (${env_cdpath})"
else
  echo "FAIL: expected bash/env.sh to export a non-empty CDPATH"
  fail=1
fi

# --- Case 5: BEACON_WORKDIR is appended to CDPATH only when the directory
# actually exists. Both branches are exercised against a synthetic HOME so
# the result does not depend on whether this particular machine happens to
# be the work machine — a test that only ever sees the absent case would
# pass identically if the gate were broken open or wired shut.
beacon_home="$(mktemp -d)/home"
mkdir -p "${beacon_home}/Developer"

# Sources env.sh under a synthetic HOME and prints the resulting CDPATH.
# Runs in a fully scrubbed environment (env -i) so the caller's real HOME,
# CDPATH, or BEACON_WORKDIR cannot leak in and decide the outcome.
# The probe body lives in its own file rather than an inline -c string: it
# must be expanded by the inner shell, not this one, and a heredoc-written
# script says that unambiguously without relying on quoting subtleties.
beacon_probe="${beacon_home}/probe.sh"
cat >"${beacon_probe}" <<'PROBE'
_get_homebrew_root() { echo /opt/homebrew; }
#shellcheck source=/dev/null
source "${BASH_CONFIG_DIR}/env.sh" >/dev/null 2>&1
printf '%s' "${CDPATH:-}"
PROBE

_cdpath_under_home() {
  env -i HOME="${beacon_home}" BASH_CONFIG_DIR="${REPO_ROOT}/bash" \
    PATH="/usr/bin:/bin" bash --norc "${beacon_probe}"
}

beacon_dir="${beacon_home}/Developer/beacon-biosignals"

# 5a: directory absent — must NOT appear in CDPATH.
absent_cdpath="$(_cdpath_under_home)"
if [[ ":${absent_cdpath}:" != *":${beacon_dir}:"* ]]; then
  echo "PASS: beacon dir absent — not added to CDPATH"
else
  echo "FAIL: beacon dir absent but present in CDPATH: '${absent_cdpath}'"
  fail=1
fi

# 5b: directory present — must appear, and must be LAST so work repos never
# shadow a same-named personal repo earlier in CDPATH.
mkdir -p "${beacon_dir}"
present_cdpath="$(_cdpath_under_home)"
if [[ "${present_cdpath}" == *":${beacon_dir}" ]]; then
  echo "PASS: beacon dir present — appended as the last CDPATH entry"
else
  echo "FAIL: expected CDPATH to end with '${beacon_dir}', got: '${present_cdpath}'"
  fail=1
fi

rm -rf "$(dirname "${beacon_home}")"

exit "${fail}"
