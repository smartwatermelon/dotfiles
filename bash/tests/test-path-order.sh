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
# resulting PATH. Used by the regression checks below, each of which needs
# its own starting PATH rather than the one already built up above.
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

# Regression: re-sourcing into an already-built PATH keeps .local/bin in
# front and leaves no empty segment.
resourced_path="$(_run_with_path "${HOME}/.local/bin:/usr/bin:/bin")"
assert_no_stray_colons "re-source" "${resourced_path}"
if [[ "${resourced_path%%:*}" == "${HOME}/.local/bin" ]]; then
  echo "PASS: .local/bin leads after re-source"
else
  echo "FAIL: expected '${HOME}/.local/bin' first after re-source: ${resourced_path}"
  fail=1
fi

# Regression: GEM_EXE_DIR comes from Homebrew ruby even when a decoy system
# ruby resolves first. Each stub prints its own Gem.bindir.
fake_brew="${HOME}/fake-brew"
decoy_bin="${HOME}/decoy-bin"
brew_gem_bin="${HOME}/brew-gem-bin"
system_gem_bin="${HOME}/system-gem-bin"
mkdir -p "${fake_brew}/opt/ruby/bin" "${fake_brew}/bin" "${decoy_bin}" \
  "${brew_gem_bin}" "${system_gem_bin}"
printf '#!/bin/sh\necho "%s"\n' "${brew_gem_bin}" >"${fake_brew}/opt/ruby/bin/ruby"
printf '#!/bin/sh\necho "%s"\n' "${system_gem_bin}" >"${decoy_bin}/ruby"
chmod +x "${fake_brew}/opt/ruby/bin/ruby" "${decoy_bin}/ruby"

# A separate bash process, not a subshell: _get_homebrew_root has to be
# replaced between sourcing functions.sh and path.sh.
fake_brew_driver="${HOME}/fake-brew-driver.sh"
cat >"${fake_brew_driver}" <<'EOF'
source "${BASH_CONFIG_DIR}/functions.sh"
_get_homebrew_root() { echo "${FAKE_BREW}"; }
PATH="${START_PATH}"
source "${BASH_CONFIG_DIR}/path.sh"
printf '%s' "${PATH}"
EOF

_run_with_fake_brew() {
  FAKE_BREW="${fake_brew}" START_PATH="${decoy_bin}:/usr/bin:/bin" \
    "${BASH}" "${fake_brew_driver}"
}

gem_path="$(_run_with_fake_brew)"
if [[ ":${gem_path}:" == *":${brew_gem_bin}:"* ]]; then
  echo "PASS: Homebrew ruby's Gem.bindir is on PATH"
else
  echo "FAIL: expected Homebrew ruby's Gem.bindir '${brew_gem_bin}' in PATH: ${gem_path}"
  fail=1
fi
if [[ ":${gem_path}:" == *":${system_gem_bin}:"* ]]; then
  echo "FAIL: system ruby's Gem.bindir '${system_gem_bin}' leaked into PATH: ${gem_path}"
  fail=1
else
  echo "PASS: system ruby's Gem.bindir kept off PATH"
fi

# Without Homebrew ruby, the decoy system ruby still must not set a tier.
rm "${fake_brew}/opt/ruby/bin/ruby"
gem_path="$(_run_with_fake_brew)"
if [[ ":${gem_path}:" == *":${system_gem_bin}:"* ]]; then
  echo "FAIL: system ruby's Gem.bindir used when Homebrew ruby is absent: ${gem_path}"
  fail=1
else
  echo "PASS: no gem tier when Homebrew ruby is absent"
fi

exit "${fail}"
