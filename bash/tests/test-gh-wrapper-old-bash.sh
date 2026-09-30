#!/usr/bin/env bash
#shellcheck shell=bash
# gh-wrapper.sh under macOS /bin/bash 3.2, executed and sourced. Mock gh, sandbox HOME. Skips without bash 3.x.
set -uo pipefail

unset CDPATH

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAPPER="${REPO_ROOT}/bash/gh-wrapper.sh"

old_major="$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || echo 0)"
if [[ "${old_major}" -ge 4 || "${old_major}" -eq 0 ]]; then
  echo "SKIP: /bin/bash is not bash 3.x"
  exit 0
fi
found_new=0
for candidate in /opt/homebrew/opt/bash/bin/bash /usr/local/opt/bash/bin/bash \
  /opt/homebrew/bin/bash /usr/local/bin/bash; do
  if [[ -x "${candidate}" ]] && "${candidate}" -c '((BASH_VERSINFO[0] >= 4))'; then
    found_new=1
  fi
done
if [[ "${found_new}" -eq 0 ]]; then
  echo "SKIP: no bash 4+ where the guard looks for one"
  exit 0
fi

SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT
mkdir -p "${SANDBOX}/shim" "${SANDBOX}/mock" "${SANDBOX}/home"
ln -s /bin/bash "${SANDBOX}/shim/bash"
printf '#!/bin/sh\necho "MOCK-GH $*"\n' >"${SANDBOX}/mock/gh"
chmod +x "${SANDBOX}/mock/gh"
OLD_PATH="${SANDBOX}/shim:${SANDBOX}/mock:/usr/bin:/bin"

fail=0

# check <description> <want: ok|blocked> <mode: exec|source> <gh args...>
check() {
  local desc="$1" want="$2" mode="$3"
  shift 3
  local out rc
  if [[ "${mode}" == "exec" ]]; then
    out="$(env -i HOME="${SANDBOX}/home" PATH="${OLD_PATH}" \
      /bin/bash "${WRAPPER}" "$@" 2>&1)"
  else
    out="$(env -i HOME="${SANDBOX}/home" PATH="${OLD_PATH}" WRAP="${WRAPPER}" \
      /bin/bash -c "source \"\${WRAP}\"; gh \"\$@\"" _ "$@" 2>&1)"
  fi
  rc=$?
  if printf '%s' "${out}" | grep -qE 'bad substitution|command not found|invalid option|too old'; then
    printf 'FAIL: %s (bash error)\n' "${desc}"
    printf '%s\n' "${out}" | head -3
    fail=1
  elif [[ "${want}" == "ok" ]] && { [[ "${rc}" -ne 0 ]] || ! printf '%s' "${out}" | grep -q '^MOCK-GH '; }; then
    printf 'FAIL: %s (exit %s, mock gh not reached)\n' "${desc}" "${rc}"
    printf '%s\n' "${out}" | head -3
    fail=1
  elif [[ "${want}" == "blocked" ]] && { [[ "${rc}" -eq 0 ]] || ! printf '%s' "${out}" | grep -q '\[gh\] BLOCKED'; }; then
    printf 'FAIL: %s (not blocked, exit %s)\n' "${desc}" "${rc}"
    fail=1
  else
    printf 'PASS: %s\n' "${desc}"
  fi
}

merge_endpoint="repos/smartwatermelon/dotfiles/pulls/1/merge"

check "executed under 3.2: gh pr list reaches gh" ok exec \
  pr list --repo smartwatermelon/dotfiles
check "sourced into 3.2: gh pr list reaches gh" ok source \
  pr list --repo smartwatermelon/dotfiles
check "executed under 3.2: REST merge still blocked" blocked exec \
  api "${merge_endpoint}" -X PUT
check "sourced into 3.2: REST merge still blocked" blocked source \
  api "${merge_endpoint}" -X PUT

if [[ "${fail}" -ne 0 ]]; then
  echo "Some old-bash checks FAILED."
  exit 1
fi
echo "All old-bash checks passed."
