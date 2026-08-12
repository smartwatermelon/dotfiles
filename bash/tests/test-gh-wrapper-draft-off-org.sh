#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification for bash/gh-wrapper.sh's off-org draft-forcing.
# Run directly: bash bash/tests/test-gh-wrapper-draft-off-org.sh
#
# Coverage for smartwatermelon/dotfiles#174: `gh pr create` targeting a repo
# outside smartwatermelon/nightowlstudiollc must have --draft injected into
# the argument list, unconditionally, with no way for the caller to opt out.
set -euo pipefail

unset CDPATH

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export BASH_CONFIG_DIR="${REPO_ROOT}/bash"

# Sourcing (not executing) the file puts it in function-definition mode,
# where _gh_wrapper_force_draft_for_off_org is defined but gh() itself is
# not invoked.
#shellcheck source=/dev/null
source "${BASH_CONFIG_DIR}/gh-wrapper.sh"

fail=0

assert_args() {
  local label="$1"
  shift
  local expected_has_draft="$1"
  shift
  local -a got=()
  local out
  out="$(_gh_wrapper_force_draft_for_off_org "$@")"
  mapfile -t got <<<"${out}"

  local has_draft=0 a
  for a in "${got[@]}"; do
    [[ "${a}" == "--draft" ]] && has_draft=1
  done

  if [[ "${has_draft}" == "${expected_has_draft}" ]]; then
    echo "PASS: ${label}"
  else
    echo "FAIL: ${label} — expected --draft present=${expected_has_draft}, got=${has_draft} (args: ${got[*]})"
    fail=1
  fi
}

# In-org, explicit -R: no draft forced.
assert_args "in-org explicit --repo" 0 pr create --repo smartwatermelon/dotfiles --title x

# Off-org, explicit --repo=: draft forced.
assert_args "off-org explicit --repo=" 1 pr create --repo=someoutsideorg/foo --title x

# nightowlstudiollc counts as in-org: no draft forced.
assert_args "nightowlstudiollc explicit -R" 0 pr create -R nightowlstudiollc/somerepo --title x

# Case-insensitive owner match, mirroring _gh_wrapper_sync_identity's
# regression coverage for smartwatermelon/dotfiles#159.
assert_args "mixed-case in-org owner" 0 pr create --repo SmartWatermelon/dotfiles --title x

# Not `pr create`: unaffected regardless of owner.
assert_args "gh issue create off-org (unaffected)" 0 issue create --repo someoutsideorg/foo --title x
assert_args "gh pr merge off-org (unaffected)" 0 pr merge 5 --repo someoutsideorg/foo

# --help on an off-org pr create: the caller (standalone/function-mode entry
# points) skips calling this function at all for --help requests, but the
# function itself must still not misbehave if invoked directly.
assert_args "off-org pr create --help (function itself is harmless)" 1 pr create --repo someoutsideorg/foo --help

# Caller already passed --draft explicitly: harmless, still present exactly
# once more isn't required to be deduped, just confirm it's present.
assert_args "off-org pr create with explicit --draft already present" 1 pr create --repo someoutsideorg/foo --draft --title x

# Zero args: must not error and must not fabricate an argument.
out="$(_gh_wrapper_force_draft_for_off_org)"
mapfile -t zero_args <<<"${out}"
if [[ "${#zero_args[@]}" == "1" && -z "${zero_args[0]}" ]]; then
  echo "PASS: zero-arg call produces a single empty line (caller guards against rebuilding \$@ from this)"
else
  echo "FAIL: zero-arg call produced unexpected output: ${zero_args[*]}"
  fail=1
fi

# cwd-remote fallback: no explicit -R/--repo, owner resolved from `origin`.
off_org_clone="/tmp/gh-wrapper-draft-test-off-org-$$"
in_org_clone="/tmp/gh-wrapper-draft-test-in-org-$$"
mkdir -p "${off_org_clone}" "${in_org_clone}"
trap 'rm -rf "${off_org_clone}" "${in_org_clone}"' EXIT
(cd "${off_org_clone}" && command git init -q && command git remote add origin git@github.com:someoutsideorg/foo.git)
(cd "${in_org_clone}" && command git init -q && command git remote add origin git@github.com:smartwatermelon/dotfiles.git)

cwd_fail_file="/tmp/gh-wrapper-draft-test-cwd-fail-$$"
rm -f "${cwd_fail_file}"
(
  cd "${off_org_clone}"
  assert_args "off-org cwd remote fallback" 1 pr create --title x
  if [[ "${fail}" == "1" ]]; then touch "${cwd_fail_file}"; fi
)
(
  cd "${in_org_clone}"
  assert_args "in-org cwd remote fallback" 0 pr create --title x
  if [[ "${fail}" == "1" ]]; then touch "${cwd_fail_file}"; fi
)
if [[ -f "${cwd_fail_file}" ]]; then
  fail=1
fi
rm -f "${cwd_fail_file}"

exit "${fail}"
