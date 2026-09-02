#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification of finicky/generate-config.sh.
# Run directly: bash bash/tests/test-finicky-generate-config.sh
#
# The generator decides which Chrome PWAs get Finicky handlers. A handler
# for an app that is not installed drops the URL (Finicky has no fallback),
# and a config that fails to build sends every URL to Safari, so both the
# scan and the render are pinned here against fixtures — never against the
# real ~/Applications or Chrome profile directories.
set -euo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GEN="${REPO_ROOT}/finicky/generate-config.sh"

fail=0
check() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "  PASS: ${label}"
  else
    echo "  FAIL: ${label} — expected [${expected}], got [${actual}]"
    fail=1
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# ── Fixture: two PWA shims, one profile layout ──────────────────────────
# GitHub is in Default and Profile 4; Foo is only in Profile 4.
GH_ID="mjoklplbddabcmpepnokjaffbmgbkkgg"
FOO_ID="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
APPS="${TMP}/Chrome Apps.localized"
PROFILES="${TMP}/Chrome"

make_shim() {
  local name="$1" id="$2" url="$3"
  mkdir -p "${APPS}/${name}.app/Contents"
  cat >"${APPS}/${name}.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.google.Chrome.app.${id}</string>
  <key>CrAppModeShortcutID</key><string>${id}</string>
  <key>CrAppModeShortcutName</key><string>${name}</string>
  <key>CrAppModeShortcutURL</key><string>${url}</string>
</dict></plist>
EOF
}
make_shim "GitHub" "${GH_ID}" "https://github.com/"
make_shim "Foo" "${FOO_ID}" "https://foo.example/"
mkdir -p "${PROFILES}/Default/Web Applications/Manifest Resources/${GH_ID}"
mkdir -p "${PROFILES}/Profile 4/Web Applications/Manifest Resources/${GH_ID}"
mkdir -p "${PROFILES}/Profile 4/Web Applications/Manifest Resources/${FOO_ID}"

#shellcheck source=/dev/null
source "${GEN}"

echo "scan:"
scan="$(finicky_scan_pwas "${APPS}" "${PROFILES}")"
expected_scan="$(printf '%s\tFoo\tProfile 4\n%s\tGitHub\tDefault' "${FOO_ID}" "${GH_ID}")"
check "scan lists both apps sorted by id with preferred profile" "${expected_scan}" "${scan}"

echo "scan with no apps dir:"
check "missing apps dir yields empty scan" "" "$(finicky_scan_pwas "${TMP}/nope" "${PROFILES}")"

echo "scan with app in no profile:"
make_shim "Orphan" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "https://orphan.example/"
orphan_line="$(finicky_scan_pwas "${APPS}" "${PROFILES}" 2>/dev/null | grep '^bbbb')"
check "app in no profile falls back to Default" "$(printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\tOrphan\tDefault')" "${orphan_line}"
rm -rf "${APPS}/Orphan.app"

echo "render:"
TEMPLATE="${TMP}/finicky.template.js"
cat >"${TEMPLATE}" <<'EOF'
// header
const INSTALLED_PWAS = {}; // @@INSTALLED_PWAS@@
export default { defaultBrowser: "Google Chrome", handlers: [] };
EOF
rendered="$(finicky_render "${TEMPLATE}" "${scan}")"
expected_literal='const INSTALLED_PWAS = {"'"${FOO_ID}"'": {"name": "Foo", "profile": "Profile 4"}, "'"${GH_ID}"'": {"name": "GitHub", "profile": "Default"}};'
check "render replaces marker with sorted literal" "1" "$(grep -cF "${expected_literal}" <<<"${rendered}")"
check "render drops the marker comment" "0" "$(grep -c '@@INSTALLED_PWAS@@' <<<"${rendered}")"
check "render keeps the rest of the template" "1" "$(grep -c '^export default' <<<"${rendered}")"
check "render prepends a GENERATED header on line 1" "1" "$(head -1 <<<"${rendered}" | grep -c 'GENERATED')"

echo "render with empty scan:"
rendered_empty="$(finicky_render "${TEMPLATE}" "")"
check "empty scan renders an empty object" "1" "$(grep -cF 'const INSTALLED_PWAS = {};' <<<"${rendered_empty}")"

echo "render without marker:"
printf '// no marker\nexport default {};\n' >"${TMP}/bad.js"
if finicky_render "${TMP}/bad.js" "${scan}" >/dev/null 2>&1; then
  check "missing marker fails" "nonzero" "0"
else
  check "missing marker fails" "nonzero" "nonzero"
fi

echo "render with duplicate marker:"
{
  cat "${TEMPLATE}"
  echo 'const INSTALLED_PWAS = {}; // @@INSTALLED_PWAS@@'
} >"${TMP}/dup.js"
if finicky_render "${TMP}/dup.js" "${scan}" >/dev/null 2>&1; then
  check "duplicate marker fails" "nonzero" "0"
else
  check "duplicate marker fails" "nonzero" "nonzero"
fi

echo "real template:"
REAL_TEMPLATE="${REPO_ROOT}/finicky/finicky.template.js"
check "real template has exactly one marker" "1" "$(grep -cF 'const INSTALLED_PWAS = {}; // @@INSTALLED_PWAS@@' "${REAL_TEMPLATE}" 2>/dev/null || echo 0)"
check "real template catalogs GitHub" "1" "$(grep -c 'mjoklplbddabcmpepnokjaffbmgbkkgg' "${REAL_TEMPLATE}" 2>/dev/null || echo 0)"
real_rendered="$(finicky_render "${REAL_TEMPLATE}" "${scan}")"
check "real template renders with fixture scan" "2" "$(grep -cF "${GH_ID}" <<<"${real_rendered}")"
if command -v node >/dev/null 2>&1; then
  printf '%s\n' "${real_rendered}" >"${TMP}/rendered.mjs"
  if node --check "${TMP}/rendered.mjs" 2>"${TMP}/node.err"; then
    check "rendered real template passes node --check" "ok" "ok"
  else
    check "rendered real template passes node --check" "ok" "$(head -3 "${TMP}/node.err")"
  fi
  printf '%s\n' "$(finicky_render "${REAL_TEMPLATE}" "")" >"${TMP}/rendered-empty.mjs"
  if node --check "${TMP}/rendered-empty.mjs" 2>"${TMP}/node2.err"; then
    check "rendered real template with no PWAs passes node --check" "ok" "ok"
  else
    check "rendered real template with no PWAs passes node --check" "ok" "$(head -3 "${TMP}/node2.err")"
  fi
else
  echo "  SKIP: node not on PATH, syntax check not run"
fi

exit "${fail}"
