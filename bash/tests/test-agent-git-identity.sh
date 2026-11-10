#!/usr/bin/env bash
# git/agent-identity: App bot identity in App-routed repos only; matches gh-app-routes.conf.
# KNOWN-BAD on origin/main: 7 fail.
set -uo pipefail
unset CDPATH

TESTS_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-env-isolation.sh
source "${TESTS_DIR}/lib/git-env-isolation.sh"
isolate_git_env
REPO_ROOT="$(CDPATH='' cd "${TESTS_DIR}/../.." && pwd)"
AGENT_FILE="${REPO_ROOT}/git/agent-identity"
ROUTES_FILE="${REPO_ROOT}/bash/gh-app-routes.conf"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-git-identity-test.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

fail=0
_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

# A sandboxed global config stands in for ~/.config/git/config + ~/.gitconfig-beacon.
export HOME="${WORKDIR}/home"
mkdir -p "${HOME}"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${WORKDIR}/global.gitconfig"
printf '[user]\n\tname = Human\n\temail = human@example.com\n' >"${GIT_CONFIG_GLOBAL}"
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS

SW_BOT='345515361+smartwatermelon-agent[bot]@users.noreply.github.com'
NO_BOT='354264458+nightowlstudiollc-agent[bot]@users.noreply.github.com'

# Checks the commit email an agent session gets in a fresh repo with this origin.
_check() {
  local label="$1" want="$2" url="$3" include="${4:-${AGENT_FILE}}" dir got
  dir="$(mktemp -d "${WORKDIR}/repo.XXXXXX")"
  git init -q "${dir}"
  git -C "${dir}" remote add origin "${url}"
  got="$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=include.path GIT_CONFIG_VALUE_0="${include}" \
    git -C "${dir}" config user.email || true)"
  if [[ "${got}" == "${want}" ]]; then
    _pass "${label}"
  else
    _fail "${label}: want '${want}', got '${got}'"
  fi
}

echo "== App-routed owners get the bot"
_check "smartwatermelon, SSH alias" "${SW_BOT}" git@github-smartwatermelon:smartwatermelon/claude-config.git
_check "smartwatermelon, plain SSH" "${SW_BOT}" git@github.com:smartwatermelon/dotfiles.git
_check "smartwatermelon, HTTPS" "${SW_BOT}" https://github.com/smartwatermelon/claude-config.git
_check "nightowlstudiollc, SSH alias" "${NO_BOT}" git@github-nightowl:nightowlstudiollc/kebab-tax.git
_check "nightowlstudiollc, HTTPS" "${NO_BOT}" https://github.com/nightowlstudiollc/kebab-tax.git

echo "== Other owners keep the normal identity"
_check "twistedmelonman" human@example.com git@github-smartwatermelon:twistedmelonman/dotfiles.git
_check "beacon-biosignals" human@example.com git@github.com:beacon-biosignals/infra.git
_check "andrewmrich" human@example.com git@github.com:andrewmrich/beacon-workspace.git
_check "owner name only as a prefix" human@example.com git@github.com:smartwatermelon-fork/x.git

echo "== A missing include file changes nothing"
_check "missing file, routed owner" human@example.com https://github.com/smartwatermelon/x.git "${WORKDIR}/absent"

echo "== An env identity still wins"
dir="$(mktemp -d "${WORKDIR}/repo.XXXXXX")"
git init -q "${dir}"
git -C "${dir}" remote add origin https://github.com/smartwatermelon/x.git
ident="$(GIT_AUTHOR_EMAIL=env@example.com GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=include.path \
  GIT_CONFIG_VALUE_0="${AGENT_FILE}" git -C "${dir}" var GIT_AUTHOR_IDENT || true)"
if [[ "${ident}" == *"<env@example.com>"* ]]; then
  _pass "GIT_AUTHOR_EMAIL outranks the file"
else
  _fail "GIT_AUTHOR_EMAIL outranks the file: got '${ident}'"
fi

echo "== Every owner/* route has an identity"
while IFS=$'\t' read -r route _; do
  [[ "${route}" != \#* && "${route}" == */\* ]] || continue
  owner="${route%/\*}"
  if [[ -f "${REPO_ROOT}/git/agent-identity-${owner}" ]] \
    && grep -qF "hasconfig:remote.*.url:git@github*:${owner}/**" "${AGENT_FILE}" \
    && grep -qF "hasconfig:remote.*.url:https://github.com/${owner}/**" "${AGENT_FILE}"; then
    _pass "route ${route}"
  else
    _fail "route ${route}: no SSH and HTTPS blocks in git/agent-identity, or no git/agent-identity-${owner}"
  fi
done <"${ROUTES_FILE}"

exit "${fail}"
