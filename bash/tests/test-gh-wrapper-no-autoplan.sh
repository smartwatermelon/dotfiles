#!/usr/bin/env bash
#shellcheck shell=bash
# gh-wrapper.sh: `pr create` in an Atlantis repo gets no-autoplan once.
set -euo pipefail

unset CDPATH GH_REPO

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_tests_dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-env-isolation.sh
source "${_tests_dir}/lib/git-env-isolation.sh"
isolate_git_env

export BASH_CONFIG_DIR="${REPO_ROOT}/bash"

#shellcheck source=/dev/null
source "${BASH_CONFIG_DIR}/gh-wrapper.sh"

fail=0

# Counts how many times the no-autoplan label is attached in the rebuilt args.
count_label() {
  local -a got=()
  local a want="" n=0
  mapfile -t -d '' got < <(_gh_wrapper_add_no_autoplan_label "$@" 2>/dev/null || true)
  for a in "${got[@]}"; do
    if [[ "${want}" == "1" ]]; then
      [[ ",${a,,}," == *",no-autoplan,"* ]] && n=$((n + 1))
      want=""
    elif [[ "${a}" == "--label" || "${a}" == "-l" ]]; then
      want=1
    elif [[ "${a}" == --label=* && ",${a#--label=}," == *",no-autoplan,"* ]]; then
      n=$((n + 1))
    elif [[ "${a}" == -l?* && ",${a#-l[=]}," == *",no-autoplan,"* ]]; then
      n=$((n + 1))
    fi
  done
  printf '%s\n' "${n}"
}

assert_count() {
  local desc="$1" want="$2"
  shift 2
  local got
  got="$(count_label "$@")"
  if [[ "${got}" == "${want}" ]]; then
    echo "PASS: ${desc}"
  else
    echo "FAIL: ${desc}: expected no-autoplan ${want} time(s), got ${got} (args: $*)"
    fail=1
  fi
}

assert_count "infra pr create gets the label" 1 pr create --repo beacon-biosignals/infra --title x
assert_count "infra pr new (alias) gets the label" 1 pr new -R beacon-biosignals/infra --title x
assert_count "infra --repo= form gets the label" 1 pr create --repo=beacon-biosignals/infra --title x
assert_count "mixed-case repo gets the label" 1 pr create --repo Beacon-Biosignals/Infra --title x
assert_count "infra repo URL gets the label" 1 pr create --repo https://github.com/beacon-biosignals/infra --title x
assert_count "already --label no-autoplan: not duplicated" 1 pr create --repo beacon-biosignals/infra --label no-autoplan --title x
assert_count "already in a comma list: not duplicated" 1 pr create --repo beacon-biosignals/infra --label infra,no-autoplan --title x
assert_count "already -l=no-autoplan: not duplicated" 1 pr create --repo beacon-biosignals/infra -l=no-autoplan --title x
assert_count "already --label=no-autoplan: not duplicated" 1 pr create --repo beacon-biosignals/infra --label=no-autoplan --title x
assert_count "other label kept, no-autoplan added" 1 pr create --repo beacon-biosignals/infra --label infra --title x
assert_count "non-Atlantis Beacon repo unchanged" 0 pr create --repo beacon-biosignals/platform-datastore --title x
assert_count "personal repo unchanged" 0 pr create --repo smartwatermelon/dotfiles --title x
assert_count "infra pr edit unchanged" 0 pr edit 5 --repo beacon-biosignals/infra --title x
assert_count "infra issue create unchanged" 0 issue create --repo beacon-biosignals/infra --title x

# Injection keeps --draft forcing working: the draft step runs on the rebuilt args.
mapfile -t -d '' after_label < <(_gh_wrapper_add_no_autoplan_label pr create --repo beacon-biosignals/infra --title x || true)
mapfile -t -d '' after_draft < <(_gh_wrapper_force_draft_for_off_org "${after_label[@]}" || true)
if [[ " ${after_draft[*]} " == *" --label no-autoplan "* ]]; then
  echo "PASS: label survives the later draft step"
else
  echo "FAIL: label lost after the draft step: ${after_draft[*]@Q}"
  fail=1
fi

# A multi-line --body survives the NUL rebuild as one argument, label appended after it.
body="$(printf 'line one\nline two')"
mapfile -t -d '' got < <(_gh_wrapper_add_no_autoplan_label pr create --repo beacon-biosignals/infra --body "${body}" || true)
if [[ "${#got[@]}" == "8" && "${got[5]}" == "${body}" && "${got[6]}" == "--label" && "${got[7]}" == "no-autoplan" ]]; then
  echo "PASS: multi-line --body survives intact"
else
  echo "FAIL: multi-line --body rebuild wrong (count=${#got[@]}): ${got[*]@Q}"
  fail=1
fi

# A child shell that inherits the exported function without re-sourcing still sees the repo list.
child_out="$(bash -c '_gh_wrapper_add_no_autoplan_label pr create --repo beacon-biosignals/infra | tr "\0" " "' 2>&1)" || child_out="error: ${child_out}"
if [[ "${child_out}" == *"--label no-autoplan "* ]]; then
  echo "PASS: child shell adds the label"
else
  echo "FAIL: child shell did not add the label: ${child_out@Q}"
  fail=1
fi

# Zero args: no output.
mapfile -t -d '' zero < <(_gh_wrapper_add_no_autoplan_label || true)
if [[ "${#zero[@]}" == "0" ]]; then
  echo "PASS: zero args produce nothing"
else
  echo "FAIL: zero args produced: ${zero[*]@Q}"
  fail=1
fi

# Unresolved repo (no -R, no GH_REPO, cwd not a git repo): warns, passes args through.
unresolved_err="$(cd / && _gh_wrapper_add_no_autoplan_label pr create --title x 2>&1 >/dev/null)" || true
unresolved_n="$(cd / && count_label pr create --title x)" || unresolved_n="error"
if [[ "${unresolved_err}" == *"no-autoplan not checked"* && "${unresolved_n}" == "0" ]]; then
  echo "PASS: unresolved repo warns and passes through"
else
  echo "FAIL: unresolved repo: stderr=${unresolved_err@Q} count=${unresolved_n}"
  fail=1
fi

exit "${fail}"
