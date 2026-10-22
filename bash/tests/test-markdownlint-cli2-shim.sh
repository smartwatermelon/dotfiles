#!/usr/bin/env bash
#shellcheck shell=bash
# The markdownlint-cli2 shim, against an argv-recording stub.
# MDL_SHIM swaps in a known-bad shim.
set -uo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SHIM="${MDL_SHIM:-${REPO_ROOT}/bash/markdownlint-cli2-wrapper.sh}"

fail=0
_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT

# Installed layout: a PATH dir holding a symlink to the shim, ahead of the real binary.
SHIMDIR="${TMPROOT}/shim-bin"
mkdir -p "${SHIMDIR}"
ln -s "${SHIM}" "${SHIMDIR}/markdownlint-cli2"

REALDIR="${TMPROOT}/real-bin"
RECORD="${TMPROOT}/argv"
mkdir -p "${REALDIR}"
cat >"${REALDIR}/markdownlint-cli2" <<EOF
#!/bin/bash
: >"${RECORD}"
for a in "\$@"; do printf '%s\n' "\$a" >>"${RECORD}"; done
echo REAL-RAN
EOF
chmod +x "${REALDIR}/markdownlint-cli2"

CANONICAL="${TMPROOT}/canonical.json"
printf '{"default": true, "MD013": false}\n' >"${CANONICAL}"

BASE_PATH="/usr/bin:/bin"

# 10 s cap: an exec loop fails the case, not the suite. 124 = killed.
_bounded() {
  "$@" &
  local pid=$! i=0
  while kill -0 "${pid}" 2>/dev/null; do
    if ((i >= 100)); then
      kill -9 "${pid}" 2>/dev/null
      wait "${pid}" 2>/dev/null
      return 124
    fi
    sleep 0.1
    i=$((i + 1))
  done
  wait "${pid}"
}

# _run <cwd> <PATH> <canonical> args...  — sets OUT (stdout+stderr) and RC.
_run() {
  local dir="$1" path="$2" canon="$3"
  shift 3
  rm -f "${RECORD}"
  RC=0
  OUT="$(cd "${dir}" && _bounded env -u _MARKDOWNLINT_SHIM_ACTIVE PATH="${path}" \
    MARKDOWNLINT_CANONICAL_CONFIG="${canon}" markdownlint-cli2 "$@" 2>&1)" || RC=$?
}

# _expect_argv <label> args...  — the stub ran and saw exactly these args.
_expect_argv() {
  local label="$1"
  shift
  local want got
  want="$(printf '%s\n' "$@")"
  if [[ ! -f "${RECORD}" ]]; then
    _fail "${label}: real binary never ran (rc=${RC}): ${OUT}"
    return
  fi
  got="$(cat "${RECORD}")"
  if [[ "${got}" == "${want}" ]]; then
    _pass "${label}"
  else
    _fail "${label}: argv was [${got//$'\n'/ }], want [${want//$'\n'/ }]"
  fi
}

_case_dir() {
  local d="${TMPROOT}/case-$1"
  mkdir -p "${d}"
  printf '# Doc\n' >"${d}/README.md"
  printf '%s' "${d}"
}

P="${SHIMDIR}:${REALDIR}:${BASE_PATH}"

echo "-- no repo config: canonical added"
d="$(_case_dir none)"
_run "${d}" "${P}" "${CANONICAL}" README.md
_expect_argv "--config <canonical> prepended" --config "${CANONICAL}" README.md

echo "-- repo config present: unchanged"
for cfg in .markdownlint-cli2.jsonc .markdownlint.json .markdownlintrc; do
  d="$(_case_dir "repo${cfg}")"
  printf '{}\n' >"${d}/${cfg}"
  _run "${d}" "${P}" "${CANONICAL}" README.md
  _expect_argv "${cfg} in cwd: args unchanged" README.md
done

echo "-- caller passed --config: unchanged"
d="$(_case_dir explicit)"
_run "${d}" "${P}" "${CANONICAL}" --config other.json README.md
_expect_argv "--config X: args unchanged" --config other.json README.md
_run "${d}" "${P}" "${CANONICAL}" --fix --config=other.json README.md
_expect_argv "--config=X: args unchanged" --fix --config=other.json README.md

echo "-- canonical missing: unchanged, with a notice"
d="$(_case_dir missing)"
_run "${d}" "${P}" "${TMPROOT}/does-not-exist.json" README.md
_expect_argv "missing canonical: args unchanged" README.md
if grep -q 'canonical config not found' <<<"${OUT}"; then
  _pass "missing canonical: stderr notice"
else
  _fail "missing canonical: no notice: ${OUT}"
fi

echo "-- no args and --help: unchanged"
d="$(_case_dir help)"
_run "${d}" "${P}" "${CANONICAL}"
if [[ -f "${RECORD}" && ! -s "${RECORD}" ]]; then
  _pass "no args: real binary ran with no args"
else
  rec=""
  [[ -f "${RECORD}" ]] && rec="$(cat "${RECORD}")"
  _fail "no args: record=[${rec}] rc=${RC}: ${OUT}"
fi
_run "${d}" "${P}" "${CANONICAL}" --help
_expect_argv "--help: args unchanged" --help

echo "-- self-skip: the shim never picks itself as the real binary"
# Two PATH dirs ahead of the real one hold the shim (different symlink paths,
# same realpath), and the first dir is listed twice.
SHIMDIR2="${TMPROOT}/shim-bin-2"
mkdir -p "${SHIMDIR2}"
ln -s "${SHIMDIR}/markdownlint-cli2" "${SHIMDIR2}/markdownlint-cli2"
d="$(_case_dir self)"
_run "${d}" "${SHIMDIR}:${SHIMDIR2}:${SHIMDIR}:${REALDIR}:${BASE_PATH}" "${CANONICAL}" README.md
if ((RC == 124)); then
  _fail "self-skip: killed after 10 s (exec loop)"
else
  _expect_argv "self-skip: reached the real binary" --config "${CANONICAL}" README.md
fi

echo "-- no real binary: exit 127"
d="$(_case_dir noreal)"
_run "${d}" "${SHIMDIR}:${SHIMDIR2}:${BASE_PATH}" "${CANONICAL}" README.md
if ((RC == 127)) && grep -q 'no real markdownlint-cli2' <<<"${OUT}"; then
  _pass "no real binary: exit 127 with a message"
else
  _fail "no real binary: rc=${RC}: ${OUT}"
fi

if ((fail)); then
  echo "FAIL: markdownlint-cli2 shim"
  exit 1
fi
echo "OK: markdownlint-cli2 shim"
