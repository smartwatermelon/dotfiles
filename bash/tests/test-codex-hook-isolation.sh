#!/usr/bin/env bash
# Isolated fixtures prove Codex avoids CC layers but retains normal Git checks.
set -euo pipefail
unset CDPATH
# Imported interactive wrappers must not shadow the fixture executables.
unset -f git gh || true
root="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
real_git="$(type -P git)"
test_home="${work}/home"
repo="${work}/repo"
mkdir -p "${test_home}/.config/pre-commit" "${work}/bin" "${work}/empty-hooks" "${repo}"
while IFS= read -r name; do unset "${name}"; done < <(compgen -v GIT_)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export CODEX_THREAD_ID=codex-fixture
unset CODEX_SESSION_ID CLAUDECODE
export CODEX_FIXTURE_CALLS="${work}/calls"
: >"${CODEX_FIXTURE_CALLS}"
# Hooks are empty only in these newly created, private test repositories.
git_fixture() { "${real_git}" -c core.hooksPath="${work}/empty-hooks" "$@"; }
git_fixture -C "${repo}" init -q -b main
git_fixture -C "${repo}" config user.name Fixture
git_fixture -C "${repo}" config user.email fixture@example.invalid
printf 'base\n' >"${repo}/base.txt"
git_fixture -C "${repo}" add base.txt
git_fixture -C "${repo}" commit -qm 'test: base'
base="$(git_fixture -C "${repo}" rev-parse HEAD)"
git_fixture -C "${repo}" update-ref refs/remotes/origin/main "${base}"
git_fixture -C "${repo}" switch -qc feature
printf 'change\n' >"${repo}/change.txt"
git_fixture -C "${repo}" add change.txt
git_fixture -C "${repo}" commit -qm 'test: change'
tip="$(git_fixture -C "${repo}" rev-parse HEAD)"

mkdir -p "${test_home}/.claude/hooks" "${test_home}/.claude/scripts"
for name in hooks/run-review.sh scripts/gate-review.sh scripts/gate-lint.sh hooks/pre-merge-review.sh; do
  cat >"${test_home}/.claude/${name}" <<'MOCK'
#!/usr/bin/env bash
printf 'forbidden-cc\n' >>"${CODEX_FIXTURE_CALLS}"
exit 99
MOCK
  chmod +x "${test_home}/.claude/${name}"
done
cat >"${work}/bin/pre-commit" <<'MOCK'
#!/usr/bin/env bash
printf 'deterministic-lint\n' >>"${CODEX_FIXTURE_CALLS}"
exit "${CODEX_FIXTURE_LINT_RC:-0}"
MOCK
cat >"${work}/bin/semgrep" <<'MOCK'
#!/usr/bin/env bash
printf 'security-scan\n' >>"${CODEX_FIXTURE_CALLS}"
exit "${CODEX_FIXTURE_SCAN_RC:-0}"
MOCK
cat >"${work}/bin/gh" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
chmod +x "${work}/bin/"*
export PATH="${work}/bin:${PATH}"
printf 'repos: []\n' >"${test_home}/.config/pre-commit/config.yaml"
run_hook() { (cd "${repo}" && env HOME="${test_home}" "${BASH}" "$@"); }
expect_block() {
  if "$@" >"${work}/blocked.log" 2>&1; then
    echo "FAIL: expected rejection: $*" >&2
    exit 1
  fi
}

printf 'feat: test change\n' >"${work}/message"
run_hook "${root}/git/hooks/commit-msg" "${work}/message"
printf 'not conventional\n' >"${work}/message"
expect_block run_hook "${root}/git/hooks/commit-msg" "${work}/message"
run_hook "${root}/git/hooks/lint-length.sh"
run_hook "${root}/git/hooks/pre-commit"
grep -q deterministic-lint "${CODEX_FIXTURE_CALLS}"
# Expansion belongs to the child shell.
# shellcheck disable=SC2016
expect_block env CODEX_FIXTURE_LINT_RC=1 HOME="${test_home}" "${BASH}" -c \
  'cd "$1"; exec "$BASH" "$2"' -- "${repo}" "${root}/git/hooks/pre-commit"
git_fixture -C "${repo}" switch -q main
expect_block run_hook "${root}/git/hooks/pre-commit"
git_fixture -C "${repo}" switch -q feature

mkdir -p "${repo}/.project-hooks"
cat >"${repo}/.project-hooks/pre-push" <<'MOCK'
#!/usr/bin/env bash
printf 'project-tests\n' >>"${CODEX_FIXTURE_CALLS}"
exit "${CODEX_FIXTURE_PROJECT_RC:-0}"
MOCK
chmod +x "${repo}/.project-hooks/pre-push"
printf 'refs/heads/feature %s refs/heads/feature %s\n' "${tip}" "${base}" \
  | run_hook "${root}/git/hooks/pre-push" origin git@github.com:fixture/repo.git
for marker in security-scan project-tests; do grep -q "${marker}" "${CODEX_FIXTURE_CALLS}"; done
if printf 'refs/heads/feature %s refs/heads/main %s\n' "${tip}" "${base}" \
  | run_hook "${root}/git/hooks/pre-push" origin git@github.com:fixture/repo.git >"${work}/blocked.log" 2>&1; then
  echo 'FAIL: direct main push passed' >&2
  exit 1
fi
if printf 'refs/heads/feature %s refs/heads/feature %s\n' "${tip}" "${base}" \
  | CODEX_FIXTURE_SCAN_RC=1 run_hook "${root}/git/hooks/pre-push" origin git@github.com:fixture/repo.git >"${work}/blocked.log" 2>&1; then
  echo 'FAIL: failed security scan passed' >&2
  exit 1
fi
if printf 'refs/heads/feature %s refs/heads/feature %s\n' "${tip}" "${base}" \
  | CODEX_FIXTURE_PROJECT_RC=1 run_hook "${root}/git/hooks/pre-push" origin git@github.com:fixture/repo.git >"${work}/blocked.log" 2>&1; then
  echo 'FAIL: failed project tests passed' >&2
  exit 1
fi

mkdir -p "${test_home}/.local/state/claude-review"
printf 'commit: unchanged\n' >"${test_home}/.local/state/claude-review/last-review-result.log"
run_hook "${root}/git/hooks/post-commit"
grep -qx 'commit: unchanged' "${test_home}/.local/state/claude-review/last-review-result.log"

fresh="${work}/fresh"
mkdir -p "${fresh}" "${work}/template/.claude-template"
printf 'fixture\n' >"${work}/template/.claude-template/sentinel"
printf 'root = true\n' >"${work}/template/.editorconfig"
git_fixture -C "${fresh}" init -q -b feature
git_fixture -C "${fresh}" config init.templateDir "${work}/template"
(cd "${fresh}" && env HOME="${test_home}" "${BASH}" "${root}/git/template/hooks/post-checkout" \
  0000000000000000000000000000000000000000 "${tip}" 1)
[[ -f "${fresh}/.editorconfig" && ! -e "${fresh}/.claude" ]]

# Expansion belongs to the child shell.
# shellcheck disable=SC2016
env HOME="${test_home}" "${BASH}" -c '
  source "$1/bash/gh-wrapper.sh"
  _gh_wrapper_approval_gate pr create --body "fixture"
  if _gh_wrapper_maybe_review strict pr merge 1; then exit 1; fi
  if _gh_wrapper_block_bypass api repos/fixture/repo/pulls/1/merge -X PUT; then exit 1; fi
' -- "${root}"
if grep -q forbidden-cc "${CODEX_FIXTURE_CALLS}"; then
  echo 'FAIL: a CC hook ran' >&2
  exit 1
fi
# A standalone Codex session identifier must select the same isolated path.
unset CODEX_THREAD_ID
export CODEX_SESSION_ID=codex-session-fixture
printf 'feat: test change\n' >"${work}/message"
run_hook "${root}/git/hooks/commit-msg" "${work}/message"
run_hook "${root}/git/hooks/lint-length.sh"
# Ordinary non-Codex validation still rejects malformed commit messages.
unset CODEX_SESSION_ID
printf 'not conventional\n' >"${work}/message"
expect_block run_hook "${root}/git/hooks/commit-msg" "${work}/message"
echo 'PASS: Codex isolation, lint/security/project failures, protected branches, and merge guards'
