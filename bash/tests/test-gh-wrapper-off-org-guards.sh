#!/usr/bin/env bash
# Off-org guards in gh-wrapper.sh (dotfiles#339): pr new forced draft; pr ready and undrafted api POST pulls refused.

# Each case runs in standalone and function mode against a stub gh. No network.

# Known-bad on origin/main: the pr new, pr ready and api POST refusal cases fail there.
# #391 added GH_REPO, PR URL and GraphQL cases (sections 4-5); 48 of them fail on the wrapper before that fix.
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
# `auth token` is the wrapper's keyring lookup, not a call under test: answer
# it with a fixture string and keep it out of the log.
cat >"${STUB_DIR}/gh" <<STUB_EOF
#!/usr/bin/env bash
[[ "\$1 \$2" == "auth token" ]] && { echo keyring-fixture; exit 0; }
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

# GraphQL fixtures (#391): queries the wrapper must read from a file.
GQL_READY="${WORKDIR}/ready.graphql"
GQL_BENIGN="${WORKDIR}/viewer.graphql"
JSON_READY="${WORKDIR}/ready.json"
JSON_ESCAPED="${WORKDIR}/escaped.json"
JSON_BENIGN="${WORKDIR}/viewer.json"
printf '%s\n' 'mutation { markPullRequestReadyForReview(input: {pullRequestId: "PR_x"}) { clientMutationId } }' >"${GQL_READY}"
printf '%s\n' 'query { viewer { login } }' >"${GQL_BENIGN}"
printf '%s\n' '{"query":"mutation{markPullRequestReadyForReview(input:{pullRequestId:\"PR_x\"}){clientMutationId}}"}' >"${JSON_READY}"
# The P is a JSON escape (backslash, u, 0050): it decodes to the mutation name, which a byte scan cannot see.
bs="\\"
printf '%s\n' "{\"query\":\"mutation{mark${bs}u0050ullRequestReadyForReview(input:{pullRequestId:${bs}\"PR_x${bs}\"}){clientMutationId}}\"}" >"${JSON_ESCAPED}"
grep -q 'markPull' "${JSON_ESCAPED}" && echo "fixture error: ${JSON_ESCAPED} is not escaped" >&2 && exit 1
printf '%s\n' '{"query":"query{viewer{login}}"}' >"${JSON_BENIGN}"

# _run MODE ARGS... sets rc, err, and called (the argv the stub saw, or empty).
_run() {
  local mode="$1"
  shift
  : >"${LOG}"
  if [[ "${mode}" == "standalone" ]]; then
    (cd "${NEUTRAL}" && PATH="${STUB_DIR}:${PATH}" bash "${WRAPPER}" "$@") </dev/null >/dev/null 2>"${WORKDIR}/err"
  else
    (cd "${NEUTRAL}" && PATH="${WRAP_DIR}:${STUB_DIR}:${PATH}" bash "${FN_DRIVER}" "$@") </dev/null >/dev/null 2>"${WORKDIR}/err"
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

  # (4) #391 item 1: GH_REPO and a PR URL name the repo. gh's order: URL > -R > GH_REPO > checkout remote.
  GH_REPO="${OFF}" expect_refused "${mode}" "GH_REPO off-org pr ready" pr ready 5
  GH_REPO="github.com/${OFF}" expect_refused "${mode}" "GH_REPO HOST/OWNER/REPO pr ready" pr ready 5
  expect_refused "${mode}" "pr ready https URL" pr ready "https://github.com/${OFF}/pull/5"
  expect_refused "${mode}" "pr ready http www URL with path and query" pr ready "http://www.github.com/${OFF}/pull/5/files?w=1"
  expect_refused "${mode}" "pr ready mixed-case URL" pr ready "HTTPS://GitHub.com/${OFF}/pull/5"
  expect_refused "${mode}" "URL beats -R (off-org URL)" pr ready "https://github.com/${OFF}/pull/5" -R smartwatermelon/dotfiles
  expect_passes "${mode}" "URL beats -R (in-org URL)" "pr ready" pr ready https://github.com/smartwatermelon/dotfiles/pull/5 -R "${OFF}"
  GH_REPO="${OFF}" expect_passes "${mode}" "-R beats GH_REPO (in-org -R)" "pr ready 5" pr ready 5 -R smartwatermelon/dotfiles
  GH_REPO=smartwatermelon/dotfiles expect_refused "${mode}" "-R beats GH_REPO (off-org -R)" pr ready 5 -R "${OFF}"
  expect_passes "${mode}" "-R HOST/OWNER/REPO in-org" "pr ready 5" pr ready 5 -R github.com/smartwatermelon/dotfiles
  expect_passes "${mode}" "in-org URL pr ready" "pr ready" pr ready https://github.com/smartwatermelon/dotfiles/pull/5
  GH_REPO="${OFF}" expect_passes "${mode}" "GH_REPO off-org pr create gets --draft" "--draft" pr create --title x
  GH_REPO="${OFF}" expect_passes "${mode}" "GH_REPO off-org pr new gets --draft" "--draft" pr new --title x
  GH_REPO="${OFF}" expect_refused "${mode}" "GH_REPO fills api {owner}/{repo}" api -X POST "repos/{owner}/{repo}/pulls" -f title=x
  # pr create takes no selector: an in-org URL as a flag value must not beat -R.
  expect_passes "${mode}" "pr create URL value does not beat -R" "--draft" pr create -R "${OFF}" --title https://github.com/smartwatermelon/y/pull/1
  GH_REPO=smartwatermelon/dotfiles _run "${mode}" pr create --title x
  if [[ "${called}" != *--draft* && "${rc}" -eq 0 ]]; then
    _pass "${mode}: GH_REPO in-org pr create not forced"
  else
    _fail "${mode}: GH_REPO in-org pr create: rc=${rc} called='${called}'"
  fi

  # (5) #391 item 2: GraphQL mutations that publish a PR name it by node ID, so they are refused outright.
  expect_refused "${mode}" "graphql markPullRequestReadyForReview" api graphql -f "query=mutation{markPullRequestReadyForReview(input:{pullRequestId:\"PR_x\"}){clientMutationId}}"
  expect_refused "${mode}" "graphql createPullRequest" api graphql -f "query=mutation{createPullRequest(input:{repositoryId:\"R_x\",baseRefName:\"main\",headRefName:\"b\",title:\"t\"}){clientMutationId}}"
  expect_refused "${mode}" "graphql revertPullRequest" api graphql -f "query=mutation{revertPullRequest(input:{pullRequestId:\"PR_x\"}){clientMutationId}}"
  expect_refused "${mode}" "graphql aliased, spaced" api graphql --raw-field "query=mutation { a: markPullRequestReadyForReview (input: {pullRequestId: \$id}) { clientMutationId } }" -f id=PR_x
  expect_refused "${mode}" "graphql via /graphql endpoint" api -X POST /graphql -f "query=mutation{markPullRequestReadyForReview(input:{pullRequestId:\"PR_x\"}){clientMutationId}}"
  expect_refused "${mode}" "graphql via full URL endpoint" api https://api.github.com/graphql -f "query=mutation{markPullRequestReadyForReview(input:{pullRequestId:\"PR_x\"}){clientMutationId}}"
  expect_refused "${mode}" "graphql query from -F @file" api graphql -F "query=@${GQL_READY}"
  expect_refused "${mode}" "graphql query from --input file" api graphql --input "${JSON_READY}"
  expect_refused "${mode}" "graphql --input= file" api graphql "--input=${JSON_READY}"
  expect_refused "${mode}" "graphql --input with \\u escape" api graphql --input "${JSON_ESCAPED}"
  [[ "${err}" == *"escapes"* ]] || _fail "${mode}: \\u escape refused for the wrong reason: ${err}"
  expect_refused "${mode}" "graphql --input stdin" api graphql --input -
  expect_refused "${mode}" "graphql -F query=@- stdin" api graphql -F query=@-
  expect_refused "${mode}" "graphql --input missing file" api graphql --input "${WORKDIR}/no-such.json"
  expect_passes "${mode}" "graphql convertPullRequestToDraft" "graphql" api graphql -f "query=mutation{convertPullRequestToDraft(input:{pullRequestId:\"PR_x\"}){clientMutationId}}"
  expect_passes "${mode}" "graphql viewer query" "graphql" api graphql -f "query=query{viewer{login}}"
  expect_passes "${mode}" "graphql benign -F @file" "graphql" api graphql -F "query=@${GQL_BENIGN}"
  expect_passes "${mode}" "graphql benign --input file" "graphql" api graphql --input "${JSON_BENIGN}"
  expect_passes "${mode}" "REST field naming a mutation" "issues" api "repos/${OFF}/issues" -f title=createPullRequest
done

exit "${fail}"
