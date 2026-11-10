#!/usr/bin/env bash
# gh-wrapper app-only rule (2026-11-09): an agent acts on GitHub only as a GitHub App.

# Agent (CLAUDECODE or CODEX_*), not arich-mac: no App route, a bad route or a failed mint exits before gh runs.

# Without the signal, nothing changes. A `hostname` stub on PATH picks the host.

# KNOWN-BAD on origin/main: 16 agent cases fail (PAT used, or no rule line).
set -uo pipefail
unset CDPATH

TESTS_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${TESTS_DIR}/../gh-wrapper.sh"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gh-app-only-test.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

unset GH_TOKEN GITHUB_TOKEN GH_HOST GH_REPO CLAUDE_GH_TOKEN_LOGIN CLAUDE_GH_TOKEN_ROUTER
unset GH_TOKEN_SWM GH_TOKEN_NOS GH_TOKEN_TWM _GH_REVIEW_DONE _gh_wrapper_review_script
unset CLAUDECODE CODEX_THREAD_ID CODEX_SESSION_ID

GIT=/usr/bin/git
fail=0
_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

export HOME="${WORKDIR}/home"
export XDG_CACHE_HOME="${WORKDIR}/cache"
mkdir -p "${HOME}/.config/gh" "${HOME}/neutral-cwd"
cat >"${HOME}/.config/gh/hosts.yml" <<'YAML'
github.com:
    user: twistedmelonman
    oauth_token: fake
YAML
export TMPDIR="${WORKDIR}/tmp"
mkdir -p "${TMPDIR}"

ITEM='op://Automation/test app'
ROUTES="${WORKDIR}/routes.conf"
printf 'smartwatermelon/claude-wrapper\t%s\nsmartwatermelon/broken no-tab\n' "${ITEM}" >"${ROUTES}"
CACHE_KEY="$(printf '%s' "${ITEM}" | openssl dgst -sha256 -r)"
CACHE_FILE="${XDG_CACHE_HOME}/gh-app-tokens/${CACHE_KEY%% *}"
_seed_cache() {
  mkdir -p "${CACHE_FILE%/*}"
  chmod 700 "${CACHE_FILE%/*}"
  local now
  now="$(date +%s)"
  printf '%s\nghs_app.tok-1\n' "$((now + 3000))" >"${CACHE_FILE}"
  chmod 600 "${CACHE_FILE}"
}

for repo in claude-wrapper example broken; do
  "${GIT}" init -q "${WORKDIR}/${repo}"
  "${GIT}" -C "${WORKDIR}/${repo}" remote add origin "git@github.com:smartwatermelon/${repo}.git"
done

LOG="${WORKDIR}/gh.log"
HOST_LOG="${WORKDIR}/hostname.log"
STUB_DIR="${WORKDIR}/stub-bin"
mkdir -p "${STUB_DIR}"
cat >"${STUB_DIR}/gh" <<STUB_EOF
#!/usr/bin/env bash
[[ "\$1 \$2" == "auth token" ]] && { printf 'kr-%s\n' "\${*: -1}"; exit 0; }
printf 'token=%s|%s\n' "\${GH_TOKEN:-<unset>}" "\$*" >>"${LOG}"
exit 0
STUB_EOF
# STUB_HOST names the host; STUB_HOST=fail makes hostname itself fail.
cat >"${STUB_DIR}/hostname" <<STUB_EOF
#!/usr/bin/env bash
echo ran >>"${HOST_LOG}"
[[ "\${STUB_HOST:-ASIAGO}" == fail ]] && exit 1
printf '%s\n' "\${STUB_HOST:-ASIAGO}"
STUB_EOF
# Every mint fails: only the seeded cache can supply a token.
printf '#!/usr/bin/env bash\nexit 1\n' >"${STUB_DIR}/op"
printf '#!/usr/bin/env bash\nexit 22\n' >"${STUB_DIR}/curl"
# The minter falls back to the macOS Keychain when op fails; keep it off the real one.
printf '#!/usr/bin/env bash\nexit 44\n' >"${STUB_DIR}/security"
chmod +x "${STUB_DIR}/gh" "${STUB_DIR}/hostname" "${STUB_DIR}/op" "${STUB_DIR}/curl" "${STUB_DIR}/security"

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

# _run MODE CWD [VAR=VALUE ...] -- ARGS: sets rc, err, calls (stub log lines), logged (token on the last call).
_run() {
  local mode="$1" cwd="$2"
  shift 2
  local -a assigns=()
  while [[ "$1" != "--" ]]; do
    assigns+=("$1")
    shift
  done
  shift
  : >"${LOG}"
  : >"${HOST_LOG}"
  local -a common=(GH_APP_ROUTES_FILE="${ROUTES}" GH_TOKEN=launch-stub GH_TOKEN_SWM=swm-stub
    GH_TOKEN_TWM=twm-stub GH_TOKEN_NOS=nos-stub ${assigns[@]+"${assigns[@]}"})
  if [[ "${mode}" == "standalone" ]]; then
    (cd "${cwd}" && env "${common[@]}" PATH="${STUB_DIR}:${PATH}" bash "${WRAPPER}" "$@") >/dev/null 2>"${WORKDIR}/err"
  else
    (cd "${cwd}" && env "${common[@]}" PATH="${WRAP_DIR}:${STUB_DIR}:${PATH}" bash "${FN_DRIVER}" "$@") \
      >/dev/null 2>"${WORKDIR}/err"
  fi
  rc=$?
  err="$(cat "${WORKDIR}/err")"
  calls="$(wc -l <"${LOG}" | tr -d ' ')"
  logged="$(tail -1 "${LOG}" 2>/dev/null | sed -E 's/^token=([^|]*)\|.*/\1/')"
}

_expect() {
  local want="$1" label="$2"
  if [[ "${rc}" -eq 0 && "${calls}" == 1 && "${logged}" == "${want}" ]]; then
    _pass "${label}"
  else
    _fail "${label}: rc=${rc} calls=${calls} token=${logged} err=${err}"
  fi
}

RULE="agents act on GitHub only as a GitHub App; this call has no App route"
_expect_refused() {
  local label="$1"
  if [[ "${rc}" -ne 0 && "${calls}" == 0 && "${err}" == *"[gh] ERROR: ${RULE}"* ]]; then
    _pass "${label}"
  else
    _fail "${label}: rc=${rc} calls=${calls} token=${logged} err=${err}"
  fi
}

CW="${WORKDIR}/claude-wrapper"
EX="${WORKDIR}/example"
BR="${WORKDIR}/broken"
NEUTRAL="${HOME}/neutral-cwd"

for mode in standalone function; do
  echo "--- ${mode} mode"
  _seed_cache

  # Andrew's shell (no agent signal): exactly the old behavior, and hostname never runs.
  _run "${mode}" "${EX}" -- pr list
  _expect swm-stub "${mode}: no agent: unrouted repo keeps GH_TOKEN_SWM"
  [[ -s "${HOST_LOG}" ]] && _fail "${mode}: no agent: hostname ran"
  _run "${mode}" "${NEUTRAL}" -- api user
  _expect launch-stub "${mode}: no agent: owner-less call keeps the launch token"
  _run "${mode}" "${NEUTRAL}" -- pr list -R twistedmelonman/example
  _expect twm-stub "${mode}: no agent: twistedmelonman keeps GH_TOKEN_TWM"
  _run "${mode}" "${CW}" -- pr list
  _expect ghs_app.tok-1 "${mode}: no agent: routed repo uses the app token"
  [[ -s "${HOST_LOG}" ]] && _fail "${mode}: no agent: hostname ran on a routed call"

  # Agent on a personal Mac: only App-routed calls run.
  _run "${mode}" "${CW}" CLAUDECODE=1 -- pr list
  _expect ghs_app.tok-1 "${mode}: agent: routed repo uses the app token"
  _run "${mode}" "${EX}" CLAUDECODE=1 -- pr list
  _expect_refused "${mode}: agent: unrouted repo is refused"
  _run "${mode}" "${NEUTRAL}" CLAUDECODE=1 -- pr list -R twistedmelonman/example
  _expect_refused "${mode}: agent: twistedmelonman (no App) is refused"
  _run "${mode}" "${NEUTRAL}" CLAUDECODE=1 -- api user
  _expect_refused "${mode}: agent: owner-less api user is refused"
  _run "${mode}" "${NEUTRAL}" CLAUDECODE=1 GH_TOKEN= -- search issues foo
  _expect_refused "${mode}: agent: owner-less search with GH_TOKEN empty is refused"
  _run "${mode}" "${EX}" CODEX_THREAD_ID=t1 -- pr list
  _expect_refused "${mode}: Codex agent: unrouted repo is refused"
  _run "${mode}" "${EX}" CLAUDECODE=1 STUB_HOST=fail -- pr list
  _expect_refused "${mode}: agent: hostname failure is treated as a personal Mac"
  _run "${mode}" "${BR}" CLAUDECODE=1 -- pr list
  _expect_refused "${mode}: agent: malformed route is refused with the rule"

  # arich-mac (either case) keeps the old agent behavior.
  _run "${mode}" "${EX}" CLAUDECODE=1 STUB_HOST=ARICH-MAC -- pr list
  _expect swm-stub "${mode}: agent on ARICH-MAC: unrouted repo keeps GH_TOKEN_SWM"
  _run "${mode}" "${NEUTRAL}" CLAUDECODE=1 STUB_HOST=arich-mac -- pr list -R twistedmelonman/example
  _expect twm-stub "${mode}: agent on arich-mac: twistedmelonman keeps GH_TOKEN_TWM"

  # No cache and op fails.
  rm -f "${CACHE_FILE}"
  _run "${mode}" "${CW}" CLAUDECODE=1 -- pr list
  _expect_refused "${mode}: agent: mint failure is refused with the rule"
  _run "${mode}" "${CW}" -- pr list
  if [[ "${rc}" -ne 0 && "${calls}" == 0 && "${err}" == *"Failing closed"* && "${err}" != *"${RULE}"* ]]; then
    _pass "${mode}: no agent: mint failure fails closed as before (no rule line)"
  else
    _fail "${mode}: no agent: mint failure: rc=${rc} calls=${calls} err=${err}"
  fi
done

exit "${fail}"
