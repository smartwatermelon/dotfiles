#!/usr/bin/env bash
# gh-wrapper GitHub App routing (claude-config#659): routed repo -> App token; others keep PATs.

# A routed repo with no token fails closed: gh never runs. No `gh api user` lookup for routed repos.

# Real minter, seeded cache, failing op stub. KNOWN-BAD on origin/main: 14 fail (PAT used, gh runs).
set -uo pipefail
unset CDPATH

TESTS_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${TESTS_DIR}/../gh-wrapper.sh"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gh-app-route-test.XXXXXX")"
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
STUB_DIR="${WORKDIR}/stub-bin"
mkdir -p "${STUB_DIR}"
cat >"${STUB_DIR}/gh" <<STUB_EOF
#!/usr/bin/env bash
[[ "\$1 \$2" == "auth token" ]] && { printf 'kr-%s\n' "\${*: -1}"; exit 0; }
printf 'token=%s|%s\n' "\${GH_TOKEN:-<unset>}" "\$*" >>"${LOG}"
exit 0
STUB_EOF
# Every mint fails: only the seeded cache can supply a token.
printf '#!/usr/bin/env bash\nexit 1\n' >"${STUB_DIR}/op"
printf '#!/usr/bin/env bash\nexit 22\n' >"${STUB_DIR}/curl"
# The minter falls back to the macOS Keychain when op fails; keep it off the real one.
printf '#!/usr/bin/env bash\nexit 44\n' >"${STUB_DIR}/security"
chmod +x "${STUB_DIR}/gh" "${STUB_DIR}/op" "${STUB_DIR}/curl" "${STUB_DIR}/security"

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

# _run MODE CWD -- ARGS: sets rc, err, calls (stub log lines), logged (token on the last call).
_run() {
  local mode="$1" cwd="$2"
  shift 3
  : >"${LOG}"
  local -a common=(GH_APP_ROUTES_FILE="${ROUTES}" GH_TOKEN=launch-stub GH_TOKEN_SWM=swm-stub GH_TOKEN_TWM=twm-stub)
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

CW="${WORKDIR}/claude-wrapper"
EX="${WORKDIR}/example"
NEUTRAL="${HOME}/neutral-cwd"

for mode in standalone function; do
  echo "--- ${mode} mode"
  _seed_cache

  _run "${mode}" "${CW}" -- pr list
  _expect ghs_app.tok-1 "${mode}: routed repo from its checkout uses the app token (one call, no api user)"
  _run "${mode}" "${NEUTRAL}" -- pr list -R SmartWatermelon/Claude-Wrapper
  _expect ghs_app.tok-1 "${mode}: -R routed repo (any case) uses the app token"
  _run "${mode}" "${NEUTRAL}" -- api repos/smartwatermelon/claude-wrapper/pulls
  _expect ghs_app.tok-1 "${mode}: api repos/routed uses the app token"
  _run "${mode}" "${NEUTRAL}" -- pr view https://github.com/smartwatermelon/claude-wrapper/pull/3
  _expect ghs_app.tok-1 "${mode}: PR URL of routed repo uses the app token"
  _run "${mode}" "${EX}" -- api repos/smartwatermelon/claude-wrapper
  _expect ghs_app.tok-1 "${mode}: api endpoint beats the cwd remote"

  _run "${mode}" "${EX}" -- pr list
  _expect swm-stub "${mode}: unrouted repo keeps GH_TOKEN_SWM"
  _run "${mode}" "${CW}" -- pr list -R smartwatermelon/example
  _expect swm-stub "${mode}: -R unrouted from a routed checkout keeps GH_TOKEN_SWM"
  _run "${mode}" "${NEUTRAL}" -- repo list smartwatermelon
  _expect swm-stub "${mode}: owner-only repo list is not routed"
  _run "${mode}" "${NEUTRAL}" -- api orgs/smartwatermelon
  _expect swm-stub "${mode}: api orgs/OWNER is not routed"

  # No cache and op fails: gh must not run at all.
  rm -f "${CACHE_FILE}"
  _run "${mode}" "${CW}" -- pr list
  if [[ "${rc}" -ne 0 && "${calls}" == 0 && "${err}" == *"Failing closed"* ]]; then
    _pass "${mode}: mint failure on a routed repo fails closed, gh never runs"
  else
    _fail "${mode}: mint failure: rc=${rc} calls=${calls} token=${logged} err=${err}"
  fi

  _run "${mode}" "${WORKDIR}/broken" -- pr list
  if [[ "${rc}" -ne 0 && "${calls}" == 0 ]]; then
    _pass "${mode}: malformed route fails closed"
  else
    _fail "${mode}: malformed route: rc=${rc} calls=${calls} token=${logged}"
  fi
done

exit "${fail}"
