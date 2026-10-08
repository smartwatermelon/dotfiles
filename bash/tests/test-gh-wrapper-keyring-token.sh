#!/usr/bin/env bash
# Per-call keyring token in bash/gh-wrapper.sh (dotfiles#404, #336), both modes.

# No env token: the real gh gets the owner's keyring token; no `gh auth switch`.

# Known-bad on origin/main: token, no-switch, hosts.yml, missing-login cases.

set -uo pipefail
unset CDPATH

TESTS_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${TESTS_DIR}/../gh-wrapper.sh"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gh-keyring-token-test.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

unset GH_TOKEN GITHUB_TOKEN GH_HOST GH_REPO CLAUDE_GH_TOKEN_LOGIN CLAUDE_GH_TOKEN_ROUTER
unset GH_TOKEN_SWM GH_TOKEN_NOS GH_TOKEN_TWM _GH_REVIEW_DONE _gh_wrapper_review_script

GIT=/usr/bin/git
fail=0
_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

export HOME="${WORKDIR}/home"
mkdir -p "${HOME}/.config/gh" "${HOME}/neutral-cwd"
export TMPDIR="${WORKDIR}/tmp"
mkdir -p "${TMPDIR}"
export GH_WRAPPER_BEACON_DIR="${HOME}/no-beacon-dir"
HOSTS="${HOME}/.config/gh/hosts.yml"

# hosts.yml: active login, then held logins. AndrewMRich's mixed casing is deliberate.
_write_hosts() {
  local active="$1"
  shift
  {
    printf 'github.com:\n    git_protocol: ssh\n    users:\n'
    local u
    for u in "$@"; do
      printf '        %s:\n' "${u}"
    done
    printf '    user: %s\n' "${active}"
  } >"${HOSTS}"
}

for owner in smartwatermelon beacon-biosignals; do
  "${GIT}" init -q "${WORKDIR}/${owner}-repo"
  "${GIT}" -C "${WORKDIR}/${owner}-repo" remote add origin \
    "git@github.com:${owner}/example.git"
done
SWM="${WORKDIR}/smartwatermelon-repo"
BEACON="${WORKDIR}/beacon-biosignals-repo"
NEUTRAL="${HOME}/neutral-cwd"

# Stub: `auth token --user X` prints kr-X if held (exact case); `auth switch` edits hosts.yml.
LOG="${WORKDIR}/gh.log"
SWITCH_LOG="${WORKDIR}/switch.log"
STUB_DIR="${WORKDIR}/stub-bin"
mkdir -p "${STUB_DIR}"
cat >"${STUB_DIR}/gh" <<STUB_EOF
#!/usr/bin/env bash
user=""
prev=""
for a in "\$@"; do
  [[ "\${prev}" == "--user" ]] && user="\${a}"
  prev="\${a}"
done
if [[ "\$1" == auth && "\$2" == token ]]; then
  grep -q "^        \${user}:\$" "${HOSTS}" || { echo "no oauth token found for \${user}" >&2; exit 1; }
  case "\${user}" in
    twistedmelonman | AndrewMRich) printf 'kr-%s\n' "\${user}"; exit 0 ;;
    *) echo "no oauth token found for \${user}" >&2; exit 1 ;;
  esac
fi
if [[ "\$1" == auth && "\$2" == switch ]]; then
  printf '%s\n' "\${user}" >>"${SWITCH_LOG}"
  grep -q "^        \${user}:\$" "${HOSTS}" || exit 1
  sed -i.bak -E "s/^    user: .*/    user: \${user}/" "${HOSTS}"
  exit 0
fi
printf 'token=%s|%s\n' "\${GH_TOKEN:-<unset>}" "\$*" >>"${LOG}"
[[ -n "\${STUB_SCOPE:-}" ]] && echo 'gh: This API operation needs the "admin:org" scope.' >&2
exit "\${STUB_RC:-0}"
STUB_EOF
chmod +x "${STUB_DIR}/gh"

WRAP_DIR="${WORKDIR}/wrap-bin"
mkdir -p "${WRAP_DIR}"
ln -s "${WRAPPER}" "${WRAP_DIR}/gh"
FN_DRIVER="${WORKDIR}/fn-driver.sh"
{
  printf 'source %q\n' "${WRAPPER}"
  printf '%s\n' 'gh "$@"'
} >"${FN_DRIVER}"
# Prints "clean" when no token is visible in the caller's shell. Prints no value.
LEAK_DRIVER="${WORKDIR}/leak-driver.sh"
{
  printf 'source %q\n' "${WRAPPER}"
  cat <<'DRIVER_EOF'
gh pr list >/dev/null 2>&1
[[ -z "${GH_TOKEN+x}" && -z "${_gh_wrapper_keyring_token:-}" ]] && echo clean
DRIVER_EOF
} >"${LEAK_DRIVER}"

# _run MODE CWD GH-ARGS... sets rc, err, logged (token on the last real call),
# called (lines in LOG) and switched (lines in SWITCH_LOG).
_run() {
  local mode="$1" cwd="$2"
  shift 2
  : >"${LOG}"
  : >"${SWITCH_LOG}"
  if [[ "${mode}" == "standalone" ]]; then
    (cd "${cwd}" && PATH="${STUB_DIR}:${PATH}" bash "${WRAPPER}" "$@") >/dev/null 2>"${WORKDIR}/err"
  else
    (cd "${cwd}" && PATH="${WRAP_DIR}:${STUB_DIR}:${PATH}" bash "${FN_DRIVER}" "$@") >/dev/null 2>"${WORKDIR}/err"
  fi
  rc=$?
  err="$(cat "${WORKDIR}/err")"
  logged="$(tail -1 "${LOG}" 2>/dev/null | sed -E 's/^token=([^|]*)\|.*/\1/')"
  called="$(wc -l <"${LOG}" | tr -d ' ')"
  switched="$(wc -l <"${SWITCH_LOG}" | tr -d ' ')"
}

for mode in standalone function; do
  echo "--- ${mode} mode"

  # (a) Active account is wrong for the owner: the real gh gets the owner's
  # keyring token, and nothing switches.
  _write_hosts AndrewMRich AndrewMRich twistedmelonman
  _run "${mode}" "${SWM}" pr list
  if [[ "${rc}" -eq 0 && "${logged}" == "kr-twistedmelonman" ]]; then
    _pass "${mode}: wrong active account, real gh gets twistedmelonman's token"
  else
    _fail "${mode}: wrong active account: rc=${rc} called=${called} err=${err}"
  fi
  if [[ "${switched}" == "0" ]]; then
    _pass "${mode}: no gh auth switch"
  else
    _fail "${mode}: gh auth switch ran ${switched} time(s)"
  fi

  # (d) hosts.yml is byte-identical after the call.
  _write_hosts AndrewMRich AndrewMRich twistedmelonman
  cp "${HOSTS}" "${WORKDIR}/hosts.before"
  _run "${mode}" "${SWM}" pr list
  if cmp -s "${HOSTS}" "${WORKDIR}/hosts.before"; then
    _pass "${mode}: hosts.yml unchanged"
  else
    _fail "${mode}: hosts.yml was rewritten"
  fi

  # Active account already right: still injected, so a later switch by
  # another shell cannot change who this call runs as.
  _write_hosts twistedmelonman AndrewMRich twistedmelonman
  _run "${mode}" "${SWM}" pr list
  if [[ "${rc}" -eq 0 && "${logged}" == "kr-twistedmelonman" ]]; then
    _pass "${mode}: right active account, token still injected"
  else
    _fail "${mode}: right active account: rc=${rc} called=${called} err=${err}"
  fi

  # Keyring casing: andrewmrich is held as AndrewMRich, and --user is exact.
  _run "${mode}" "${BEACON}" pr list
  if [[ "${rc}" -eq 0 && "${logged}" == "kr-AndrewMRich" ]]; then
    _pass "${mode}: --user uses the keyring's casing"
  else
    _fail "${mode}: keyring casing: rc=${rc} called=${called} err=${err}"
  fi

  # A keyring token is not an env-token override: no "unset GH_TOKEN" hint.
  STUB_SCOPE=1 STUB_RC=4 _run "${mode}" "${SWM}" api orgs/smartwatermelon/actions/secrets
  if [[ "${rc}" -eq 4 && "${logged}" == "kr-twistedmelonman" && "${err}" != *"lacks the"* ]]; then
    _pass "${mode}: keyring token gets no env-token scope hint"
  else
    _fail "${mode}: scope hint: rc=${rc} err=${err}"
  fi

  # (c) The login is not in the keyring: fail closed, name it, say how to add
  # it, and never reach the real gh.
  _write_hosts AndrewMRich AndrewMRich
  _run "${mode}" "${SWM}" pr list
  if [[ "${rc}" -ne 0 && "${called}" == "0" && "${switched}" == "0" ]]; then
    _pass "${mode}: missing login fails closed without running gh"
  else
    _fail "${mode}: missing login: rc=${rc} called=${called} switched=${switched}"
  fi
  if [[ "${err}" == *"twistedmelonman"* && "${err}" == *"gh auth login"* ]]; then
    _pass "${mode}: missing login message names the login and gh auth login"
  else
    _fail "${mode}: missing login message: ${err}"
  fi

  # Unresolved owner: no lookup, no injection, the active account is used.
  _write_hosts twistedmelonman AndrewMRich twistedmelonman
  _run "${mode}" "${NEUTRAL}" api user
  if [[ "${rc}" -eq 0 && "${logged}" == "<unset>" && "${switched}" == "0" ]]; then
    _pass "${mode}: unresolved owner runs without an injected token"
  else
    _fail "${mode}: unresolved owner: rc=${rc} token-set=$([[ "${logged}" == "<unset>" ]] || echo yes)"
  fi

  # No hosts.yml at all (a CI runner): nothing to look up, gh runs as is.
  rm -f "${HOSTS}"
  _run "${mode}" "${SWM}" pr list
  if [[ "${rc}" -eq 0 && "${logged}" == "<unset>" ]]; then
    _pass "${mode}: no hosts.yml, no lookup"
  else
    _fail "${mode}: no hosts.yml: rc=${rc} err=${err}"
  fi
done

# (b) Function mode leaves the caller's shell as it was.
_write_hosts AndrewMRich AndrewMRich twistedmelonman
after="$(cd "${SWM}" && PATH="${WRAP_DIR}:${STUB_DIR}:${PATH}" bash "${LEAK_DRIVER}")"
if [[ "${after}" == "clean" ]]; then
  _pass "function: caller's GH_TOKEN stays unset after the call"
else
  _fail "function: the keyring token leaked into the caller's shell"
fi

if [[ ${fail} -eq 0 ]]; then
  echo "test-gh-wrapper-keyring-token.sh: all assertions passed"
  exit 0
fi
exit 1
