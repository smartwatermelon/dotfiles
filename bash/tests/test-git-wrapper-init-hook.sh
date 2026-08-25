#!/usr/bin/env bash
# shellcheck shell=bash
# Standalone verification for bash/git-wrapper.sh's post-init hook trigger.
# Run directly: bash bash/tests/test-git-wrapper-init-hook.sh
#
# Regression coverage for the git()->git-wrapper.sh extraction: git init
# (bare, with a trailing directory arg, and with git's global -C flag) must
# still invoke the newly-created repo's post-checkout hook with null-SHA init
# parameters.
# Note: -C is git's global pre-subcommand flag (`git -C <dir> init`), not an
# init-specific flag. The wrapper's target_dir resolution logic handles this
# and is tested below in Case 3.
set -euo pipefail

unset CDPATH

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export BASH_CONFIG_DIR="${REPO_ROOT}/bash"

WORKDIR="/tmp/git-wrapper-init-hook-test-$$"
mkdir -p "${WORKDIR}"
trap 'rm -rf "${WORKDIR}"' EXIT

# Clear inherited git repository-selection state before touching any fixture.
# A hook invoked from a linked worktree exports GIT_DIR, which outranks both the
# working directory and `git -C`, so without this the scratch repos below are
# silently redirected at the real checkout (smartwatermelon/dotfiles#239).
_tests_dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-env-isolation.sh
source "${_tests_dir}/lib/git-env-isolation.sh"
isolate_git_env "${WORKDIR}"

# Reset the wrapper guard to ensure clean test environment
unset _GIT_WRAPPER_ACTIVE
# Isolate test repos from any ambient git context
# GIT_CEILING_DIRECTORIES is set by isolate_git_env above, which receives
# WORKDIR as its ceiling argument.

# Disable the global init.templateDir for every `git init` this test runs.
# On a machine with init.templateDir configured (this repo's own install.sh
# sets it to ~/.config/git/template), git's template-copy step preserves
# symlinks rather than dereferencing them — and ~/.config/git/template's own
# hooks/post-checkout is a symlink straight into this repo's
# git/template/hooks/post-checkout. Without this override, `command git
# init` below would populate each scratch repo's .git/hooks/post-checkout
# as a symlink to the real file, and install_hook()'s `cat >` would then
# write through that symlink and clobber the real repo file instead of the
# scratch fixture. Confirmed by direct reproduction: prior to this fix,
# every run of this test corrupted git/template/hooks/post-checkout.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="init.templateDir"
export GIT_CONFIG_VALUE_0=""

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

# Case 3: `git -C <dir> init <name>` (git's global -C flag before subcommand)
# This exercises the wrapper's c_flag_dir-only branch of target_dir resolution.
repo3_parent="${WORKDIR}/parent3"
repo3_name="repo3"
repo3="${repo3_parent}/${repo3_name}"
mkdir -p "${repo3_parent}"
(cd "${repo3_parent}" && command git init -q "${repo3_name}")
install_hook "${repo3}"
(cd "${repo3_parent}" && git -C "${repo3_name}" init -q)
assert_hook_ran "git -C <dir> init triggers post-checkout hook" "${repo3}"

if [[ "${fail}" -eq 1 ]]; then
  echo "FAILED"
  exit 1
fi
echo "All git-wrapper tests passed"
