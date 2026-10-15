#!/usr/bin/env bash
# Tests allup's failed-pull prompt: _allup_pull_step in bash/functions.sh
# (smartwatermelon/scripts#2, #6).
set -euo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/git-env-isolation.sh
source "${REPO_ROOT}/bash/tests/lib/git-env-isolation.sh"
isolate_git_env

fail=0

WORKDIR="$(mktemp -d "/tmp/allup-pull-retry-test.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

# Extract the functions under test through bash's own parser, as
# test-allup-continue-state.sh does, rather than slicing the file by text.
_fn_src="$(bash --norc --noprofile -c '
  source "$1" >/dev/null 2>&1 || exit 1
  declare -f allup _allup_pull_step _updates_noninteractive \
    _allup_scripts_dir _allup_scripts_current _allup_check_scripts _allup_versions
  declare -p _ALLUP_MIN_SCRIPTS
' _ "${REPO_ROOT}/bash/functions.sh")"
for fn in allup _allup_pull_step _updates_noninteractive \
  _allup_scripts_dir _allup_scripts_current _allup_check_scripts _allup_versions; do
  if [[ "${_fn_src}" != *"${fn} ()"* ]]; then
    echo "FAIL: could not extract ${fn} from functions.sh" >&2
    exit 1
  fi
done
eval "${_fn_src}"
# The same value, read into a name shellcheck can see assigned.
MIN="$(bash --norc --noprofile -c '
  source "$1" >/dev/null 2>&1 || exit 1
  echo "${_ALLUP_MIN_SCRIPTS:?}"
' _ "${REPO_ROOT}/bash/functions.sh")"

# Stubs for allup's other calls. Sourced from a file: shellcheck cannot see
# calls from eval'd code.
cat >"${WORKDIR}/stubs.sh" <<'EOF'
_notif() { echo "notif: $1"; }
_updates_state_entrypoint() {
  [[ -n "${STATE_EP:-}" ]] || return 1
  echo "${STATE_EP}"
}
updates() { echo "updates $*" >>"${CALLS}"; }
EOF
#shellcheck source=/dev/null
source "${WORKDIR}/stubs.sh"

# Fake HOME: the two install.sh --sync targets and .bash_profile.
FAKE_HOME="${WORKDIR}/home"
mkdir -p "${FAKE_HOME}/Developer/dotfiles" "${FAKE_HOME}/Developer/claude-config"
for repo in dotfiles claude-config; do
  cat >"${FAKE_HOME}/Developer/${repo}/install.sh" <<EOF
#!/usr/bin/env bash
echo "install ${repo} \$*" >>"\${CALLS}"
EOF
  chmod +x "${FAKE_HOME}/Developer/${repo}/install.sh"
done
: >"${FAKE_HOME}/.bash_profile"

# Walker stub. PLAN_<name> lists one outcome per call: ok, fail (exit 1),
# crash (exit 2), dirty.
BIN="${WORKDIR}/bin"
mkdir -p "${BIN}"
cat >"${BIN}/walker-stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
name="$(basename "$0")"
echo "${name}" >>"${CALLS}"
n="$(grep -cx "${name}" "${CALLS}")"
plan_var="PLAN_${name//-/_}"
read -r -a plan <<<"${!plan_var:-ok}"
outcome="${plan[n - 1]:-ok}"
C=$'\033[0;36m' G=$'\033[0;32m' Y=$'\033[0;33m' R=$'\033[0;31m' Z=$'\033[0m'
summary() {
  echo ""
  echo "${C}━━━ Summary ━━━${Z}"
  echo "  Total: 2  ${G}Pulled: $1${Z}  ${Y}Skipped: $2${Z}  ${R}Failed: $3${Z}"
}
echo ""
echo "${C}━━━ goodrepo ━━━${Z}"
echo "  ${G}✓ up to date${Z}"
case "${outcome}" in
  ok) summary 2 0 0 ;;
  fail)
    echo "${C}━━━ badrepo ━━━${Z}"
    echo "  ${R}✗ pull failed${Z}"
    summary 1 0 1
    echo ""
    echo "  ${R}Failed:${Z}"
    echo "    - badrepo"
    exit 1
    ;;
  dirty)
    summary 1 1 0
    echo ""
    echo "  ${Y}Skipped (dirty):${Z}"
    echo "    - dirtyrepo"
    ;;
  crash)
    echo "Unknown argument: --bogus" >&2
    exit 2
    ;;
  *) exit 99 ;;
esac
EOF
chmod +x "${BIN}/walker-stub"

# allup checks the clone my-repos runs from, so the stub lives in one.
# Upstream has "old", then "new" tagged with the minimum.
fgit() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"; }
SCRIPTS_UP="${WORKDIR}/scripts-up.git"
SCRIPTS_SEED="${WORKDIR}/scripts-seed"
SCRIPTS="${WORKDIR}/scripts"
fgit init -q --bare -b main "${SCRIPTS_UP}"
fgit init -q --template= -b main "${SCRIPTS_SEED}"
cp "${BIN}/walker-stub" "${SCRIPTS_SEED}/walker-stub"
fgit -C "${SCRIPTS_SEED}" add walker-stub
fgit -C "${SCRIPTS_SEED}" -c user.name=t -c user.email=t@t commit -qm old
OLD_SHA="$(fgit -C "${SCRIPTS_SEED}" rev-parse HEAD)"
: >"${SCRIPTS_SEED}/fixed"
fgit -C "${SCRIPTS_SEED}" add fixed
fgit -C "${SCRIPTS_SEED}" -c user.name=t -c user.email=t@t commit -qm new
fgit -C "${SCRIPTS_SEED}" tag "${MIN}"
fgit -C "${SCRIPTS_SEED}" push -q "${SCRIPTS_UP}" main "${MIN}"
fgit clone -q "${SCRIPTS_UP}" "${SCRIPTS}"
ln -s "${SCRIPTS}/walker-stub" "${BIN}/my-repos"
ln -s "${SCRIPTS}/walker-stub" "${BIN}/beacon-repos"

# Puts the scripts clone back at the tagged head, with the tag present.
reset_scripts() {
  fgit -C "${SCRIPTS}" checkout -q main
  fgit -C "${SCRIPTS}" reset -q --hard origin/main
  fgit -C "${SCRIPTS}" fetch -q --tags origin
}

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "  PASS: ${label}"
  else
    echo "  FAIL: ${label} — expected [${expected}], got [${actual}]"
    fail=1
  fi
}

check_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    echo "  PASS: ${label}"
  else
    echo "  FAIL: ${label} — [${needle}] not in output:"
    sed 's/^/        /' <<<"${haystack}"
    fail=1
  fi
}

# Runs allup with stdin text $1. Sets rc, out, and calls (the call log,
# comma-joined).
run_allup() {
  local input="$1"
  shift
  case_no=$((case_no + 1))
  CALLS="${WORKDIR}/calls.${case_no}"
  : >"${CALLS}"
  export CALLS
  rc=0
  out="$(
    HOME="${FAKE_HOME}" PATH="${BIN}:${PATH}" allup "$@" 2>&1 <<<"${input}"
  )" || rc=$?
  calls="$(paste -sd, "${CALLS}")"
}
case_no=0
INSTALLS="install dotfiles --sync,install claude-config --sync"

echo "Case: both pulls succeed"
export UPDATES_NONINTERACTIVE=0 PLAN_my_repos="ok" PLAN_beacon_repos="ok"
run_allup ""
check "status" "0" "${rc}"
check "every step runs once" "my-repos,beacon-repos,${INSTALLS},updates " "${calls}"

echo "Case: a dirty repo is not a failure"
export PLAN_my_repos="dirty"
run_allup ""
check "status" "0" "${rc}"
check "every step runs once" "my-repos,beacon-repos,${INSTALLS},updates " "${calls}"

echo "Case: my-repos fails, Enter retries, retry succeeds"
export PLAN_my_repos="fail ok"
run_allup ""
check "status" "0" "${rc}"
check "my-repos runs twice, then the rest" "my-repos,my-repos,beacon-repos,${INSTALLS},updates " "${calls}"
check_contains "lists the failed repo" "  - badrepo" "${out}"
check_contains "says the retry is the whole step" "Retrying my-repos" "${out}"

echo "Case: my-repos fails twice, Enter twice, then success"
export PLAN_my_repos="fail fail ok"
run_allup $'\n\n'
check "status" "0" "${rc}"
check "my-repos runs three times" "my-repos,my-repos,my-repos,beacon-repos,${INSTALLS},updates " "${calls}"

echo "Case: my-repos fails, s skips the remaining pulls"
export PLAN_my_repos="fail"
run_allup "s"
check "status" "0" "${rc}"
check "beacon-repos skipped; installs and updates run" "my-repos,${INSTALLS},updates " "${calls}"

echo "Case: beacon-repos fails, s continues to installs and updates"
export PLAN_my_repos="ok" PLAN_beacon_repos="fail"
run_allup "s"
check "status" "0" "${rc}"
check "installs and updates run" "my-repos,beacon-repos,${INSTALLS},updates " "${calls}"

echo "Case: my-repos fails, q quits with a non-zero status"
export PLAN_my_repos="fail" PLAN_beacon_repos="ok"
run_allup "q"
check "status" "1" "${rc}"
check "nothing after my-repos runs" "my-repos" "${calls}"
check_contains "says how to resume" "fix the failed repos and rerun 'allup'" "${out}"
check_contains "reports the walker's real exit code" "my-repos failed (exit 1)" "${out}"

echo "Case: my-repos exits non-zero, q keeps its status"
export PLAN_my_repos="crash"
run_allup "q"
check "status" "2" "${rc}"
check "nothing after my-repos runs" "my-repos" "${calls}"

echo "Case: an unrecognized reply asks again"
export PLAN_my_repos="fail"
run_allup $'x\nq'
check "status" "1" "${rc}"
check_contains "rejects the reply" "Unrecognized reply 'x'" "${out}"
check "my-repos runs once" "my-repos" "${calls}"

echo "Case: EOF at the prompt counts as q"
export PLAN_my_repos="fail"
# A here-string always ends in a newline, which reads as Enter. Feed true
# EOF instead through /dev/null.
CALLS="${WORKDIR}/calls.eof"
: >"${CALLS}"
rc=0
out="$(HOME="${FAKE_HOME}" PATH="${BIN}:${PATH}" allup 2>&1 </dev/null)" || rc=$?
calls="$(paste -sd, "${CALLS}")"
check "status" "1" "${rc}"
check "nothing after my-repos runs" "my-repos" "${calls}"

echo "Case: non-interactive run stops without a prompt"
export UPDATES_NONINTERACTIVE=1 PLAN_my_repos="fail ok"
run_allup ""
check "status" "1" "${rc}"
check "no retry, nothing after my-repos" "my-repos" "${calls}"
check_contains "names the failed step" "allup stopped at my-repos" "${out}"
check_contains "lists the failed repo" "  - badrepo" "${out}"
if [[ "${out}" == *"press Enter"* ]]; then
  echo "  FAIL: non-interactive run printed the prompt"
  fail=1
else
  echo "  PASS: no prompt printed"
fi

echo "Case: non-interactive, my-repos exits non-zero"
export PLAN_my_repos="crash"
run_allup ""
check "status" "2" "${rc}"
check_contains "names the failed step" "allup stopped at my-repos" "${out}"

echo "Case: allup --continue after an allup failure still skips the pulls"
export UPDATES_NONINTERACTIVE=0 PLAN_my_repos="fail" STATE_EP=allup
run_allup "" --continue
check "status" "0" "${rc}"
check "no pulls; installs and updates run" "${INSTALLS},updates --continue" "${calls}"
unset STATE_EP

echo "Case: a successful run ends with the version table"
export PLAN_my_repos="ok" PLAN_beacon_repos="ok"
mkdir -p "${FAKE_HOME}/.local/state/dotfiles"
echo "v1.0.7" >"${FAKE_HOME}/.local/state/dotfiles/version"
run_allup ""
check "status" "0" "${rc}"
check_contains "dotfiles row" "dotfiles       v1.0.7" "${out}"
check_contains "claude-config row" "claude-config  not recorded" "${out}"
check_contains "scripts row" "scripts        ${MIN}" "${out}"

echo "Case: scripts older than the minimum is pulled before the walk"
fgit -C "${SCRIPTS}" reset -q --hard "${OLD_SHA}"
run_allup ""
check "status" "0" "${rc}"
check_contains "says it pulls scripts first" "older than ${MIN}; pulling it first" "${out}"
check "every step runs once" "my-repos,beacon-repos,${INSTALLS},updates " "${calls}"
want_sha="$(fgit -C "${SCRIPTS}" rev-parse "${MIN}^{commit}")"
head_sha="$(fgit -C "${SCRIPTS}" rev-parse HEAD)"
check "scripts is now at the tag" "${want_sha}" "${head_sha}"

echo "Case: scripts that cannot reach the minimum stops allup before any pull"
reset_scripts
fgit -C "${SCRIPTS}" reset -q --hard "${OLD_SHA}"
# An untracked file where the incoming commit adds one makes the pull refuse.
echo "local" >"${SCRIPTS}/fixed"
run_allup ""
check "status" "1" "${rc}"
check "nothing runs" "" "${calls}"
# realpath: on macOS /tmp resolves to /private/tmp.
scripts_real="$(realpath "${SCRIPTS}")"
check_contains "names the clone and the minimum" \
  "allup needs scripts ${MIN} or later at ${scripts_real}" "${out}"
rm -f "${SCRIPTS}/fixed"
reset_scripts

echo "Case: allup --continue does not check scripts (no walk runs)"
fgit -C "${SCRIPTS}" reset -q --hard "${OLD_SHA}"
export STATE_EP=allup
run_allup "" --continue
check "status" "0" "${rc}"
check "no pulls; installs and updates run" "${INSTALLS},updates --continue" "${calls}"
unset STATE_EP
reset_scripts

# allup needs a failed pull to exit non-zero. Checked on the real walker
# when installed (not in CI); the fixture's origin does not exist.
echo "Case: the real walker's exit status"
real_walker="${HOME}/Developer/scripts/my-repos.sh"
if [[ -x "${real_walker}" ]]; then
  devdir="${WORKDIR}/devdir"
  mkdir -p "${devdir}"
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git init -q --template= -b main "${devdir}/brokenrepo"
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "${devdir}/brokenrepo" remote add origin \
    "${WORKDIR}/missing/smartwatermelon/brokenrepo.git"
  real_log="${WORKDIR}/real-walker.log"
  real_rc=0
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 MY_REPOS_DIR="${devdir}" \
    "${real_walker}" >"${real_log}" 2>&1 || real_rc=$?
  check "real walker exits 1 on a failed pull" "1" "${real_rc}"
  real_out="$(<"${real_log}")"
  check_contains "real walker lists the failed repo" "- brokenrepo" "${real_out}"
else
  echo "  SKIP: ${real_walker} not present"
fi

echo ""
if [[ "${fail}" -eq 0 ]]; then
  echo "ALL CHECKS PASSED"
else
  echo "SOME CHECKS FAILED"
fi
exit "${fail}"
