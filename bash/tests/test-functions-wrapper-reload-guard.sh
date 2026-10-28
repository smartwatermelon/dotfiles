#!/usr/bin/env bash
#shellcheck shell=bash
# functions.sh skips re-sourcing inherited, unchanged wrappers; a source
# appends git/gh to a log. Run: bash <this file>
set -euo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${REPO_ROOT}/bash"

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

for f in functions.sh git-wrapper.sh gh-wrapper.sh gpush-wrapper.sh; do
  if [[ ! -f "${SRC}/${f}" ]]; then
    echo "FAIL: ${SRC}/${f} not found" >&2
    exit 1
  fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
LOG="${WORK}/source.log"

# make_home <dir>: .config/bash with marked copies of both wrappers.
make_home() {
  local h="$1"
  mkdir -p "${h}/.config/bash"
  ln -s "${SRC}/functions.sh" "${h}/.config/bash/functions.sh"
  ln -s "${SRC}/gpush-wrapper.sh" "${h}/.config/bash/gpush-wrapper.sh"
  {
    cat "${SRC}/git-wrapper.sh"
    cat <<'MARK_EOF'
printf "git\n" >>"${_GUARD_TEST_LOG}"
MARK_EOF
  } >"${h}/.config/bash/git-wrapper.sh"
  {
    cat "${SRC}/gh-wrapper.sh"
    cat <<'MARK_EOF'
printf "gh\n" >>"${_GUARD_TEST_LOG}"
MARK_EOF
  } >"${h}/.config/bash/gh-wrapper.sh"
}

H="${WORK}/home"
H2="${WORK}/home2"
# Built before any stamp: only the -ef check makes HOME=home2 source.
make_home "${H2}"
make_home "${H}"

# Stub gh. #!${BASH}: PATH bash 3.2 always re-sources git-wrapper.sh.
STUB_DIR="${WORK}/stub-bin"
STUB_LOG="${WORK}/stub.log"
mkdir -p "${STUB_DIR}"
cat >"${STUB_DIR}/gh" <<STUB_EOF
#!${BASH}
[[ "\$1 \$2" == "auth token" ]] && { echo keyring-fixture; exit 0; }
printf '%s\n' "\$*" >>"${STUB_LOG}"
exit 0
STUB_EOF
chmod +x "${STUB_DIR}/gh"

CHILD_PATH="${STUB_DIR}:/usr/bin:/bin"
FN="${H}/.config/bash/functions.sh"

# Interactive parent: source, clear the log, run the child via BASH_ENV.
PARENT="${WORK}/parent.sh"
cat >"${PARENT}" <<'PARENT_EOF'
source "${FN}" >/dev/null 2>&1
: >"${_GUARD_TEST_LOG}"
BASH_ENV="${FN}" "${BASH}" --norc --noprofile "${CHILD}"
PARENT_EOF

# log_words <file>: the file's lines joined by single spaces.
log_words() {
  local w out=""
  while IFS= read -r w; do
    out+="${out:+ }${w}"
  done <"$1"
  printf '%s' "${out}"
}

# parent [env...] <<<script: prints "<source log>|<child stdout>".
parent() {
  local child="${WORK}/child.sh" out
  cat >"${child}"
  : >"${LOG}"
  out=$(env -i HOME="${H}" PATH="${CHILD_PATH}" TMPDIR="${WORK}" \
    XDG_STATE_HOME="${WORK}/state" _GUARD_TEST_LOG="${LOG}" \
    BEACON_WORKDIR="${WORK}/no-beacon" FN="${FN}" CHILD="${child}" H2="${H2}" "$@" \
    "${BASH}" --norc --noprofile -i "${PARENT}" 2>/dev/null) || true
  local logged
  logged="$(log_words "${LOG}")"
  printf '%s|%s' "${logged}" "${out}"
}

echo "Case: the interactive parent writes a stamp"
parent >/dev/null <<<'true'
stamps=0
for _s in "${WORK}/state/dotfiles/wrapper-stamps"/*; do
  [[ -f "${_s}" ]] && stamps=$((stamps + 1))
done
check "one stamp file" "1" "${stamps}"

echo "Case: non-interactive child with inherited exports and a fresh stamp skips both"
got=$(
  parent <<'EOF'
declare -F gh git _gh_wrapper_find_real_gh _git_wrapper_restore_dir >/dev/null && echo present
EOF
)
check "nothing re-sourced, functions present" "|present" "${got}"

echo "Case: the skip is errexit- and nounset-safe"
got=$(
  parent <<'EOF'
set -eu
source "${FN}"
echo ok
EOF
)
check "explicit re-source under set -eu skips cleanly" "|ok" "${got}"

echo "Case: clean environment (env -i) sources both"
: >"${LOG}"
env -i HOME="${H}" PATH="${CHILD_PATH}" XDG_STATE_HOME="${WORK}/state-clean" \
  _GUARD_TEST_LOG="${LOG}" BASH_ENV="${FN}" "${BASH}" --norc --noprofile -c 'true' 2>/dev/null || true
logged="$(log_words "${LOG}")"
check "git and gh sourced" "git gh" "${logged}"
if [[ -e "${WORK}/state-clean" ]]; then
  check "a non-interactive sourcer writes no stamp" "absent" "present"
else
  check "a non-interactive sourcer writes no stamp" "absent" "absent"
fi

echo "Case: interactive child with inherited exports sources both"
# Interactive shells ignore BASH_ENV; main.sh sources functions.sh in them.
got=$(
  parent <<'EOF'
"${BASH}" --norc --noprofile -i -c 'source "${FN}"' >/dev/null 2>&1
echo done
EOF
)
check "interactive shells always source" "git gh|done" "${got}"

echo "Case: a wrapper newer than the stamp is re-sourced"
got=$(
  parent <<'EOF'
touch "${HOME}/.config/bash/gh-wrapper.sh"
"${BASH}" --norc --noprofile -c true
EOF
)
check "only the changed wrapper is sourced" "gh|" "${got}"

echo "Case: stamp missing"
got=$(
  parent <<'EOF'
_BASH_WRAPPER_STAMP="${HOME}/no-such-stamp" "${BASH}" --norc --noprofile -c true
EOF
)
check "missing stamp sources both" "git gh|" "${got}"

echo "Case: stamp rewritten by another shell (ID mismatch)"
got=$(
  parent <<'EOF'
_BASH_WRAPPER_STAMP_ID=someone-else "${BASH}" --norc --noprofile -c true
EOF
)
check "foreign ID sources both" "git gh|" "${got}"

echo "Case: stamp cannot be written"
# A state dir below a regular file cannot be created.
: >"${WORK}/not-a-dir"
got=$(
  parent XDG_STATE_HOME="${WORK}/not-a-dir/state" <<'EOF'
echo "${_BASH_WRAPPER_STAMP:-unset}"
EOF
)
check "no stamp exported, both sourced" "git gh|unset" "${got}"

echo "Case: a missing helper forces a source"
got=$(
  parent <<'EOF'
env -u 'BASH_FUNC__gh_wrapper_find_real_gh%%' "${BASH}" --norc --noprofile -c true
EOF
)
check "gh sourced, git skipped" "gh|" "${got}"
got=$(
  parent <<'EOF'
env -u 'BASH_FUNC__git_wrapper_restore_dir%%' "${BASH}" --norc --noprofile -c true
EOF
)
check "git sourced, gh skipped" "git|" "${got}"

echo "Case: a different HOME with older files of its own sources both"
got=$(
  parent <<'EOF'
HOME="${H2}" BASH_ENV="${H2}/.config/bash/functions.sh" "${BASH}" --norc --noprofile -c true
EOF
)
check "identity check catches the other file" "git gh|" "${got}"

echo "Case: BEACON_WORKDIR changed in the child"
got=$(
  parent <<'EOF'
BEACON_WORKDIR=/elsewhere "${BASH}" --norc --noprofile -c true
EOF
)
check "gh sourced to recompute its Beacon default" "gh|" "${got}"

echo "Case: sugh follows CLAUDECODE on the skip path"
got=$(
  parent <<'EOF'
CLAUDECODE=1 "${BASH}" --norc --noprofile -c 'if declare -F sugh >/dev/null; then echo defined; else echo absent; fi'
EOF
)
check "agent child: skipped, sugh removed" "|absent" "${got}"
got=$(
  parent CLAUDECODE=1 <<'EOF'
env -u CLAUDECODE "${BASH}" --norc --noprofile -c 'if declare -F sugh >/dev/null; then echo defined; else echo absent; fi'
EOF
)
check "human child of agent parent: gh sourced, sugh defined" "gh|defined" "${got}"

echo "Case: after a skip, gh and git work end to end"
: >"${STUB_LOG}"
got=$(
  parent <<'EOF'
cd "${TMPDIR}" && gh --version >/dev/null && echo rc=$?
EOF
)
check "gh reaches the real (stub) binary" "|rc=0" "${got}"
logged="$(log_words "${STUB_LOG}")"
check "stub saw the call" "--version" "${logged}"
: >"${STUB_LOG}"
got=$(
  parent <<'EOF'
cd "${TMPDIR}" || exit 1
if gh api -X PUT repos/o/r/pulls/1/merge >/dev/null 2>&1; then echo allowed; else echo refused; fi
EOF
)
check "REST merge bypass still refused" "|refused" "${got}"
logged="$(log_words "${STUB_LOG}")"
check "stub not called for the refused merge" "" "${logged}"
got=$(
  parent <<'EOF'
git -C "${TMPDIR}" init -q repo 2>&1
[[ -d "${TMPDIR}/repo/.git" ]] && echo init-ok
EOF
)
check "git init works, RETURN trap helper present" "|init-ok" "${got}"

echo
if [[ "${fail}" -eq 0 ]]; then
  echo "test-functions-wrapper-reload-guard: all cases passed"
else
  echo "test-functions-wrapper-reload-guard: FAILURES above"
fi
exit "${fail}"
