#!/usr/bin/env bash
# shellcheck shell=bash
# Standalone verification for bash/git-wrapper.sh's post-init hook trigger.
# Run directly: bash bash/tests/test-git-wrapper-init-hook.sh
#
# Regression coverage for the git()->git-wrapper.sh extraction: git init
# (bare and with a trailing directory arg) must still invoke the
# newly-created repo's post-checkout hook with null-SHA init parameters.
# Note: -C flag support is included in the wrapper for future git versions;
# current git versions don't support `git init -C`.
set -euo pipefail

unset CDPATH

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export BASH_CONFIG_DIR="${REPO_ROOT}/bash"

WORKDIR="/tmp/git-wrapper-init-hook-test-$$"
mkdir -p "${WORKDIR}"
trap 'rm -rf "${WORKDIR}"' EXIT

# Reset the wrapper guard to ensure clean test environment
unset _GIT_WRAPPER_ACTIVE
# Isolate test repos from any ambient git context
export GIT_CEILING_DIRECTORIES="${WORKDIR}"

#shellcheck source=/dev/null
source "${BASH_CONFIG_DIR}/git-wrapper.sh"

fail=0

assert_hook_ran() {
  local desc="$1" repo_dir="$2"
  local marker="${repo_dir}/.git/post-checkout-ran"
  if [[ -f "${marker}" ]]; then
    echo "PASS: ${desc}"
  else
    echo "FAIL: ${desc} — expected ${marker} to exist"
    fail=1
  fi
}

install_hook() {
  local repo_dir="$1"
  mkdir -p "${repo_dir}/.git/hooks"
  cat >"${repo_dir}/.git/hooks/post-checkout" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "0000000000000000000000000000000000000000" ]] || exit 1
[[ "$2" == "0000000000000000000000000000000000000000" ]] || exit 1
[[ "$3" == "1" ]] || exit 1
touch "$(dirname "$0")/../post-checkout-ran"
EOF
  chmod +x "${repo_dir}/.git/hooks/post-checkout"
}

# Case 1: bare `git init` in the target directory (hook doesn't exist yet
# at init time, so we init first, then install the hook, then re-run init
# — git init is idempotent on an existing repo and still triggers our
# wrapper's post-init detection).
repo1="${WORKDIR}/repo1"
mkdir -p "${repo1}"
(cd "${repo1}" && command git init -q)
install_hook "${repo1}"
(cd "${repo1}" && git init -q)
assert_hook_ran "bare git init re-run triggers post-checkout hook" "${repo1}"

# Case 2: `git init <dir>` (directory argument form)
repo2="${WORKDIR}/repo2"
(cd "${WORKDIR}" && command git init -q repo2)
install_hook "${repo2}"
(cd "${WORKDIR}" && git init -q repo2)
assert_hook_ran "git init <dir> triggers post-checkout hook" "${repo2}"

if [[ "${fail}" -eq 1 ]]; then
  echo "FAILED"
  exit 1
fi
echo "All git-wrapper tests passed"
