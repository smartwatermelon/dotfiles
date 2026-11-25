#!/usr/bin/env bash
#shellcheck shell=bash
# pre-commit/config.yaml: semgrep-secrets scans against HEAD as a baseline, so it reports only new findings.

set -euo pipefail

unset CDPATH
# A hook run from a linked worktree exports these; they would point git at the real checkout.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_YAML="${REPO_ROOT}/pre-commit/config.yaml"

# A python with PyYAML: yamllint's own interpreter, as the length-caps test does.
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
        if h.get("id") == "semgrep-secrets":
            print(h["entry"])
            sys.exit(0)
sys.exit(1)
' "${CONFIG_YAML}")"

SANDBOX="$(mktemp -d)"
mkdir -p "${SANDBOX}/bin"
# The stub records its arguments one per line and exits STUB_RC.
cat >"${SANDBOX}/bin/semgrep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${STUB_ARGS}"
exit "${STUB_RC:-0}"
EOF
chmod +x "${SANDBOX}/bin/semgrep"
export STUB_ARGS="${SANDBOX}/args"

# new_repo <dir> <commit: yes|no>: a repo with a.tf staged, and committed first when asked.
new_repo() {
  git init -q -b work "$1"
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name test
  git -C "$1" config commit.gpgsign false
  git -C "$1" config core.hooksPath /dev/null
  echo 'a = 1' >"$1/a.tf"
  git -C "$1" add a.tf
  if [[ "$2" == "yes" ]]; then
    git -C "$1" commit -qm init
    echo 'b = 2' >>"$1/a.tf"
    git -C "$1" add a.tf
  fi
}

fail=0
# run_entry <repo> <path>...: sets OUT, RC and ARGS (the stub's arguments, space-joined).
run_entry() {
  local repo="$1"
  shift
  RC=0
  : >"${STUB_ARGS}"
  OUT="$(cd "${repo}" && PATH="${SANDBOX}/bin:${PATH}" "${YAML_PY}" -c '
import shlex, subprocess, sys
sys.exit(subprocess.call(shlex.split(sys.argv[1]) + sys.argv[2:]))
' "${ENTRY}" "$@" 2>&1)" || RC=$?
  ARGS="$(tr '\n' ' ' <"${STUB_ARGS}")"
}

check() { # <label> <ok: 1 pass, 0 fail>
  if [[ "$2" == "1" ]]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 — rc=${RC}; args: ${ARGS}; output: ${OUT}"
    fail=1
  fi
}

new_repo "${SANDBOX}/with-head" yes
run_entry "${SANDBOX}/with-head" a.tf
ok=0
[[ "${RC}" == "0" && "${ARGS}" == *"--baseline-commit HEAD "* && "${ARGS}" == *" a.tf " ]] && ok=1
check "with HEAD: scans the staged file against HEAD" "${ok}"

STUB_RC=1 run_entry "${SANDBOX}/with-head" a.tf
ok=0
[[ "${RC}" == "1" ]] && ok=1
check "with HEAD: a finding still blocks the commit" "${ok}"

new_repo "${SANDBOX}/no-head" no
run_entry "${SANDBOX}/no-head" a.tf
ok=0
[[ "${RC}" == "0" && "${ARGS}" != *"--baseline-commit"* && "${ARGS}" == *" a.tf " ]] && ok=1
check "first commit: scans the whole file, with no baseline" "${ok}"

STUB_RC=1 run_entry "${SANDBOX}/no-head" a.tf
ok=0
[[ "${RC}" == "1" ]] && ok=1
check "first commit: a finding still blocks the commit" "${ok}"

if [[ "${fail}" == "0" ]]; then
  echo "All semgrep-secrets baseline checks passed."
else
  echo "semgrep-secrets baseline checks FAILED."
fi
exit "${fail}"
