#!/usr/bin/env bash
#shellcheck shell=bash
# The length-caps entry in pre-commit/config.yaml, before lint-length.sh is linked.

set -euo pipefail

unset CDPATH

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_YAML="${REPO_ROOT}/pre-commit/config.yaml"

# A python with PyYAML: yamllint's own interpreter, as the prettier test does.
_yaml_python() {
  command -v yamllint >/dev/null || return 1
  local shebang yl
  yl="$(command -v yamllint)"
  shebang="$(head -1 "${yl}")"
  [[ "${shebang}" == '#!'* ]] || return 1
  shebang="${shebang#\#!}"
  local py="${shebang%% *}"
  "${py}" -c 'import yaml' 2>/dev/null && printf '%s\n' "${py}"
}

YAML_PY="$(_yaml_python || true)"
if [[ -z "${YAML_PY}" ]]; then
  echo "SKIP: no PyYAML-capable interpreter, cannot read the entry: string"
  exit 0
fi

ENTRY="$("${YAML_PY}" -c '
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for repo in doc["repos"]:
    for h in repo.get("hooks", []):
        if h.get("id") == "length-caps":
            print(h["entry"])
            sys.exit(0)
sys.exit(1)
' "${CONFIG_YAML}")"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT
mkdir -p "${SANDBOX}/home/.config/git/hooks"

fail=0
# run_entry: sets OUT (stdout and stderr) and RC, with HOME in the sandbox.
run_entry() {
  RC=0
  OUT="$(HOME="${SANDBOX}/home" "${YAML_PY}" -c '
import shlex, subprocess, sys
sys.exit(subprocess.call(shlex.split(sys.argv[1])))
' "${ENTRY}" 2>&1)" || RC=$?
}

check() { # <label> <ok: 1 pass, 0 fail>
  if [[ "$2" == "1" ]]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 — rc=${RC}; output: ${OUT}"
    fail=1
  fi
}

# Not linked: blocks, names install.sh --sync and the SKIP bypass.
run_entry
ok=0
[[ "${RC}" != "0" ]] && ok=1
check "not linked: the entry fails closed" "${ok}"
ok=0
[[ "${OUT}" == *"install.sh --sync"* ]] && ok=1
check "not linked: the message names install.sh --sync" "${ok}"
ok=0
[[ "${OUT}" == *"SKIP=length-caps"* ]] && ok=1
check "not linked: the message names the SKIP bypass" "${ok}"

# Linked: the script runs and its exit code passes through.
printf '#!/usr/bin/env bash\necho linked-hook-ran\nexit 7\n' \
  >"${SANDBOX}/home/.config/git/hooks/lint-length.sh"
chmod +x "${SANDBOX}/home/.config/git/hooks/lint-length.sh"
run_entry
ok=0
[[ "${RC}" == "7" && "${OUT}" == *"linked-hook-ran"* ]] && ok=1
check "linked: the script runs and its exit code passes through" "${ok}"

if [[ "${fail}" == "0" ]]; then
  echo "All length-caps entry checks passed."
else
  echo "length-caps entry checks FAILED."
fi
exit "${fail}"
