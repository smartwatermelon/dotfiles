#!/usr/bin/env bash
# git-wrapper routed pushes (claude-config#659): a routed repo pushes over HTTPS as the GitHub App.

# Stub git logs each push and runs a real `git credential fill` with the wrapper's -c options.

# KNOWN-BAD on origin/main: every routed case fails (plain SSH push, no App credential).
set -uo pipefail
unset CDPATH

TESTS_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${TESTS_DIR}/../git-wrapper.sh"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/git-app-push-test.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

REAL_GIT=/usr/bin/git
fail=0
_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

export HOME="${WORKDIR}/home"
export XDG_CACHE_HOME="${WORKDIR}/cache"
export TMPDIR="${WORKDIR}/tmp"
mkdir -p "${HOME}/neutral" "${TMPDIR}"
unset GIT_ASKPASS SSH_ASKPASS GIT_TERMINAL_PROMPT _GIT_WRAPPER_ACTIVE
# A URL-scoped personal helper, as osxkeychain could be: the wrapper's reset must silence it too.
cat >"${HOME}/.gitconfig" <<'GITCONFIG_EOF'
[credential "https://github.com"]
	helper = "!f() { echo username=me; echo password=personal; }; f"
GITCONFIG_EOF

ITEM='op://Automation/test app'
export GH_APP_ROUTES_FILE="${WORKDIR}/routes.conf"
printf 'smartwatermelon/claude-wrapper\t%s\nsmartwatermelon/broken no-tab\n' "${ITEM}" >"${GH_APP_ROUTES_FILE}"
CACHE_KEY="$(printf '%s' "${ITEM}" | openssl dgst -sha256 -r)"
CACHE_FILE="${XDG_CACHE_HOME}/gh-app-tokens/${CACHE_KEY%% *}"
# Built in two parts so secret scanners skip the fake.
TOK="ghs_push"".tok-9"
_seed_cache() {
  mkdir -p "${CACHE_FILE%/*}"
  chmod 700 "${CACHE_FILE%/*}"
  local now
  now="$(date +%s)"
  printf '%s\n%s\n' "$((now + 3000))" "${TOK}" >"${CACHE_FILE}"
  chmod 600 "${CACHE_FILE}"
}

LOG="${WORKDIR}/push.log"
STUB_DIR="${WORKDIR}/stub-bin"
mkdir -p "${STUB_DIR}"
cat >"${STUB_DIR}/git" <<STUB_EOF
#!/usr/bin/env bash
is_push=0
for a in "\$@"; do [[ "\${a}" == push || "\${a}" == pp || "\${a}" == pq ]] && is_push=1; done
((is_push == 1)) || exec ${REAL_GIT} "\$@"
printf 'argv=%s\n' "\$*" >>"${LOG}"
printf 'env=prompt:%s askpass:[%s]\n' "\${GIT_TERMINAL_PROMPT-unset}" "\${GIT_ASKPASS-unset}" >>"${LOG}"
cfg=()
while [[ "\${1:-}" == -c ]]; do cfg+=(-c "\$2"); shift 2; done
pw="\$(printf 'protocol=https\nhost=github.com\npath=smartwatermelon/claude-wrapper.git\n\n' \
  | ${REAL_GIT} \${cfg[@]+"\${cfg[@]}"} credential fill 2>/dev/null | sed -n 's/^password=//p')"
if [[ "\${pw}" == "${TOK}" ]]; then echo cred=match >>"${LOG}"; else echo cred=nomatch >>"${LOG}"; fi
if [[ "\${1:-}" == -C ]]; then cd "\$2" || exit 1; fi
echo "url=\$(${REAL_GIT} \${cfg[@]+"\${cfg[@]}"} remote get-url --push --all origin | tr '\n' ' ')" >>"${LOG}"
exit 0
STUB_EOF
printf '#!/usr/bin/env bash\nexit 1\n' >"${STUB_DIR}/op"
printf '#!/usr/bin/env bash\nexit 6\n' >"${STUB_DIR}/curl"
chmod +x "${STUB_DIR}/git" "${STUB_DIR}/op" "${STUB_DIR}/curl"

DRIVER="${WORKDIR}/driver.sh"
{
  printf 'source %q\n' "${WRAPPER}"
  cat <<'DRIVER_EOF'
git "$@"
DRIVER_EOF
} >"${DRIVER}"

_mkrepo() {
  "${REAL_GIT}" init -q "${WORKDIR}/$1"
  "${REAL_GIT}" -C "${WORKDIR}/$1" remote add origin "$2"
}
_mkrepo routed git@github.com:smartwatermelon/claude-wrapper.git
_mkrepo alias git@github.com-claude:SmartWatermelon/claude-wrapper.git
_mkrepo plain git@github.com:smartwatermelon/example.git
_mkrepo pushurl https://github.com/smartwatermelon/claude-wrapper.git
"${REAL_GIT}" -C "${WORKDIR}/pushurl" config remote.origin.pushurl git@github.com:smartwatermelon/claude-wrapper.git
_mkrepo mixed git@github.com:smartwatermelon/claude-wrapper.git
"${REAL_GIT}" -C "${WORKDIR}/mixed" config --add remote.origin.pushurl git@github.com:smartwatermelon/claude-wrapper.git
"${REAL_GIT}" -C "${WORKDIR}/mixed" config --add remote.origin.pushurl git@github.com:smartwatermelon/example.git
_mkrepo broken git@github.com:smartwatermelon/broken.git
"${REAL_GIT}" -C "${WORKDIR}/routed" config alias.pp "push -u"
"${REAL_GIT}" -C "${WORKDIR}/routed" config alias.pq "pp --no-verify"
_mkrepo pushinsteadof git@github.com:smartwatermelon/example.git
"${REAL_GIT}" -C "${WORKDIR}/pushinsteadof" config url.ssh://elsewhere/.pushInsteadOf https://github.com/

# _run BASH CWD ARGS...: sets rc, err, log (the stub's push log).
_run() {
  local sh="$1" cwd="$2"
  shift 2
  : >"${LOG}"
  (cd "${cwd}" && PATH="${STUB_DIR}:${PATH}" "${sh}" "${DRIVER}" "$@") >/dev/null 2>"${WORKDIR}/err"
  rc=$?
  err="$(cat "${WORKDIR}/err")"
  log="$(cat "${LOG}")"
}

APP_URL="https://github.com/smartwatermelon/claude-wrapper.git"
_expect_app() {
  local label="$1"
  if [[ "${rc}" -eq 0 && "${log}" == *"cred=match"* && "${log}" == *"url=${APP_URL} "* &&
    "${log}" == *"prompt:0 askpass:[]"* && "${log}" == *"argv=-c credential.helper= -c credential.helper=!"* &&
    "${log}" == *"credential.useHttpPath=true"* && "${log}" != *"${TOK}"* && "${err}" != *"${TOK}"* ]]; then
    _pass "${label}"
  else
    _fail "${label}: rc=${rc} log=${log} err=${err}"
  fi
}

BASHES=("${BASH}")
[[ -x /bin/bash && "${BASH}" != /bin/bash ]] && BASHES+=(/bin/bash)
for sh in "${BASHES[@]}"; do
  ver="$("${sh}" -c "echo \${BASH_VERSION}")"
  echo "--- ${sh} (${ver})"
  _seed_cache

  _run "${sh}" "${WORKDIR}/routed" push -u origin feat
  _expect_app "${ver}: push origin on a routed repo goes as the App over HTTPS"
  stored="$("${REAL_GIT}" -C "${WORKDIR}/routed" config --get remote.origin.url)"
  if [[ "${stored}" == git@github.com:smartwatermelon/claude-wrapper.git ]]; then
    _pass "${ver}: stored remote URL unchanged"
  else
    _fail "${ver}: stored URL changed: ${stored}"
  fi
  _run "${sh}" "${WORKDIR}/routed" push
  _expect_app "${ver}: bare push defaults to origin and is routed"
  _run "${sh}" "${HOME}/neutral" -C "${WORKDIR}/routed" push origin HEAD
  _expect_app "${ver}: git -C routed push is routed"
  _run "${sh}" "${WORKDIR}/alias" push origin feat
  _expect_app "${ver}: ssh alias host remote is routed"
  _run "${sh}" "${WORKDIR}/pushurl" push origin feat
  _expect_app "${ver}: explicit SSH pushurl is rewritten too"

  _run "${sh}" "${WORKDIR}/routed" pp origin feat
  _expect_app "${ver}: alias expanding to push is routed"
  _run "${sh}" "${WORKDIR}/routed" pq origin feat
  _expect_app "${ver}: alias of an alias of push is routed"
  _run "${sh}" "${WORKDIR}/routed" push --recurse-submodules on-demand origin feat
  _expect_app "${ver}: separated --recurse-submodules value is not read as the remote"
  _run "${sh}" "${WORKDIR}/routed" push --unknown-opt value origin feat
  if [[ "${rc}" -ne 0 && -z "${log}" && "${err}" == *"not a remote, URL or path"* ]]; then
    _pass "${ver}: a bare word that is no remote refuses the push"
  else
    _fail "${ver}: bare word: rc=${rc} log=${log} err=${err}"
  fi
  _run "${sh}" "${WORKDIR}/plain" push git@github.com:smartwatermelon/claude-wrapper.git feat
  if [[ "${rc}" -eq 0 && "${log}" == *"cred=match"* && "${log}" == *".insteadOf=git@github.com:smartwatermelon/claude-wrapper.git"* ]]; then
    _pass "${ver}: push to a literal routed URL is routed"
  else
    _fail "${ver}: literal URL: rc=${rc} log=${log} err=${err}"
  fi
  _run "${sh}" "${WORKDIR}/pushinsteadof" push git@github.com:smartwatermelon/claude-wrapper.git feat
  if [[ "${rc}" -ne 0 && -z "${log}" && "${err}" == *"pushInsteadOf"* ]]; then
    _pass "${ver}: literal routed URL with a pushInsteadOf rule is refused"
  else
    _fail "${ver}: pushInsteadOf: rc=${rc} log=${log} err=${err}"
  fi

  _run "${sh}" "${WORKDIR}/plain" push origin feat
  if [[ "${rc}" -eq 0 && "${log}" == "argv=push origin feat"* && "${err}" != *"GitHub App"* ]]; then
    _pass "${ver}: unrouted repo pushes unchanged"
  else
    _fail "${ver}: unrouted: rc=${rc} log=${log} err=${err}"
  fi
  _run "${sh}" "${WORKDIR}/routed" status --short
  if [[ "${rc}" -eq 0 && -z "${log}" ]]; then _pass "${ver}: non-push commands untouched"; else _fail "${ver}: status: rc=${rc}"; fi

  _run "${sh}" "${WORKDIR}/mixed" push origin feat
  if [[ "${rc}" -ne 0 && -z "${log}" && "${err}" == *"mixes"* ]]; then
    _pass "${ver}: remote mixing routed and unrouted push URLs is refused"
  else
    _fail "${ver}: mixed: rc=${rc} log=${log} err=${err}"
  fi
  _run "${sh}" "${WORKDIR}/broken" push origin feat
  if [[ "${rc}" -ne 0 && -z "${log}" ]]; then _pass "${ver}: malformed route refuses the push"; else _fail "${ver}: broken: rc=${rc}"; fi

  rm -f "${CACHE_FILE}"
  _run "${sh}" "${WORKDIR}/routed" push origin feat
  if [[ "${rc}" -ne 0 && -z "${log}" && "${err}" == *"Failing closed"* ]]; then
    _pass "${ver}: mint failure refuses the push (no SSH fallback)"
  else
    _fail "${ver}: mint failure: rc=${rc} log=${log} err=${err}"
  fi
done

exit "${fail}"
