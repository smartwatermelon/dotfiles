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

# functions.sh defines _get_homebrew_root, _prepend_path_once, etc.
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

exit "${fail}"
