#!/usr/bin/env bash
#shellcheck shell=bash
# Real-path clone lookup: install.sh, both hooks, _dotfiles_dir.
# Temp HOME only; install.sh runs as --sync --dry-run.
set -euo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/git-env-isolation.sh
source "${REPO_ROOT}/bash/tests/lib/git-env-isolation.sh"

fail=0
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-real-path-test.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT
isolate_git_env "${WORKDIR}"
unset CODEX_THREAD_ID CODEX_SESSION_ID

check() {
  if [[ "$2" == "$3" ]]; then
    echo "  PASS: $1"
  else
    echo "  FAIL: $1 — expected [$2], got [$3]"
    fail=1
  fi
}

# Clone at internal/dotfiles; ~/Developer links to internal/, so
# ~/Developer/dotfiles resolves only through that symlink.
export HOME="${WORKDIR}/home"
mkdir -p "${HOME}" "${WORKDIR}/internal"
ln -s "${WORKDIR}/internal" "${HOME}/Developer"
VIA_LINK="${HOME}/Developer/dotfiles"
REAL="${WORKDIR}/internal/dotfiles"
mkdir -p "${REAL}/bash" "${REAL}/git/hooks" "${REAL}/git/template/hooks"
# TMPDIR itself sits under a symlink (/var -> /private/var) on macOS, so
# compare against the fully resolved path.
REAL_P="$(cd "${REAL}" && pwd -P)"

cp "${REPO_ROOT}/install.sh" "${REAL}/install.sh"
cp "${REPO_ROOT}/git/hooks/lib-symlink-exclusions.sh" "${REAL}/git/hooks/"
cp "${REPO_ROOT}/git/hooks/pre-commit" "${REAL}/git/hooks/pre-commit"
cp "${REPO_ROOT}/git/hooks/post-checkout" "${REAL}/git/hooks/post-checkout"
: >"${REAL}/git/config"
: >"${REAL}/bash/main.sh"
: >"${REAL}/bash/.bash_profile"

# The canonical post-checkout hook, stubbed to log the path it ran from.
HOOK_LOG="${WORKDIR}/hook.log"
stub_canonical() {
  mkdir -p "$1/git/template/hooks"
  cat >"$1/git/template/hooks/post-checkout" <<EOF
#!/usr/bin/env bash
echo "\$0" >"${HOOK_LOG}"
EOF
  chmod +x "$1/git/template/hooks/post-checkout"
}
stub_canonical "${REAL}"

fgit() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"; }
fgit init -q --template= -b main "${REAL}"
fgit -C "${REAL}" add install.sh git/config bash/main.sh bash/.bash_profile \
  git/hooks/lib-symlink-exclusions.sh

# ---------------------------------------------------------------
echo "Case: install.sh run through a symlinked parent links to the real path"
rc=0
out="$("${VIA_LINK}/install.sh" --sync --dry-run 2>&1)" || rc=$?
check "install.sh --sync --dry-run status" "0" "${rc}"
want="Would symlink: ${HOME}/.config/bash/main.sh -> ${REAL_P}/bash/main.sh"
if [[ "${out}" == *"${want}"* ]]; then
  echo "  PASS: link target is the physical repo path"
else
  echo "  FAIL: link target is not the physical repo path — [${want}] not in [${out}]"
  fail=1
fi
# No link target may go through the symlinked ~/Developer.
if grep -q -- "-> ${HOME}/Developer/" <<<"${out}"; then
  echo "  FAIL: a link target goes through the symlinked ${HOME}/Developer"
  fail=1
else
  echo "  PASS: no link target goes through the symlinked parent"
fi

# ---------------------------------------------------------------
# Deployed hooks link via the symlinked ~/Developer (the old link form),
# so resolution crosses both links.
DEPLOYED="${HOME}/.config/git/hooks"
mkdir -p "${DEPLOYED}"
NOT_A_REPO="${WORKDIR}/not-a-repo"
mkdir -p "${NOT_A_REPO}"

# Stub repair lib: logs the exported REPO_DIR, then exits before the
# pre-commit framework runs.
REPO_DIR_LOG="${WORKDIR}/repo-dir.log"
cat >"${DEPLOYED}/lib-symlink-repair.sh" <<EOF
echo "\${REPO_DIR}" >"${REPO_DIR_LOG}"
exit 0
EOF

run_hook() {
  rm -f "${HOOK_LOG}" "${REPO_DIR_LOG}"
  (cd "${NOT_A_REPO}" && "$@" >/dev/null 2>&1) || true
}
logged() { cat "$1" 2>/dev/null || echo "<nothing>"; }

echo "Case: hooks resolve REPO_DIR through the symlinks to the real clone"
ln -s "${VIA_LINK}/git/hooks/post-checkout" "${DEPLOYED}/post-checkout"
ln -s "${VIA_LINK}/git/hooks/pre-commit" "${DEPLOYED}/pre-commit"
run_hook "${DEPLOYED}/post-checkout" 0 1 1
got="$(logged "${HOOK_LOG}")"
check "post-checkout execs the real clone's canonical hook" \
  "${REAL_P}/git/template/hooks/post-checkout" "${got}"
run_hook "${DEPLOYED}/pre-commit"
got="$(logged "${REPO_DIR_LOG}")"
check "pre-commit exports the real clone as REPO_DIR" "${REAL_P}" "${got}"

echo "Case: hooks fall back to ~/Developer/dotfiles outside a repo layout"
# A plain copy (no link) resolves to ~/.config/git/hooks/<hook>, whose
# grandparent is not the dotfiles repo.
rm "${DEPLOYED}/post-checkout" "${DEPLOYED}/pre-commit"
cp "${REPO_ROOT}/git/hooks/post-checkout" "${REPO_ROOT}/git/hooks/pre-commit" "${DEPLOYED}/"
# The fallback reaches the same clone through the symlink, so the logged path
# is the unresolved one.
run_hook "${DEPLOYED}/post-checkout" 0 1 1
got="$(logged "${HOOK_LOG}")"
check "post-checkout falls back" \
  "${HOME}/Developer/dotfiles/git/template/hooks/post-checkout" "${got}"
run_hook "${DEPLOYED}/pre-commit"
got="$(logged "${REPO_DIR_LOG}")"
check "pre-commit falls back" "${HOME}/Developer/dotfiles" "${got}"

echo "Case: hooks fall back when the resolved layout lacks install.sh"
FAKE="${WORKDIR}/no-install/repo"
mkdir -p "${FAKE}/git/hooks"
: >"${FAKE}/git/config"
cp "${REPO_ROOT}/git/hooks/pre-commit" "${FAKE}/git/hooks/pre-commit"
stub_canonical "${FAKE}"
cp "${REPO_ROOT}/git/hooks/post-checkout" "${FAKE}/git/hooks/post-checkout"
ln -sf "${FAKE}/git/hooks/pre-commit" "${DEPLOYED}/pre-commit"
ln -sf "${FAKE}/git/hooks/post-checkout" "${DEPLOYED}/post-checkout"
run_hook "${DEPLOYED}/post-checkout" 0 1 1
got="$(logged "${HOOK_LOG}")"
check "post-checkout falls back" \
  "${HOME}/Developer/dotfiles/git/template/hooks/post-checkout" "${got}"
run_hook "${DEPLOYED}/pre-commit"
got="$(logged "${REPO_DIR_LOG}")"
check "pre-commit falls back" "${HOME}/Developer/dotfiles" "${got}"

# ---------------------------------------------------------------
# Extract the helper through bash's own parser, as the allup tests do.
_fn_src="$(bash --norc --noprofile -c '
  source "$1" >/dev/null 2>&1 || exit 1
  declare -f _dotfiles_dir
' _ "${REPO_ROOT}/bash/functions.sh")" || true
if [[ "${_fn_src}" != *"_dotfiles_dir ()"* ]]; then
  echo "FAIL: could not extract _dotfiles_dir from functions.sh" >&2
  exit 1
fi
eval "${_fn_src}"

PROFILE="${HOME}/.config/bash/.bash_profile"
mkdir -p "${HOME}/.config/bash"

echo "Case: _dotfiles_dir resolves the deployed .bash_profile link"
ln -s "${VIA_LINK}/bash/.bash_profile" "${PROFILE}"
got="$(_dotfiles_dir)"
check "real clone path" "${REAL_P}" "${got}"

echo "Case: _dotfiles_dir falls back without a valid link"
rm "${PROFILE}"
got="$(_dotfiles_dir)"
check "no .bash_profile link" "${HOME}/Developer/dotfiles" "${got}"
mkdir -p "${WORKDIR}/no-install/repo/bash"
: >"${WORKDIR}/no-install/repo/bash/.bash_profile"
ln -s "${WORKDIR}/no-install/repo/bash/.bash_profile" "${PROFILE}"
got="$(_dotfiles_dir)"
check "link into a dir without install.sh" "${HOME}/Developer/dotfiles" "${got}"

# ---------------------------------------------------------------
# Other hosts keep the clone in a real ~/Developer/dotfiles directory. There
# every derivation must give exactly the old hardcoded path.
echo "Case: a real ~/Developer/dotfiles directory gives the old path everywhere"
HOME="$(cd "${WORKDIR}" && pwd -P)/plain-home"
export HOME
PLAIN="${HOME}/Developer/dotfiles"
mkdir -p "${PLAIN}/bash" "${PLAIN}/git/hooks" "${HOME}/.config/bash" "${HOME}/.config/git/hooks"
cp "${REPO_ROOT}/install.sh" "${PLAIN}/install.sh"
cp "${REPO_ROOT}/git/hooks/lib-symlink-exclusions.sh" "${PLAIN}/git/hooks/"
cp "${REPO_ROOT}/git/hooks/pre-commit" "${REPO_ROOT}/git/hooks/post-checkout" "${PLAIN}/git/hooks/"
: >"${PLAIN}/git/config"
: >"${PLAIN}/bash/main.sh"
: >"${PLAIN}/bash/.bash_profile"
stub_canonical "${PLAIN}"
fgit init -q --template= -b main "${PLAIN}"
fgit -C "${PLAIN}" add install.sh git/config bash/main.sh git/hooks/lib-symlink-exclusions.sh
ln -s "${PLAIN}/bash/.bash_profile" "${HOME}/.config/bash/.bash_profile"
ln -s "${PLAIN}/git/hooks/post-checkout" "${HOME}/.config/git/hooks/post-checkout"
ln -s "${PLAIN}/git/hooks/pre-commit" "${HOME}/.config/git/hooks/pre-commit"
cp "${DEPLOYED}/lib-symlink-repair.sh" "${HOME}/.config/git/hooks/"

rc=0
out="$("${PLAIN}/install.sh" --sync --dry-run 2>&1)" || rc=$?
check "install.sh --sync --dry-run status" "0" "${rc}"
want="Would symlink: ${HOME}/.config/bash/main.sh -> ${PLAIN}/bash/main.sh"
if [[ "${out}" == *"${want}"* ]]; then
  echo "  PASS: install.sh link target unchanged"
else
  echo "  FAIL: install.sh link target changed — [${want}] not in [${out}]"
  fail=1
fi
got="$(_dotfiles_dir)"
check "_dotfiles_dir unchanged" "${PLAIN}" "${got}"
run_hook "${HOME}/.config/git/hooks/post-checkout" 0 1 1
got="$(logged "${HOOK_LOG}")"
check "post-checkout unchanged" "${PLAIN}/git/template/hooks/post-checkout" "${got}"
run_hook "${HOME}/.config/git/hooks/pre-commit"
got="$(logged "${REPO_DIR_LOG}")"
check "pre-commit unchanged" "${PLAIN}" "${got}"

echo ""
if [[ "${fail}" -eq 0 ]]; then
  echo "ALL CHECKS PASSED"
else
  echo "SOME CHECKS FAILED"
fi
exit "${fail}"
