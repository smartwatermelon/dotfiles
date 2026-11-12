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
OP_LOG="${WORKDIR}/op.log"
cat >"${STUB_DIR}/op" <<STUB_EOF
#!/usr/bin/env bash
printf 'argv=%s\n' "\$*" >>"${OP_LOG}"
[[ -n "\${OP_FAIL:-}" ]] && exit 1
[[ -n "\${OP_NO_IDS:-}" && "\$2" == *_id ]] && { echo "op stub: \$2 must come from the route line" >&2; exit 1; }
case "\$2" in
  *"/app_id") echo 5401431 ;;
  *"/installation_id") echo 173522549 ;;
  *"/private_key") [[ -n "\${OP_PEM_ATTACHMENT:-}" ]] && exit 1; cat "${WORKDIR}/key.flat" ;;
  *"/private_key.pem") [[ -n "\${OP_PEM_ATTACHMENT:-}" ]] || exit 1; cat "${WORKDIR}/key.pem" ;;
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
# Stub security: never the real Keychain. SEC_MODE unset = no item (44), plain, hex (as -w prints).
SEC_LOG="${WORKDIR}/security.log"
cat >"${STUB_DIR}/security" <<STUB_EOF
#!/usr/bin/env bash
printf 'argv=%s\n' "\$*" >>"${SEC_LOG}"
case "\${SEC_MODE:-}" in
  plain) cat "${WORKDIR}/key.flat" ;;
  hex) xxd -p "${WORKDIR}/key.pem" | tr -d '\n'; echo ;;
  *) echo 'security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.' >&2; exit 44 ;;
esac
STUB_EOF
chmod +x "${STUB_DIR}/op" "${STUB_DIR}/curl" "${STUB_DIR}/security"
# ssh stub (ssh -G only): a github-* alias has HostName github.com; any other host is itself. Never the real ~/.ssh/config.
cat >"${STUB_DIR}/ssh" <<'STUB_EOF'
#!/usr/bin/env bash
[[ "$1" == -G ]] || exit 255
h="$2"
[[ "${h}" == -- ]] && h="$3"
case "${h}" in github-*) echo "hostname github.com" ;; *) echo "hostname ${h}" ;; esac
STUB_EOF
chmod +x "${STUB_DIR}/ssh"
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
  git@github-alias:smartwatermelon/claude-wrapper.git ssh://git@github-alias/smartwatermelon/claude-wrapper \
  https://x-access-token@github.com/SmartWatermelon/claude-wrapper.git smartwatermelon/claude-wrapper; do
  _run route "${spec}"
  if [[ "${rc}" -eq 0 && "${out}" == "${ITEM}" ]]; then _pass "route ${spec}"; else _fail "route ${spec}: rc=${rc} out=${out}"; fi
done
for spec in smartwatermelon/dotfiles git@gitlab.com:smartwatermelon/claude-wrapper.git smartwatermelon \
  git@gitlab-alias:smartwatermelon/claude-wrapper.git https://github-alias/smartwatermelon/claude-wrapper \
  git@-oProxyCommand=x:smartwatermelon/claude-wrapper.git \
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

echo "--- owner-wide route (owner/*)"
WIDE_ROUTES="${WORKDIR}/routes-wide.conf"
OTHER_ITEM='op://Automation/other app'
# The owner/* line comes first, so the exact line below must win by kind, not by order.
printf 'SmartWatermelon/*\t%s\nsmartwatermelon/special\t%s\ntwistedmelonman/*\tnot-an-item\nnightowlstudiollc/* %s\nsmartwatermelon/dot*\t%s\n' \
  "${ITEM}" "${OTHER_ITEM}" "${ITEM}" "${OTHER_ITEM}" >"${WIDE_ROUTES}"
for spec in smartwatermelon/dotfiles git@github.com:SmartWatermelon/claude-config.git \
  https://github.com/smartwatermelon/github-workflows/pull/9 smartwatermelon/dotty; do
  GH_APP_ROUTES_FILE="${WIDE_ROUTES}" _run route "${spec}"
  if [[ "${rc}" -eq 0 && "${out}" == "${ITEM}" ]]; then _pass "owner-wide route ${spec}"; else _fail "owner-wide ${spec}: rc=${rc} out=${out}"; fi
done
GH_APP_ROUTES_FILE="${WIDE_ROUTES}" _run route smartwatermelon/special
if [[ "${rc}" -eq 0 && "${out}" == "${OTHER_ITEM}" ]]; then _pass "a repo line beats an earlier owner/* line"; else _fail "exact vs wide: rc=${rc} out=${out}"; fi
for spec in smartwatermelonx/dotfiles smartwatermelo/dotfiles someone/dotfiles smartwatermelon \
  git@gitlab.com:smartwatermelon/dotfiles.git; do
  GH_APP_ROUTES_FILE="${WIDE_ROUTES}" _run route "${spec}"
  if [[ "${rc}" -eq 1 && -z "${out}" ]]; then _pass "owner-wide does not route ${spec}"; else _fail "owner-wide leak ${spec}: rc=${rc} out=${out}"; fi
done
for spec in twistedmelonman/anything nightowlstudiollc/anything; do
  GH_APP_ROUTES_FILE="${WIDE_ROUTES}" _run route "${spec}"
  if [[ "${rc}" -eq 2 && -z "${out}" ]]; then _pass "malformed owner/* line fails closed: ${spec}"; else _fail "malformed wide ${spec}: rc=${rc}"; fi
done
GH_APP_ROUTES_FILE="${WIDE_ROUTES}" _run owner-route SmartWatermelon
if [[ "${rc}" -eq 0 && "${out}" == "${ITEM}" ]]; then _pass "owner-route answers from owner/*"; else _fail "owner-route: rc=${rc} out=${out}"; fi
for spec in smartwatermelon "smartwatermelon/*" "bad owner"; do
  _run owner-route "${spec}"
  if [[ "${rc}" -eq 1 && -z "${out}" ]]; then _pass "owner-route ignores repo lines and bad input: ${spec}"; else _fail "owner-route ${spec}: rc=${rc} out=${out}"; fi
done
GH_APP_ROUTES_FILE="${WIDE_ROUTES}" _run owner-route twistedmelonman
if [[ "${rc}" -eq 2 ]]; then _pass "owner-route fails closed on a malformed owner/* line"; else _fail "owner-route malformed: rc=${rc}"; fi
GH_APP_ROUTES_FILE="${WIDE_ROUTES}" _run check smartwatermelon/dotfiles
if [[ "${rc}" -eq 0 && "${out}" == *"routed to ${ITEM}"* ]]; then _pass "check follows an owner/* route"; else _fail "check wide: rc=${rc} out=${out}"; fi
GH_APP_ROUTES_FILE="${WIDE_ROUTES}" _run smartwatermelon
if [[ "${rc}" -eq 0 && "${out}" == "${STUB_TOK}" ]]; then _pass "owner form mints from an owner/* line"; else _fail "owner form wide: rc=${rc} err=${err}"; fi
out="$(printf 'protocol=https\nhost=github.com\npath=smartwatermelon/dotfiles.git\n\n' \
  | GH_APP_ROUTES_FILE="${WIDE_ROUTES}" bash "${SCRIPT}" git-credential "${ITEM}" get 2>/dev/null)"
if [[ "${out}" == *"password=${STUB_TOK}"* ]]; then _pass "credential get answers a path under owner/*"; else _fail "credential wide: out=${out}"; fi
out="$(printf 'protocol=https\nhost=github.com\npath=smartwatermelon/special.git\n\n' \
  | GH_APP_ROUTES_FILE="${WIDE_ROUTES}" bash "${SCRIPT}" git-credential "${ITEM}" get 2>/dev/null)"
if [[ -z "${out}" ]]; then _pass "credential get refuses a repo whose exact line names another item"; else _fail "credential exact override answered"; fi

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

echo "--- route fields, the Keychain, then op"
ME="$(id -un)"
FIELDS_ROUTES="${WORKDIR}/routes-fields.conf"
printf '%s\t%s\t%s\t%s\n' smartwatermelon/claude-wrapper "${ITEM}" app_id=5401431 installation_id=173522549 \
  >"${FIELDS_ROUTES}"
printf 'smartwatermelon/bad-name\top://Automation/x\tapp-id=5\nsmartwatermelon/bad-value\top://Automation/y\tapp_id=abc\n' \
  >>"${FIELDS_ROUTES}"
printf 'smartwatermelon/unknown\top://Automation/z\tcolor=5\nsmartwatermelon/bare\top://Automation/z\tapp_id\n' \
  >>"${FIELDS_ROUTES}"

_clear_cache
: >"${SEC_LOG}"
GH_APP_ROUTES_FILE="${FIELDS_ROUTES}" OP_FAIL=1 _run --item "${ITEM}" smartwatermelon
if [[ "${rc}" -eq 1 && -z "${out}" && "${err}" == *"${ITEM}"* && "${err}" == *"Keychain"* &&
  "${err}" == *"service 'test app'"* && "${err}" == *"account '${ME}'"* ]]; then
  _pass "Keychain and op both failing exits 1 and names both sources"
else
  _fail "both sources fail: rc=${rc} out=${out} err=${err}"
fi

# Keychain first: with a Keychain item, op must not be called at all (the IDs come from the route line).
for mode in plain hex; do
  _clear_cache
  : >"${SEC_LOG}"
  : >"${OP_LOG}"
  GH_APP_ROUTES_FILE="${FIELDS_ROUTES}" SEC_MODE="${mode}" _run --item "${ITEM}" smartwatermelon
  if [[ "${rc}" -eq 0 && "${out}" == "${STUB_TOK}" && "${mints}" == 1 && ! -s "${OP_LOG}" ]] \
    && grep -q '^jwt=ok' "${CURL_LOG}" && grep -qxF "argv=find-generic-password -s test app -a ${ME} -w" "${SEC_LOG}"; then
    _pass "Keychain ${mode} PEM mints a token and op is never called"
  else
    _fail "Keychain ${mode}: rc=${rc} mints=${mints} err=${err} sec=$(<"${SEC_LOG}") op=$(<"${OP_LOG}")"
  fi
done
left="$(ls "${TMPDIR}")" || left="?"
if [[ -z "${left}" ]]; then _pass "no key file left in TMPDIR after Keychain mints"; else _fail "TMPDIR not empty: ${left}"; fi

# A Keychain item with no IDs on the route line still needs op for them; op down means app_id fails first.
_clear_cache
OP_FAIL=1 SEC_MODE=plain _run --item "${ITEM}" smartwatermelon
if [[ "${rc}" -eq 1 && -z "${out}" && "${err}" == *"cannot read app_id"* ]]; then
  _pass "without route IDs, op failure still fails on app_id"
else
  _fail "no route IDs: rc=${rc} err=${err}"
fi

# No Keychain item (SEC_MODE unset: exit 44): asked once, then op supplies the key. op refuses ID reads here.
_clear_cache
: >"${SEC_LOG}"
: >"${OP_LOG}"
GH_APP_ROUTES_FILE="${FIELDS_ROUTES}" OP_NO_IDS=1 _run --item "${ITEM}" smartwatermelon
asks="$(grep -c '^argv=find-generic-password' "${SEC_LOG}")" || asks=0
if [[ "${rc}" -eq 0 && "${out}" == "${STUB_TOK}" && "${mints}" == 1 && "${asks}" == 1 ]] \
  && grep -qxF "argv=read ${ITEM}/private_key" "${OP_LOG}"; then
  _pass "Keychain has no item: op supplies the key, IDs come from the route fields"
else
  _fail "Keychain missing: rc=${rc} err=${err} sec=$(<"${SEC_LOG}") op=$(<"${OP_LOG}")"
fi

# Key saved as attachment private_key.pem: <item>/private_key fails, so <item>/private_key.pem is next.
_clear_cache
: >"${OP_LOG}"
GH_APP_ROUTES_FILE="${FIELDS_ROUTES}" OP_NO_IDS=1 OP_PEM_ATTACHMENT=1 _run --item "${ITEM}" smartwatermelon
if [[ "${rc}" -eq 0 && "${out}" == "${STUB_TOK}" && "${mints}" == 1 ]] && grep -q '^jwt=ok' "${CURL_LOG}" \
  && grep -qxF "argv=read ${ITEM}/private_key" "${OP_LOG}" && grep -qxF "argv=read ${ITEM}/private_key.pem" "${OP_LOG}"; then
  _pass "a private_key.pem attachment supplies the key when private_key does not resolve"
else
  _fail "pem attachment: rc=${rc} err=${err} op=$(<"${OP_LOG}")"
fi

echo "--- key file (between the Keychain and op)"
KEY_DIR="${HOME}/.config/gh-app-keys"
KEY_FILE="${KEY_DIR}/test app.pem"
mkdir -p "${KEY_DIR}"
_key_file() { (umask 077 && cp "${WORKDIR}/key.pem" "${KEY_FILE}") && chmod "$1" "${KEY_FILE}"; }

# No Keychain item, a mode-600 key file: the file supplies the key and op is never called.
for m in 600 400; do
  _clear_cache
  : >"${OP_LOG}"
  rm -f "${KEY_FILE}"
  _key_file "${m}"
  GH_APP_ROUTES_FILE="${FIELDS_ROUTES}" _run --item "${ITEM}" smartwatermelon
  if [[ "${rc}" -eq 0 && "${out}" == "${STUB_TOK}" && "${mints}" == 1 && ! -s "${OP_LOG}" ]] \
    && grep -q '^jwt=ok' "${CURL_LOG}"; then
    _pass "a mode-${m} key file mints a token and op is never called"
  else
    _fail "key file ${m}: rc=${rc} err=${err} op=$(<"${OP_LOG}")"
  fi
done

# The Keychain still wins over the file: the file is not read when the Keychain answers.
_clear_cache
: >"${OP_LOG}"
printf 'not a key\n' >"${KEY_FILE}"
GH_APP_ROUTES_FILE="${FIELDS_ROUTES}" SEC_MODE=plain _run --item "${ITEM}" smartwatermelon
if [[ "${rc}" -eq 0 && "${out}" == "${STUB_TOK}" && "${mints}" == 1 && ! -s "${OP_LOG}" ]]; then
  _pass "a Keychain item is used before the key file"
else
  _fail "Keychain before file: rc=${rc} err=${err}"
fi

# An unsafe or bad key file stops the mint: no op fallback (it could prompt), no network call.
_unsafe_case() {
  local label="$1" want="$2"
  _clear_cache
  : >"${OP_LOG}"
  GH_APP_ROUTES_FILE="${FIELDS_ROUTES}" _run --item "${ITEM}" smartwatermelon
  if [[ "${rc}" -eq 1 && -z "${out}" && "${mints}" == 0 && ! -s "${OP_LOG}" && "${err}" == *"${want}"* ]]; then
    _pass "key file ${label} stops the mint without op"
  else
    _fail "key file ${label}: rc=${rc} mints=${mints} err=${err} op=$(<"${OP_LOG}")"
  fi
}
rm -f "${KEY_FILE}"
_key_file 644
_unsafe_case "mode 644" "mode 644"
chmod 600 "${KEY_FILE}"
printf 'not a key\n' >"${KEY_FILE}"
_unsafe_case "with no PEM" "does not hold a PEM"
rm -f "${KEY_FILE}"
ln -s "${WORKDIR}/key.pem" "${KEY_FILE}"
_unsafe_case "as a symlink" "not a regular file"
rm -f "${KEY_FILE}"
mkdir "${KEY_FILE}"
_unsafe_case "as a directory" "not a regular file"
rmdir "${KEY_FILE}"

# An unreadable key file (a sandbox read-deny) counts as no file; a cat stub plays the sandbox.
_key_file 600
mkdir -p "${WORKDIR}/deny-bin"
# Denies only the key file; every other cat (the op and curl stubs use it) is the real one.
cat >"${WORKDIR}/deny-bin/cat" <<STUB_EOF
#!/usr/bin/env bash
for a in "\$@"; do
  [[ "\${a}" == "${KEY_FILE}" ]] && { echo "cat: \${a}: Operation not permitted" >&2; exit 1; }
done
exec /bin/cat "\$@"
STUB_EOF
chmod +x "${WORKDIR}/deny-bin/cat"
_clear_cache
: >"${OP_LOG}"
GH_APP_ROUTES_FILE="${FIELDS_ROUTES}" OP_NO_IDS=1 PATH="${WORKDIR}/deny-bin:${PATH}" _run --item "${ITEM}" smartwatermelon
if [[ "${rc}" -eq 0 && "${out}" == "${STUB_TOK}" && "${err}" == *"not readable here"* && "${err}" != *"Operation not permitted"* ]] \
  && grep -qxF "argv=read ${ITEM}/private_key" "${OP_LOG}"; then
  _pass "an unreadable key file falls back to op with one notice and no raw read error"
else
  _fail "unreadable key file: rc=${rc} err=${err} op=$(<"${OP_LOG}")"
fi
rm -f "${KEY_FILE}"

# GH_APP_KEY_DIR moves the file; the error for no source names the file path.
_clear_cache
ALT_DIR="${WORKDIR}/alt-keys"
mkdir -p "${ALT_DIR}"
(umask 077 && cp "${WORKDIR}/key.pem" "${ALT_DIR}/test app.pem")
GH_APP_ROUTES_FILE="${FIELDS_ROUTES}" GH_APP_KEY_DIR="${ALT_DIR}" OP_FAIL=1 _run --item "${ITEM}" smartwatermelon
if [[ "${rc}" -eq 0 && "${out}" == "${STUB_TOK}" ]]; then _pass "GH_APP_KEY_DIR names the key folder"; else _fail "GH_APP_KEY_DIR: rc=${rc} err=${err}"; fi
_clear_cache
GH_APP_ROUTES_FILE="${FIELDS_ROUTES}" OP_FAIL=1 _run --item "${ITEM}" smartwatermelon
if [[ "${rc}" -eq 1 && "${err}" == *"${KEY_FILE}"* ]]; then
  _pass "with no source, the error names the key file path"
else
  _fail "no source names file: rc=${rc} err=${err}"
fi
left="$(ls "${TMPDIR}")" || left="?"
if [[ -z "${left}" ]]; then _pass "no key file left in TMPDIR after key-file mints"; else _fail "TMPDIR not empty: ${left}"; fi

GH_APP_ROUTES_FILE="${FIELDS_ROUTES}" _run route smartwatermelon/claude-wrapper
if [[ "${rc}" -eq 0 && "${out}" == "${ITEM}" ]]; then _pass "route with fields prints only the item"; else _fail "route fields: rc=${rc} out=${out}"; fi
_run route smartwatermelon/claude-wrapper
if [[ "${rc}" -eq 0 && "${out}" == "${ITEM}" ]]; then _pass "one-field route line still works"; else _fail "one-field route: rc=${rc} out=${out}"; fi
for spec in smartwatermelon/bad-name smartwatermelon/bad-value smartwatermelon/unknown smartwatermelon/bare; do
  GH_APP_ROUTES_FILE="${FIELDS_ROUTES}" _run route "${spec}"
  if [[ "${rc}" -eq 2 && -z "${out}" ]]; then _pass "malformed field fails closed: ${spec}"; else _fail "field ${spec}: rc=${rc} out=${out}"; fi
done
GH_APP_ROUTES_FILE="${FIELDS_ROUTES}" _run check smartwatermelon/unknown
if [[ "${rc}" -eq 2 ]]; then _pass "check fails closed on a malformed field"; else _fail "check malformed field: rc=${rc}"; fi
_clear_cache
GH_APP_ROUTES_FILE="${FIELDS_ROUTES}" _run ensure 'op://Automation/z'
if [[ "${rc}" -eq 2 && "${mints}" == 0 ]]; then _pass "minting refuses an item whose route field is malformed"; else _fail "ensure malformed: rc=${rc}"; fi
out="$(printf 'protocol=https\nhost=github.com\npath=smartwatermelon/claude-wrapper.git\n\n' \
  | GH_APP_ROUTES_FILE="${FIELDS_ROUTES}" OP_NO_IDS=1 bash "${SCRIPT}" git-credential "${ITEM}" get 2>/dev/null)"
if [[ "${out}" == "username=x-access-token"$'\n'"password=${STUB_TOK}" ]]; then
  _pass "credential get matches a route line with fields"
else
  _fail "credential with fields: ${out}"
fi

exit "${fail}"
