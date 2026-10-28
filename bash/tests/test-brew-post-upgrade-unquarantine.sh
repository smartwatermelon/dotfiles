#!/usr/bin/env bash
#shellcheck shell=bash
# Cask unquarantine (bash/functions.sh), with brew, xattr and codesign stubbed.
set -euo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

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

# Physical path, so it matches what realpath returns (/var is a symlink on macOS).
WORK="$(mktemp -d)"
WORK="$(CDPATH='' cd "${WORK}" && pwd -P)"
trap 'rm -rf "${WORK}"' EXIT

# Extract via bash's parser; HOME is the temp dir so no real wrapper is sourced.
_fns=(vax _brew_unq_brew _brew_unq_xattr _brew_unq_codesign _brew_unq_jq _brew_unq_warn
  _brew_cask_versions _brew_changed_casks _brew_unq_file _brew_post_upgrade_unquarantine
  _brew_wrap _homebrew_update)
_fn_src="$(HOME="${WORK}" bash --norc --noprofile -c '
  source "$1" >/dev/null 2>&1 || exit 1
  shift
  declare -f "$@"
' _ "${REPO_ROOT}/bash/functions.sh" "${_fns[@]}")"
if [[ -z "${_fn_src}" ]]; then
  echo "FAIL: could not extract functions from functions.sh" >&2
  exit 1
fi

# Tripwire: any brew, xattr or codesign reached through PATH instead of a stub fails loudly.
mkdir -p "${WORK}/tripwire" "${WORK}/stubs" "${WORK}/fx"
for tool in brew xattr codesign; do
  printf '#!/bin/bash\necho "TRIPWIRE %s $*" >>"%s/tripwire.log"\nexit 99\n' \
    "${tool}" "${WORK}" >"${WORK}/tripwire/${tool}"
  chmod +x "${WORK}/tripwire/${tool}"
done

# brew stub: list prints fx/list.before until an install/upgrade/reinstall ran, then fx/list.after.
cat >"${WORK}/stubs/brew" <<'STUB'
#!/bin/bash
echo "brew $*" >>"${CALLS}"
case "$1" in
  --caskroom) echo "${FX}/Caskroom" ;;
  --prefix) echo "/opt/homebrew" ;;
  info) cat "${FX}/info.json" ;;
  list)
    [[ -e "${FX}/ran" || ! -e "${FX}/list-fail" ]] || exit 1
    if [[ -e "${FX}/ran" ]]; then cat "${FX}/list.after"; else cat "${FX}/list.before"; fi
    ;;
  install | upgrade | reinstall)
    touch "${FX}/ran"
    exit "${BREW_RC:-0}"
    ;;
  *) echo "passthrough $*" ;;
esac
STUB

# xattr stub: quarantined paths are listed in fx/quarantined; -d fails for paths in fx/xattr-fail.
cat >"${WORK}/stubs/xattr" <<'STUB'
#!/bin/bash
echo "xattr $*" >>"${CALLS}"
f="${*: -1}"
case "$1" in
  -p) grep -qxF -- "${f}" "${FX}/quarantined" ;;
  -v) if grep -qxF -- "${f}" "${FX}/xattr-fail"; then exit 1; fi ;;
  *) exit 2 ;;
esac
STUB

# codesign stub: fx/sig lists "<path><TAB>devid|adhoc|unsigned|badverify".
cat >"${WORK}/stubs/codesign" <<'STUB'
#!/bin/bash
echo "codesign $*" >>"${CALLS}"
f="${*: -1}"
kind="$(awk -F'\t' -v f="${f}" '$1 == f { print $2 }' "${FX}/sig")"
case "$1" in
  --verify) [[ "${kind}" != "badverify" && "${kind}" != "unsigned" ]] ;;
  -dv)
    case "${kind}" in
      devid) printf 'Authority=Developer ID Application: Example (TEAM123)\nTeamIdentifier=TEAM123\n' >&2 ;;
      adhoc) printf 'Signature=adhoc\nTeamIdentifier=not set\n' >&2 ;;
      *) echo "${f}: code object is not signed at all" >&2; exit 1 ;;
    esac
    ;;
esac
STUB
chmod +x "${WORK}/stubs/brew" "${WORK}/stubs/xattr" "${WORK}/stubs/codesign"

# foo: relative Caskroom binary (1password-cli). bar, baz: absolute, in an app (bbedit).
FX="${WORK}/fx"
FOO="${FX}/Caskroom/foo/1.1/foo"
BAR="${FX}/Apps/Bar.app/Contents/Helpers/bar_tool"
BAZ="${FX}/Apps/Bar.app/Contents/Helpers/bazdiff"
mkdir -p "$(dirname "${FOO}")" "$(dirname "${BAR}")" "${FX}/bin"
touch "${FOO}" "${BAR}" "${BAZ}" "${FX}/bin/ghost"
ln -s "${FOO}" "${FX}/bin/foo"
ln -s "${BAR}" "${FX}/bin/bar"
ln -s "${BAZ}" "${FX}/bin/bazdiff"
cat >"${FX}/info.json" <<JSON
{"formulae": [], "casks": [
  {"token": "foo", "installed": "1.1", "artifacts": [
    {"binary": [], "target": "${FX}/bin/ghost"},
    {"binary": ["foo"], "target": "${FX}/bin/foo"},
    {"zap": [{"trash": "~/.config/foo"}]}]},
  {"token": "bar", "installed": "2.0", "artifacts": [
    {"app": ["Bar.app"], "target": "${FX}/Apps/Bar.app"},
    {"binary": ["${BAR}", {"target": "bar"}], "target": "${FX}/bin/bar"},
    {"binary": ["${BAZ}"], "target": "${FX}/bin/bazdiff"}]}
]}
JSON

# Reset the per-case fixture state: quarantined paths, signatures, list snapshots.
reset_fx() {
  : >"${WORK}/calls"
  : >"${FX}/quarantined"
  : >"${FX}/xattr-fail"
  : >"${FX}/sig"
  rm -f "${FX}/ran" "${FX}/list-fail"
  printf 'bar 2.0\nfoo 1.0\n' >"${FX}/list.before"
  printf 'bar 2.0\nfoo 1.1\n' >"${FX}/list.after"
}
quarantine() { printf '%s\n' "$@" >>"${FX}/quarantined"; }
sig() { printf '%s\t%s\n' "$1" "$2" >>"${FX}/sig"; }

# Run a snippet in a clean child bash with the functions and stubs loaded.
# Prints the snippet's stdout+stderr, then "RC=<n>".
run() {
  HOME="${WORK}" CALLS="${WORK}/calls" FX="${FX}" BREW_RC="${BREW_RC:-0}" \
    PATH="${WORK}/tripwire:${PATH}" \
    _BREW_UNQ_BREW_BIN="${WORK}/stubs/brew" \
    _BREW_UNQ_XATTR_BIN="${WORK}/stubs/xattr" \
    _BREW_UNQ_CODESIGN_BIN="${WORK}/stubs/codesign" \
    bash --norc --noprofile -c '
      eval "$1"
      eval "$2"
      echo "RC=$?"
    ' _ "${_fn_src}" "$1" 2>&1
}
count() { grep -cxF -- "$1" "${WORK}/calls" || true; }

echo "Case: quarantined file with a valid Developer ID signature"
reset_fx
quarantine "${FOO}" "${FX}/bin/ghost"
sig "${FOO}" devid
sig "${FX}/bin/ghost" devid
out="$(run '_brew_post_upgrade_unquarantine foo')"
check "xattr -d is called with the Caskroom path" "1" "$(count "xattr -v -d com.apple.quarantine ${FOO}" || true)"
check "returns 0" "1" "$(grep -cx 'RC=0' <<<"${out}" || true)"
check "brew info is asked for the token" "1" "$(count "brew info --json=v2 --cask foo" || true)"
check "an empty binary entry does not shift its target into the source" "0" "$(grep -c "${FX}/bin/ghost" "${WORK}/calls" || true)"

echo "Case: file without quarantine"
reset_fx
sig "${FOO}" devid
out="$(run '_brew_post_upgrade_unquarantine foo')"
check "no xattr -d" "0" "$(grep -c 'xattr -v -d' "${WORK}/calls" || true)"
check "no codesign call" "0" "$(grep -c '^codesign' "${WORK}/calls" || true)"
check "no warning" "0" "$(grep -c 'warning' <<<"${out}" || true)"
check "returns 0" "1" "$(grep -cx 'RC=0' <<<"${out}" || true)"

echo "Case: codesign --verify --strict fails"
reset_fx
quarantine "${FOO}"
sig "${FOO}" badverify
out="$(run '_brew_post_upgrade_unquarantine foo')"
check "no xattr -d" "0" "$(grep -c 'xattr -v -d' "${WORK}/calls" || true)"
check "warning names the file" "1" "$(grep -cF "${FOO}: codesign --verify --strict failed" <<<"${out}" || true)"
check "policy skip returns 0" "1" "$(grep -cx 'RC=0' <<<"${out}" || true)"

echo "Case: ad-hoc signature"
reset_fx
quarantine "${FOO}"
sig "${FOO}" adhoc
out="$(run '_brew_post_upgrade_unquarantine foo')"
check "no xattr -d" "0" "$(grep -c 'xattr -v -d' "${WORK}/calls" || true)"
check "warning names the file" "1" "$(grep -cF "${FOO}: no Developer ID signature" <<<"${out}" || true)"

echo "Case: several files, one xattr -d fails, one unsigned"
reset_fx
quarantine "${FOO}" "${BAR}" "${BAZ}"
sig "${FOO}" devid
sig "${BAR}" devid
sig "${BAZ}" unsigned
printf '%s\n' "${FOO}" >"${FX}/xattr-fail"
out="$(run '_brew_post_upgrade_unquarantine foo bar')"
check "failing file was attempted" "1" "$(count "xattr -v -d com.apple.quarantine ${FOO}" || true)"
check "later file is still cleared" "1" "$(count "xattr -v -d com.apple.quarantine ${BAR}" || true)"
check "unsigned file is kept" "0" "$(count "xattr -v -d com.apple.quarantine ${BAZ}" || true)"
check "unsigned file is warned about" "1" "$(grep -cF "${BAZ}: codesign --verify --strict failed" <<<"${out}" || true)"
check "returns 1 after a failed attempt" "1" "$(grep -cx 'RC=1' <<<"${out}" || true)"
check "each file is checked once (source and target dedupe)" "1" "$(count "xattr -p com.apple.quarantine ${BAR}" || true)"

echo "Case: brew info fails"
reset_fx
mv "${FX}/info.json" "${FX}/info.json.bak"
out="$(run '_brew_post_upgrade_unquarantine foo')"
mv "${FX}/info.json.bak" "${FX}/info.json"
check "returns 1" "1" "$(grep -cx 'RC=1' <<<"${out}" || true)"
check "no xattr call" "0" "$(grep -c '^xattr' "${WORK}/calls" || true)"

echo "Case: brew wrapper passes other subcommands straight through"
reset_fx
out="$(run '_brew_wrap search --cask foo')"
check "real brew gets the args" "1" "$(count "brew search --cask foo" || true)"
check "only one brew call (no snapshot)" "1" "$(grep -c "" "${WORK}/calls" || true)"
check "output passes through" "1" "$(grep -c 'passthrough search --cask foo' <<<"${out}" || true)"

echo "Case: brew upgrade fails"
reset_fx
quarantine "${FOO}"
sig "${FOO}" devid
out="$(BREW_RC=3 run '_brew_wrap upgrade')"
check "exit code is preserved" "1" "$(grep -cx 'RC=3' <<<"${out}" || true)"
check "helper does not run" "0" "$(grep -c '^brew info' "${WORK}/calls" || true)"
check "no xattr call" "0" "$(grep -c '^xattr' "${WORK}/calls" || true)"

echo "Case: brew upgrade succeeds"
reset_fx
quarantine "${FOO}" "${BAR}"
sig "${FOO}" devid
sig "${BAR}" devid
out="$(run '_brew_wrap upgrade')"
check "returns 0" "1" "$(grep -cx 'RC=0' <<<"${out}" || true)"
check "helper runs for the changed cask only" "1" "$(count "brew info --json=v2 --cask foo" || true)"
check "helper runs once" "1" "$(grep -c '^brew info' "${WORK}/calls" || true)"
check "changed cask binary is cleared" "1" "$(count "xattr -v -d com.apple.quarantine ${FOO}" || true)"

echo "Case: brew install of a new cask"
reset_fx
printf 'foo 1.0\n' >"${FX}/list.before"
printf 'bar 2.0\nfoo 1.0\n' >"${FX}/list.after"
out="$(run '_brew_wrap install --cask bar')"
check "helper runs for the new cask" "1" "$(count "brew info --json=v2 --cask bar" || true)"

echo "Case: brew reinstall keeps the version"
reset_fx
printf 'bar 2.0\nfoo 1.1\n' >"${FX}/list.before"
out="$(run '_brew_wrap reinstall --cask foo')"
check "helper runs for the named cask" "1" "$(count "brew info --json=v2 --cask foo" || true)"

echo "Case: brew upgrade when the before snapshot fails"
reset_fx
touch "${FX}/list-fail"
out="$(run '_brew_wrap upgrade')"
check "brew upgrade still runs" "1" "$(count "brew upgrade" || true)"
check "skip is warned about" "1" "$(grep -c 'cask snapshot failed' <<<"${out}" || true)"
check "helper does not run" "0" "$(grep -c '^brew info' "${WORK}/calls" || true)"
check "returns 0" "1" "$(grep -cx 'RC=0' <<<"${out}" || true)"

echo "Case: brew upgrade with no cask change"
reset_fx
cp "${FX}/list.before" "${FX}/list.after"
out="$(run '_brew_wrap upgrade')"
check "helper does not run" "0" "$(grep -c '^brew info' "${WORK}/calls" || true)"

# _homebrew_update calls bare brew: hbu-direct sends it to the stub, hbu-wrapped to the wrapper.
cat >"${WORK}/hbu-prelude.sh" <<'PRELUDE'
stat() { id -u; }
_notif() { echo "NOTIF $*"; }
_update_log() { cat; }
_updates_noninteractive() { return 1; }
_updates_sudo_shim() { return 1; }
PRELUDE
cp "${WORK}/hbu-prelude.sh" "${WORK}/hbu-direct.sh"
cat >>"${WORK}/hbu-direct.sh" <<'DIRECT'
brew() { "${_BREW_UNQ_BREW_BIN}" "$@"; }
DIRECT
cp "${WORK}/hbu-prelude.sh" "${WORK}/hbu-wrapped.sh"
cat >>"${WORK}/hbu-wrapped.sh" <<'WRAPPED'
brew() { _brew_wrap "$@"; }
WRAPPED

echo "Case: _homebrew_update unquarantines upgraded casks"
reset_fx
quarantine "${FOO}"
sig "${FOO}" devid
out="$(run "source '${WORK}/hbu-direct.sh'; _homebrew_update")"
check "helper runs for the changed cask" "1" "$(count "brew info --json=v2 --cask foo" || true)"
check "changed cask binary is cleared" "1" "$(count "xattr -v -d com.apple.quarantine ${FOO}" || true)"
check "returns 0" "1" "$(grep -cx 'RC=0' <<<"${out}" || true)"
check "success is still notified" "1" "$(grep -c 'NOTIF Homebrew update completed successfully' <<<"${out}" || true)"

echo "Case: _homebrew_update through the interactive brew wrapper"
reset_fx
quarantine "${FOO}"
sig "${FOO}" devid
out="$(run "source '${WORK}/hbu-wrapped.sh'; _homebrew_update")"
check "helper runs exactly once (wrapper passes through)" "1" "$(grep -c '^brew info' "${WORK}/calls" || true)"
check "returns 0" "1" "$(grep -cx 'RC=0' <<<"${out}" || true)"

echo "Case: _homebrew_update keeps its result when unquarantine fails"
reset_fx
quarantine "${FOO}"
sig "${FOO}" devid
printf '%s\n' "${FOO}" >"${FX}/xattr-fail"
out="$(run "source '${WORK}/hbu-direct.sh'; _homebrew_update")"
check "returns 0" "1" "$(grep -cx 'RC=0' <<<"${out}" || true)"
check "failure is notified" "1" "$(grep -c 'NOTIF Some upgraded cask binaries were not unquarantined' <<<"${out}" || true)"

echo "Case: _homebrew_update when a cask snapshot fails"
reset_fx
touch "${FX}/list-fail"
out="$(run "source '${WORK}/hbu-direct.sh'; _homebrew_update")"
check "helper does not run" "0" "$(grep -c '^brew info' "${WORK}/calls" || true)"
check "skip is notified" "1" "$(grep -c 'NOTIF Cask snapshot failed' <<<"${out}" || true)"
check "returns 0" "1" "$(grep -cx 'RC=0' <<<"${out}" || true)"

echo "Case: brew() is defined only in interactive shells and is not exported"
nonint="$(HOME="${WORK}" bash --norc --noprofile -c '
  source "$1" >/dev/null 2>&1
  declare -F brew >/dev/null && echo defined || echo absent
' _ "${REPO_ROOT}/bash/functions.sh")"
check "non-interactive source leaves brew undefined" "absent" "${nonint}"
inter="$(HOME="${WORK}" bash --norc --noprofile -i -c '
  source "$1" >/dev/null 2>&1
  declare -F brew >/dev/null && echo defined || echo absent
  bash --norc --noprofile -c "declare -F brew >/dev/null && echo exported || echo private"
' _ "${REPO_ROOT}/bash/functions.sh" 2>/dev/null)"
check "interactive source defines brew" "1" "$(grep -cx defined <<<"${inter}" || true)"
check "brew is not exported to child shells" "1" "$(grep -cx private <<<"${inter}" || true)"

echo "Case: no stubbed tool was reached through PATH"
check "tripwire log is empty" "" "$(cat "${WORK}/tripwire.log" 2>/dev/null || true)"

echo
if [[ "${fail}" -eq 0 ]]; then
  echo "test-brew-post-upgrade-unquarantine: all cases passed"
else
  echo "test-brew-post-upgrade-unquarantine: FAILURES above"
fi
exit "${fail}"
