#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification for bash/path.sh PATH ordering.
# Run directly: bash bash/tests/test-path-order.sh
set -euo pipefail

# Avoid CDPATH causing `cd` to echo the resolved directory to stdout, which
# would corrupt the REPO_ROOT command substitution below.
unset CDPATH

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export BASH_CONFIG_DIR="${REPO_ROOT}/bash"

# Isolate from the real environment so the test is deterministic regardless
# of what's actually installed on the machine running it.
export HOME="/tmp/path-order-test-home-$$"
mkdir -p "${HOME}/.local/bin" "${HOME}/.bun/bin"
trap 'rm -rf "${HOME}"' EXIT

# functions.sh defines _get_homebrew_root, etc. (_prepend_path_once and
# _append_path_once are defined in path.sh itself, sourced below.)
#shellcheck source=/dev/null
source "${BASH_CONFIG_DIR}/functions.sh"

export PATH="/usr/bin:/bin"
#shellcheck source=/dev/null
source "${BASH_CONFIG_DIR}/path.sh"

fail=0
assert_before() {
  local first="$1" second="$2"
  local first_idx second_idx idx=0
  first_idx=-1
  second_idx=-1
  IFS=':' read -ra parts <<<"${PATH}"
  for p in "${parts[@]}"; do
    [[ "${p}" == "${first}" ]] && first_idx=${idx}
    [[ "${p}" == "${second}" ]] && second_idx=${idx}
    ((idx += 1))
  done
  if [[ ${first_idx} -eq -1 || ${second_idx} -eq -1 ]]; then
    echo "FAIL: expected both '${first}' and '${second}' in PATH: ${PATH}"
    fail=1
  elif [[ ${first_idx} -ge ${second_idx} ]]; then
    echo "FAIL: expected '${first}' before '${second}' in PATH: ${PATH}"
    fail=1
  else
    echo "PASS: '${first}' before '${second}'"
  fi
}

assert_before "${HOME}/.local/bin" "${HOME}/.bun/bin"

# Homebrew-dependent assertions: this is a personal, single-machine dotfiles
# repo, but skip gracefully (instead of failing) on a machine where Homebrew
# isn't installed at all, rather than asserting on a directory that can't
# exist.
homebrew_root="$(_get_homebrew_root)"
if [[ -d "${homebrew_root}/bin" ]]; then
  assert_before "${HOME}/.bun/bin" "${homebrew_root}/bin"
  assert_before "${homebrew_root}/bin" "/usr/bin"
else
  echo "SKIP: Homebrew not installed at ${homebrew_root}; skipping Homebrew-bin ordering checks"
fi

# Structural sanity check: the tier array in path.sh always contains
# GEM_EXE_DIR as an element, which is "" whenever ruby isn't resolvable on
# the (intentionally minimal) PATH this test sources path.sh with. Confirm
# that an empty tier doesn't leak into PATH as an empty segment (leading,
# trailing, or doubled colon) -- that's the structural risk of the "always
# include GEM_EXE_DIR in the array" approach.
case ":${PATH}:" in
  *"::"*)
    echo "FAIL: PATH contains an empty segment (likely from an unset tier): ${PATH}"
    fail=1
    ;;
  *)
    echo "PASS: no empty PATH segments"
    ;;
esac

# Run path.sh in a fresh subshell with a given starting PATH, printing the
# resulting PATH. Used by the two regression checks below, each of which
# needs its own starting PATH rather than the one already built up above.
_run_with_path() {
  local starting_path="$1"
  (
    #shellcheck source=/dev/null
    source "${BASH_CONFIG_DIR}/functions.sh"
    export PATH="${starting_path}"
    #shellcheck source=/dev/null
    source "${BASH_CONFIG_DIR}/path.sh"
    printf '%s' "${PATH}"
  )
}

assert_no_stray_colons() {
  local label="$1" result_path="$2"
  local ok=1
  [[ "${result_path}" == :* ]] && ok=0
  [[ "${result_path}" == *: ]] && ok=0
  [[ "${result_path}" == *"::"* ]] && ok=0
  if [[ "${ok}" -eq 1 ]]; then
    echo "PASS: ${label} (no leading/trailing/double colon): ${result_path}"
  else
    echo "FAIL: ${label} — stray colon in PATH: ${result_path}"
    fail=1
  fi
}

# Regression: when every existing PATH entry is itself tier-managed (i.e.
# the "remainder" left after stripping tiers is fully consumed), the final
# assembly must not leave a trailing ":" — a trailing colon is read by
# bash/POSIX as "include the current directory," a PATH-injection risk.
homebrew_root="$(_get_homebrew_root)"
if [[ -d "${homebrew_root}/bin" ]]; then
  fully_consumed_path="${HOME}/.local/bin:${homebrew_root}/bin"
  result="$(_run_with_path "${fully_consumed_path}")"
  assert_no_stray_colons "fully-consumed remainder" "${result}"
else
  echo "SKIP: Homebrew not installed at ${homebrew_root}; skipping trailing-colon regression check"
fi

# Regression: a duplicate tier entry already present (twice) in the
# starting PATH must not survive as a duplicate in the result.
dup_start_path="${HOME}/.local/bin:${HOME}/.local/bin:/usr/bin"
dup_result="$(_run_with_path "${dup_start_path}")"
dup_count=0
IFS=':' read -ra dup_parts <<<"${dup_result}"
for p in "${dup_parts[@]}"; do
  [[ "${p}" == "${HOME}/.local/bin" ]] && ((dup_count += 1))
done
if [[ "${dup_count}" -eq 1 ]]; then
  echo "PASS: duplicate starting-PATH entry collapsed to one occurrence"
else
  echo "FAIL: expected exactly 1 occurrence of '${HOME}/.local/bin', found ${dup_count}: ${dup_result}"
  fail=1
fi

exit "${fail}"
