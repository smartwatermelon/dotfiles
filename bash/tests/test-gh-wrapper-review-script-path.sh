#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification for bash/gh-wrapper.sh's pre-merge review script
# resolution. Run directly: bash bash/tests/test-gh-wrapper-review-script-path.sh
#
# Regression: the location used to be computed once, at source time, from
# ${HOME}:
#
#     _gh_wrapper_review_script="${HOME}/.claude/hooks/pre-merge-review.sh"
#
# ${HOME} at source time is not necessarily ${HOME} at call time. Any harness
# that sandboxes HOME after sourcing -- which is how the wrapper's own tests
# work -- still got the sourcing user's path, so `gh pr merge` ran the REAL
# pre-merge hook instead of the mock. The failure surfaced as an unrelated
# "Claude CLI not found" error from the real hook, which sent the diagnosis in
# entirely the wrong direction (claude-config#360).
#
# The variable is also exported, so a stale value reaches every child process,
# including a test runner launched from an interactive shell. That is why the
# cases below run with the variable explicitly unset unless they are testing
# inheritance: inheriting it would mask the very thing under test.
#
# Each case runs in a separate `bash -c` process rather than a subshell, so the
# HOME and override juggling cannot leak between cases -- and so shellcheck is
# not left warning about subshell-local modifications that are the entire point.
set -euo pipefail

unset CDPATH

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAPPER="${REPO_ROOT}/bash/gh-wrapper.sh"

SANDBOX="/tmp/gh-wrapper-review-path-test-$$"
mkdir -p "${SANDBOX}/home/.claude/hooks"
trap 'rm -rf "${SANDBOX}"' EXIT

fail=0
actual=""

# Run one scenario in a pristine process and echo the resolved path.
#   $1 - value for _gh_wrapper_review_script ("" means unset it)
#   $2 - "before" or "after": whether HOME is set before or after sourcing
resolve_in_clean_shell() {
  local override="$1" when="$2" script

  # The child expands SBX/WRAP itself, so they are passed through the
  # environment rather than interpolated here. printf keeps the deferred
  # expansion explicit instead of hiding it in a single-quoted literal.
  local d
  d="$(printf '%s' '$')"
  if [[ "${when}" == "before" ]]; then
    script="export HOME=\"${d}SBX/home\"; . \"${d}WRAP\"; _gh_wrapper_review_script_path"
  else
    script=". \"${d}WRAP\"; export HOME=\"${d}SBX/home\"; _gh_wrapper_review_script_path"
  fi

  if [[ -n "${override}" ]]; then
    SBX="${SANDBOX}" WRAP="${WRAPPER}" _gh_wrapper_review_script="${override}" \
      bash --noprofile --norc -c "${script}" 2>/dev/null
  else
    env -u _gh_wrapper_review_script \
      SBX="${SANDBOX}" WRAP="${WRAPPER}" \
      bash --noprofile --norc -c "${script}" 2>/dev/null
  fi
}

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    echo "PASS: ${label}"
  else
    echo "FAIL: ${label}"
    echo "      expected: ${expected}"
    echo "      actual:   ${actual}"
    fail=1
  fi
}

# Case 1: HOME reassigned AFTER sourcing must be honored. This is the
# regression itself -- under the old code the answer stayed pinned to whatever
# HOME held while the file was being read.
actual="$(resolve_in_clean_shell "" after)" || actual="<resolution failed>"
check "HOME reassigned after sourcing is honored" \
  "${SANDBOX}/home/.claude/hooks/pre-merge-review.sh" "${actual}"

# Case 2: with no override and HOME already set, the default tracks the active
# HOME -- the ordinary interactive case must not have changed.
actual="$(resolve_in_clean_shell "" before)" || actual="<resolution failed>"
check "default resolves under the active HOME" \
  "${SANDBOX}/home/.claude/hooks/pre-merge-review.sh" "${actual}"

# Case 3: an explicit (and inherited, since it is exported into the child)
# override wins over HOME-derived resolution, so a caller can point this
# anywhere without staging a whole fake home directory. The variable is
# exported by design; this documents that inheritance is a feature, and tells
# any future test author why they must unset it to sandbox HOME.
actual="$(resolve_in_clean_shell "${SANDBOX}/explicit-override.sh" after)" || actual="<resolution failed>"
check "exported override beats HOME-derived path" \
  "${SANDBOX}/explicit-override.sh" "${actual}"

# Case 4: the override also wins when HOME was set before sourcing, so
# precedence does not depend on ordering.
actual="$(resolve_in_clean_shell "${SANDBOX}/inherited.sh" before)" || actual="<resolution failed>"
check "override wins regardless of when HOME was set" \
  "${SANDBOX}/inherited.sh" "${actual}"

# Case 5: the helper must survive export -f inheritance. _gh_wrapper_maybe_review
# is exported and calls this function, but an exported function carries only its
# own body into a subshell -- so a helper left out of the export list fails with
# "command not found" in any subshell that inherited gh() without re-sourcing
# this file. That is the documented reason the export list exists, and it is
# exactly the kind of omission a new helper invites.
#
# The check reads the BASH_FUNC_* environment entry directly rather than asking
# a child shell with `type -t`. A child started from the ambient environment
# inherits whatever the developer's own shell already exported, so `type -t`
# reports "function" even when the export list is wrong -- the assertion passes
# for the wrong reason. Counting the marshalled env entry cannot be fooled that
# way.
marker_d="$(printf '%s' '$')"
marker_script=". \"${marker_d}WRAP\" >/dev/null 2>&1 || true; env | grep -c \"^BASH_FUNC__gh_wrapper_review_script_path\""
exported_marker="$(
  env -i PATH="${PATH}" HOME="${HOME}" WRAP="${WRAPPER}" \
    bash --noprofile --norc -c "${marker_script}" 2>/dev/null
)" || exported_marker="0"
check "helper is marshalled into the environment by export -f" "1" "${exported_marker}"

echo ""
if ((fail == 0)); then
  echo "All review-script-path checks passed."
else
  echo "Review-script-path checks FAILED."
fi
exit "${fail}"
