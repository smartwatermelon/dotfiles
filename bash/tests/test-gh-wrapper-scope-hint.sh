#!/usr/bin/env bash
# shellcheck shell=bash
# Standalone verification for bash/gh-wrapper.sh's F4 scope-error hint.
# Run directly: bash bash/tests/test-gh-wrapper-scope-hint.sh
#
# When the real gh fails with GitHub's "needs the ... scope" error, the
# wrapper must print the exact fix (env -u GH_TOKEN ... when GH_TOKEN is set;
# gh auth refresh otherwise), keep the original stderr, and pass the exit
# code through. A non-scope failure prints no hint. A success prints nothing.
# Design: dev-env docs/superpowers/specs/2026-09-03-org-migration-design.md.
set -uo pipefail

unset CDPATH

# ~/.config/bash/functions.sh defines a `gh` shell function that wins over any
# PATH lookup. Claude Code sets BASH_ENV to that file, so a child bash would
# source it and never reach the stubs below. Clear it for this whole test.
unset BASH_ENV

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_tests_dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-env-isolation.sh
source "${_tests_dir}/lib/git-env-isolation.sh"
isolate_git_env

WRAPPER="${REPO_ROOT}/bash/gh-wrapper.sh"
WORKDIR="/tmp/gh-wrapper-scope-hint-test-$$"
mkdir -p "${WORKDIR}"
trap 'rm -rf "${WORKDIR}"' EXIT

export HOME="${WORKDIR}/home"
mkdir -p "${HOME}/.config/gh" "${HOME}/neutral-cwd"
cat >"${HOME}/.config/gh/hosts.yml" <<'YAML'
github.com:
    user: twistedmelonman
    oauth_token: fake
YAML
# GH_TOKEN and GITHUB_TOKEN both authenticate gh (in that precedence order) and
# GH_HOST redirects which host it talks to; any of the three leaking in from the
# caller's environment would change what the hint says. Clear all three so each
# case below controls them explicitly.
unset GH_TOKEN GH_HOST GITHUB_TOKEN
# The wrapper's F3 guard resolves GH_TOKEN's login through `gh api user` when
# this is unset; that would hit the stub and fail. Pin it so no case here
# depends on identity resolution — the scope hint is the thing under test.
export CLAUDE_GH_TOKEN_LOGIN="twistedmelonman"

fail=0
_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

# Three stub gh binaries. Each is the only `gh` on PATH after the wrapper
# itself, which _gh_wrapper_find_real_gh skips.
STUBS="${WORKDIR}/stubs"
mkdir -p "${STUBS}/scope" "${STUBS}/plain403" "${STUBS}/ok"

# Text measured against the real gh binary (gh 2.x, 2026-09-03), via
#   gh api orgs/nightowlstudiollc/actions/secrets
# whose stderr was, verbatim:
#   gh: You must be an org admin or have the actions secrets fine-grained permission. (HTTP 403)
#   gh: This API operation needs the "admin:org" scope. To request it, run:  gh auth refresh -h github.com -s admin:org
# The real exit status there is 1; the stub uses 4 so the pass-through
# assertion cannot be satisfied by the wrapper's own generic failure code.
cat >"${STUBS}/scope/gh" <<'STUB'
#!/usr/bin/env bash
echo '{"message":"You must be an org admin or have the actions secrets fine-grained permission.","status":"403"}'
echo 'gh: You must be an org admin or have the actions secrets fine-grained permission. (HTTP 403)' >&2
echo 'gh: This API operation needs the "admin:org" scope. To request it, run:  gh auth refresh -h github.com -s admin:org' >&2
exit 4
STUB
cat >"${STUBS}/plain403/gh" <<'STUB'
#!/usr/bin/env bash
echo 'gh: Must have admin rights to Repository. (HTTP 403)' >&2
exit 1
STUB
cat >"${STUBS}/ok/gh" <<'STUB'
#!/usr/bin/env bash
echo 'stdout-from-gh'
echo 'stderr-from-gh' >&2
exit 0
STUB
chmod +x "${STUBS}"/*/gh

# The wrapper's stderr temp files land in ${TMPDIR}. Point that at a sandbox so
# the leak assertions below observe only this test's files, and cannot be
# fooled by an unrelated process's leftovers in the shared /tmp.
export TMPDIR="${WORKDIR}/tmp"
mkdir -p "${TMPDIR}"

# Count the wrapper's stderr temp files currently in the sandboxed TMPDIR.
_errfile_count() {
  find "${TMPDIR}" -maxdepth 1 -name 'gh-wrapper-stderr.*' 2>/dev/null | wc -l | tr -d ' '
}

# Run the wrapper in standalone mode from a non-repo cwd (owner resolution
# yields nothing, so no identity switch is attempted) with the given stub
# first on PATH after the wrapper. Captures stdout and stderr separately.
#
# The wrapper is invoked as `bash "${WRAPPER}"` — the repo file directly, NOT
# ~/.local/bin/gh. Going through the installed symlink makes
# _gh_wrapper_find_real_gh resolve `gh` back to the wrapper itself, which
# re-enters and never reaches the code under test.
_run() {
  local stub="$1"
  shift
  (
    cd "${HOME}/neutral-cwd" || exit 99
    PATH="${STUBS}/${stub}:${PATH}" bash "${WRAPPER}" "$@" \
      >"${WORKDIR}/out" 2>"${WORKDIR}/err"
  )
}

# --- Case 1: scope error with GH_TOKEN set -> env -u hint ---------------------
GH_TOKEN="fixture-token" _run scope secret set CLAUDE_CODE_OAUTH_TOKEN --org smartwatermelon --visibility all
rc=$?
err="$(cat "${WORKDIR}/err")"
out="$(cat "${WORKDIR}/out")"

if [[ "${rc}" -eq 4 ]]; then
  _pass "scope error: exit code passes through (4)"
else
  _fail "scope error: expected exit 4, got ${rc}"
fi
if [[ "${err}" == *'needs the "admin:org" scope'* ]]; then
  _pass "scope error: original stderr preserved"
else
  _fail "scope error: original stderr missing, got: ${err}"
fi
if [[ "${err}" == *"[gh] GH_TOKEN is set and lacks the 'admin:org' scope"* ]]; then
  _pass "scope error: hint names the scope"
else
  _fail "scope error: hint missing, got: ${err}"
fi
if [[ "${err}" == *"env -u GH_TOKEN gh secret set CLAUDE_CODE_OAUTH_TOKEN --org smartwatermelon --visibility all"* ]]; then
  _pass "scope error: hint carries the exact re-run command"
else
  _fail "scope error: re-run command missing, got: ${err}"
fi
if [[ "${err}" == *"keyring identity for twistedmelonman"* ]]; then
  _pass "scope error: hint names the keyring login from hosts.yml"
else
  _fail "scope error: keyring login missing, got: ${err}"
fi
if [[ "${out}" == *'You must be an org admin'* ]]; then
  _pass "scope error: stdout passes through untouched"
else
  _fail "scope error: stdout lost, got: ${out}"
fi

# --- Case 2: scope error WITHOUT GH_TOKEN -> gh auth refresh hint -------------
_run scope secret set CLAUDE_CODE_OAUTH_TOKEN --org smartwatermelon
err="$(cat "${WORKDIR}/err")"
if [[ "${err}" == *"gh auth refresh -h github.com -s admin:org"* && "${err}" == *"[gh]"* ]]; then
  _pass "scope error, no GH_TOKEN: refresh hint"
else
  _fail "scope error, no GH_TOKEN: expected refresh hint, got: ${err}"
fi
if [[ "${err}" == *"env -u GH_TOKEN"* ]]; then
  _fail "scope error, no GH_TOKEN: must not suggest env -u"
else
  _pass "scope error, no GH_TOKEN: does not suggest env -u"
fi

# --- Case 3: negative control, non-scope 403 -> no hint -----------------------
GH_TOKEN="fixture-token" _run plain403 pr list --repo smartwatermelon/dotfiles
rc=$?
err="$(cat "${WORKDIR}/err")"
if [[ "${rc}" -eq 1 && "${err}" == *"Must have admin rights"* && "${err}" != *"[gh]"* ]]; then
  _pass "non-scope 403: stderr preserved, no hint, exit 1"
else
  _fail "non-scope 403: expected no hint, got rc=${rc} err=${err}"
fi

# --- Case 4: negative control, success -> nothing added -----------------------
GH_TOKEN="fixture-token" _run ok repo view smartwatermelon/dotfiles
rc=$?
out="$(cat "${WORKDIR}/out")"
err="$(cat "${WORKDIR}/err")"
if [[ "${rc}" -eq 0 && "${out}" == "stdout-from-gh" && "${err}" == "stderr-from-gh" ]]; then
  _pass "success: stdout and stderr untouched, exit 0"
else
  _fail "success: output altered, rc=${rc} out=${out} err=${err}"
fi

# --- Case 5: no stray temp files --------------------------------------------
leftover="$(_errfile_count)"
if [[ "${leftover}" == "0" ]]; then
  _pass "temp stderr files cleaned up"
else
  _fail "temp stderr files left behind: ${leftover}"
fi

# --- Case 6: secret-bearing flag values are redacted from the hint -----------
# The hint goes to stderr, which lands in scrollback, CI logs and transcripts.
# Echoing back `--body <token>` would copy a live credential into all three.
SECRET="totally-not-a-real-secret-value-9271"
GH_TOKEN="fixture-token" _run scope secret set FOO --body "${SECRET}" --org smartwatermelon
err="$(cat "${WORKDIR}/err")"
if [[ "${err}" == *"<redacted>"* ]]; then
  _pass "redaction: hint shows <redacted> for --body"
else
  _fail "redaction: expected <redacted>, got: ${err}"
fi
if [[ "${err}" == *"${SECRET}"* ]]; then
  _fail "redaction: SECRET LEAKED into the hint: ${err}"
else
  _pass "redaction: secret value never appears in the hint"
fi
# The non-secret parts must survive, or the suggestion is not runnable.
if [[ "${err}" == *"gh secret set FOO"* && "${err}" == *"--org smartwatermelon"* ]]; then
  _pass "redaction: non-secret arguments preserved"
else
  _fail "redaction: non-secret arguments mangled, got: ${err}"
fi

# --with-equals spelling must redact too; a key=value field keeps its key.
GH_TOKEN="fixture-token" _run scope api -X POST /x --field="body=${SECRET}"
err="$(cat "${WORKDIR}/err")"
if [[ "${err}" != *"${SECRET}"* && "${err}" == *"--field=body=<redacted>"* ]]; then
  _pass "redaction: --field=key=VALUE keeps the key, redacts the value"
else
  _fail "redaction: --field=key=VALUE not redacted as expected, got: ${err}"
fi

# Stuck short flags (-bVALUE, -fkey=VALUE) are valid pflag syntax and were the
# leak the first fix round missed: an exact-token `case` never saw them.
GH_TOKEN="fixture-token" _run scope secret set FOO "-b${SECRET}" --org smartwatermelon
err="$(cat "${WORKDIR}/err")"
if [[ "${err}" != *"${SECRET}"* && "${err}" == *" -b<redacted> "* ]]; then
  _pass "redaction: stuck -bVALUE redacted"
else
  _fail "redaction: stuck -bVALUE leaked or mangled, got: ${err}"
fi
GH_TOKEN="fixture-token" _run scope api -X POST /x "-fquery=${SECRET}"
err="$(cat "${WORKDIR}/err")"
if [[ "${err}" != *"${SECRET}"* && "${err}" == *" -fquery=<redacted>"* ]]; then
  _pass "redaction: stuck -fkey=VALUE keeps the key, redacts the value"
else
  _fail "redaction: stuck -fkey=VALUE leaked or mangled, got: ${err}"
fi

# A positional after `--` is never a flag, even if it spells one.
GH_TOKEN="fixture-token" _run scope api /x -- --body
err="$(cat "${WORKDIR}/err")"
if [[ "${err}" == *"gh api /x -- --body"* && "${err}" != *"<redacted>"* ]]; then
  _pass "redaction: -- ends flag parsing"
else
  _fail "redaction: -- not honored, got: ${err}"
fi

# --- Case 7: GITHUB_TOKEN (no GH_TOKEN) names the right variable -------------
# gh reads GH_TOKEN first, then GITHUB_TOKEN. Suggesting `gh auth refresh` here
# would be useless: an env-var token overrides the keyring token it rewrites.
GITHUB_TOKEN="fixture-token" _run scope secret set FOO --org smartwatermelon
err="$(cat "${WORKDIR}/err")"
if [[ "${err}" == *"env -u GITHUB_TOKEN"* ]]; then
  _pass "GITHUB_TOKEN: hint names GITHUB_TOKEN in the re-run"
else
  _fail "GITHUB_TOKEN: expected 'env -u GITHUB_TOKEN', got: ${err}"
fi
if [[ "${err}" == *"env -u GH_TOKEN "* ]]; then
  _fail "GITHUB_TOKEN: wrongly told the user to unset GH_TOKEN"
else
  _pass "GITHUB_TOKEN: does not name the unset GH_TOKEN"
fi

# --- Case 8: no temp-file leak when the wrapper is signalled mid-run ---------
# SIGTERM/SIGHUP skip the function's trailing rm -f; only a RETURN trap cleans
# up. SIGINT already unwound correctly, so TERM is the case that regressed.
mkdir -p "${STUBS}/sleeper"
cat >"${STUBS}/sleeper/gh" <<'STUB'
#!/usr/bin/env bash
echo 'starting' >&2
sleep 30
STUB
chmod +x "${STUBS}/sleeper/gh"

leak_before="$(_errfile_count)"
# `exec` so the backgrounded pid IS the wrapper. Without it the pid belongs to
# the subshell, and signalling that leaves the wrapper running untouched — the
# trap never fires and the test reports a leak that is really a mis-aimed kill.
(
  cd "${HOME}/neutral-cwd" || exit 99
  PATH="${STUBS}/sleeper:${PATH}" exec bash "${WRAPPER}" api user \
    >/dev/null 2>&1
) &
sleeper_pid=$!
# Wait for the errfile to actually exist before signalling. Without this the
# test can kill the wrapper before mktemp runs and pass for the wrong reason —
# a clean result would then prove nothing.
saw_errfile=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  now="$(_errfile_count)"
  if [[ "${now}" != "${leak_before}" ]]; then
    saw_errfile=1
    break
  fi
  sleep 0.25
done
kill -TERM "${sleeper_pid}" 2>/dev/null
wait "${sleeper_pid}" 2>/dev/null
sleep 0.3

if [[ "${saw_errfile}" == "1" ]]; then
  _pass "SIGTERM leak: errfile observed mid-run (assertion is meaningful)"
else
  _fail "SIGTERM leak: errfile never appeared; the check below proves nothing"
fi
leak_after="$(_errfile_count)"
if [[ "${leak_after}" == "0" ]]; then
  _pass "SIGTERM leak: no temp file left behind after SIGTERM"
else
  _fail "SIGTERM leak: ${leak_after} temp file(s) left behind after SIGTERM"
fi

if [[ ${fail} -eq 0 ]]; then
  echo "test-gh-wrapper-scope-hint.sh: all assertions passed"
  exit 0
fi
exit 1
