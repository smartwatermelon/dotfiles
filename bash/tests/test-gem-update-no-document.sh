#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification that `_gem_update` skips RubyGems doc generation.
# Run directly: bash bash/tests/test-gem-update-no-document.sh
#
# Homebrew's rubygems plugin shim (lib/ruby/gems/*/plugins/rdoc_plugin.rb)
# hardcodes the RDoc version shipped with the ruby formula, so every `gem`
# process loads that RDoc at startup. Doc generation then activates the newer
# rdoc from GEM_HOME, and the two copies overwrite each other's constants
# in-process. RDoc::Markup::Formatter#initialize has different arity between
# the versions, so the older ToJoinedParagraph's `super nil` raises
# ArgumentError and fails the entire `gem update`, which stops `allup` at
# _gem_update.
#
# The failure is intermittent in two ways, which is why it resisted diagnosis:
# it needs an updated gem whose comments are Markdown (only that path reaches
# ToJoinedParagraph), and it depends on which copy loses the constant race.
# A passing run therefore does not prove the collision is gone.
#
# Doc generation is the only path that reaches the colliding code, so
# --no-document avoids the collision regardless of which RDoc versions happen
# to be installed. This test pins that flag: removing it reintroduces an
# intermittent failure that a green run would not catch.
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

# Pull the function under test out of functions.sh by name. Extraction goes
# through bash's own parser -- source the file in a clean subshell, then let
# `declare -f` print the parsed function -- rather than slicing the file with
# a text pattern, so the test does not depend on source formatting.
#
# The subshell uses --norc --noprofile so no interactive-shell setup runs, and
# functions.sh is side-effect-free at source time (it only defines functions).
_fn_src="$(bash --norc --noprofile -c '
  source "$1" >/dev/null 2>&1 || exit 1
  declare -f _gem_update
' _ "${REPO_ROOT}/bash/functions.sh")"
if [[ -z "${_fn_src}" ]]; then
  echo "FAIL: could not extract _gem_update from functions.sh" >&2
  echo "      (the function may have been renamed or removed)" >&2
  exit 1
fi

# Guard against a partial match that would silently under-test: the extracted
# body must contain the update invocation this test is about.
if [[ "${_fn_src}" != *"gem update"* ]]; then
  echo "FAIL: extracted _gem_update does not invoke 'gem update'" >&2
  exit 1
fi

echo "Case: the update invocation suppresses doc generation"
# Read the actual `gem update` line rather than grepping the whole body, so a
# --no-document appearing on some other command (a future `gem install`, say)
# cannot satisfy this check.
update_line="$(printf '%s\n' "${_fn_src}" | grep -E '^\s*output=\$\(gem update' | head -1)"
if [[ -z "${update_line}" ]]; then
  echo "  FAIL: no 'output=\$(gem update ...)' line found in _gem_update"
  fail=1
else
  if [[ "${update_line}" == *"--no-document"* ]]; then
    check "gem update passes --no-document" "yes" "yes"
  else
    check "gem update passes --no-document" "yes" "no"
    echo "         line was: ${update_line}"
  fi
fi

echo "Case: the rationale is recorded at the call site"
# The flag looks like a mere speed tweak, so a future reader could drop it to
# restore local `ri` docs without knowing it prevents a real failure. Require
# the comment naming the cause to stay next to it.
mentions=0
mentions="$(grep -c 'no-document' "${REPO_ROOT}/bash/functions.sh")" || mentions=0
if [[ "${mentions}" -ge 2 ]]; then
  check "flag is accompanied by an explanatory comment" "yes" "yes"
else
  check "flag is accompanied by an explanatory comment" "yes" "no"
fi

if grep -q 'RDoc' "${REPO_ROOT}/bash/functions.sh"; then
  check "comment names RDoc as the cause" "yes" "yes"
else
  check "comment names RDoc as the cause" "yes" "no"
fi

echo "Case: a real failure is still reported (fail-fast preserved)"
# --no-document must not mask genuine update failures: _gem_update returns
# non-zero so `updates` records the step and stops.
# The literal source text being searched for, assembled so no dollar sign
# appears inside quotes that shellcheck would read as an expansion.
propagate_expr="return \"\${result}\""
if [[ "${_fn_src}" == *"${propagate_expr}"* ]]; then
  check "non-zero exit from gem update is propagated" "yes" "yes"
else
  check "non-zero exit from gem update is propagated" "yes" "no"
fi

echo
if [[ "${fail}" -eq 0 ]]; then
  echo "test-gem-update-no-document: all cases passed"
else
  echo "test-gem-update-no-document: FAILURES above"
fi
exit "${fail}"
