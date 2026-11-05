#!/usr/bin/env bash
# Tests bash/owner-tokens.sh: GH_TOKEN_NOS from the Keychain, interactive only.

# A stub `security` stands in for the Keychain; the real one is never called.
set -uo pipefail
unset CDPATH

TESTS_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOADER="${TESTS_DIR}/../owner-tokens.sh"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/owner-tokens-test.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

fail=0
_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

STUB_DIR="${WORKDIR}/stub-bin"
mkdir -p "${STUB_DIR}"
SEC_LOG="${WORKDIR}/security.log"
cat >"${STUB_DIR}/security" <<STUB_EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${SEC_LOG}"
case "\${SEC_MODE:-ok}" in
  ok) echo "github_pat_stub123" ;;
  missing) exit 44 ;;
  junk) echo 'not a token; rm -rf' ;;
esac
STUB_EOF
chmod +x "${STUB_DIR}/security"

# _load MODE(i|n) [VAR=VAL...]: print the loaded value marker in a fresh bash.
_load() {
  local mode="$1"
  shift
  : >"${SEC_LOG}"
  local flag=()
  [[ "${mode}" == i ]] && flag=(-i)
  env -u GH_TOKEN_NOS "$@" PATH="${STUB_DIR}:${PATH}" HOME="${WORKDIR}" \
    bash --norc --noprofile "${flag[@]}" -c "source '${LOADER}'; printf '%s' \"\${GH_TOKEN_NOS:-<unset>}\"; \
      declare -F _owner_tokens_load >/dev/null && printf ' leaked-fn'" 2>/dev/null
}

out="$(_load i)"
if [[ "${out}" == "github_pat_stub123" ]] && grep -q -- '-s gh-token-nightowlstudiollc' "${SEC_LOG}"; then
  _pass "interactive shell loads GH_TOKEN_NOS from the Keychain item"
else
  _fail "interactive load: out=${out}"
fi
out="$(_load n)"
if [[ "${out}" == "<unset>" && ! -s "${SEC_LOG}" ]]; then _pass "non-interactive shell never reads the Keychain"; else _fail "non-interactive: out=${out}"; fi
out="$(_load i GH_TOKEN_NOS=preset)"
if [[ "${out}" == "preset" && ! -s "${SEC_LOG}" ]]; then _pass "an already-set GH_TOKEN_NOS is kept"; else _fail "preset: out=${out}"; fi
out="$(_load i SEC_MODE=missing)"
if [[ "${out}" == "<unset>" ]]; then _pass "missing Keychain item loads nothing"; else _fail "missing: out=${out}"; fi
out="$(_load i SEC_MODE=junk)"
if [[ "${out}" == "<unset>" ]]; then _pass "a value that is not token-shaped is refused"; else _fail "junk: out=${out}"; fi
out="$(_load i)"
if [[ "${out}" != *leaked-fn* ]]; then _pass "the loader function does not stay in the shell"; else _fail "function leaked"; fi
if ! grep -q -E 'GH_TOKEN(_SWM|_TWM)?=|GITHUB_TOKEN=' "${LOADER}"; then
  _pass "the loader sets no smartwatermelon, twistedmelonman or launch token"
else
  _fail "loader sets a token other than GH_TOKEN_NOS"
fi

exit "${fail}"
