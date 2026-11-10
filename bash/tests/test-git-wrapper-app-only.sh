#!/usr/bin/env bash
# git-wrapper app-only rule (2026-11-09): an agent pushes to GitHub only as a GitHub App.

# Agent (CLAUDECODE or CODEX_*), not arich-mac: an unrouted push to a github.com remote is refused.

# Other remotes, fetch, and Andrew's shell (no signal) are unchanged. A `hostname` stub on PATH picks the host.

# KNOWN-BAD on origin/main: 12 fail (6 refusals x 2 bashes; push runs).
set -uo pipefail
unset CDPATH

TESTS_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${TESTS_DIR}/../git-wrapper.sh"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/git-app-only-test.XXXXXX")"
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
: >"${HOME}/.gitconfig"
unset GIT_ASKPASS SSH_ASKPASS GIT_TERMINAL_PROMPT _GIT_WRAPPER_ACTIVE
unset CLAUDECODE CODEX_THREAD_ID CODEX_SESSION_ID

ITEM='op://Automation/test app'
export GH_APP_ROUTES_FILE="${WORKDIR}/routes.conf"
printf 'smartwatermelon/claude-wrapper\t%s\n' "${ITEM}" >"${GH_APP_ROUTES_FILE}"
CACHE_KEY="$(printf '%s' "${ITEM}" | openssl dgst -sha256 -r)"
CACHE_FILE="${XDG_CACHE_HOME}/gh-app-tokens/${CACHE_KEY%% *}"
# Built in two parts so secret scanners skip the fake.
TOK="ghs_push"".tok-7"
mkdir -p "${CACHE_FILE%/*}"
chmod 700 "${CACHE_FILE%/*}"
NOW="$(date +%s)"
printf '%s\n%s\n' "$((NOW + 3000))" "${TOK}" >"${CACHE_FILE}"
chmod 600 "${CACHE_FILE}"

# The stub logs each push (argv only) and never contacts a remote; other commands run the real git.
LOG="${WORKDIR}/push.log"
HOST_LOG="${WORKDIR}/hostname.log"
STUB_DIR="${WORKDIR}/stub-bin"
mkdir -p "${STUB_DIR}"
cat >"${STUB_DIR}/git" <<STUB_EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [[ "\${a}" == push ]]; then
    printf 'argv=%s\n' "\$*" >>"${LOG}"
    exit 0
  fi
done
exec ${REAL_GIT} "\$@"
STUB_EOF
# STUB_HOST names the host.
cat >"${STUB_DIR}/hostname" <<STUB_EOF
#!/usr/bin/env bash
echo ran >>"${HOST_LOG}"
printf '%s\n' "\${STUB_HOST:-ASIAGO}"
STUB_EOF
printf '#!/usr/bin/env bash\nexit 1\n' >"${STUB_DIR}/op"
printf '#!/usr/bin/env bash\nexit 6\n' >"${STUB_DIR}/curl"
# The minter falls back to the macOS Keychain when op fails; keep it off the real one.
printf '#!/usr/bin/env bash\nexit 44\n' >"${STUB_DIR}/security"
chmod +x "${STUB_DIR}/git" "${STUB_DIR}/hostname" "${STUB_DIR}/op" "${STUB_DIR}/curl" "${STUB_DIR}/security"
# ssh stub (ssh -G only): a github-* alias has HostName github.com; any other host is itself. Never the real ~/.ssh/config.
cat >"${STUB_DIR}/ssh" <<'STUB_EOF'
#!/usr/bin/env bash
[[ "$1" == -G ]] || exit 255
h="$2"
[[ "${h}" == -- ]] && h="$3"
case "${h}" in github-*) echo "hostname github.com" ;; *) echo "hostname ${h}" ;; esac
STUB_EOF
chmod +x "${STUB_DIR}/ssh"

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
_mkrepo plain git@github.com:smartwatermelon/example.git
_mkrepo https https://github.com/twistedmelonman/example.git
_mkrepo alias git@github.com-twm:twistedmelonman/example.git
_mkrepo sshalias git@github-alias:twistedmelonman/example.git
_mkrepo gitlab git@gitlab.com:someone/example.git
"${REAL_GIT}" init -q --bare "${WORKDIR}/bare.git"
_mkrepo local "${WORKDIR}/bare.git"
# Seed the bare repo so the fetch case has a ref to fetch.
"${REAL_GIT}" -C "${WORKDIR}/local" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m seed
"${REAL_GIT}" -C "${WORKDIR}/local" push -q origin HEAD:refs/heads/main
"${REAL_GIT}" -C "${WORKDIR}/bare.git" symbolic-ref HEAD refs/heads/main

# _run BASH CWD [VAR=VALUE ...] -- ARGS: sets rc, err, log (the stub's push log).
_run() {
  local sh="$1" cwd="$2"
  shift 2
  local -a assigns=()
  while [[ "$1" != "--" ]]; do
    assigns+=("$1")
    shift
  done
  shift
  : >"${LOG}"
  : >"${HOST_LOG}"
  (cd "${cwd}" && env ${assigns[@]+"${assigns[@]}"} PATH="${STUB_DIR}:${PATH}" "${sh}" "${DRIVER}" "$@") \
    >/dev/null 2>"${WORKDIR}/err"
  rc=$?
  err="$(cat "${WORKDIR}/err")"
  log="$(cat "${LOG}")"
}

RULE="agents act on GitHub only as a GitHub App; this push has no App route"
_expect_refused() {
  local label="$1"
  if [[ "${rc}" -ne 0 && -z "${log}" && "${err}" == *"[git] ERROR: ${RULE}"* ]]; then
    _pass "${label}"
  else
    _fail "${label}: rc=${rc} log=${log} err=${err}"
  fi
}
# _expect_plain LABEL ARGV: the push ran unchanged (no App config, no rule line).
_expect_plain() {
  local label="$1" want="$2"
  if [[ "${rc}" -eq 0 && "${log}" == "argv=${want}" && "${err}" != *"GitHub App"* ]]; then
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

  # Andrew's shell: unchanged, and hostname never runs.
  _run "${sh}" "${WORKDIR}/plain" -- push origin feat
  _expect_plain "${ver}: no agent: unrouted GitHub push runs unchanged" "push origin feat"
  [[ -s "${HOST_LOG}" ]] && _fail "${ver}: no agent: hostname ran"
  _run "${sh}" "${WORKDIR}/routed" -- push origin feat
  if [[ "${rc}" -eq 0 && "${log}" == *"credential.helper="* ]]; then
    _pass "${ver}: no agent: routed push still goes as the App"
  else
    _fail "${ver}: no agent: routed: rc=${rc} log=${log} err=${err}"
  fi

  # Agent on a personal Mac.
  _run "${sh}" "${WORKDIR}/plain" CLAUDECODE=1 -- push origin feat
  _expect_refused "${ver}: agent: unrouted SSH push to GitHub is refused"
  _run "${sh}" "${WORKDIR}/plain" CLAUDECODE=1 -- push
  _expect_refused "${ver}: agent: bare unrouted push is refused"
  _run "${sh}" "${WORKDIR}/https" CLAUDECODE=1 -- push origin feat
  _expect_refused "${ver}: agent: unrouted HTTPS push to GitHub is refused"
  _run "${sh}" "${WORKDIR}/alias" CLAUDECODE=1 -- push origin feat
  _expect_refused "${ver}: agent: unrouted push via an ssh alias host is refused"
  _run "${sh}" "${WORKDIR}/sshalias" CLAUDECODE=1 -- push origin feat
  _expect_refused "${ver}: agent: unrouted push via a ~/.ssh/config alias of github.com is refused"
  _run "${sh}" "${WORKDIR}/gitlab" CLAUDECODE=1 -- push git@github.com:smartwatermelon/example.git feat
  _expect_refused "${ver}: agent: push to a literal unrouted GitHub URL is refused"
  _run "${sh}" "${WORKDIR}/plain" CODEX_SESSION_ID=s1 -- push origin feat
  _expect_refused "${ver}: Codex agent: unrouted GitHub push is refused"
  _run "${sh}" "${WORKDIR}/routed" CLAUDECODE=1 -- push origin feat
  if [[ "${rc}" -eq 0 && "${log}" == *"credential.helper="* && "${err}" == *"as the GitHub App"* ]]; then
    _pass "${ver}: agent: routed push goes as the App"
  else
    _fail "${ver}: agent: routed: rc=${rc} log=${log} err=${err}"
  fi

  # Not GitHub, or not a push: unaffected.
  _run "${sh}" "${WORKDIR}/gitlab" CLAUDECODE=1 -- push origin feat
  _expect_plain "${ver}: agent: push to a non-GitHub remote runs" "push origin feat"
  _run "${sh}" "${WORKDIR}/local" CLAUDECODE=1 -- push origin feat
  _expect_plain "${ver}: agent: push to a local bare repo runs" "push origin feat"
  _run "${sh}" "${WORKDIR}/plain" CLAUDECODE=1 -- push . HEAD:other
  _expect_plain "${ver}: agent: push to . runs" "push . HEAD:other"
  _run "${sh}" "${WORKDIR}/local" CLAUDECODE=1 -- \
    -c "url.${WORKDIR}/bare.git.insteadOf=git@github.com:smartwatermelon/example.git" \
    fetch -q git@github.com:smartwatermelon/example.git
  if [[ "${rc}" -eq 0 && -z "${log}" && "${err}" != *"GitHub App"* ]]; then
    _pass "${ver}: agent: fetch from an unrouted GitHub URL is untouched"
  else
    _fail "${ver}: agent: fetch: rc=${rc} log=${log} err=${err}"
  fi

  # arich-mac keeps the old behavior.
  _run "${sh}" "${WORKDIR}/plain" CLAUDECODE=1 STUB_HOST=ARICH-MAC -- push origin feat
  _expect_plain "${ver}: agent on ARICH-MAC: unrouted GitHub push runs" "push origin feat"
  _run "${sh}" "${WORKDIR}/https" CLAUDECODE=1 STUB_HOST=arich-mac -- push origin feat
  _expect_plain "${ver}: agent on arich-mac: unrouted HTTPS push runs" "push origin feat"
done

exit "${fail}"
