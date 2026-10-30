#!/usr/bin/env bash
#shellcheck shell=bash
# Tests the pipx completion block in bash/completion.sh.
# Runs the block alone (no TTY) with a stub generator.
set -euo pipefail

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail=0

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/completion-pipx-test.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

stub_bin="${WORKDIR}/bin"
mkdir -p "${stub_bin}"

block="${WORKDIR}/pipx-block.sh"
sed -n '/^# pipx completion/,/^unset _pipx_ac/p' "${REPO_ROOT}/bash/completion.sh" >"${block}"
if ! grep -q 'register-python-argcomplete pipx' "${block}"; then
  echo "FAIL: could not extract the pipx block from bash/completion.sh"
  exit 1
fi

# Stub: prints a completion registration, then exits with STUB_EXIT.
cat >"${stub_bin}/register-python-argcomplete" <<'STUB'
#!/bin/bash
echo 'complete -F _pipx_stub pipx'
exit "${STUB_EXIT:-0}"
STUB
chmod +x "${stub_bin}/register-python-argcomplete"

# Sources the block, then prints the pipx completion spec and any leaked
# helper variable.
probe="${WORKDIR}/probe.sh"
cat >"${probe}" <<'PROBE'
#shellcheck source=/dev/null
source "${PIPX_BLOCK}"
complete -p pipx 2>/dev/null
declare -p _pipx_ac 2>/dev/null
true
PROBE

run_block() {
  env -i HOME="${WORKDIR}" PATH="$1" STUB_EXIT="${2:-0}" PIPX_BLOCK="${block}" \
    "${BASH}" --norc "${probe}"
}

check() {
  if [[ "$2" == "$3" ]]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 (expected '$3', got '$2')"
    fail=1
  fi
}

out="$(run_block "${stub_bin}:/usr/bin:/bin")"
check "registers pipx completion, leaks no variables" "${out}" 'complete -F _pipx_stub pipx'

out="$(run_block "${stub_bin}:/usr/bin:/bin" 1)"
check "failed generator: output is not evaluated" "${out}" ''

out="$(run_block "/usr/bin:/bin")"
check "generator missing: block is a no-op" "${out}" ''

exit "${fail}"
