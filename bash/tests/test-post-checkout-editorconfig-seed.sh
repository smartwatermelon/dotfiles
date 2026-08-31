#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification that git/template/hooks/post-checkout seeds
# .editorconfig into a newly initialized repo -- and only there.
# Run directly: bash bash/tests/test-post-checkout-editorconfig-seed.sh
#
# lint-shell.sh auto-formats only when a repo states a preference via
# .editorconfig; without one it reports drift and writes nothing
# (smartwatermelon/dotfiles#290). Seeding at init gives a new repo that stated
# preference up front.
#
# The hook fires on `git clone` as well as on the init call synthesized by
# bash/git-wrapper.sh, and BOTH arrive with a null _prev_head -- so the hook
# parameters cannot tell them apart. The discriminator is the origin remote,
# present on a clone and absent on a fresh init. Commit count does NOT work:
# at hook time both report an empty `rev-list --all`. Seeding a clone would
# push a personal style into someone else's repo, so the clone case is a
# correctness requirement, not a nicety.
set -uo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${REPO_ROOT}/git/template/hooks/post-checkout"
SEED="${REPO_ROOT}/git/template/.editorconfig"

fail=0

_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT

# The hook walks upward to / looking for an .editorconfig and defers to any it
# finds. A stray one above the tmpdir would make every "did it seed?" case
# silently test the skip path instead. Verify, don't assume.
_probe="${TMPROOT}"
_stray=""
while true; do
  [[ -f "${_probe}/.editorconfig" ]] && _stray="${_probe}/.editorconfig"
  [[ "${_probe}" == "/" ]] && break
  _probe="$(dirname "${_probe}")"
done
if [[ -n "${_stray}" ]]; then
  echo "SKIP: a stray .editorconfig above the tmpdir (${_stray}) would void these cases"
  exit 0
fi

# Drive the hook the way git and git-wrapper.sh do: null prev SHA,
# branch_checkout=1. TEMPLATE_DIR is where the hook resolves its seed source,
# so point init.templateDir at the repo's real template directory.
_run_hook() {
  local dir="$1"
  (
    cd "${dir}" 2>/dev/null || exit 0
    git config --local init.templateDir "${REPO_ROOT}/git/template" >/dev/null 2>&1
    bash "${HOOK}" \
      0000000000000000000000000000000000000000 \
      0000000000000000000000000000000000000000 \
      1 >/dev/null 2>&1
  )
}

# ---------------------------------------------------------------
# Case 0: the seed source ships with the template
# ---------------------------------------------------------------
echo "Case: the template carries an .editorconfig to copy"

if [[ -f "${SEED}" ]]; then
  _pass "git/template/.editorconfig exists"
else
  _fail "no git/template/.editorconfig; the hook has nothing to copy"
fi

# It must be a real file. A symlink would make the hook's cp follow into a
# checkout path that is not guaranteed to exist on another machine.
if [[ -L "${SEED}" ]]; then
  _fail "the seed is a symlink; it must be a regular file"
else
  _pass "the seed is a regular file"
fi

# Duplicated content drifts. This repo's own .editorconfig is the thing being
# handed to new repos, so the two must not diverge.
if diff -q "${REPO_ROOT}/.editorconfig" "${SEED}" >/dev/null 2>&1; then
  _pass "the seed matches this repo's own .editorconfig"
else
  _fail "git/template/.editorconfig has drifted from the root .editorconfig"
fi

# ---------------------------------------------------------------
# Case 1: git init -> seeded
# ---------------------------------------------------------------
echo "Case: a freshly initialized repo is seeded"

d1="${TMPROOT}/fresh"
git init -q "${d1}" >/dev/null 2>&1
_run_hook "${d1}"

if [[ -f "${d1}/.editorconfig" ]]; then
  _pass "a new repo received an .editorconfig"
  if [[ -L "${d1}/.editorconfig" ]]; then
    _fail "it was symlinked; a committed symlink into \$HOME breaks for others"
  else
    _pass "it was copied, not symlinked"
  fi
  if diff -q "${SEED}" "${d1}/.editorconfig" >/dev/null 2>&1; then
    _pass "the copy matches the template"
  else
    _fail "the seeded file does not match the template"
  fi
else
  _fail "a new repo was not seeded"
fi

# The whole point: the seeded file must actually state a shell style, so
# lint-shell.sh auto-formats there instead of only advising.
if grep -q 'binary_next_line' "${d1}/.editorconfig" 2>/dev/null; then
  _pass "the seeded config states a shell style"
else
  _fail "the seeded config states no shell style"
fi

# ---------------------------------------------------------------
# Case 1b: seeding is not gated on .claude/ being absent
# ---------------------------------------------------------------
# The hook exits early when .claude/ already exists, to avoid clobbering
# existing infrastructure. Seeding placed after that guard never runs for the
# many repos that already have .claude/ -- which is most of them, since Claude
# Code creates it. The two concerns are independent and must stay that way.
echo "Case: a repo that already has .claude/ is still seeded"

d1b="${TMPROOT}/has-claude"
git init -q "${d1b}" >/dev/null 2>&1
mkdir -p "${d1b}/.claude"
_run_hook "${d1b}"

if [[ -f "${d1b}/.editorconfig" ]]; then
  _pass "seeded despite an existing .claude/"
else
  _fail "the .claude/ early exit swallowed .editorconfig seeding"
fi

# ---------------------------------------------------------------
# Case 2: git clone -> NOT seeded
# ---------------------------------------------------------------
echo "Case: a clone of someone else's repo is left alone"

origin="${TMPROOT}/origin"
git init -q --initial-branch=main "${origin}" >/dev/null 2>&1
printf 'hi\n' >"${origin}/f.txt"
git -C "${origin}" add f.txt >/dev/null 2>&1
git -C "${origin}" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1

d2="${TMPROOT}/cloned"
git clone -q "${origin}" "${d2}" >/dev/null 2>&1
_run_hook "${d2}"

if [[ -f "${d2}/.editorconfig" ]]; then
  _fail "a clone was seeded; this imposes a personal style on another project"
else
  _pass "a clone was not seeded"
fi

# ---------------------------------------------------------------
# Case 3: an existing .editorconfig is never overwritten
# ---------------------------------------------------------------
echo "Case: an existing .editorconfig wins"

d3="${TMPROOT}/existing"
git init -q "${d3}" >/dev/null 2>&1
printf 'root = true\n[*.sh]\nindent_size = 4\n' >"${d3}/.editorconfig"
_run_hook "${d3}"

if grep -q 'indent_size = 4' "${d3}/.editorconfig" 2>/dev/null; then
  _pass "the repo's own .editorconfig was left untouched"
else
  _fail "the hook overwrote an existing .editorconfig"
fi

# ---------------------------------------------------------------
# Case 4: an .editorconfig in a PARENT directory also wins
# ---------------------------------------------------------------
# shfmt searches upward, so a parent's config already answers for this repo.
# Adding a second one would silently change how the parent's files are treated.
echo "Case: an .editorconfig above the repo is respected"

parent="${TMPROOT}/parent"
mkdir -p "${parent}"
printf 'root = true\n[*.sh]\nindent_size = 8\n' >"${parent}/.editorconfig"
d4="${parent}/child"
git init -q "${d4}" >/dev/null 2>&1
_run_hook "${d4}"

if [[ -f "${d4}/.editorconfig" ]]; then
  _fail "seeded despite a parent .editorconfig already in scope"
else
  _pass "deferred to the parent directory's .editorconfig"
fi

echo
if [[ ${fail} -eq 0 ]]; then
  echo "PASS: .editorconfig is seeded on init only"
else
  echo "FAIL: see above" >&2
fi
exit "${fail}"
