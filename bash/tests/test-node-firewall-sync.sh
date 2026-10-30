#!/usr/bin/env bash
#shellcheck shell=bash
# node-firewall-sync.sh and _node_firewall_sync, with socketfilterfw and sudo stubbed.
set -euo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/bash/node-firewall-sync.sh"

# As root the script ignores the stub and uses the real firewall tool.
if [[ "${EUID}" -eq 0 ]]; then
  echo "FAIL: refusing to run as root" >&2
  exit 1
fi

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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/node-fw-sync-test.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
CELLAR="${WORK}/Cellar/node"
CALLS="${WORK}/calls"
LISTING="${WORK}/listing"

# The stub prints LISTING for --listapps and records every other call.
# FW_FAIL_ON makes that one flag fail.
cat >"${WORK}/socketfilterfw" <<'STUB'
#!/bin/bash
if [ "$1" = "--listapps" ]; then
  [ "${FW_FAIL_ON:-}" = "--listapps" ] && exit 1
  cat "${LISTING}"
  exit 0
fi
printf '%s\n' "$*" >>"${CALLS}"
[ "${FW_FAIL_ON:-}" = "$1" ] && exit 1
exit 0
STUB
chmod +x "${WORK}/socketfilterfw"

install_node() {
  mkdir -p "${CELLAR}/$1/bin"
  : >"${CELLAR}/$1/bin/node"
}

# Same shape as `socketfilterfw --listapps` on MIMOLETTE (2026-10-30).
write_listing() {
  {
    printf 'Total number of apps = %s \n' "$#"
    local i=1 p
    for p in "$@"; do
      printf '%s : %s \n' "${i}" "${p}"
      printf '             (Allow incoming connections)\n'
      i=$((i + 1))
    done
  } >"${LISTING}"
}

run_sync() {
  : >"${CALLS}"
  set +e
  LISTING="${LISTING}" CALLS="${CALLS}" NODE_FW_SOCKETFILTERFW="${WORK}/socketfilterfw" \
    NODE_FW_CELLAR="${CELLAR}" /bin/bash "${SCRIPT}" >"${WORK}/out" 2>&1
  rc=$?
  set -e
}

reset_cellar() {
  rm -rf "${WORK}/Cellar"
  mkdir -p "${CELLAR}"
}

echo "Case 1: current version listed, two removed versions listed"
reset_cellar
install_node 26.13.0
write_listing "${CELLAR}/26.13.0/bin/node" "${CELLAR}/26.12.1/bin/node" \
  "${CELLAR}/26.12.0/bin/node" /sbin/launchd
run_sync
check "exit 0" 0 "${rc}"
check "removes only the two stale node entries" \
  "--remove ${CELLAR}/26.12.1/bin/node
--remove ${CELLAR}/26.12.0/bin/node" "$(<"${CALLS}")"

echo "Case 2: new version not listed yet"
reset_cellar
install_node 27.0.0
write_listing /sbin/launchd
run_sync
check "exit 0" 0 "${rc}"
check "adds and unblocks the new node" \
  "--add ${CELLAR}/27.0.0/bin/node
--unblockapp ${CELLAR}/27.0.0/bin/node" "$(<"${CALLS}")"

echo "Case 3: everything current"
reset_cellar
install_node 26.13.0
write_listing "${CELLAR}/26.13.0/bin/node" /usr/sbin/syslogd
run_sync
check "exit 0" 0 "${rc}"
check "no changes" "" "$(<"${CALLS}")"

echo "Case 4: listed paths that are not a plain node version are never touched"
reset_cellar
write_listing "${CELLAR}/x;y/bin/node" "${CELLAR}/../evil/bin/node" \
  "${CELLAR}/26.1.0/bin/node2" "${CELLAR}/abc/bin/node" \
  "${WORK}/other/node/26.1.0/bin/node" /opt/homebrew/bin/adb
run_sync
check "exit 0" 0 "${rc}"
check "no calls" "" "$(<"${CALLS}")"

echo "Case 5: no node installed and nothing listed"
reset_cellar
write_listing
run_sync
check "exit 0" 0 "${rc}"
check "no calls" "" "$(<"${CALLS}")"

echo "Case 6: --listapps fails"
reset_cellar
install_node 27.0.0
write_listing
FW_FAIL_ON=--listapps run_sync
check "exit 1" 1 "${rc}"
check "no changes after a failed read" "" "$(<"${CALLS}")"

echo "Case 7: --add fails"
FW_FAIL_ON=--add run_sync
check "exit 1" 1 "${rc}"

echo "Case 8: not root and no test variables"
: >"${CALLS}"
set +e
env -u NODE_FW_SOCKETFILTERFW -u NODE_FW_CELLAR /bin/bash "${SCRIPT}" >"${WORK}/out" 2>&1
rc=$?
set -e
check "exit 2" 2 "${rc}"
check "message names sudo" "node-firewall-sync: must run as root (sudo)" "$(<"${WORK}/out")"

echo "Case 9: _node_firewall_sync in functions.sh"
_fn_src="$(HOME="${WORK}" bash --norc --noprofile -c '
  source "$1" >/dev/null 2>&1 || exit 1
  declare -f _node_firewall_sync
' _ "${REPO_ROOT}/bash/functions.sh")"
if [[ -z "${_fn_src}" ]]; then
  echo "FAIL: could not extract _node_firewall_sync" >&2
  exit 1
fi
eval "${_fn_src}"
cat >"${WORK}/sudo" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"${CALLS}"
exit "${SUDO_RC:-0}"
STUB
chmod +x "${WORK}/sudo"
export CALLS
_NODE_FW_SUDO_BIN="${WORK}/sudo"

_NODE_FW_SYNC_BIN="${WORK}/not-installed"
: >"${CALLS}"
set +e
_node_firewall_sync
rc=$?
set -e
check "not installed: returns 0" 0 "${rc}"
check "not installed: sudo not called" "" "$(<"${CALLS}")"

: >"${WORK}/sync-bin"
chmod +x "${WORK}/sync-bin"
_NODE_FW_SYNC_BIN="${WORK}/sync-bin"
: >"${CALLS}"
set +e
_node_firewall_sync
rc=$?
set -e
check "installed: returns 0" 0 "${rc}"
check "installed: sudo -n with the path and no other arguments" "-n ${WORK}/sync-bin" "$(<"${CALLS}")"

set +e
SUDO_RC=1 _node_firewall_sync
rc=$?
set -e
check "sudo refuses: returns non-zero" 1 "${rc}"

exit "${fail}"
