#!/usr/bin/env bash
#shellcheck shell=bash

# aliases.sh clauded (#435): a = plain claude, else or timeout = YOLO;
# no TTY = YOLO with no prompt.
set -euo pipefail

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALIASES_FILE="${ALIASES_FILE:-${REPO_ROOT}/bash/aliases.sh}"

fail=0

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/aliases-clauded-prompt-test.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

# Expands aliases like an interactive shell. FAKE_TTY=1 stubs the TTY
# check so keys can come from a pipe.
cat >"${WORKDIR}/probe.sh" <<'PROBE'
shopt -s expand_aliases
#shellcheck source=/dev/null
source "${ALIASES_FILE}" >/dev/null 2>&1
if [[ "${FAKE_TTY:-0}" == 1 ]]; then
  _clauded_stdin_is_tty() { return 0; }
fi
clauded "$@"
PROBE

# Stub launcher: records its own name and each argument, one per line.
cat >"${WORKDIR}/stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${0##*/}" "$@" >"${RECORD}"
STUB
chmod +x "${WORKDIR}/stub"

# $1 tier label, then the launcher names to create under .local/bin.
make_home() {
  local home="${WORKDIR}/$1"
  shift
  mkdir -p "${home}/.local/bin"
  local f
  for f in "$@"; do
    cp "${WORKDIR}/stub" "${home}/.local/bin/${f}"
  done
  printf '%s' "${home}"
}

# $1 home, $2 FAKE_TTY, $3 timeout; then clauded's args. Reads stdin.
# Leaves the launcher record in ${WORKDIR}/record, stderr in .../err.
run_clauded() {
  local home="$1" tty="$2" timeout="$3"
  shift 3
  : >"${WORKDIR}/record"
  env -i HOME="${home}" ALIASES_FILE="${ALIASES_FILE}" \
    PATH="/usr/bin:/bin" RECORD="${WORKDIR}/record" \
    FAKE_TTY="${tty}" CLAUDED_TIMEOUT="${timeout}" \
    "${BASH}" --norc "${WORKDIR}/probe.sh" "$@" 2>"${WORKDIR}/err" || true
}

# $1 label, then the expected record lines.
assert_record() {
  local label="$1" got want
  shift
  got="$(cat "${WORKDIR}/record")"
  want="$(printf '%s\n' "$@")"
  if [[ "${got}" == "${want}" ]]; then
    echo "PASS: ${label}"
  else
    echo "FAIL: ${label}: expected [${want//$'\n'/|}], got [${got//$'\n'/|}]"
    fail=1
  fi
}

# $1 label, $2 "has" or "lacks", $3 fixed string to look for in stderr.
assert_stderr() {
  local found=lacks err
  err="$(cat "${WORKDIR}/err")"
  if grep -qF -- "$3" "${WORKDIR}/err"; then
    found=has
  fi
  if [[ "${found}" == "$2" ]]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1: stderr $2 '$3' expected; got: ${err}"
    fail=1
  fi
}

yolo=--dangerously-skip-permissions
args=(--model x 'two words')

full="$(make_home full claude claude-wrapper)"

# --- y keeps the old clauded behaviour, args unchanged.
printf y | run_clauded "${full}" 1 5 "${args[@]}"
assert_record "y runs YOLO via wrapper" claude-wrapper "${yolo}" "${args[@]}"
assert_stderr "y shows the prompt" has "[a]uto / [y]olo"

printf Y | run_clauded "${full}" 1 5 "${args[@]}"
assert_record "Y runs YOLO" claude-wrapper "${yolo}" "${args[@]}"

# --- a runs plain claude, args unchanged.
printf a | run_clauded "${full}" 1 5 "${args[@]}"
assert_record "a runs plain via wrapper" claude-wrapper "${args[@]}"
assert_stderr "a says plain claude" has "Starting plain claude."

printf A | run_clauded "${full}" 1 5 "${args[@]}"
assert_record "A runs plain" claude-wrapper "${args[@]}"

# --- Enter (empty key) runs YOLO.
printf '\n' | run_clauded "${full}" 1 5 "${args[@]}"
assert_record "Enter runs YOLO" claude-wrapper "${yolo}" "${args[@]}"

# --- Any other key runs YOLO.
printf x | run_clauded "${full}" 1 5 "${args[@]}"
assert_record "other key runs YOLO" claude-wrapper "${yolo}" "${args[@]}"

# --- Timeout: stdin stays open with no key, so read times out.
sleep 3 | run_clauded "${full}" 1 1 "${args[@]}"
assert_record "timeout runs YOLO" claude-wrapper "${yolo}" "${args[@]}"
assert_stderr "timeout is reported" has "(timed out)"

# --- EOF (Ctrl-D) runs YOLO but is not reported as a timeout.
run_clauded "${full}" 1 5 "${args[@]}" </dev/null
assert_record "EOF runs YOLO" claude-wrapper "${yolo}" "${args[@]}"
assert_stderr "EOF is not a timeout" lacks "(timed out)"

# --- A bad CLAUDED_TIMEOUT falls back to 10s, not a read error.
printf a | run_clauded "${full}" 1 bogus "${args[@]}"
assert_record "bad timeout still prompts" claude-wrapper "${args[@]}"
assert_stderr "bad timeout uses 10s" has "yolo in 10s"

# --- No TTY (real check): no prompt, old YOLO behaviour.
run_clauded "${full}" 0 5 "${args[@]}" </dev/null
assert_record "no TTY runs YOLO" claude-wrapper "${yolo}" "${args[@]}"
assert_stderr "no TTY never prompts" lacks "[a]uto / [y]olo"

# --- Other tiers route through their own launcher.
lite="$(make_home lite claude claude-wrapper-lite)"
printf y | run_clauded "${lite}" 1 5 "${args[@]}"
assert_record "lite y runs YOLO via lite" claude-wrapper-lite "${yolo}" "${args[@]}"
printf a | run_clauded "${lite}" 1 5 "${args[@]}"
assert_record "lite a runs plain via lite" claude-wrapper-lite "${args[@]}"

bare="$(make_home bare claude)"
printf y | run_clauded "${bare}" 1 5 "${args[@]}"
assert_record "bare y runs YOLO via claude" claude "${yolo}" "${args[@]}"
printf a | run_clauded "${bare}" 1 5 "${args[@]}"
assert_record "bare a runs plain via claude" claude "${args[@]}"

exit "${fail}"
