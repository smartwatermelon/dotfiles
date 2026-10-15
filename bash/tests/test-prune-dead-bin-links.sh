#!/usr/bin/env bash
# shellcheck shell=bash
# Tests prune-dead-bin-links.sh (#417): fake HOME, trash is a stub.
set -uo pipefail

unset CDPATH

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${PRUNE_SCRIPT:-${REPO_ROOT}/bash/prune-dead-bin-links.sh}"

fail=0
pass() { echo "PASS: $1"; }
bad() {
  echo "FAIL: $1"
  fail=1
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/prune-links-test.XXXXXX")" || exit 1
trap 'rm -rf "${TMP}"' EXIT
FAKE_HOME="${TMP}/home"
BIN="${FAKE_HOME}/.local/bin"
STUBS="${TMP}/stubs"
TRASHED="${TMP}/trashed"
mkdir -p "${STUBS}" "${TRASHED}"

# Stub trash: move the named path into the temp trash dir.
cat >"${STUBS}/trash" <<'STUB'
#!/usr/bin/env bash
mv -- "$1" "${PRUNE_TEST_TRASH}/"
STUB
chmod +x "${STUBS}/trash"

# A PATH with the tools the script needs but no trash.
NOTRASH="${TMP}/notrash"
mkdir -p "${NOTRASH}"
for tool in readlink cat; do
  tool_path="$(command -v "${tool}")"
  ln -s "${tool_path}" "${NOTRASH}/${tool}"
done

# Fixture: 2 dead links, a live link, a file, a dir, a dead link in the dir.
make_fixture() {
  rm -rf "${FAKE_HOME}" "${TRASHED}"
  mkdir -p "${BIN}/subdir" "${TRASHED}"
  ln -s "${TMP}/missing-target" "${BIN}/dead-abs"
  ln -s "does-not-exist" "${BIN}/dead-rel"
  : >"${TMP}/real-target"
  ln -s "${TMP}/real-target" "${BIN}/live-link"
  echo "keep me" >"${BIN}/regular-file"
  ln -s "${TMP}/missing-target" "${BIN}/subdir/nested-dead"
}

# run_prune <stdin-text> <path-dir> <args...>; sets OUT and RC.
run_prune() {
  local input="$1" path_dir="$2"
  shift 2
  OUT="$(printf '%s' "${input}" | env -i PATH="${path_dir}:/usr/bin:/bin" HOME="${FAKE_HOME}" \
    PRUNE_TEST_TRASH="${TRASHED}" "${BASH}" "${SCRIPT}" "$@" 2>&1)"
  RC=$?
}
run_notrash() {
  local input="$1"
  shift
  OUT="$(printf '%s' "${input}" | env -i PATH="${NOTRASH}" HOME="${FAKE_HOME}" \
    PRUNE_TEST_TRASH="${TRASHED}" "${BASH}" "${SCRIPT}" "$@" 2>&1)"
  RC=$?
}

trash_empty() {
  local items
  items=("${TRASHED}"/*)
  [[ ! -e "${items[0]}" ]]
}
dead_gone() { [[ ! -L "${BIN}/dead-abs" && ! -L "${BIN}/dead-rel" ]]; }
dead_kept() { [[ -L "${BIN}/dead-abs" && -L "${BIN}/dead-rel" ]]; }
others_kept() {
  [[ -L "${BIN}/live-link" && -f "${BIN}/regular-file" && -d "${BIN}/subdir" &&
    -L "${BIN}/subdir/nested-dead" && -f "${TMP}/real-target" ]]
}

# 1. --dry-run lists the dead links and changes nothing.
make_fixture
run_prune "" "${STUBS}" --dry-run
if [[ ${RC} -eq 0 ]] && dead_kept && others_kept \
  && grep -q "dead-abs" <<<"${OUT}" && grep -q "dead-rel" <<<"${OUT}" \
  && ! grep -q "live-link\|regular-file\|nested-dead" <<<"${OUT}" \
  && trash_empty; then
  pass "--dry-run lists only dead links and changes nothing"
else
  bad "--dry-run (rc=${RC})"
  echo "${OUT}" | sed 's/^/    /'
fi

# 2. No flag, answer n: nothing changes.
make_fixture
run_prune $'n\n' "${STUBS}"
if [[ ${RC} -eq 0 ]] && dead_kept && others_kept && trash_empty; then
  pass "answer n: nothing trashed"
else
  bad "answer n changed something (rc=${RC})"
fi

# 3. No flag, empty stdin (no answer): nothing changes.
make_fixture
run_prune "" "${STUBS}"
if [[ ${RC} -eq 0 ]] && dead_kept && others_kept; then
  pass "no answer (EOF): nothing trashed"
else
  bad "EOF answer changed something (rc=${RC})"
fi

# 4. Answer y: only the two top-level dead links are trashed, via trash.
make_fixture
run_prune $'y\n' "${STUBS}"
if [[ ${RC} -eq 0 ]] && dead_gone && others_kept \
  && [[ -L "${TRASHED}/dead-abs" && -L "${TRASHED}/dead-rel" ]]; then
  pass "answer y: dead links go to trash; live link, file, subdir stay"
else
  bad "answer y (rc=${RC})"
  echo "${OUT}" | sed 's/^/    /'
fi

# 5. --yes and -y skip the question.
for flag in --yes -y; do
  make_fixture
  run_prune "" "${STUBS}" "${flag}"
  if [[ ${RC} -eq 0 ]] && dead_gone && others_kept; then
    pass "${flag}: trashes without asking"
  else
    bad "${flag} (rc=${RC})"
  fi
done

# 6. Explicit DIR argument.
make_fixture
run_prune "" "${STUBS}" --yes "${BIN}/subdir"
if [[ ${RC} -eq 0 ]] && [[ ! -L "${BIN}/subdir/nested-dead" ]] && dead_kept; then
  pass "explicit DIR is used instead of ~/.local/bin"
else
  bad "explicit DIR (rc=${RC})"
fi

# 7. Nothing dead: says so and never calls trash.
make_fixture
rm -f "${BIN}/dead-abs" "${BIN}/dead-rel"
run_prune "" "${STUBS}" --yes "${BIN}"
if [[ ${RC} -eq 0 ]] && grep -q "No broken symlinks" <<<"${OUT}" && others_kept && trash_empty; then
  pass "clean dir: reports none, exits 0"
else
  bad "clean dir (rc=${RC})"
fi

# 8. trash missing: refuse, change nothing, never fall back to rm.
make_fixture
run_notrash "" --yes
if [[ ${RC} -ne 0 ]] && dead_kept && others_kept && grep -q "trash" <<<"${OUT}"; then
  pass "no trash on PATH: fails and changes nothing"
else
  bad "missing trash (rc=${RC})"
  echo "${OUT}" | sed 's/^/    /'
fi

# 9. Bad option and missing directory.
run_prune "" "${STUBS}" --bogus
if [[ ${RC} -eq 2 ]]; then pass "unknown option exits 2"; else bad "unknown option (rc=${RC})"; fi
run_prune "" "${STUBS}" --yes "${TMP}/no-such-dir"
if [[ ${RC} -eq 1 ]]; then pass "missing DIR exits 1"; else bad "missing DIR (rc=${RC})"; fi

# 10. Help text names every flag.
run_prune "" "${STUBS}" --help
if [[ ${RC} -eq 0 ]] && grep -q -- "--dry-run" <<<"${OUT}" && grep -q -- "--yes" <<<"${OUT}"; then
  pass "--help documents --dry-run and --yes"
else
  bad "--help (rc=${RC})"
fi

exit "${fail}"
