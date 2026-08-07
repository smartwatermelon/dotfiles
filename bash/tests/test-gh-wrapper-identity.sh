#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification for bash/gh-wrapper.sh's owner->identity mapping.
# Run directly: bash bash/tests/test-gh-wrapper-identity.sh
#
# Regression coverage for smartwatermelon/dotfiles#159: owner matching in
# _gh_wrapper_sync_identity must be case-insensitive, since GitHub owner
# names are case-insensitive but callers (--repo flags, URLs) may supply
# any casing.
set -euo pipefail

unset CDPATH

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export BASH_CONFIG_DIR="${REPO_ROOT}/bash"

export HOME="/tmp/gh-wrapper-identity-test-home-$$"
mkdir -p "${HOME}/.config/gh"
trap 'rm -rf "${HOME}"' EXIT

# Sourcing (not executing) the file puts it in function-definition mode,
# where _gh_wrapper_sync_identity is defined but gh() itself is not invoked.
#shellcheck source=/dev/null
source "${BASH_CONFIG_DIR}/gh-wrapper.sh"

fail=0

# Stub `command gh auth switch` so we can observe the desired identity
# without touching real gh state. Records the requested user to a file.
switch_log="${HOME}/switch-log"
command() {
  if [[ "$1" == "gh" && "$2" == "auth" && "$3" == "switch" ]]; then
    # args: gh auth switch --hostname github.com --user <desired>
    printf '%s' "${*: -1}" >"${switch_log}"
    return 0
  fi
  builtin command "$@"
}

assert_desired() {
  local label="$1" current_user="$2" repo_arg="$3" expected="$4"
  rm -f "${switch_log}"
  cat >"${HOME}/.config/gh/hosts.yml" <<EOF
github.com:
    user: ${current_user}
EOF
  if _gh_wrapper_sync_identity --repo "${repo_arg}" pr list; then
    :
  else
    echo "FAIL: ${label} — _gh_wrapper_sync_identity returned non-zero"
    fail=1
    return
  fi
  local got
  got="$(cat "${switch_log}" 2>/dev/null || true)"
  if [[ "${current_user}" == "${expected}" ]]; then
    # No switch should have been attempted.
    if [[ -z "${got}" ]]; then
      echo "PASS: ${label} (no switch needed, stayed on ${current_user})"
    else
      echo "FAIL: ${label} — unexpected switch attempted to '${got}'"
      fail=1
    fi
  else
    if [[ "${got}" == "${expected}" ]]; then
      echo "PASS: ${label} (switched to ${expected})"
    else
      echo "FAIL: ${label} — expected switch to '${expected}', got '${got}'"
      fail=1
    fi
  fi
}

# Baseline: lowercase owners resolve as before.
assert_desired "lowercase smartwatermelon" "smartwatermelon" "smartwatermelon/dotfiles" "smartwatermelon"
assert_desired "lowercase nightowlstudiollc" "andrewmrich" "nightowlstudiollc/kebab-tax" "smartwatermelon"

# Regression: mixed/upper case owner must still resolve to smartwatermelon,
# not fall through to the andrewmrich default (smartwatermelon/dotfiles#159).
assert_desired "mixed-case SmartWatermelon" "andrewmrich" "SmartWatermelon/dotfiles" "smartwatermelon"
assert_desired "upper-case NIGHTOWLSTUDIOLLC" "andrewmrich" "NIGHTOWLSTUDIOLLC/kebab-tax" "smartwatermelon"

# An owner that is genuinely neither still falls back to andrewmrich.
assert_desired "unrelated owner" "smartwatermelon" "beacon-biosignals/somerepo" "andrewmrich"

exit "${fail}"
