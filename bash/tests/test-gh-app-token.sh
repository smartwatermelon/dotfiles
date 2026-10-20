#!/usr/bin/env bash
# Tests bash/gh-app-token.sh: routes, minting, cache, failures, git-credential (claude-config#659).

# Stub op serves a generated key flattened to one line; stub curl verifies the JWT it reads on stdin.
set -uo pipefail
unset CDPATH

TESTS_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${TESTS_DIR}/../gh-app-token.sh"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gh-app-token-test.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

fail=0
_pass() { echo "  PASS: $1"; }
_fail() {
  echo "  FAIL: $1" >&2
  fail=1
}

export HOME="${WORKDIR}/home"
export XDG_CACHE_HOME="${WORKDIR}/cache"
export TMPDIR="${WORKDIR}/tmp"
mkdir -p "${HOME}" "${TMPDIR}"
ITEM='op://Automation/test app'
export GH_APP_ROUTES_FILE="${WORKDIR}/routes.conf"
printf '# comment\nSmartWaterMelon/Claude-Wrapper\t%s\nsmartwatermelon/bad-item\tnot-an-item\nsmartwatermelon/no-tab %s\n' \
  "${ITEM}" "${ITEM}" >"${GH_APP_ROUTES_FILE}"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${WORKDIR}/key.pem" 2>/dev/null
openssl pkey -in "${WORKDIR}/key.pem" -pubout -out "${WORKDIR}/pub.pem" 2>/dev/null
# One line, spaces for newlines: what `op read` returns for a pasted PEM field.
tr '\n' ' ' <"${WORKDIR}/key.pem" | sed 's/ $//' >"${WORKDIR}/key.flat"

STUB_DIR="${WORKDIR}/stub-bin"
mkdir -p "${STUB_DIR}"
CURL_LOG="${WORKDIR}/curl.log"
# Shaped like a 2026 installation token (dots and dashes); built in two parts so scanners skip it.
STUB_TOK="ghs_stub"".tok-123"
cat >"${STUB_DIR}/op" <<STUB_EOF
#!/usr/bin/env bash
[[ -n "\${OP_FAIL:-}" ]] && exit 1
case "\$2" in
  *"/app_id") echo 5401431 ;;
  *"/installation_id") echo 173522549 ;;
  *"/private_key") cat "${WORKDIR}/key.flat" ;;
  *) exit 1 ;;
esac
STUB_EOF
cat >"${STUB_DIR}/curl" <<STUB_EOF
#!/usr/bin/env bash
printf 'argv=%s\n' "\$*" >>"${CURL_LOG}"
[[ "\${CURL_FAIL:-}" == net ]] && exit 6
[[ "\${CURL_FAIL:-}" == 401 ]] && { printf '{"message":"A JSON web token could not be decoded"}\n401'; exit 0; }
cfg="\$(cat)"
jwt="\$(sed -nE 's/^header = "Authorization: Bearer ([^"]+)"$/\1/p' <<<"\${cfg}")"
IFS=. read -r h p s <<<"\${jwt}"
unb64() { local v="\$1"; v="\${v//-/+}"; v="\${v//_//}"; while (( \${#v} % 4 )); do v+="="; done; openssl base64 -d -A <<<"\${v}"; }
printf '%s.%s' "\${h}" "\${p}" >"${WORKDIR}/signed"
unb64 "\${s}" >"${WORKDIR}/sig"
if openssl dgst -sha256 -verify "${WORKDIR}/pub.pem" -signature "${WORKDIR}/sig" "${WORKDIR}/signed" >/dev/null 2>&1 \
  && [[ "\$(unb64 "\${p}" | jq -r .iss)" == 5401431 ]] && [[ "\$*" == *"/app/installations/173522549/access_tokens"* ]]; then
  echo 'jwt=ok' >>"${CURL_LOG}"
  printf '{"token":"${STUB_TOK}","expires_at":"2099-01-01T00:00:00Z"}\n201'
else
  echo 'jwt=bad' >>"${CURL_LOG}"
  printf '{"message":"bad jwt"}\n401'
fi
STUB_EOF
chmod +x "${STUB_DIR}/op" "${STUB_DIR}/curl"
export PATH="${STUB_DIR}:${PATH}"

_run() {
  : >"${CURL_LOG}"
  out="$(bash "${SCRIPT}" "$@" 2>"${WORKDIR}/err")"
  rc=$?
  err="$(cat "${WORKDIR}/err")"
  mints="$(grep -c '^argv=' "${CURL_LOG}")" || mints=0
}
CACHE_KEY="$(printf '%s' "${ITEM}" | openssl dgst -sha256 -r)"
CACHE_FILE="${XDG_CACHE_HOME}/gh-app-tokens/${CACHE_KEY%% *}"
_clear_cache() { rm -f "${CACHE_FILE}"; }

echo "--- route"
for spec in git@github.com:smartwatermelon/claude-wrapper.git ssh://git@github.com/smartwatermelon/claude-wrapper \
  git@github.com-claude:smartwatermelon/claude-wrapper.git https://github.com/smartwatermelon/claude-wrapper/pull/5 \
  https://x-access-token@github.com/SmartWatermelon/claude-wrapper.git smartwatermelon/claude-wrapper; do
  _run route "${spec}"
  if [[ "${rc}" -eq 0 && "${out}" == "${ITEM}" ]]; then _pass "route ${spec}"; else _fail "route ${spec}: rc=${rc} out=${out}"; fi
done
for spec in smartwatermelon/dotfiles git@gitlab.com:smartwatermelon/claude-wrapper.git smartwatermelon \
  smartwatermelon/claude-wrapper-extra; do
  _run route "${spec}"
  if [[ "${rc}" -eq 1 && -z "${out}" ]]; then _pass "not routed: ${spec}"; else _fail "not routed ${spec}: rc=${rc} out=${out}"; fi
done
for spec in smartwatermelon/bad-item smartwatermelon/no-tab; do
  _run route "${spec}"
  if [[ "${rc}" -eq 2 && -z "${out}" ]]; then _pass "malformed route fails closed: ${spec}"; else _fail "malformed ${spec}: rc=${rc}"; fi
done
GH_APP_ROUTES_FILE="${WORKDIR}/missing.conf" _run route smartwatermelon/claude-wrapper
if [[ "${rc}" -eq 1 ]]; then _pass "missing route file routes nothing"; else _fail "missing route file: rc=${rc}"; fi

echo "--- mint and cache"
_clear_cache
_run --item "${ITEM}" smartwatermelon
if [[ "${rc}" -eq 0 && "${out}" == "${STUB_TOK}" && "${mints}" == 1 ]] && grep -q '^jwt=ok' "${CURL_LOG}"; then
  _pass "mints with a signed JWT from a flattened PEM"
else
  _fail "mint: rc=${rc} mints=${mints} err=${err}"
fi
if ! grep -q 'Bearer' "${CURL_LOG}"; then _pass "JWT stays out of curl argv"; else _fail "JWT found in curl argv"; fi
mode="$(stat -f '%Lp' "${CACHE_FILE}" 2>/dev/null || stat -c '%a' "${CACHE_FILE}")"
dmode="$(stat -f '%Lp' "${CACHE_FILE%/*}" 2>/dev/null || stat -c '%a' "${CACHE_FILE%/*}")"
if [[ "${mode}" == 600 && "${dmode}" == 700 ]]; then _pass "cache is 0600 in a 0700 dir"; else _fail "cache modes ${mode}/${dmode}"; fi
left="$(ls "${TMPDIR}")" || left="?"
if [[ -z "${left}" ]]; then _pass "no key file left in TMPDIR"; else _fail "TMPDIR not empty: ${left}"; fi

_run smartwatermelon
if [[ "${rc}" -eq 0 && "${out}" == "${STUB_TOK}" && "${mints}" == 0 ]]; then
  _pass "owner form uses the route item and the cache (no mint)"
else
  _fail "cache hit: rc=${rc} mints=${mints}"
fi

# Inside the 5-minute margin: mint again.
now="$(date +%s)"
printf '%s\nghs_oldtoken\n' "$((now + 200))" >"${CACHE_FILE}"
_run smartwatermelon
if [[ "${rc}" -eq 0 && "${out}" == "${STUB_TOK}" && "${mints}" == 1 ]]; then
  _pass "token within 5 min of expiry is re-minted"
else
  _fail "re-mint: rc=${rc} out=${out} mints=${mints}"
fi

_run nightowlstudiollc
if [[ "${rc}" -ne 0 && -z "${out}" ]]; then _pass "owner without a route fails"; else _fail "unrouted owner: rc=${rc}"; fi

echo "--- failures print no token"
_clear_cache
OP_FAIL=1 _run --item "${ITEM}" smartwatermelon
if [[ "${rc}" -ne 0 && -z "${out}" && "${err}" == *"cannot read app_id"* ]]; then _pass "op failure fails"; else _fail "op failure: rc=${rc} out=${out}"; fi
CURL_FAIL=net _run --item "${ITEM}" smartwatermelon
if [[ "${rc}" -ne 0 && -z "${out}" && ! -f "${CACHE_FILE}" && "${err}" == *"could not reach"* ]]; then
  _pass "network failure fails"
else
  _fail "network failure: rc=${rc} out=${out} err=${err}"
fi
CURL_FAIL=401 _run --item "${ITEM}" smartwatermelon
if [[ "${rc}" -ne 0 && -z "${out}" && ! -f "${CACHE_FILE}" && "${err}" == *"HTTP 401"*"could not be decoded"* ]]; then
  _pass "HTTP 401 fails and names the status"
else
  _fail "HTTP 401: rc=${rc} out=${out} err=${err}"
fi
# Two items that differ only by "/" vs " " must not share a cache file.
_clear_cache
_run ensure "${ITEM}"
_run ensure 'op://Automation/test/app'
cached="$(find "${CACHE_FILE%/*}" -type f ! -name '.tmp.*' | wc -l | tr -d ' ')"
if [[ "${cached}" == 2 ]]; then _pass "near-identical items get distinct cache files"; else _fail "cache files: ${cached}"; fi
find "${CACHE_FILE%/*}" -type f -delete

echo "--- git-credential"
_clear_cache
: >"${CURL_LOG}"
out="$(printf 'protocol=https\nhost=github.com\npath=smartwatermelon/claude-wrapper.git\n\n' \
  | bash "${SCRIPT}" git-credential "${ITEM}" get 2>/dev/null)"
if [[ "${out}" == "username=x-access-token"$'\n'"password=${STUB_TOK}" ]]; then
  _pass "credential get answers the routed path"
else
  _fail "credential get: ${out}"
fi
out="$(printf 'protocol=https\nhost=github.com\npath=smartwatermelon/dotfiles.git\n\n' \
  | bash "${SCRIPT}" git-credential "${ITEM}" get 2>/dev/null)"
if [[ -z "${out}" ]]; then _pass "credential get ignores an unrouted path"; else _fail "credential unrouted path answered"; fi
out="$(printf 'protocol=https\nhost=github.com\n\n' | bash "${SCRIPT}" git-credential "${ITEM}" get 2>/dev/null)"
if [[ -z "${out}" ]]; then _pass "credential get without path= answers nothing"; else _fail "credential no-path answered"; fi
out="$(printf 'protocol=https\nhost=example.com\n\n' | bash "${SCRIPT}" git-credential "${ITEM}" get 2>/dev/null)"
if [[ -z "${out}" ]]; then _pass "credential get ignores another host"; else _fail "credential other host answered"; fi
out="$(printf 'protocol=https\nhost=github.com\npassword=x\n\n' | bash "${SCRIPT}" git-credential "${ITEM}" store 2>/dev/null)"
rc=$?
if [[ "${rc}" -eq 0 && -z "${out}" ]]; then _pass "credential store is a no-op"; else _fail "credential store: rc=${rc}"; fi
out="$(printf 'protocol=https\nhost=github.com\npath=smartwatermelon/claude-wrapper\n\n' | OP_FAIL=1 XDG_CACHE_HOME="${WORKDIR}/cache2" \
  bash "${SCRIPT}" git-credential "${ITEM}" get 2>/dev/null)"
rc=$?
if [[ "${rc}" -ne 0 && -z "${out}" ]]; then _pass "credential get fails closed when minting fails"; else _fail "credential fail: rc=${rc}"; fi

echo "--- repo and ensure"
_run repo git@github.com-claude:SmartWatermelon/Claude-Wrapper.git
if [[ "${rc}" -eq 0 && "${out}" == smartwatermelon/claude-wrapper ]]; then _pass "repo normalizes a remote"; else _fail "repo: ${out}"; fi
_run repo git@gitlab.com:a/b.git
if [[ "${rc}" -eq 1 && -z "${out}" ]]; then _pass "repo rejects another host"; else _fail "repo other host: ${out}"; fi
_clear_cache
_run ensure "${ITEM}"
if [[ "${rc}" -eq 0 && -z "${out}" && -f "${CACHE_FILE}" && "${mints}" == 1 ]]; then
  _pass "ensure mints silently"
else
  _fail "ensure: rc=${rc} mints=${mints}"
fi
_clear_cache
OP_FAIL=1 _run ensure "${ITEM}"
if [[ "${rc}" -ne 0 && -z "${out}" ]]; then _pass "ensure fails when minting fails"; else _fail "ensure fail: rc=${rc}"; fi

echo "--- check never prints the token"
_run check https://github.com/smartwatermelon/claude-wrapper
if [[ "${rc}" -eq 0 && "${out}" == *"routed to ${ITEM}"* && "${out}${err}" != *ghs_* ]]; then
  _pass "check reports the route without the token"
else
  _fail "check: rc=${rc} out=${out}"
fi

exit "${fail}"
