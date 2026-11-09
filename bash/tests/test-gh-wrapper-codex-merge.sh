#!/usr/bin/env bash
# Exercise the complete wrapper with fake GitHub reads/writes and App minting.
set -euo pipefail
unset CDPATH
unset -f git gh || true
root="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/code" "${work}/wrap-bin" "${work}/bin" "${work}/home/.claude/hooks" "${work}/data"
cp "${root}/bash/gh-wrapper.sh" "${root}/bash/gh-codex-merge.sh" "${work}/code/"
ln -s "${work}/code/gh-wrapper.sh" "${work}/wrap-bin/gh"
cat >"${work}/code/gh-app-token.sh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == route || "$1" == owner-route ]]; then
  [[ "${MOCK_PAT:-0}" != 1 ]] || exit 1
  echo 'op://fixture/app'
else
  echo 'fixture-app-token'
fi
MOCK
cat >"${work}/home/.claude/hooks/pre-merge-review.sh" <<'MOCK'
#!/usr/bin/env bash
echo forbidden-cc >>"${MOCK_DATA}/../boundary-violations"
exit 99
MOCK
cat >"${work}/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -eu
[[ "${GH_TOKEN:-}" == fixture-app-token ]] || { echo wrong-identity >>"${MOCK_DATA}/../boundary-violations"; exit 98; }
case "$1 $2" in
  'pr view')
    echo view >>"${MOCK_DATA}/calls"
    [[ ! -f "${MOCK_DATA}/fail-view" ]] || exit 4
    count=0
    [[ ! -f "${MOCK_DATA}/view-count" ]] || count="$(cat "${MOCK_DATA}/view-count")"
    echo "$((count + 1))" >"${MOCK_DATA}/view-count"
    if [[ "${count}" == 0 ]]; then cat "${MOCK_DATA}/pr.json"; else cat "${MOCK_DATA}/pr-second.json"; fi
    ;;
  'pr checks')
    echo checks >>"${MOCK_DATA}/calls"
    [[ ! -f "${MOCK_DATA}/fail-checks" ]] || exit 8
    cat "${MOCK_DATA}/checks.json"
    ;;
  'pr merge')
    echo merge >>"${MOCK_DATA}/calls"
    printf '%s\n' "$@" >"${MOCK_DATA}/merge-args"
    [[ ! -f "${MOCK_DATA}/fail-merge" ]] || exit 7
    ;;
  api*)
    printf '%s\n' "$*" >>"${MOCK_DATA}/read-args"
    if [[ "$*" == *'/collaborators/'* ]]; then
      echo permission >>"${MOCK_DATA}/calls"
      [[ ! -f "${MOCK_DATA}/fail-permission" ]] || exit 4
      cat "${MOCK_DATA}/permission.json"
    elif [[ "$*" == *'/reviews?'* ]]; then
      echo reviews >>"${MOCK_DATA}/calls"
      [[ ! -f "${MOCK_DATA}/fail-reviews" ]] || exit 4
      cat "${MOCK_DATA}/reviews.json"
    elif [[ "$*" == *'/rules/branches/'* ]]; then
      echo rules >>"${MOCK_DATA}/calls"
      [[ ! -f "${MOCK_DATA}/fail-rules" ]] || exit 4
      cat "${MOCK_DATA}/rules.json"
    else
      echo unexpected-api >>"${MOCK_DATA}/calls"
      exit 97
    fi
    ;;
  *) echo unexpected-command >>"${MOCK_DATA}/calls"; exit 96 ;;
esac
MOCK
chmod +x "${work}/code/gh-wrapper.sh" "${work}/bin/gh" "${work}/home/.claude/hooks/pre-merge-review.sh"
{
  printf 'source %q\n' "${work}/code/gh-wrapper.sh"
  # Expansion belongs to the generated child shell.
  # shellcheck disable=SC2016
  printf 'if declare -F sugh >/dev/null; then echo forbidden-shortcut >>"${MOCK_DATA}/../boundary-violations"; exit 1; fi\n'
  printf 'gh "$@"\n'
} >"${work}/function.sh"
{
  printf 'source %q\n' "${work}/code/gh-wrapper.sh"
  # Expansion belongs to the generated child shell.
  # shellcheck disable=SC2016
  printf 'if declare -F sugh >/dev/null; then echo forbidden-shortcut >>"${MOCK_DATA}/../boundary-violations"; exit 1; fi\n'
  # Expansion belongs to the generated child shell.
  # shellcheck disable=SC2016
  printf '"${BASH}" --norc --noprofile -c '\''gh "$@"'\'' -- "$@"\n'
} >"${work}/exported.sh"

head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
other=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
count=0
reset_case() {
  # Remove only fixture data files; the real checkout is never selected.
  find "${work}/data" -type f -delete
  cat >"${work}/data/pr.json" <<JSON
{"number":7,"url":"https://github.com/smartwatermelon/example/pull/7","state":"OPEN","isDraft":false,"headRefOid":"${head}","baseRefName":"main","reviewDecision":"APPROVED","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}
JSON
  cp "${work}/data/pr.json" "${work}/data/pr-second.json"
  cat >"${work}/data/reviews.json" <<JSON
[[{"id":1,"user":{"login":"twistedmelonman","type":"User"},"state":"APPROVED","commit_id":"${head}","submitted_at":"2026-11-09T03:54:04Z"}]]
JSON
  printf '%s\n' '[{"name":"build","bucket":"pass","state":"SUCCESS"}]' >"${work}/data/checks.json"
  printf '%s\n' '[[{"type":"pull_request","parameters":{"required_approving_review_count":1,"require_last_push_approval":true}}]]' >"${work}/data/rules.json"
  printf '%s\n' '{"permission":"admin","user":{"login":"twistedmelonman","type":"User"}}' >"${work}/data/permission.json"
  : >"${work}/data/calls"
}
mutate() {
  jq "$2" "${work}/data/$1.json" >"${work}/changed.json"
  mv "${work}/changed.json" "${work}/data/$1.json"
}
run() {
  local mode="$1"
  shift
  local -a driver=("${BASH}" "${work}/code/gh-wrapper.sh")
  [[ "${mode}" != function ]] || driver=("${BASH}" "${work}/function.sh")
  [[ "${mode}" != exported ]] || driver=("${BASH}" "${work}/exported.sh")
  (cd "${work}" && env -i PATH="${work}/wrap-bin:${work}/bin:${PATH}" HOME="${work}/home" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "${marker:-CODEX_THREAD_ID}=fixture" \
    MOCK_DATA="${work}/data" MOCK_PAT="${pat:-0}" GH_TOKEN_TWM=fixture-personal-token \
    GH_REPO=smartwatermelon/example "${driver[@]}" "$@") >"${work}/output" 2>&1
}
expect_ok() {
  local mode="$1" label="$2"
  shift 2
  if ! run "${mode}" "$@"; then
    cat "${work}/output"
    echo "FAIL: ${mode}: ${label}"
    exit 1
  fi
  [[ "$(grep -c '^merge$' "${work}/data/calls")" == 1 ]]
  printf '%s\n' pr merge 7 --repo github.com/smartwatermelon/example "${want_method:---squash}" --match-head-commit "${head}" >"${work}/expected"
  [[ "${want_delete:-0}" != 1 ]] || printf '%s\n' --delete-branch >>"${work}/expected"
  cmp "${work}/expected" "${work}/data/merge-args"
  count=$((count + 1))
}
expect_block() {
  local mode="$1" label="$2"
  shift 2
  if run "${mode}" "$@"; then
    cat "${work}/output"
    echo "FAIL: ${mode}: ${label}"
    exit 1
  fi
  if grep -q '^merge$' "${work}/data/calls"; then
    cat "${work}/output"
    echo "FAIL: merge attempted: ${label}"
    exit 1
  fi
  count=$((count + 1))
}

for mode in standalone function exported; do
  echo "Testing ${mode} wrapper"
  pat=0
  reset_case
  expect_ok "${mode}" 'exact-head approval' pr merge 7 --repo smartwatermelon/example --squash
  reset_case
  expect_ok "${mode}" 'global repo flag and existing head constraint' -Rsmartwatermelon/example pr merge 7 -s --match-head-commit="${head}"
  reset_case
  expect_ok "${mode}" 'canonical URL' pr merge https://github.com/smartwatermelon/example/pull/7 --squash
  for want_method in --merge --rebase; do
    reset_case
    expect_ok "${mode}" 'explicit method' pr merge 7 "${want_method}"
  done
  unset want_method
  reset_case
  want_delete=1
  expect_ok "${mode}" 'explicit branch deletion' pr merge 7 --squash --delete-branch
  unset want_delete
  reset_case
  marker=CODEX_SESSION_ID
  expect_ok "${mode}" 'standalone session marker' pr merge 7 --squash
  unset marker
  reset_case
  mutate pr '.baseRefName="release/one"'
  cp "${work}/data/pr.json" "${work}/data/pr-second.json"
  expect_ok "${mode}" 'base branch URI encoding' pr merge 7 --squash
  grep -q 'branches/release%2Fone?' "${work}/data/read-args"
  reset_case
  mutate reviews '. + [[.[0][0] | .id=2 | .state="COMMENTED" | .submitted_at="2026-11-09T04:00:00Z"]]'
  expect_ok "${mode}" 'later comment does not revoke approval' pr merge 7 --squash
  reset_case
  mutate reviews '[[], .[0]]'
  expect_ok "${mode}" 'approval on later review page' pr merge 7 --squash

  for flags in --admin --auto --disable-auto --unknown; do
    reset_case
    expect_block "${mode}" "reject ${flags}" pr merge 7 --squash "${flags}"
  done
  reset_case
  expect_block "${mode}" 'head mismatch' pr merge 7 --squash --match-head-commit "${other}"
  reset_case
  expect_block "${mode}" 'conflicting URL and repo' pr merge https://github.com/smartwatermelon/other/pull/7 --repo smartwatermelon/example --squash
  reset_case
  expect_block "${mode}" 'no implicit current PR' pr merge --squash
  reset_case
  expect_block "${mode}" 'no branch-name selection' pr merge feature --squash
  reset_case
  expect_block "${mode}" 'no interactive merge method' pr merge 7
  reset_case
  expect_block "${mode}" 'empty repo' pr merge 7 --repo= --squash
  reset_case
  pat=1
  expect_block "${mode}" 'personal token is not the App key' pr merge 7 --squash
  pat=0

  for mutation in '.isDraft=true' '.state="CLOSED"' '.reviewDecision="REVIEW_REQUIRED"' '.mergeStateStatus="UNKNOWN"' '.mergeable="CONFLICTING"' '.url="https://github.com/smartwatermelon/other/pull/7"'; do
    reset_case
    mutate pr "${mutation}"
    expect_block "${mode}" "unsafe PR ${mutation}" pr merge 7 --squash
  done
  for mutation in '.[0][0].user.login="someone-else"' '.[0][0].user.type="Bot"' '.[0][0].state="DISMISSED"' '.[0][0].state="CHANGES_REQUESTED"' \
    ".[0][0].commit_id=\"${other}\"" '.[0][0].submitted_at=null'; do
    reset_case
    mutate reviews "${mutation}"
    expect_block "${mode}" "ineligible human review ${mutation}" pr merge 7 --squash
  done
  reset_case
  mutate reviews '. + [[.[0][0] | .id=2 | .state="CHANGES_REQUESTED" | .submitted_at="2026-11-09T04:00:00Z"]]'
  expect_block "${mode}" 'later changes requested supersede approval' pr merge 7 --squash
  for mutation in '.[0][0].parameters.require_last_push_approval=false' '.[0][0].parameters.required_approving_review_count=0' \
    '.[0][0].parameters.required_approving_review_count="bad"' '[]'; do
    reset_case
    mutate rules "${mutation}"
    expect_block "${mode}" "missing server protection ${mutation}" pr merge 7 --squash
  done
  for mutation in '.[0].bucket="fail"' '.[0].bucket="pending"' '.[0].bucket="skipping"' '[]'; do
    reset_case
    mutate checks "${mutation}"
    expect_block "${mode}" "incomplete checks ${mutation}" pr merge 7 --squash
  done
  for endpoint in permission view rules reviews checks; do
    reset_case
    touch "${work}/data/fail-${endpoint}"
    expect_block "${mode}" "read failure ${endpoint}" pr merge 7 --squash
  done
  reset_case
  mutate permission '.permission="read"'
  expect_block "${mode}" 'reviewer write access revoked' pr merge 7 --squash
  reset_case
  printf 'malformed\n' >"${work}/data/reviews.json"
  expect_block "${mode}" 'malformed review response' pr merge 7 --squash
  reset_case
  mv "${work}/code/gh-codex-merge.sh" "${work}/code/gh-codex-merge.sh.saved"
  expect_block "${mode}" 'missing authorizer never falls back to CC' pr merge 7 --squash
  mv "${work}/code/gh-codex-merge.sh.saved" "${work}/code/gh-codex-merge.sh"
  reset_case
  mutate pr-second ".headRefOid=\"${other}\""
  expect_block "${mode}" 'head changed during preflight' pr merge 7 --squash
  reset_case
  mutate pr-second '.reviewDecision="REVIEW_REQUIRED"'
  expect_block "${mode}" 'approval withdrawn during preflight' pr merge 7 --squash
  reset_case
  touch "${work}/data/fail-merge"
  if run "${mode}" pr merge 7 --squash; then
    echo 'FAIL: failed merge reported success'
    exit 1
  fi
  [[ "$(grep -c '^merge$' "${work}/data/calls")" == 1 ]]
  grep -qx -- --match-head-commit "${work}/data/merge-args"
  count=$((count + 1))
  if grep -qE 'forbidden-cc|wrong-identity|unexpected-' "${work}/data/calls"; then
    echo 'FAIL: escaped fixture boundaries'
    exit 1
  fi
done
[[ ! -e "${work}/boundary-violations" ]] || {
  cat "${work}/boundary-violations"
  exit 1
}
echo "PASS: ${count} Codex merge authorization cases; no live GitHub writes"
