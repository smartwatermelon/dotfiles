#!/usr/bin/env bash
#shellcheck shell=bash
# _developer_link_check (functions.sh) and its prompt.sh hook: warn on a
# dangling ~/Developer symlink. Temp HOME only.
set -euo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail=0
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/developer-link-check-test.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

check() {
  if [[ "$2" == "$3" ]]; then
    echo "  PASS: $1"
  else
    echo "  FAIL: $1 — expected [$2], got [$3]"
    fail=1
  fi
}

# Extract the helper through bash's own parser, as the allup tests do.
_fn_src="$(bash --norc --noprofile -c '
  source "$1" >/dev/null 2>&1 || exit 1
  declare -f _developer_link_check
' _ "${REPO_ROOT}/bash/functions.sh")" || true
if [[ "${_fn_src}" != *"_developer_link_check ()"* ]]; then
  echo "FAIL: could not extract _developer_link_check from functions.sh" >&2
  exit 1
fi
eval "${_fn_src}"

export HOME="${WORKDIR}/home"
TARGET="${WORKDIR}/volume/Workspaces"
mkdir -p "${HOME}"
unset NO_COLOR _DEVELOPER_LINK_TTY _DEVELOPER_LINK_MISSING
WARN="⚠ ~/Developer is unavailable: ${TARGET} is missing (not mounted?)"
BACK="✓ ~/Developer is available again"

# One prompt: run the check in this shell (state persists), capture stderr.
OUT="${WORKDIR}/stderr"
prompt() { _developer_link_check 2>"${OUT}"; }
got() { cat "${OUT}"; }
fresh() { unset _DEVELOPER_LINK_MISSING; }

# ---------------------------------------------------------------
echo "Case: silent where ~/Developer is fine"
fresh
prompt
check "no ~/Developer" "" "$(got)"
mkdir "${HOME}/Developer"
fresh
prompt
check "real directory" "" "$(got)"
rmdir "${HOME}/Developer"
mkdir -p "${TARGET}"
ln -s "${TARGET}" "${HOME}/Developer"
fresh
prompt
check "healthy symlink" "" "$(got)"

# ---------------------------------------------------------------
echo "Case: dangling symlink warns once, names the target"
rm -rf "${WORKDIR}/volume"
fresh
prompt
check "warning line" "${WARN}" "$(got)"
prompt
check "repeated prompt is silent" "" "$(got)"

echo "Case: state changes print once each"
mkdir -p "${TARGET}"
prompt
check "back online" "${BACK}" "$(got)"
prompt
check "repeated prompt is silent" "" "$(got)"
rm -rf "${WORKDIR}/volume"
prompt
check "drops again" "${WARN}" "$(got)"

echo "Case: keeps the caller's \$?"
fresh
rc=0
(exit 3) || _developer_link_check 2>/dev/null || rc=$?
check "exit status passes through" "3" "${rc}"

# ---------------------------------------------------------------
echo "Case: colour only on a tty without NO_COLOR"
ESC=$'\033'
color_out() {
  fresh
  _developer_link_check 2>"${OUT}"
  if [[ "$(got)" == *"${ESC}"* ]]; then echo escape; else echo plain; fi
}
check "non-tty stderr" "plain" "$(color_out)"
check "tty" "escape" "$(_DEVELOPER_LINK_TTY=1 color_out)"
check "tty with NO_COLOR" "plain" "$(_DEVELOPER_LINK_TTY=1 NO_COLOR=1 color_out)"
fresh

# ---------------------------------------------------------------
# prompt.sh: warns at start, hooks PROMPT_COMMAND once, interactive only.
probe="${WORKDIR}/probe.sh"
cat >"${probe}" <<'PROBE'
#shellcheck source=/dev/null
source "$1/bash/functions.sh" >/dev/null 2>&1
#shellcheck source=/dev/null
source "$1/bash/prompt.sh" 2>&1 >/dev/null
last=""
((${#PROMPT_COMMAND[@]} == 0)) || last="${PROMPT_COMMAND[-1]}"
# Re-source: the fallback branch re-appends its own entry, but not ours.
#shellcheck source=/dev/null
source "$1/bash/prompt.sh" 2>&1 >/dev/null
n=0
for c in "${PROMPT_COMMAND[@]}"; do
  [[ "${c}" == *_developer_link_check* ]] && n=$((n + 1))
done
printf 'hooks=%s last=%s\n' "${n}" "${last}"
PROBE
run_probe() {
  env -i HOME="${HOME}" PATH="/usr/bin:/bin" TERM=dumb \
    "${BASH}" --norc --noprofile "$@" "${probe}" "${REPO_ROOT}" 2>/dev/null
}

echo "Case: prompt.sh in an interactive shell"
out="$(run_probe -i)"
check "startup warning, once" "1" "$(grep -c -F -- "${WARN}" <<<"${out}")"
check "hooked once, last" "hooks=1 last=_developer_link_check" "$(tail -n 1 <<<"${out}")"

echo "Case: prompt.sh in a non-interactive shell"
out="$(run_probe)"
check "no warning" "0" "$(grep -c -F -- "${WARN}" <<<"${out}" || true)"
check "no hook" "hooks=0" "$(tail -n 1 <<<"${out}" | cut -d' ' -f1)"

echo ""
if [[ "${fail}" -eq 0 ]]; then
  echo "ALL CHECKS PASSED"
else
  echo "SOME CHECKS FAILED"
fi
exit "${fail}"
