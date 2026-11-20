#!/usr/bin/env bash
#shellcheck shell=bash
# Tests the asana-cli completion cache in bash/completion.sh.
# Runs the block alone (no TTY) with a stub asana-cli.
set -euo pipefail

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail=0

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/completion-asana-cli-cache-test.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

stub_bin="${WORKDIR}/bin"
cache_home="${WORKDIR}/cache"
calls="${WORKDIR}/calls"
cache_dir="${cache_home}/asana-cli"
cache_file="${cache_dir}/autocomplete.bash"
mkdir -p "${stub_bin}"

block="${WORKDIR}/asana-block.sh"
sed -n '/^# asana-cli completion/,/^unset _asana_bin/p' "${REPO_ROOT}/bash/completion.sh" >"${block}"
if ! grep -q 'refresh-cache' "${block}"; then
  echo "FAIL: could not extract the asana-cli block from bash/completion.sh"
  exit 1
fi

# Stub asana-cli: logs its args, prints a progress line, and writes the
# oclif cache layout. Fails when ASANA_STUB_FAIL is set.
cat >"${stub_bin}/asana-cli" <<'STUB'
#!/bin/bash
echo "$*" >>"${ASANA_STUB_CALLS}"
echo "Building the autocomplete cache... done"
[[ -n "${ASANA_STUB_FAIL:-}" ]] && exit 1
d="${ASANA_CLI_CACHE_DIR}/autocomplete/functions/bash"
mkdir -p "${d}" "${ASANA_CLI_CACHE_DIR}/autocomplete/functions/zsh"
echo 'complete -F _asana_stub asana-cli' >"${d}/asana-cli.bash"
echo '#compdef asana-cli' >"${ASANA_CLI_CACHE_DIR}/autocomplete/functions/zsh/_asana-cli"
STUB
chmod +x "${stub_bin}/asana-cli"

# Sources the block, then prints the asana-cli completion spec and any
# leaked helper variable.
probe="${WORKDIR}/probe.sh"
cat >"${probe}" <<'PROBE'
#shellcheck source=/dev/null
source "${ASANA_BLOCK}"
complete -p asana-cli 2>/dev/null
declare -p _asana_bin _asana_ac_cache _asana_ac_tmp 2>/dev/null
true
PROBE

# Runs the probe in a scrubbed shell with the given PATH.
run_block() {
  env -i HOME="${WORKDIR}" XDG_CACHE_HOME="${cache_home}" PATH="$1" \
    ASANA_STUB_CALLS="${calls}" ASANA_STUB_FAIL="${2:-}" ASANA_BLOCK="${block}" \
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

# --- Case 1: no cache yet — asana-cli runs once and the cache is written ---
out="$(run_block "${stub_bin}:/usr/bin:/bin")"
got="$(call_count)"
check "first shell calls asana-cli once" "${got}" 1
got="$(cat "${calls}")"
check "first shell runs refresh-cache" "${got}" 'autocomplete --refresh-cache'
got="$(cat "${cache_file}" 2>/dev/null || true)"
check "first shell writes the bash function to the cache" "${got}" 'complete -F _asana_stub asana-cli'
check "first shell registers completion, prints nothing else, leaks no variables" \
  "${out}" 'complete -F _asana_stub asana-cli'
got="$(compgen -G "${cache_file}.tmp*" || echo absent)"
check "first shell removes its temp dir" "${got}" absent

# --- Case 2: fresh cache — asana-cli is not called ---
out="$(run_block "${stub_bin}:/usr/bin:/bin")"
got="$(call_count)"
check "cached shell does not call asana-cli" "${got}" 1
check "cached shell registers completion" "${out}" 'complete -F _asana_stub asana-cli'

# --- Case 3: asana-cli upgraded (binary newer than cache) — cache regenerates ---
touch -t 202001010000 "${cache_file}"
run_block "${stub_bin}:/usr/bin:/bin" >/dev/null
got="$(call_count)"
check "newer asana-cli binary triggers regeneration" "${got}" 2

# --- Case 4: asana-cli fails — no cache, no temp dir, retried next shell ---
rm -f "${cache_file}"
out="$(run_block "${stub_bin}:/usr/bin:/bin" 1)"
got="$(exists "${cache_file}")"
check "failed asana-cli leaves no cache" "${got}" absent
got="$(compgen -G "${cache_file}.tmp*" || echo absent)"
check "failed asana-cli leaves no temp dir" "${got}" absent
check "failed asana-cli registers nothing, prints nothing" "${out}" ''
run_block "${stub_bin}:/usr/bin:/bin" >/dev/null
got="$(call_count)"
check "next shell retries after a failure" "${got}" 4

# --- Case 5: asana-cli not installed — block is a no-op ---
rm -rf "${cache_home}"
out="$(run_block "/usr/bin:/bin")"
check "no asana-cli: nothing registered, no variables leaked" "${out}" ''
got="$(exists "${cache_home}")"
check "no asana-cli: no cache directory created" "${got}" absent

exit "${fail}"
