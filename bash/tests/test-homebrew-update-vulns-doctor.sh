#!/usr/bin/env bash
#shellcheck shell=bash
# Behaviour test for the Homebrew 7.0 additions to `_homebrew_update`
# (bash/functions.sh) and the auto-updating-cask opt-out in bash/env.sh.
# Run directly: bash bash/tests/test-homebrew-update-vulns-doctor.sh
#
# _homebrew_update runs against a stub `brew` that records each call and
# returns per-subcommand exit codes and output, so the test covers:
#   - `brew vulns --severity=high --fix-available` runs on every update
#   - a vulns finding (non-zero exit) is notified but does not fail the chain
#   - a doctor warning that another brew shadows this one is notified
#   - an ordinary doctor warning does not raise the shadow notification
#   - env.sh exports HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS
set -euo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "  PASS: ${label}"
  else
    echo "  FAIL: ${label} — expected [${expected}], got [${actual}]"
    fail=1
  fi
}

# Extract the function through bash's own parser (same approach as
# test-gem-update-no-document.sh) so the test does not depend on formatting.
_fn_src="$(bash --norc --noprofile -c '
  source "$1" >/dev/null 2>&1 || exit 1
  declare -f _homebrew_update
' _ "${REPO_ROOT}/bash/functions.sh")"
if [[ -z "${_fn_src}" ]]; then
  echo "FAIL: could not extract _homebrew_update from functions.sh" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Run _homebrew_update in a child bash with every external dependency
# stubbed. Arguments: vulns exit code, doctor exit code, doctor output,
# and optional vulns output.
# Prints the notifications, then a line "RC=<n>", then the brew call log.
run_update() {
  local vulns_rc="$1" doctor_rc="$2" doctor_out="$3" vulns_out="${4:-vulns report}"
  : >"${WORK}/calls"
  : >"${WORK}/notifs"
  HOME="${WORK}" VULNS_RC="${vulns_rc}" DOCTOR_RC="${doctor_rc}" \
    DOCTOR_OUT="${doctor_out}" VULNS_OUT="${vulns_out}" CALLS="${WORK}/calls" NOTIFS="${WORK}/notifs" \
    bash --norc --noprofile -c '
      brew() {
        echo "brew $*" >>"${CALLS}"
        case "$1" in
          --prefix) echo "/opt/homebrew" ;;
          vulns) echo "${VULNS_OUT}"; return "${VULNS_RC}" ;;
          doctor) echo "${DOCTOR_OUT}"; return "${DOCTOR_RC}" ;;
          *) return 0 ;;
        esac
      }
      stat() { id -u; }
      _notif() { echo "$*" >>"${NOTIFS}"; }
      _update_log() { cat >/dev/null; }
      _updates_noninteractive() { return 1; }
      eval "$1"
      _homebrew_update
      echo "RC=$?" >>"${NOTIFS}"
    ' _ "${_fn_src}"
  cat "${WORK}/notifs"
  echo "--- calls"
  cat "${WORK}/calls"
}

# Verbatim from Homebrew diagnostic.rb, so the match key is tested against
# the real wording.
shadow_text="Warning: Another \`brew\` shadows this Homebrew installation in your PATH:"
untrusted_text="Warning: 1 installed keg from an untrusted tap not scanned:"

echo "Case: clean run"
out="$(run_update 0 0 "Your system is ready to brew.")"
if grep -qx 'brew vulns --severity=high --fix-available' <<<"${out}"; then
  check "brew vulns --severity=high --fix-available is called" "yes" "yes"
else
  check "brew vulns --severity=high --fix-available is called" "yes" "no"
fi
check "no vulns notification" "0" "$(grep -c 'brew vulns:' <<<"${out}" || true)"
check "no shadow notification" "0" "$(grep -c 'shadows this installation' <<<"${out}" || true)"
check "returns 0" "1" "$(grep -cx 'RC=0' <<<"${out}" || true)"

echo "Case: vulns reports findings"
out="$(run_update 1 0 "Your system is ready to brew.")"
check "vulns finding is notified" "1" "$(grep -c 'brew vulns:' <<<"${out}" || true)"
check "update chain is not failed" "1" "$(grep -cx 'RC=0' <<<"${out}" || true)"

echo "Case: vulns skipped a keg from an untrusted tap"
out="$(run_update 1 0 "Your system is ready to brew." "${untrusted_text}")"
check "untrusted-tap skip is notified" "1" "$(grep -c 'untrusted tap were not scanned' <<<"${out}" || true)"
check "update chain is not failed" "1" "$(grep -cx 'RC=0' <<<"${out}" || true)"

echo "Case: doctor reports a shadowing brew"
out="$(run_update 0 1 "${shadow_text}")"
check "shadow warning is notified" "1" "$(grep -c 'shadows this installation' <<<"${out}" || true)"
check "update chain is not failed" "1" "$(grep -cx 'RC=0' <<<"${out}" || true)"

echo "Case: doctor reports an unrelated warning"
out="$(run_update 0 1 "Warning: Some installed formulae are deprecated.")"
check "no shadow notification" "0" "$(grep -c 'shadows this installation' <<<"${out}" || true)"
check "generic warning notification kept" "1" "$(grep -c 'completed with warnings' <<<"${out}" || true)"

echo "Case: env.sh opts out of upgrading auto-updating casks"
# Read the assignment line rather than sourcing env.sh, which probes
# macOS-only paths and calls brew.
if grep -qxE 'export HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS=1' "${REPO_ROOT}/bash/env.sh"; then
  check "HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS is exported" "yes" "yes"
else
  check "HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS is exported" "yes" "no"
fi
# This variable is ignored when greedy upgrades are on, so a greedy setting
# anywhere in the shell config would silently undo the opt-out.
# Comment lines are skipped: env.sh names --greedy when explaining the opt-out.
greedy_hits="$(grep -rhE 'HOMEBREW_UPGRADE_GREEDY|upgrade[^#]*--greedy' "${REPO_ROOT}/bash" \
  --include='*.sh' --exclude='test-*' | grep -vE '^[[:space:]]*#' || true)"
if [[ -n "${greedy_hits}" ]]; then
  check "no greedy upgrade setting undoes the opt-out" "yes" "no"
else
  check "no greedy upgrade setting undoes the opt-out" "yes" "yes"
fi

echo
if [[ "${fail}" -eq 0 ]]; then
  echo "test-homebrew-update-vulns-doctor: all cases passed"
else
  echo "test-homebrew-update-vulns-doctor: FAILURES above"
fi
exit "${fail}"
