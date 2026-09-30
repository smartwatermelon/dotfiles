#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification for bash/gh-wrapper.sh's approval gate.
# Run directly: bash bash/tests/test-gh-wrapper-approval-gate.sh
#
# The gate refuses to write a PR or issue body unless those exact bytes are in
# gate-review's approved/ directory. It is the manual-`gh` half of a pair whose
# other half is ~/.claude/scripts/hook-block-personify.sh; the two enforce the
# same rule so the human learns one rule and not two.
#
# These cases drive the REAL gate-review.sh against a sandboxed GATE_REVIEW_DIR
# rather than a stub. A stub would encode what this test's author believed
# `check` does; claude-config's own history has three separate incidents of a
# green suite over broken code from exactly that substitution.
set -euo pipefail

unset CDPATH

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_tests_dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-env-isolation.sh
source "${_tests_dir}/lib/git-env-isolation.sh"
isolate_git_env

export BASH_CONFIG_DIR="${REPO_ROOT}/bash"

#shellcheck source=/dev/null
source "${BASH_CONFIG_DIR}/gh-wrapper.sh"

fail=0

# Sandbox HOME so the gate resolves gate-review.sh and the approvals directory
# inside the fixture, never against the real one. Approving bytes for a test
# must not create an approval the live gate would honour.
SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT
# GATE_REVIEW_SH points the suite at a gate-review.sh other than the installed
# one, e.g. a claude-config worktree carrying a change not yet installed.
REAL_GATE="${GATE_REVIEW_SH:-${HOME}/.claude/scripts/gate-review.sh}"
export HOME="${SANDBOX}"
mkdir -p "${SANDBOX}/.claude/scripts"

if [[ -x "${REAL_GATE}" ]]; then
  cp "${REAL_GATE}" "${SANDBOX}/.claude/scripts/gate-review.sh"
  # gate-review.sh finds its router next to itself (claude-config#628).
  REAL_ROUTE="$(dirname "${REAL_GATE}")/gate-route.sh"
  if [[ -x "${REAL_ROUTE}" ]]; then
    cp "${REAL_ROUTE}" "${SANDBOX}/.claude/scripts/gate-route.sh"
  fi
  HAVE_GATE=1
else
  # claude-config is not installed on this machine. The gate-absent case is
  # still exercised below; the approval cases are skipped rather than faked.
  HAVE_GATE=0
fi

GATE="${SANDBOX}/.claude/scripts/gate-review.sh"
export GATE_REVIEW_DIR="${SANDBOX}/.claude/gate-review"
# The wrapper passes every body's destination to check, so a gate-review.sh
# with routing reads a rules file, resolves the author through this wrapper,
# and looks for check records. All three stay inside the sandbox. The rules
# are the shipped ones (claude-config gate-rules.conf); cases outside the
# routing block run from a twistedmelonman checkout or no repo at all, both
# rule 3, visual.
export GATE_RULES_FILE="${SANDBOX}/gate-rules.conf"
printf '%s\n' 'repo=andrewmrich/beacon-workspace visual' 'author=andrewmrich pangram' '* visual' >"${GATE_RULES_FILE}"
export GH_WRAPPER_LIB="${BASH_CONFIG_DIR}/gh-wrapper.sh"
export XDG_CONFIG_HOME="${SANDBOX}/.config"
unset GH_REPO
mkdir -p "${GATE_REVIEW_DIR}/pending" "${GATE_REVIEW_DIR}/approved"

# check --kind measures the body with personify's length_check.py, found through
# installed_plugins.json under CLAUDE_CONFIG_DIR. The fixture is a stub that logs
# its arguments and judges by a marker in the text, so the suite neither needs
# personify installed nor reads the live ~/.claude.
export CLAUDE_CONFIG_DIR="${SANDBOX}/.claude"
PERSONIFY_FIX="${SANDBOX}/personify-fixture"
KIND_LOG="${SANDBOX}/length-check-args.log"
mkdir -p "${PERSONIFY_FIX}/scripts" "${CLAUDE_CONFIG_DIR}/plugins"
: >"${PERSONIFY_FIX}/scripts/pangram_check.py"
cat >"${PERSONIFY_FIX}/scripts/length_check.py" <<'STUB'
import os
import sys

with open(os.environ["KIND_LOG"], "a") as log:
    log.write(" ".join(sys.argv[1:]) + "\n")
text = sys.stdin.read()
if "CHECKERR" in text:
    sys.stderr.write("stub checker failure\n")
    sys.exit(5)
if "OVERCAP" in text:
    print("body:1 over by 9")
    sys.exit(1)
STUB
export KIND_LOG
printf '{"plugins":{"personify@personify":[{"installPath":"%s"}]}}\n' "${PERSONIFY_FIX}" \
  >"${CLAUDE_CONFIG_DIR}/plugins/installed_plugins.json"

BODY="${SANDBOX}/body.md"
printf 'A body that was approved.\n' >"${BODY}"

UNAPPROVED="${SANDBOX}/unapproved.md"
printf 'A body nobody ever read.\n' >"${UNAPPROVED}"

# Approve BODY's bytes by placing them in approved/, which is what a human
# typing APPROVED in the editor ultimately produces.
if [[ "${HAVE_GATE}" == "1" ]]; then
  cp "${BODY}" "${GATE_REVIEW_DIR}/approved/somelabel"
fi

# expected: 0 = call is allowed through, 1 = call is blocked
assert_gate() {
  local label="$1" expected="$2"
  shift 2
  local rc=0
  _gh_wrapper_approval_gate "$@" >/dev/null 2>&1 || rc=1

  if [[ "${rc}" == "${expected}" ]]; then
    echo "PASS: ${label}"
  else
    echo "FAIL: ${label} — expected rc=${expected}, got rc=${rc}"
    fail=1
  fi
}

# --- surfaces that carry no body: always allowed ------------------------------
# Titles are one line by nature and stay ungated, per the locked decision.
assert_gate "pr create with title only" 0 pr create --title "a title"
assert_gate "pr edit --add-label (no body)" 0 pr edit 5 --add-label bug
assert_gate "pr review --approve (no body)" 0 pr review 5 --approve
assert_gate "pr merge (not a text surface)" 0 pr merge 5 --squash
assert_gate "issue list (not a text surface)" 0 issue list
assert_gate "pr view (not a text surface)" 0 pr view 5
assert_gate "pr review --request-changes (no body)" 0 pr review 5 --request-changes
assert_gate "api GET, no fields" 0 api repos/o/r/pulls/5
assert_gate "api non-body field" 0 api repos/o/r/issues/5 -X PATCH -f state=closed
assert_gate "api title field (titles stay ungated)" 0 api repos/o/r/issues -f title=t
assert_gate "api field whose name only ends in body" 0 api repos/o/r/x -f nobody=1
assert_gate "api --jq .body reads, does not write" 0 api repos/o/r/issues/5 --jq .body
assert_gate "api graphql read-only query" 0 api graphql -f query='{ viewer { login } }'
assert_gate "api graphql query reading comment bodies" 0 \
  api graphql -f query='{ repository(owner:"o",name:"r") { issue(number:5) { comments(first:5) { nodes { body } } } } }'
# A --jq or -H value that happens to read like a body field is a value, not a
# field, and must not be mistaken for one.
assert_gate "api --jq value that looks like a field" 0 api repos/o/r/issues/5 --jq 'body=x'

# --- pr review and gh api carry prose too (claude-config#548) ------------------
assert_gate "pr review --comment --body inline" 1 pr review 5 --comment --body "inline"
assert_gate "pr review -b inline" 1 pr review 5 -b "inline"
assert_gate "api -f body= inline" 1 api repos/o/r/issues/5/comments -f body=hi
assert_gate "api --field body= inline" 1 api repos/o/r/issues/5/comments --field body=hi
assert_gate "api --raw-field body= inline" 1 api repos/o/r/issues/5/comments --raw-field body=hi
assert_gate "api -F body= typed but inline" 1 api repos/o/r/issues/5/comments -F body=hi
assert_gate "api attached -fbody= inline" 1 api repos/o/r/issues/5/comments -fbody=hi
assert_gate "api --field=body= inline" 1 api repos/o/r/issues/5/comments --field=body=hi
assert_gate "api -F body=@relative" 1 api repos/o/r/issues/5/comments -F body=@body.md
assert_gate "api -F body=@- (stdin)" 1 api repos/o/r/issues/5/comments -F body=@-
assert_gate "api --hostname before api, inline body" 1 \
  --hostname github.com api repos/o/r/issues/5/comments -f body=hi
assert_gate "api graphql addComment mutation with inline body" 1 \
  api graphql -f query='mutation { addComment(input: {subjectId: "X", body: "hi"}) { clientMutationId } }'
# The usual layout puts the query across lines. One argv string still holds
# all of it, so the match must cross the newlines.
assert_gate "api graphql mutation spread across lines" 1 \
  api graphql -f query='
mutation {
  addComment(input: {
    subjectId: "X"
    body: "hi"
  }) { clientMutationId }
}'

# --- inline body: unverifiable, always blocked --------------------------------
# There is nothing on disk to hash, so no approval can exist for it.
assert_gate "pr create --body inline" 1 pr create --title t --body "inline text"
assert_gate "pr create -b inline" 1 pr create --title t -b "inline text"
assert_gate "pr comment --body inline" 1 pr comment 5 --body "inline text"
assert_gate "issue create --body inline" 1 issue create --title t --body "inline"
assert_gate "issue comment --body inline" 1 issue comment 5 --body "inline"
assert_gate "pr edit --body inline" 1 pr edit 5 --body "inline"
assert_gate "issue edit --body inline" 1 issue edit 5 --body "inline"

# --- relative and unexpanded paths: blocked -----------------------------------
# gh resolves these against its own cwd and the gate against this process's;
# the two can disagree silently, so neither is trusted.
#
# These cases run from a cwd where the relative name RESOLVES to a file whose
# bytes are approved. Without that, a relative path blocks because no such file
# exists, the assertion passes, and the absolute-path rule itself is never
# exercised -- measured 2026-09-18: deleting that rule left this whole group
# green. Making the file real and approved leaves the path rule as the only
# thing that can block, so the case fails if it is removed.
pushd "${SANDBOX}" >/dev/null
assert_gate "relative --body-file" 1 pr create --title t --body-file body.md
assert_gate "dot-relative --body-file" 1 pr create --title t --body-file ./body.md
popd >/dev/null
# Both paths below are deliberately UNEXPANDED: a tilde and a dollar-var that
# reached the gate as literal text, which is what happens when gh is handed a
# quoted path. They are assembled from pieces so the literal bytes exist without
# writing a tilde or a `$VAR` inside quotes, which shellcheck reads as a mistake
# (SC2088/SC2016) and which no `disable` directive is permitted to silence.
#
# As above, these run from a cwd where the literal name resolves to an approved
# file, so the path rule is the only thing left that can block them.
tilde_path="$(printf '%s/body.md' '~')"
dollar_path="$(printf '%sHOME/body.md' '$')"
mkdir -p "${SANDBOX}/~" "${SANDBOX}/\$HOME"
cp "${BODY}" "${SANDBOX}/${tilde_path}"
cp "${BODY}" "${SANDBOX}/${dollar_path}"
pushd "${SANDBOX}" >/dev/null
assert_gate "tilde path --body-file" 1 pr create --title t --body-file "${tilde_path}"
assert_gate "unexpanded var --body-file" 1 pr create --title t --body-file "${dollar_path}"
popd >/dev/null

# A stdin body has no path to resolve and no bytes on disk to hash, so it is
# blocked by the same absolute-path rule rather than a case of its own.
assert_gate "stdin --body-file -" 1 pr create --title t --body-file -

# --- absolute path that does not exist ----------------------------------------
assert_gate "absolute path, missing file" 1 pr create --title t --body-file "${SANDBOX}/nope.md"

if [[ "${HAVE_GATE}" == "1" ]]; then
  # --- unapproved bytes: blocked ----------------------------------------------
  assert_gate "absolute path, unapproved bytes" 1 pr create --title t --body-file "${UNAPPROVED}"

  # --- approved bytes: allowed, in each flag spelling -------------------------
  assert_gate "--body-file approved" 0 pr create --title t --body-file "${BODY}"
  assert_gate "--body-file= approved" 0 pr create --title t "--body-file=${BODY}"
  assert_gate "-F approved" 0 pr create --title t -F "${BODY}"
  assert_gate "-F<path> attached, approved" 0 pr create --title t "-F${BODY}"
  assert_gate "pr comment approved" 0 pr comment 5 --body-file "${BODY}"
  assert_gate "issue create approved" 0 issue create --title t --body-file "${BODY}"
  assert_gate "issue comment approved" 0 issue comment 5 --body-file "${BODY}"
  assert_gate "pr edit approved" 0 pr edit 5 --body-file "${BODY}"
  assert_gate "issue edit approved" 0 issue edit 5 --body-file "${BODY}"

  # A -R value that happens to look like a subcommand must not be read as one.
  assert_gate "--repo value not mistaken for subcommand" 0 \
    pr create -R someorg/pr --title t --body-file "${BODY}"

  # Editing the approved file after approval invalidates it: the gate binds to
  # bytes, not to the filename.
  printf 'Edited after approval.\n' >"${SANDBOX}/tampered.md"
  assert_gate "bytes changed after approval" 1 pr create --title t --body-file "${SANDBOX}/tampered.md"

  # An approval made under one label satisfies a body used anywhere: `check`
  # matches on content and takes no name.
  assert_gate "approval is label-independent" 0 issue comment 9 --body-file "${BODY}"

  # --- pr review and gh api file forms (claude-config#548) --------------------
  assert_gate "pr review --body-file approved" 0 pr review 5 --request-changes --body-file "${BODY}"
  assert_gate "pr review -F approved" 0 pr review 5 --comment -F "${BODY}"
  assert_gate "pr review --body-file unapproved" 1 pr review 5 --comment --body-file "${UNAPPROVED}"
  assert_gate "api -F body=@abs approved" 0 api repos/o/r/issues/5/comments -F "body=@${BODY}"
  assert_gate "api --field body=@abs approved" 0 api repos/o/r/issues/5/comments --field "body=@${BODY}"
  assert_gate "api --field=body=@abs approved" 0 api repos/o/r/issues/5/comments "--field=body=@${BODY}"
  assert_gate "api attached -Fbody=@abs approved" 0 api repos/o/r/issues/5/comments "-Fbody=@${BODY}"
  assert_gate "api -F body=@abs unapproved" 1 api repos/o/r/issues/5/comments -F "body=@${UNAPPROVED}"
  # -f/--raw-field never expands @: this posts the literal path string.
  assert_gate "api -f body=@abs is raw, inline" 1 api repos/o/r/issues/5/comments -f "body=@${BODY}"
  assert_gate "api approved body plus a second inline body" 1 \
    api repos/o/r/issues/5/comments -F "body=@${BODY}" -f body=x
else
  echo "SKIP: approval cases — gate-review.sh not installed at ${REAL_GATE}"
fi

# --- length cap kind per subcommand ---------------------------------------------
# Each gated subcommand hands check the kind hook-block-personify.sh derives for
# the same command, including the gh api rows. The kind is read back from the
# stub checker's argument log.
if [[ "${HAVE_GATE}" == "1" ]] && grep -q -- '--kind' "${GATE}"; then
  assert_kind() {
    local label="$1" expected="$2" got
    shift 2
    : >"${KIND_LOG}"
    _gh_wrapper_approval_gate "$@" >/dev/null 2>&1 || true
    got="$(tail -n 1 "${KIND_LOG}")"
    if [[ "${got}" == "--kind ${expected}" ]]; then
      echo "PASS: ${label}"
    else
      echo "FAIL: ${label} — expected '--kind ${expected}', checker saw '${got}'"
      fail=1
    fi
  }
  assert_kind "kind: pr create" pr pr create --title t --body-file "${BODY}"
  assert_kind "kind: pr edit" pr pr edit 5 --body-file "${BODY}"
  assert_kind "kind: issue create" issue issue create --title t --body-file "${BODY}"
  assert_kind "kind: issue edit" issue issue edit 5 --body-file "${BODY}"
  assert_kind "kind: pr comment" pr-comment pr comment 5 --body-file "${BODY}"
  assert_kind "kind: pr review" pr-comment pr review 5 --comment --body-file "${BODY}"
  assert_kind "kind: issue comment" pr-comment issue comment 5 --body-file "${BODY}"
  assert_kind "kind: api issue comments" pr-comment \
    api repos/o/r/issues/5/comments -F "body=@${BODY}"
  assert_kind "kind: api pulls/N/comments is a line comment" line-comment \
    api repos/o/r/pulls/5/comments -F "body=@${BODY}"
  assert_kind "kind: api /repos/ full URL pulls/N/comments" line-comment \
    api https://api.github.com/repos/o/r/pulls/5/comments -F "body=@${BODY}"
  assert_kind "kind: api pulls/N/reviews is not a line comment" pr-comment \
    api repos/o/r/pulls/5/reviews -F "body=@${BODY}"
  # The body file's name cannot select the looser cap: only the endpoint counts.
  cp "${BODY}" "${SANDBOX}/repos-o-r-pulls-5-comments.md"
  assert_kind "kind: api body path naming pulls/N/comments" pr-comment \
    api repos/o/r/issues/5/comments -F "body=@${SANDBOX}/repos-o-r-pulls-5-comments.md"
  mkdir -p "${SANDBOX}/repos/o/r/pulls/5"
  cp "${BODY}" "${SANDBOX}/repos/o/r/pulls/5/comments"
  assert_kind "kind: api body path is a repos/.../pulls/N/comments file" pr-comment \
    api repos/o/r/issues/5/comments -F "body=@${SANDBOX}/repos/o/r/pulls/5/comments"
  assert_kind "kind: api graphql has no repos endpoint" pr-comment \
    api graphql -F "body=@${BODY}"

  # Over the cap blocks even though the bytes are approved; the reason is shown.
  OVER="${SANDBOX}/over.md"
  printf 'OVERCAP but approved.\n' >"${OVER}"
  cp "${OVER}" "${GATE_REVIEW_DIR}/approved/overlabel"
  assert_gate "over the cap: approved bytes still blocked" 1 pr create --title t --body-file "${OVER}"
  msg="$(_gh_wrapper_approval_gate pr create --title t --body-file "${OVER}" 2>&1 || true)"
  if [[ "${msg}" == *"over length"* ]]; then
    echo "PASS: over the cap: block message names the length"
  else
    echo "FAIL: over the cap: block message names the length — got: ${msg}"
    fail=1
  fi
  # A checker error is not a verdict on the text, and also blocks.
  ERR="${SANDBOX}/err.md"
  printf 'CHECKERR but approved.\n' >"${ERR}"
  cp "${ERR}" "${GATE_REVIEW_DIR}/approved/errlabel"
  assert_gate "checker error: blocked" 1 pr create --title t --body-file "${ERR}"
  if [[ "${msg}" == *"over its length cap"* && "${msg}" != *"not been visually approved"* ]]; then
    echo "PASS: over the cap: headline says over its length cap"
  else
    echo "FAIL: over the cap: headline says over its length cap — got: ${msg}"
    fail=1
  fi
  msg="$(_gh_wrapper_approval_gate pr create --title t --body-file "${ERR}" 2>&1 || true)"
  if [[ "${msg}" == *"length checker failed"* && "${msg}" == *"not a verdict on the text"* && "${msg}" != *"not been visually approved"* ]]; then
    echo "PASS: checker error: headline says the checker failed"
  else
    echo "FAIL: checker error: headline says the checker failed — got: ${msg}"
    fail=1
  fi
  # Fail closed when personify is not installed.
  mv "${CLAUDE_CONFIG_DIR}/plugins/installed_plugins.json" "${CLAUDE_CONFIG_DIR}/plugins/installed_plugins.json.hidden"
  assert_gate "personify not installed: blocked" 1 pr create --title t --body-file "${BODY}"
  mv "${CLAUDE_CONFIG_DIR}/plugins/installed_plugins.json.hidden" "${CLAUDE_CONFIG_DIR}/plugins/installed_plugins.json"
  assert_gate "personify restored: allowed" 0 pr create --title t --body-file "${BODY}"
else
  echo "SKIP: length cap kind cases — ${REAL_GATE} predates check --kind"
fi

# --- time-boxed suspension ----------------------------------------------------
# SUSPENDED holds the last local day the gate is off. gate-review.sh does the
# parsing (its own suite covers the malformed inputs); these cases prove the
# wrapper honours the answer in both directions.
SUSP="${GATE_REVIEW_DIR}/SUSPENDED"
_day() {
  date -v"$1"d +%F 2>/dev/null || date -d "$1 days" +%F
}
if [[ "${HAVE_GATE}" == "1" ]] && grep -q '_cmd_suspended' "${GATE}"; then
  printf '%s\n' "$(_day +1)" >"${SUSP}"
  assert_gate "suspended through tomorrow: unapproved body allowed" 0 \
    pr create --title t --body-file "${UNAPPROVED}"
  assert_gate "suspended through tomorrow: inline body allowed" 0 \
    pr create --title t --body "inline text"
  assert_gate "suspended through tomorrow: inline review body allowed" 0 \
    pr review 5 --comment --body "inline text"
  assert_gate "suspended through tomorrow: inline api body allowed" 0 \
    api repos/o/r/issues/5/comments -f body=hi
  notice="$(_gh_wrapper_approval_gate pr create --title t --body-file "${UNAPPROVED}" 2>&1 >/dev/null)" || true
  if [[ "${notice}" == *"[personify-gate] SUSPENDED until"* ]]; then
    echo "PASS: suspension prints its notice"
  else
    echo "FAIL: suspension prints its notice — got: ${notice}"
    fail=1
  fi
  printf '%s\n' "$(date +%F)" >"${SUSP}"
  assert_gate "suspended through today: unapproved body allowed" 0 \
    pr create --title t --body-file "${UNAPPROVED}"
  printf '%s\n' "$(_day -1)" >"${SUSP}"
  assert_gate "expired yesterday: unapproved body blocked" 1 \
    pr create --title t --body-file "${UNAPPROVED}"
  assert_gate "expired yesterday: inline body blocked" 1 \
    pr create --title t --body "inline text"
  printf '2099-02-31\n' >"${SUSP}"
  assert_gate "impossible date: unapproved body blocked" 1 \
    pr create --title t --body-file "${UNAPPROVED}"
  # Known-bad control: with the file gone the gate is armed again.
  rm -f "${SUSP}"
  assert_gate "no SUSPENDED file: unapproved body blocked (control)" 1 \
    pr create --title t --body-file "${UNAPPROVED}"
  assert_gate "no SUSPENDED file: inline review body blocked (control)" 1 \
    pr review 5 --comment --body "inline text"
  assert_gate "no SUSPENDED file: inline api body blocked (control)" 1 \
    api repos/o/r/issues/5/comments -f body=hi
else
  echo "SKIP: suspension cases — ${REAL_GATE} has no 'suspended' subcommand"
fi

# --- per-repo approvals (claude-config#623) -----------------------------------
# gate-review keeps approvals in approved/<repo>-<branch>/. The block message
# must point there, not at the old flat approved/<label>.
hint="$(_gh_wrapper_approval_gate pr create --title t --body-file "${UNAPPROVED}" 2>&1 || true)"
if [[ "${hint}" == *"gate-review/approved/<repo>-<branch>/<label>"* ]]; then
  echo "PASS: block message names the per-repo approved/ path"
else
  echo "FAIL: block message names the per-repo approved/ path — got: ${hint}"
  fail=1
fi

if [[ "${HAVE_GATE}" == "1" ]] && grep -q '<repo>-<branch>' "${GATE}"; then
  KEYED="${SANDBOX}/keyed.md"
  printf 'A body approved under a per-repo key.\n' >"${KEYED}"
  mkdir -p "${GATE_REVIEW_DIR}/approved/dotfiles-main"
  cp "${KEYED}" "${GATE_REVIEW_DIR}/approved/dotfiles-main/commit-1"
  assert_gate "body approved under approved/<repo>-<branch>/ is allowed" 0 \
    pr create --title t --body-file "${KEYED}"
else
  echo "SKIP: keyed approval case — installed gate-review.sh predates per-repo keys"
fi

# --- routing by destination (claude-config#628) -------------------------------
# check routes each body by the repository it goes to. beacon-biosignals/x
# resolves to the andrewmrich identity (rule 2, pangram: an approval AND a
# check record); twistedmelonman/y to twistedmelonman (rule 3, visual: the
# approval alone). Each form the wrapper reads the destination from must reach
# check, and must reach it the same way the Bash-tool hook would.
if [[ "${HAVE_GATE}" == "1" && -x "${SANDBOX}/.claude/scripts/gate-route.sh" ]]; then
  # assert_gate with GH_REPO set for that one call.
  assert_gate_gh_repo() {
    local label="$1" expected="$2" gh_repo="$3"
    shift 3
    GH_REPO="${gh_repo}" assert_gate "${label}" "${expected}" "$@"
  }

  EMP="${SANDBOX}/emp"
  PERS="${SANDBOX}/pers"
  for r in "${EMP}" "${PERS}"; do
    git init -q "${r}"
  done
  git -C "${EMP}" remote add origin git@github.com:beacon-biosignals/x.git
  git -C "${PERS}" remote add origin git@github.com:twistedmelonman/y.git

  RECORD="${XDG_CONFIG_HOME}/personify/checks/$(sha256sum "${BODY}" | cut -d' ' -f1).json"
  mkdir -p "$(dirname "${RECORD}")"
  # The same approved bytes in every case; only the destination changes.
  EMP_URL="https://github.com/beacon-biosignals/x/pull/5"
  PERS_URL="https://github.com/twistedmelonman/y/pull/5"

  pushd "${PERS}" >/dev/null
  assert_gate "route: -R employer, no record" 1 pr create --title t --body-file "${BODY}" -R beacon-biosignals/x
  msg="$(_gh_wrapper_approval_gate pr create --title t --body-file "${BODY}" -R beacon-biosignals/x 2>&1 || true)"
  if [[ "${msg}" == *"no Pangram check ran"* && "${msg}" == *"Pangram-gated repository"* ]]; then
    echo "PASS: route: unchecked block names the missing check"
  else
    echo "FAIL: route: unchecked block names the missing check — got: ${msg}"
    fail=1
  fi
  assert_gate "route: --repo= employer, no record" 1 pr create --title t --body-file "${BODY}" --repo=beacon-biosignals/x
  assert_gate "route: attached -R employer, no record" 1 pr create --title t --body-file "${BODY}" -Rbeacon-biosignals/x
  assert_gate "route: -R https URL spelling, no record" 1 pr create --title t --body-file "${BODY}" -R https://github.com/beacon-biosignals/x
  assert_gate "route: -R github.com/ mixed case, no record" 1 pr create --title t --body-file "${BODY}" -R github.com/Beacon-Biosignals/X
  assert_gate_gh_repo "route: GH_REPO employer, no record" 1 beacon-biosignals/x pr create --title t --body-file "${BODY}"
  assert_gate "route: URL argument employer, no record" 1 pr comment "${EMP_URL}" --body-file "${BODY}"
  assert_gate "route: api repos/ employer, no record" 1 api repos/beacon-biosignals/x/issues/1/comments -F "body=@${BODY}"
  assert_gate "route: api /repos/ employer, no record" 1 api /repos/beacon-biosignals/x/issues/1/comments -F "body=@${BODY}"
  assert_gate "route: api full URL employer, no record" 1 api https://api.github.com/repos/beacon-biosignals/x/issues/1/comments -F "body=@${BODY}"
  assert_gate "route: -R personal, no record" 0 pr create --title t --body-file "${BODY}" -R twistedmelonman/y
  assert_gate "route: personal checkout, no -R, no record" 0 pr create --title t --body-file "${BODY}"
  assert_gate "route: URL argument personal, no record" 0 pr comment "${PERS_URL}" --body-file "${BODY}"
  assert_gate "route: api repos/ personal, no record" 0 api repos/twistedmelonman/y/issues/1/comments -F "body=@${BODY}"
  assert_gate "route: api {owner}/{repo} in personal checkout" 0 api 'repos/{owner}/{repo}/issues/1/comments' -F "body=@${BODY}"
  # Disagreeing or unreadable destinations block even when every candidate
  # would route visual: the gate does not pick one.
  assert_gate "route: -R and URL disagree" 1 pr comment "${PERS_URL}" -R twistedmelonman/z --body-file "${BODY}"
  assert_gate_gh_repo "route: -R and GH_REPO disagree" 1 twistedmelonman/z pr create --title t --body-file "${BODY}" -R twistedmelonman/y
  assert_gate_gh_repo "route: api endpoint and GH_REPO disagree" 1 twistedmelonman/z api repos/twistedmelonman/y/issues/1/comments -F "body=@${BODY}"
  assert_gate "route: -R on another host" 1 pr create --title t --body-file "${BODY}" -R gitlab.example.com/o/n
  assert_gate "route: api repositories/<id>" 1 api repositories/123/issues/1/comments -F "body=@${BODY}"
  popd >/dev/null

  pushd "${EMP}" >/dev/null
  assert_gate "route: employer checkout, no -R, no record" 1 pr create --title t --body-file "${BODY}"
  assert_gate "route: api {owner}/{repo} in employer checkout" 1 api 'repos/{owner}/{repo}/issues/1/comments' -F "body=@${BODY}"
  # A URL with no -R may be a flag value, so the checkout must pass as well.
  assert_gate "route: personal URL from employer checkout" 1 pr comment "${PERS_URL}" --body-file "${BODY}"
  # -R is the destination outright; the checkout does not matter.
  assert_gate "route: -R personal from employer checkout" 0 pr create --title t --body-file "${BODY}" -R twistedmelonman/y
  popd >/dev/null

  printf '{}\n' >"${RECORD}"
  pushd "${PERS}" >/dev/null
  assert_gate "route: -R employer with a record" 0 pr create --title t --body-file "${BODY}" -R beacon-biosignals/x
  assert_gate "route: api repos/ employer with a record" 0 api repos/beacon-biosignals/x/issues/1/comments -F "body=@${BODY}"
  assert_gate "route: -R employer, record, unapproved bytes" 1 pr create --title t --body-file "${UNAPPROVED}" -R beacon-biosignals/x
  popd >/dev/null
  rm -f "${RECORD}"
else
  echo "SKIP: routing cases — ${REAL_GATE} has no gate-route.sh beside it"
fi

# --- gate-review.sh absent: fails CLOSED --------------------------------------
# A redundant pair whose halves disagree about the unverifiable case is not
# redundant. Removing the gate must not turn the check into a pass.
mv "${GATE}" "${GATE}.hidden" 2>/dev/null || true
assert_gate "gate-review.sh absent fails closed" 1 pr create --title t --body-file "${BODY}"
# ...but a call with no body is still unaffected by the gate's absence.
assert_gate "gate absent, no body, still allowed" 0 pr create --title "a title"
# A SUSPENDED file cannot be read without gate-review.sh, so it must not
# suspend anything on its own.
printf '%s\n' "$(_day +1)" >"${SUSP}"
assert_gate "gate absent, SUSPENDED present, still fails closed" 1 \
  pr create --title t --body-file "${BODY}"
rm -f "${SUSP}"
mv "${GATE}.hidden" "${GATE}" 2>/dev/null || true

if [[ "${fail}" == "0" ]]; then
  echo "All approval-gate checks passed."
else
  echo "Approval-gate checks FAILED."
fi
exit "${fail}"
