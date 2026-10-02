#!/usr/bin/env bash
# Off-org guards in gh-wrapper.sh (dotfiles#339): pr new forced draft; pr ready and undrafted api POST pulls refused.

# Each case runs in standalone and function mode against a stub gh. No network.

# Known-bad on origin/main: the pr new, pr ready and api POST refusal cases fail there.
set -uo pipefail
unset CDPATH

TESTS_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${TESTS_DIR}/../gh-wrapper.sh"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gh-offorg-guards-test.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

unset GH_TOKEN GITHUB_TOKEN GH_HOST GH_REPO CLAUDE_GH_TOKEN_LOGIN CLAUDE_GH_TOKEN_ROUTER
unset GH_TOKEN_SWM GH_TOKEN_NOS GH_TOKEN_TWM _GH_REVIEW_DONE _gh_wrapper_review_script

fail=0
_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

export HOME="${WORKDIR}/home"
mkdir -p "${HOME}/.config/gh" "${HOME}/neutral-cwd"
printf 'github.com:\n    user: twistedmelonman\n    oauth_token: fake\n' >"${HOME}/.config/gh/hosts.yml"
export TMPDIR="${WORKDIR}/tmp"
mkdir -p "${TMPDIR}"
NEUTRAL="${HOME}/neutral-cwd"

LOG="${WORKDIR}/gh.log"
STUB_DIR="${WORKDIR}/stub-bin"
mkdir -p "${STUB_DIR}"
cat >"${STUB_DIR}/gh" <<STUB_EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${LOG}"
exit 0
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

# _run MODE ARGS... sets rc, err, and called (the argv the stub saw, or empty).
_run() {
  local mode="$1"
  shift
  : >"${LOG}"
  if [[ "${mode}" == "standalone" ]]; then
    (cd "${NEUTRAL}" && PATH="${STUB_DIR}:${PATH}" bash "${WRAPPER}" "$@") >/dev/null 2>"${WORKDIR}/err"
  else
    (cd "${NEUTRAL}" && PATH="${WRAP_DIR}:${STUB_DIR}:${PATH}" bash "${FN_DRIVER}" "$@") >/dev/null 2>"${WORKDIR}/err"
  fi
  rc=$?
  err="$(cat "${WORKDIR}/err")"
  called="$(cat "${LOG}")"
}

expect_refused() {
  local mode="$1" label="$2"
  shift 2
  _run "${mode}" "$@"
  if [[ "${rc}" -ne 0 && -z "${called}" && "${err}" == *"human"* && "${err}" == *"GitHub UI"* ]]; then
    _pass "${mode}: ${label} refused"
  else
    _fail "${mode}: ${label}: expected refusal, rc=${rc} called='${called}' err='${err}'"
  fi
}

expect_passes() {
  local mode="$1" label="$2" want="$3"
  shift 3
  _run "${mode}" "$@"
  if [[ "${rc}" -eq 0 && "${called}" == *"${want}"* && "${err}" != *BLOCKED* ]]; then
    _pass "${mode}: ${label} passes"
  else
    _fail "${mode}: ${label}: expected pass containing '${want}', rc=${rc} called='${called}' err='${err}'"
  fi
}

OFF=someoutsideorg/foo
for mode in standalone function; do
  echo "--- ${mode} mode"

  # (1) pr new
  expect_passes "${mode}" "off-org pr new gets --draft" "--draft" pr new -R "${OFF}" --title x
  expect_passes "${mode}" "off-org pr create still gets --draft" "--draft" pr create -R "${OFF}" --title x
  _run "${mode}" pr new -R smartwatermelon/dotfiles --title x
  if [[ "${called}" != *--draft* && "${rc}" -eq 0 ]]; then
    _pass "${mode}: in-org pr new not forced"
  else
    _fail "${mode}: in-org pr new: rc=${rc} called='${called}'"
  fi

  # (2) pr ready
  expect_refused "${mode}" "off-org pr ready" pr ready 5 -R "${OFF}"
  expect_refused "${mode}" "off-org pr ready (--repo=)" pr ready 5 --repo="${OFF}"
  expect_passes "${mode}" "off-org pr ready --undo" "pr ready 5" pr ready 5 -R "${OFF}" --undo
  expect_passes "${mode}" "in-org pr ready" "pr ready 5" pr ready 5 -R smartwatermelon/dotfiles
  expect_passes "${mode}" "off-org pr list unaffected" "pr list" pr list -R "${OFF}"

  # (3) api POST to pulls
  expect_refused "${mode}" "api -X POST off-org pulls" api -X POST "repos/${OFF}/pulls" -f title=x
  expect_refused "${mode}" "api --method=POST, leading slash" api --method=POST "/repos/${OFF}/pulls"
  expect_refused "${mode}" "api implicit POST via -f" api "repos/${OFF}/pulls" -f title=x -f head=a
  expect_refused "${mode}" "api implicit POST via --raw-field" api "repos/${OFF}/pulls" --raw-field title=x
  expect_refused "${mode}" "api implicit POST via --input" api "repos/${OFF}/pulls" --input body.json
  expect_refused "${mode}" "api draft=false" api -X POST "repos/${OFF}/pulls" -F draft=false
  expect_refused "${mode}" "api draft=true then draft=false" api -X POST "repos/${OFF}/pulls" -F draft=true -F draft=false
  expect_passes "${mode}" "api POST with -F draft=true" "repos/${OFF}/pulls" api -X POST "repos/${OFF}/pulls" -F draft=true -f title=x
  expect_passes "${mode}" "api implicit POST with draft=true" "repos/${OFF}/pulls" api "repos/${OFF}/pulls" -f title=x -F draft=true
  expect_passes "${mode}" "api GET off-org pulls" "repos/${OFF}/pulls" api "repos/${OFF}/pulls"
  expect_passes "${mode}" "api -X GET with fields" "repos/${OFF}/pulls" api -X GET "repos/${OFF}/pulls" -f state=open
  expect_passes "${mode}" "api POST to pulls/<n>/comments" "pulls/5/comments" api -X POST "repos/${OFF}/pulls/5/comments" -f state=x
  expect_passes "${mode}" "api POST in-org pulls" "repos/smartwatermelon/dotfiles/pulls" api -X POST repos/smartwatermelon/dotfiles/pulls -f title=x
done

exit "${fail}"
