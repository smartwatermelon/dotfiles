#!/usr/bin/env bash
#shellcheck shell=bash
# Tests the eas completion cache in bash/completion.sh.
# Runs the block alone (no TTY) with a stub eas.
set -euo pipefail

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail=0

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/completion-eas-cache-test.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

stub_bin="${WORKDIR}/bin"
cache_home="${WORKDIR}/cache"
calls="${WORKDIR}/calls"
cache_file="${cache_home}/eas/autocomplete.bash"
mkdir -p "${stub_bin}"

block="${WORKDIR}/eas-block.sh"
sed -n '/^# eas completion/,/^unset _eas_bin/p' "${REPO_ROOT}/bash/completion.sh" >"${block}"
if ! grep -q 'autocomplete:script' "${block}"; then
  echo "FAIL: could not extract the eas block from bash/completion.sh"
  exit 1
fi

# Stub eas: logs each call, prints a completion registration, and fails
# when EAS_STUB_FAIL is set.
write_stub() {
  cat >"${stub_bin}/eas" <<'STUB'
#!/bin/bash
echo call >>"${EAS_STUB_CALLS}"
[[ -n "${EAS_STUB_FAIL:-}" ]] && exit 1
echo 'complete -F _eas_stub eas'
STUB
  chmod +x "${stub_bin}/eas"
}

# Sources the block, then prints the eas completion spec and any leaked
# helper variable.
probe="${WORKDIR}/probe.sh"
cat >"${probe}" <<'PROBE'
#shellcheck source=/dev/null
source "${EAS_BLOCK}"
complete -p eas 2>/dev/null
declare -p _eas_bin _eas_ac_cache 2>/dev/null
true
PROBE

# Runs the probe in a scrubbed shell with the given PATH.
run_block() {
  env -i HOME="${WORKDIR}" XDG_CACHE_HOME="${cache_home}" PATH="$1" \
    EAS_STUB_CALLS="${calls}" EAS_STUB_FAIL="${2:-}" EAS_BLOCK="${block}" \
    "${BASH}" --norc "${probe}"
}

call_count() {
  if [[ -f "${calls}" ]]; then
    wc -l <"${calls}" | tr -d ' '
  else
    echo 0
  fi
}

exists() {
  if [[ -e "$1" ]]; then echo present; else echo absent; fi
}

check() {
  if [[ "$2" == "$3" ]]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 (expected '$3', got '$2')"
    fail=1
  fi
}

write_stub

# --- Case 1: no cache yet — eas runs once and the cache is written ---
out="$(run_block "${stub_bin}:/usr/bin:/bin")"
got="$(call_count)"
check "first shell calls eas once" "${got}" 1
got="$(cat "${cache_file}" 2>/dev/null || true)"
check "first shell writes the cache" "${got}" 'complete -F _eas_stub eas'
check "first shell registers completion, leaks no variables" "${out}" 'complete -F _eas_stub eas'

# --- Case 2: fresh cache — eas is not called ---
out="$(run_block "${stub_bin}:/usr/bin:/bin")"
got="$(call_count)"
check "cached shell does not call eas" "${got}" 1
check "cached shell registers completion" "${out}" 'complete -F _eas_stub eas'

# --- Case 3: eas reinstalled (binary newer than cache) — cache regenerates ---
touch -t 202001010000 "${cache_file}"
run_block "${stub_bin}:/usr/bin:/bin" >/dev/null
got="$(call_count)"
check "newer eas binary triggers regeneration" "${got}" 2

# --- Case 4: eas fails — no cache, no temp file, retried next shell ---
rm -f "${cache_file}"
out="$(run_block "${stub_bin}:/usr/bin:/bin" 1)"
got="$(exists "${cache_file}")"
check "failed eas leaves no cache" "${got}" absent
got="$(compgen -G "${cache_file}.tmp*" || echo absent)"
check "failed eas leaves no temp file" "${got}" absent
check "failed eas registers nothing" "${out}" ''
run_block "${stub_bin}:/usr/bin:/bin" >/dev/null
got="$(call_count)"
check "next shell retries after a failure" "${got}" 4

# --- Case 5: eas not installed — block is a no-op ---
rm -rf "${cache_home}"
out="$(run_block "/usr/bin:/bin")"
check "no eas: nothing registered, no variables leaked" "${out}" ''
got="$(exists "${cache_home}")"
check "no eas: no cache directory created" "${got}" absent

exit "${fail}"
