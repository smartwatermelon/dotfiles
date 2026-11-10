#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification that git/hooks/post-checkout (deployed via
# core.hooksPath) correctly delegates to git/template/hooks/post-checkout
# and fires on real git-resolved checkout events. Run directly:
# bash bash/tests/test-post-checkout-hookspath.sh
#
# Regression coverage: this machine sets a global core.hooksPath
# (~/.config/git/hooks), which makes git ignore a repo's own .git/hooks/
# entirely. `git init` only ever worked because bash/git-wrapper.sh
# resolves and execs git/template/hooks/post-checkout directly by path,
# bypassing hook resolution — but `git clone` and real branch-switch
# `git checkout` go through git's normal core.hooksPath resolution, which
# had no post-checkout entry at all, so .claude/ scaffolding silently
# never ran for those. This test proves git/hooks/post-checkout (the
# core.hooksPath delegate) exists, execs the canonical template hook with
# args passed through unchanged, and that a real `git clone` through a
# core.hooksPath-configured hooks dir triggers it end-to-end.
set -euo pipefail

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DELEGATE="${REPO_ROOT}/git/hooks/post-checkout"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/post-checkout-hookspath-test.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

# Clear inherited git repository-selection state before touching any fixture.
# A hook invoked from a linked worktree exports GIT_DIR, which outranks both the
# working directory and `git -C`, so without this the scratch repos below are
# silently redirected at the real checkout (smartwatermelon/dotfiles#239).
_tests_dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-env-isolation.sh
source "${_tests_dir}/lib/git-env-isolation.sh"
isolate_git_env "${WORKDIR}"

# Temp HOME, so the delegate's fallback can never reach the real clone.
export HOME="${WORKDIR}/home"
mkdir -p "${HOME}"

fail=0

# --- Case 1: delegate execs the canonical hook with args intact -----------
# The delegate finds the repo from its real path, so it runs from a fake
# repo copy whose canonical hook is a stub.
STUB_DIR="${WORKDIR}/stub-repo"
mkdir -p "${STUB_DIR}"
STUB_LOG="${WORKDIR}/stub.log"
FAKE_REPO="${WORKDIR}/fake-dotfiles"
mkdir -p "${FAKE_REPO}/git/hooks" "${FAKE_REPO}/git/template/hooks"
: >"${FAKE_REPO}/install.sh"
: >"${FAKE_REPO}/git/config"
STUB_CANONICAL="${FAKE_REPO}/git/template/hooks/post-checkout"
cat >"${STUB_CANONICAL}" <<EOF
#!/usr/bin/env bash
echo "\$1 \$2 \$3" > "${STUB_LOG}"
EOF
chmod +x "${STUB_CANONICAL}"

STUB_DELEGATE="${FAKE_REPO}/git/hooks/post-checkout"
cp "${DELEGATE}" "${STUB_DELEGATE}"
chmod +x "${STUB_DELEGATE}"

(cd "${STUB_DIR}" && "${STUB_DELEGATE}" \
  0000000000000000000000000000000000000000 \
  1111111111111111111111111111111111111111 \
  1)

stub_log_contents=""
[[ -f "${STUB_LOG}" ]] && stub_log_contents="$(cat "${STUB_LOG}")"
if [[ "${stub_log_contents}" == "0000000000000000000000000000000000000000 1111111111111111111111111111111111111111 1" ]]; then
  echo "PASS: delegate execs canonical hook with args passed through unchanged"
else
  echo "FAIL: delegate did not exec canonical hook with correct args"
  fail=1
fi

# --- Case 2: real `git clone` fires the delegate via core.hooksPath -------
HOOKS_DIR="${WORKDIR}/hookspath"
mkdir -p "${HOOKS_DIR}"

# The hooks-dir entry links to the fake delegate. This proves only that
# the delegate fires on a real `git clone` via core.hooksPath.
SRC="${WORKDIR}/src"
mkdir -p "${SRC}"
git -c init.templateDir="" -C "${SRC}" init -q -b main
echo "content" >"${SRC}/file.txt"
git -C "${SRC}" add file.txt
git -C "${SRC}" -c user.email=t@t.com -c user.name=t -c core.hooksPath="" commit -q -m "chore: test fixture"

DST="${WORKDIR}/dst"
MARKER_LOG="${WORKDIR}/clone-fired.log"
cat >"${STUB_CANONICAL}" <<EOF
#!/usr/bin/env bash
echo "clone fired: \$3" >> "${MARKER_LOG}"
EOF
ln -sf "${STUB_DELEGATE}" "${HOOKS_DIR}/post-checkout"

git -c core.hooksPath="${HOOKS_DIR}" clone -q "${SRC}" "${DST}" >/dev/null 2>&1

if [[ -f "${MARKER_LOG}" ]] && grep -q "clone fired: 1" "${MARKER_LOG}"; then
  echo "PASS: real git clone through core.hooksPath fires the delegate"
else
  echo "FAIL: git clone did not fire post-checkout via core.hooksPath"
  fail=1
fi

if [[ "${fail}" -eq 1 ]]; then
  echo "FAILED"
  exit 1
fi
echo "All post-checkout hookspath tests passed"
