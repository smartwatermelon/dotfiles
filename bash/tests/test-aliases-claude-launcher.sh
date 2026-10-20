#!/usr/bin/env bash
#shellcheck shell=bash

# aliases.sh launcher order: claude-wrapper, claude-wrapper-lite, then
# caffeinate claude.
set -euo pipefail

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail=0

WORKDIR="$(mktemp -d "/tmp/aliases-claude-launcher-test.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

# Sources aliases.sh under a synthetic HOME with env -i, so the real
# ~/.local/bin cannot decide the result.
cat >"${WORKDIR}/probe.sh" <<'PROBE'
#shellcheck source=/dev/null
source "${ALIASES_FILE}" >/dev/null 2>&1
if [[ -n "${BASH_ALIASES[$1]+set}" ]]; then
  printf '%s' "${BASH_ALIASES[$1]}"
else
  printf '<unset>'
fi
PROBE

_alias_under_home() {
  env -i HOME="$1" ALIASES_FILE="${REPO_ROOT}/bash/aliases.sh" \
    PATH="/usr/bin:/bin" "${BASH}" --norc "${WORKDIR}/probe.sh" "$2"
}

# $1 home, $2 alias name, $3 expected stored text, $4 case label.
assert_alias() {
  local got
  got="$(_alias_under_home "$1" "$2")"
  if [[ "${got}" == "$3" ]]; then
    echo "PASS: $4: $2='${got}'"
  else
    echo "FAIL: $4: expected $2='$3', got '${got}'"
    fail=1
  fi
}

# aliases.sh single-quotes the ${HOME} paths, so the stored alias text keeps
# a literal ${HOME} that expands only when the alias runs.
dollar='$'
lit_bin="${dollar}{HOME}/.local/bin"
mega_env='BUDGET_SESSION_TOKENS=50000000 BUDGET_SUBAGENT_TOKENS=12000000'

# Builds a synthetic HOME holding the named launcher files under .local/bin.
make_home() {
  local home="${WORKDIR}/$1"
  shift
  mkdir -p "${home}/.local/bin"
  local f
  for f in "$@"; do
    touch "${home}/.local/bin/${f}"
  done
  printf '%s' "${home}"
}

# --- Case 1: the full wrapper wins, even when lite is also present.
for label in full both; do
  if [[ "${label}" == full ]]; then
    home="$(make_home "${label}" claude claude-wrapper)"
  else
    home="$(make_home "${label}" claude claude-wrapper claude-wrapper-lite)"
  fi
  assert_alias "${home}" claude "${lit_bin}/claude-wrapper" "${label}"
  assert_alias "${home}" clauded "claude --dangerously-skip-permissions" "${label}"
  assert_alias "${home}" megaclaude "${mega_env} claude" "${label}"
  assert_alias "${home}" megaclauded "${mega_env} clauded" "${label}"
done

# --- Case 2: only claude-wrapper-lite present. It runs caffeinate itself,
# so the alias must not wrap it in caffeinate again.
home="$(make_home lite claude claude-wrapper-lite)"
assert_alias "${home}" claude "${lit_bin}/claude-wrapper-lite" "lite"
assert_alias "${home}" clauded "claude --dangerously-skip-permissions" "lite"
assert_alias "${home}" megaclaude "${mega_env} claude" "lite"
assert_alias "${home}" megaclauded "${mega_env} clauded" "lite"

# --- Case 3: neither wrapper present — today's caffeinate fallback, and no
# mega aliases.
home="$(make_home bare claude)"
assert_alias "${home}" claude "/usr/bin/caffeinate -i ${lit_bin}/claude" "bare"
assert_alias "${home}" clauded "claude --dangerously-skip-permissions" "bare"
assert_alias "${home}" megaclaude "<unset>" "bare"
assert_alias "${home}" megaclauded "<unset>" "bare"

# --- Case 4: suclaude always bypasses every wrapper, in every tier.
for label in full lite bare; do
  assert_alias "${WORKDIR}/${label}" suclaude "${lit_bin}/claude" "${label}"
  assert_alias "${WORKDIR}/${label}" suclauded "suclaude --dangerously-skip-permissions" "${label}"
done

exit "${fail}"
