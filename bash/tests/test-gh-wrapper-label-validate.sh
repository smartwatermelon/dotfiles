#!/usr/bin/env bash
# gh-wrapper.sh label check (#323): _gh_wrapper_check_labels, both modes, stub gh.

# Prompt cases stand in for _gh_wrapper_label_interactive; its `-t 0 && -t 2` is untested.
set -uo pipefail
unset CDPATH

TESTS_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${TESTS_DIR}/../gh-wrapper.sh"
# shellcheck source=lib/git-env-isolation.sh
source "${TESTS_DIR}/lib/git-env-isolation.sh"
isolate_git_env

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gh-label-test.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

unset GH_TOKEN GITHUB_TOKEN GH_HOST GH_REPO CLAUDE_GH_TOKEN_LOGIN
unset GH_TOKEN_SWM GH_TOKEN_NOS GH_TOKEN_TWM _GH_REVIEW_DONE _gh_wrapper_review_script

GIT=/usr/bin/git
fail=0
_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

export HOME="${WORKDIR}/home"
mkdir -p "${HOME}/.config/gh"
cat >"${HOME}/.config/gh/hosts.yml" <<'YAML'
github.com:
    user: twistedmelonman
    oauth_token: fake
YAML
export TMPDIR="${WORKDIR}/tmp"
mkdir -p "${TMPDIR}"

SWM="${WORKDIR}/swm-repo"
"${GIT}" init -q "${SWM}"
"${GIT}" -C "${SWM}" remote add origin git@github.com:smartwatermelon/example.git

LABELS="${WORKDIR}/labels"
printf '%s\n' bug enhancement tech-debt 'good first issue' Documentation >"${LABELS}"

# The stub logs token and argv for every call. `label list` prints the
# fixture, or fails with LABEL_RC. Nothing else prints.
LOG="${WORKDIR}/gh.log"
STUB_DIR="${WORKDIR}/stub-bin"
mkdir -p "${STUB_DIR}"
cat >"${STUB_DIR}/gh" <<STUB_EOF
#!/usr/bin/env bash
[[ "\$1 \$2" == "auth token" ]] && { printf 'kr-%s\n' "\${*: -1}"; exit 0; }
printf 'token=%s|%s\n' "\${GH_TOKEN:-<unset>}" "\$*" >>"${LOG}"
if [[ "\$1 \$2" == "label list" ]]; then
  if [[ "\${LABEL_RC:-0}" != "0" ]]; then
    echo "HTTP 403: Resource not accessible" >&2
    exit "\${LABEL_RC}"
  fi
  cat "${LABELS}"
fi
exit 0
STUB_EOF
chmod +x "${STUB_DIR}/gh"

WRAP_DIR="${WORKDIR}/wrap-bin"
mkdir -p "${WRAP_DIR}"
ln -s "${WRAPPER}" "${WRAP_DIR}/gh"

FN_DRIVER="${WORKDIR}/fn-driver.sh"
{
  printf 'source %q\n' "${WRAPPER}"
  cat <<'DRIVER_EOF'
gh "$@"
DRIVER_EOF
} >"${FN_DRIVER}"
# Stands in for a terminal on stdin and stderr; input comes from the test.
TTY_DRIVER="${WORKDIR}/tty-driver.sh"
{
  printf 'source %q\n' "${WRAPPER}"
  cat <<'DRIVER_EOF'
_gh_wrapper_label_interactive() { return 0; }
gh "$@"
DRIVER_EOF
} >"${TTY_DRIVER}"

# _run MODE STDIN [VAR=VALUE ...] -- GH-ARGS...   (cwd: SWM)
# Sets rc and err; the stub log is in LOG.
_run() {
  local mode="$1" input="$2"
  shift 2
  local assigns=(GH_TOKEN_SWM=swm-stub GH_TOKEN_TWM=twm-stub)
  while [[ "$1" != "--" ]]; do
    assigns+=("$1")
    shift
  done
  shift
  : >"${LOG}"
  case "${mode}" in
    standalone)
      (cd "${SWM}" && env "${assigns[@]}" PATH="${STUB_DIR}:${PATH}" \
        bash "${WRAPPER}" "$@") <<<"${input}" >/dev/null 2>"${WORKDIR}/err"
      ;;
    function)
      (cd "${SWM}" && env "${assigns[@]}" PATH="${WRAP_DIR}:${STUB_DIR}:${PATH}" \
        bash "${FN_DRIVER}" "$@") <<<"${input}" >/dev/null 2>"${WORKDIR}/err"
      ;;
    tty)
      (cd "${SWM}" && env "${assigns[@]}" PATH="${WRAP_DIR}:${STUB_DIR}:${PATH}" \
        bash "${TTY_DRIVER}" "$@") <<<"${input}" >/dev/null 2>"${WORKDIR}/err"
      ;;
    *) return 1 ;;
  esac
  rc=$?
  err="$(cat "${WORKDIR}/err")"
}

# Count stub-log lines whose argv part matches an ERE.
_calls() { grep -cE "\|$1" "${LOG}" || true; }

for mode in standalone function; do
  echo "--- ${mode} mode"

  _run "${mode}" "" -- issue create -t x -l bug
  if [[ "${rc}" -eq 0 && "$(_calls 'issue create')" == "1" ]] \
    && grep -qF 'token=swm-stub|label list -R smartwatermelon/example --limit 500' "${LOG}"; then
    _pass "${mode}: existing label dispatches; lookup used the selected token and repo"
  else
    _fail "${mode}: existing label: rc=${rc} log=$(cat "${LOG}") err=${err}"
  fi

  _run "${mode}" "" -- issue create -t x -l BUG,Tech-Debt
  if [[ "${rc}" -eq 0 && "$(_calls 'issue create')" == "1" ]]; then
    _pass "${mode}: label match is case-insensitive"
  else
    _fail "${mode}: case-insensitive: rc=${rc} err=${err}"
  fi

  _run "${mode}" "" -- issue create -t x -l tech-dbet
  if [[ "${rc}" -ne 0 && "$(_calls 'issue create')" == "0" ]] \
    && [[ "${err}" == *"'tech-dbet'"* && "${err}" == *"did you mean tech-debt"* ]] \
    && [[ "${err}" == *"Valid labels in smartwatermelon/example: bug, enhancement, tech-debt, good first issue, Documentation"* ]]; then
    _pass "${mode}: missing label aborts before dispatch, suggests and lists"
  else
    _fail "${mode}: missing label: rc=${rc} log=$(cat "${LOG}") err=${err}"
  fi

  _run "${mode}" "" -- pr edit 5 --add-label bug,nope
  if [[ "${rc}" -ne 0 && "$(_calls 'pr edit')" == "0" ]] \
    && [[ "${err}" == *"not found in smartwatermelon/example: 'nope'"* && "${err}" != *"'bug'"* ]]; then
    _pass "${mode}: comma list with one bad label names only that one"
  else
    _fail "${mode}: comma list: rc=${rc} err=${err}"
  fi

  _run "${mode}" "" -- pr create -t x --label=nope
  if [[ "${rc}" -ne 0 && "$(_calls 'pr create')" == "0" && "${err}" == *"'nope'"* ]]; then
    _pass "${mode}: --label=x form is checked"
  else
    _fail "${mode}: --label=x: rc=${rc} err=${err}"
  fi

  _run "${mode}" "" -- pr create -t x -lnope
  if [[ "${rc}" -ne 0 && "$(_calls 'pr create')" == "0" && "${err}" == *"'nope'"* ]]; then
    _pass "${mode}: -lx form is checked"
  else
    _fail "${mode}: -lx: rc=${rc} err=${err}"
  fi

  _run "${mode}" "" -- issue edit 3 --add-label bug --add-label nope
  if [[ "${rc}" -ne 0 && "$(_calls 'issue edit')" == "0" && "${err}" == *"'nope'"* ]]; then
    _pass "${mode}: repeated flags are each checked"
  else
    _fail "${mode}: repeated flags: rc=${rc} err=${err}"
  fi

  _run "${mode}" "" -- issue list --label nope
  if [[ "${rc}" -eq 0 && "$(_calls 'label list')" == "0" && "$(_calls 'issue list --label nope')" == "1" ]]; then
    _pass "${mode}: --label on list is a filter, not checked"
  else
    _fail "${mode}: list filter: rc=${rc} log=$(cat "${LOG}") err=${err}"
  fi

  _run "${mode}" "" -- pr edit 5 --remove-label nope
  if [[ "${rc}" -eq 0 && "$(_calls 'label list')" == "0" && "$(_calls 'pr edit')" == "1" ]]; then
    _pass "${mode}: --remove-label is not checked"
  else
    _fail "${mode}: remove-label: rc=${rc} log=$(cat "${LOG}") err=${err}"
  fi

  # A value flag whose value looks like a label flag is not read as one.
  _run "${mode}" "" -- issue create -t -l -m x
  if [[ "${rc}" -eq 0 && "$(_calls 'label list')" == "0" && "$(_calls 'issue create')" == "1" ]]; then
    _pass "${mode}: a flag value is never read as a label flag"
  else
    _fail "${mode}: flag value: rc=${rc} log=$(cat "${LOG}") err=${err}"
  fi

  _run "${mode}" "" LABEL_RC=1 -- issue create -t x -l nope
  if [[ "${rc}" -eq 0 && "$(_calls 'issue create')" == "1" && "${err}" == *"label lookup in smartwatermelon/example failed"* ]]; then
    _pass "${mode}: lookup failure warns and dispatches unchanged"
  else
    _fail "${mode}: lookup failure: rc=${rc} log=$(cat "${LOG}") err=${err}"
  fi

  _run "${mode}" "" -- issue create -R smartwatermelon/other -t x -l bug
  if [[ "${rc}" -eq 0 ]] && grep -qF '|label list -R smartwatermelon/other ' "${LOG}"; then
    _pass "${mode}: -R decides which repo's labels are checked"
  else
    _fail "${mode}: -R: rc=${rc} log=$(cat "${LOG}")"
  fi

  _run "${mode}" "" -- pr edit https://github.com/smartwatermelon/zzz/pull/5 --add-label bug
  if [[ "${rc}" -eq 0 ]] && grep -qF '|label list -R smartwatermelon/zzz ' "${LOG}"; then
    _pass "${mode}: a PR URL decides which repo's labels are checked"
  else
    _fail "${mode}: URL: rc=${rc} log=$(cat "${LOG}")"
  fi

  _run "${mode}" "" -- issue create -t x -l nope --help
  if [[ "${rc}" -eq 0 && "$(_calls 'label list')" == "0" ]]; then
    _pass "${mode}: --help is not checked"
  else
    _fail "${mode}: --help: rc=${rc} log=$(cat "${LOG}")"
  fi
done

echo "--- prompt path (function mode, terminal stood in for)"

_run tty "a" -- issue create -t x -l tech-dbet
if [[ "${rc}" -ne 0 && "$(_calls 'issue create')" == "0" && "$(_calls 'label create')" == "0" ]] \
  && [[ "${err}" == *"1) use 'tech-debt'"* && "${err}" == *"Aborted"* ]]; then
  _pass "prompt: abort dispatches nothing and creates nothing"
else
  _fail "prompt abort: rc=${rc} log=$(cat "${LOG}") err=${err}"
fi

_run tty "" -- issue create -t x -l tech-dbet
if [[ "${rc}" -ne 0 && "$(_calls 'issue create')" == "0" ]]; then
  _pass "prompt: empty answer is abort"
else
  _fail "prompt empty: rc=${rc} log=$(cat "${LOG}")"
fi

_run tty "1" -- issue create -t x -l bug,tech-dbet
if [[ "${rc}" -eq 0 && "$(_calls 'issue create -t x -l bug,tech-debt$')" == "1" && "$(_calls 'label create')" == "0" ]]; then
  _pass "prompt: choosing a near match rewrites the label in place"
else
  _fail "prompt near match: rc=${rc} log=$(cat "${LOG}") err=${err}"
fi

_run tty "c" -- pr create -t x --label=brand-new
if [[ "${rc}" -eq 0 ]] && grep -qF 'token=swm-stub|label create brand-new -R smartwatermelon/example' "${LOG}" \
  && [[ "$(_calls 'pr create -t x --label=brand-new$')" == "1" ]]; then
  _pass "prompt: create makes the label, then dispatches unchanged"
else
  _fail "prompt create: rc=${rc} log=$(cat "${LOG}") err=${err}"
fi

echo "--- helpers"
# shellcheck source=/dev/null
source "${WRAPPER}"

check_repo() {
  local got
  got="$(_gh_wrapper_label_repo "$1")"
  if [[ "${got}" == "$2" ]]; then
    _pass "label_repo '$1' -> '$2'"
  else
    _fail "label_repo '$1': expected '$2', got '${got}'"
  fi
}
check_repo smartwatermelon/dotfiles smartwatermelon/dotfiles
check_repo git@github.com:smartwatermelon/dotfiles.git smartwatermelon/dotfiles
check_repo https://github.com/smartwatermelon/dotfiles.git smartwatermelon/dotfiles
check_repo github.com/smartwatermelon/dotfiles smartwatermelon/dotfiles
check_repo smartwatermelon/dotfiles/pull/12 smartwatermelon/dotfiles
check_repo smartwatermelon ""

check_edit() {
  local got=no
  _gh_wrapper_within_one_edit "$1" "$2" && got=yes
  if [[ "${got}" == "$3" ]]; then
    _pass "within_one_edit '$1' '$2' = $3"
  else
    _fail "within_one_edit '$1' '$2': expected $3, got ${got}"
  fi
}
check_edit tech-dbet tech-debt yes
check_edit bgu bug yes
check_edit bugs bug yes
check_edit bg bug yes
check_edit bxg bug yes
check_edit bug enhancement no
check_edit abcd badc no

echo
if [[ "${fail}" -eq 0 ]]; then
  echo "test-gh-wrapper-label-validate: all cases passed"
else
  echo "test-gh-wrapper-label-validate: FAILURES above"
fi
exit "${fail}"
