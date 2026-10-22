#!/usr/bin/env bash
# Tests run-tests.sh's CI-only guard and RUN_FULL_SUITE=1 override, on a
# runner copy with fake tests.
set -euo pipefail
unset CDPATH

TESTS_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH}"' EXIT
mkdir -p "${SCRATCH}/lib"
cp "${TESTS_DIR}/run-tests.sh" "${SCRATCH}/run-tests.sh"
cp "${TESTS_DIR}/lib/git-env-isolation.sh" "${SCRATCH}/lib/git-env-isolation.sh"
printf 'echo marker-ran\n' >"${SCRATCH}/test-fake.sh"
chmod +x "${SCRATCH}/test-fake.sh"

fail=0
# run_case <name> <want rc> <want marker: yes|no> <env assignments...> -- [runner args...]
run_case() {
  local name="$1" want_rc="$2" want_marker="$3" out rc
  shift 3
  local envs=()
  while [[ "$1" != "--" ]]; do
    envs+=("$1")
    shift
  done
  shift
  rc=0
  out="$(env -u GITHUB_ACTIONS -u RUN_FULL_SUITE "${envs[@]}" "${BASH}" "${SCRATCH}/run-tests.sh" "$@" 2>&1)" || rc=$?
  local got_marker=no
  [[ "${out}" == *marker-ran* ]] && got_marker=yes
  if [[ "${rc}" == "${want_rc}" && "${got_marker}" == "${want_marker}" ]]; then
    echo "PASS: ${name}"
  else
    echo "FAIL: ${name}: rc=${rc} (want ${want_rc}), marker=${got_marker} (want ${want_marker})"
    echo "${out}" | sed 's/^/    /'
    fail=1
  fi
}

run_case "no filter outside CI refuses with exit 3" 3 no X=1 --
run_case "no filter in CI runs the suite" 0 yes GITHUB_ACTIONS=true --
run_case "no filter with RUN_FULL_SUITE=1 runs the suite" 0 yes RUN_FULL_SUITE=1 --
run_case "only RUN_FULL_SUITE=1 overrides, not other values" 3 no RUN_FULL_SUITE=yes --
run_case "a filtered run outside CI runs" 0 yes X=1 -- fake

exit "${fail}"
