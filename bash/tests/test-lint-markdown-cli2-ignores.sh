#!/usr/bin/env bash
#shellcheck shell=bash
# git/hooks/lint-markdown.sh honors a repo's .markdownlint-cli2.jsonc "ignores", as CI does.
set -uo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${REPO_ROOT}/git/hooks/lint-markdown.sh"

fail=0
_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

for tool in markdownlint markdownlint-cli2; do
  if ! command -v "${tool}" >/dev/null; then
    echo "SKIP: ${tool} not installed"
    exit 0
  fi
done

TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT

# Like amelia-boone: content/ ignored, docs/ linted. Each file has an MD045 and a fixable trailing space.
_write_case() {
  local dir="$1"
  mkdir -p "${dir}/content" "${dir}/docs"
  printf '%s\n' '# Post' '' '![](a.png) ' >"${dir}/content/post.md"
  printf '%s\n' '# Doc' '' '![](b.png) ' >"${dir}/docs/guide.md"
  cat >"${dir}/.markdownlint-cli2.jsonc" <<'EOF'
// Posts are published verbatim.
{
  "config": { "default": true },
  "ignores": ["content/**"]
}
EOF
}

echo "-- known-bad: plain markdownlint (the old path) lints and rewrites the ignored post"
kb="${TMPROOT}/known-bad"
_write_case "${kb}"
before="$(cat "${kb}/content/post.md")"
kb_out="$(cd "${kb}" && markdownlint --fix content/post.md 2>&1)"
after="$(cat "${kb}/content/post.md")"
if grep -q MD045 <<<"${kb_out}" && [[ "${after}" != "${before}" ]]; then
  _pass "known-bad reproduces"
else
  _fail "known-bad did NOT reproduce, so the cases below prove nothing"
  exit 1
fi

echo "-- the hook leaves the ignored post alone and still lints docs/"
c="${TMPROOT}/case"
_write_case "${c}"
before="$(cat "${c}/content/post.md")"
rc=0
out="$(cd "${c}" && HOME="${TMPROOT}/home" bash "${HOOK}" content/post.md docs/guide.md 2>&1)" || rc=$?
if [[ "${rc}" -ne 0 ]]; then _pass "exits non-zero for the docs error"; else _fail "exit 0 despite MD045 in docs/"; fi
if grep -q 'docs/guide.md.*MD045' <<<"${out}"; then _pass "reports docs/guide.md"; else _fail "docs/guide.md not reported"; fi
# cli2's "Finding:" header echoes the arguments, so match findings (path:line) only.
if grep -q '^content/post.md:' <<<"${out}"; then _fail "reported the ignored post"; else _pass "ignored post not reported"; fi
after="$(cat "${c}/content/post.md")"
if [[ "${after}" == "${before}" ]]; then _pass "ignored post unchanged"; else _fail "ignored post was rewritten"; fi

echo "-- the hook fails loudly when markdownlint-cli2 is missing"
m="${TMPROOT}/missing"
_write_case "${m}"
mkdir -p "${TMPROOT}/bin"
for t in bash markdownlint jq mktemp rm; do
  p="$(command -v "${t}")" && ln -sf "${p}" "${TMPROOT}/bin/${t}"
done
rc=0
out="$(cd "${m}" && PATH="${TMPROOT}/bin" HOME="${TMPROOT}/home" "${BASH}" "${HOOK}" docs/guide.md 2>&1)" || rc=$?
if [[ "${rc}" -ne 0 ]] && grep -q 'needs markdownlint-cli2' <<<"${out}"; then
  _pass "says markdownlint-cli2 is needed"
else
  _fail "no clear failure without markdownlint-cli2 (rc=${rc})"
fi

exit "${fail}"
