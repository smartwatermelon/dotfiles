# Finicky PWA Config Generator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate `~/.config/finicky/finicky.js` per machine so only PWAs that are actually installed get handlers, and restart Finicky when the file changes.

**Architecture:** A tracked template (`finicky/finicky.template.js`) holds a hand-curated catalog and one marker line. A bash generator (`finicky/generate-config.sh`) scans `~/Applications/Chrome Apps.localized/*.app` shims for installed app IDs, picks a Chrome profile directory per app, replaces the marker with a JSON literal, validates with `node --check`, installs atomically, and restarts Finicky if the content changed. `install.sh` calls it after the symlink pass.

**Tech Stack:** GNU bash 5, `plutil`, `node --check` (optional), Finicky 4.2.2, existing `bash/tests/run-tests.sh` harness.

**Spec:** `docs/plans/2026-09-01-finicky-pwa-generator-design.md`

## Global Constraints

- Bash scripts: bash 5.x, `set -euo pipefail`, `shellcheck -S info` clean, no `# shellcheck disable`, never `((var++))`.
- Never `git add .`; add files by name. Never commit on `main`; work on branch `claude/feat-finicky-pwa-generator-01WqrfcuBbzrJqkieCHtcdUo`.
- Tests are standalone executables under `bash/tests/` named `test-*.sh`, exit 0 on pass, print `PASS:`/`FAIL:` lines, use `set -euo pipefail`, `unset CDPATH`, and `REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"`. Run the full suite with `bash bash/tests/run-tests.sh` before every commit.
- The generated file must never be committed. Only `finicky/finicky.template.js` and `finicky/generate-config.sh` are tracked under `finicky/`.
- Marker line, exact: `const INSTALLED_PWAS = {}; // @@INSTALLED_PWAS@@`
- Generated literal shape: `const INSTALLED_PWAS = {"<appId>": {"name": "<name>", "profile": "<profileDir>"}};` (keys sorted by app ID, no trailing marker comment).
- Profile directory preference: `Default` if it contains `Web Applications/Manifest Resources/<appId>`, else first matching profile in sorted order, else `Default` with a warning on stderr.
- Env overrides the generator must honor (so tests never touch real paths): `FINICKY_TEMPLATE`, `FINICKY_OUTPUT`, `CHROME_APPS_DIR`, `CHROME_PROFILE_ROOT`, `FINICKY_RESTART_CMD`.
- Commit messages end with `Claude-Session: https://claude.ai/code/session_01WqrfcuBbzrJqkieCHtcdUo`.
- Chat replies in Simplified Technical English; commit messages and docs keep repo voice.

---

### Task 1: Generator core — scan and render

**Files:**

- Create: `finicky/generate-config.sh`
- Test: `bash/tests/test-finicky-generate-config.sh`

**Interfaces:**

- Consumes: nothing from other tasks.
- Produces:
  - `finicky_scan_pwas <apps_dir> <profile_root>` → stdout lines `appId<TAB>name<TAB>profileDir`, sorted by appId. Empty output (exit 0) when `<apps_dir>` does not exist.
  - `finicky_render <template_path> <scan_lines>` → rendered config on stdout. `<scan_lines>` is the scan output as one string (may be empty). Exit 1 with a message on stderr if the marker line is absent or appears more than once.
  - The script runs `main "$@"` only when executed, not when sourced (`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]`), so tests can source the functions.

- [ ] **Step 1: Create the branch**

```bash
git -C /Users/andrewrich/Developer/dotfiles checkout -b claude/feat-finicky-pwa-generator-01WqrfcuBbzrJqkieCHtcdUo
git -C /Users/andrewrich/Developer/dotfiles branch --show-current
```

- [ ] **Step 2: Write the failing test**

Create `bash/tests/test-finicky-generate-config.sh`:

```bash
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
  cat > "${APPS}/${name}.app/Contents/Info.plist" <<EOF
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

# shellcheck source=../../finicky/generate-config.sh
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
cat > "${TEMPLATE}" <<'EOF'
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
printf '// no marker\nexport default {};\n' > "${TMP}/bad.js"
if finicky_render "${TMP}/bad.js" "${scan}" >/dev/null 2>&1; then
  check "missing marker fails" "nonzero" "0"
else
  check "missing marker fails" "nonzero" "nonzero"
fi

echo "render with duplicate marker:"
{ cat "${TEMPLATE}"; echo 'const INSTALLED_PWAS = {}; // @@INSTALLED_PWAS@@'; } > "${TMP}/dup.js"
if finicky_render "${TMP}/dup.js" "${scan}" >/dev/null 2>&1; then
  check "duplicate marker fails" "nonzero" "0"
else
  check "duplicate marker fails" "nonzero" "nonzero"
fi

exit "${fail}"
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash bash/tests/run-tests.sh finicky-generate-config`
Expected: FAIL — the runner reports the test exiting non-zero because `finicky/generate-config.sh` does not exist (source fails).

- [ ] **Step 4: Write the generator with scan and render**

Create `finicky/generate-config.sh`:

```bash
#!/usr/bin/env bash
# finicky/generate-config.sh
#
# Generates ~/.config/finicky/finicky.js from finicky.template.js plus the
# Chrome PWAs actually installed on this machine.
#
# Why generate at all (all verified with Finicky 4.2.2, 2026-09-01):
#   - A Finicky handler for an app that is not installed drops the URL —
#     Chrome opens nothing, and Finicky does not fall back to defaultBrowser.
#   - The config runs in goja with no filesystem access and cannot import a
#     second file, so it cannot discover installed apps itself.
#   - A config that fails to build makes Finicky send every URL to Safari.
#   - Finicky's file watcher dies when the config's inode is replaced (every
#     git pull did that while the file was a symlink into the repo), so a
#     changed config needs a Finicky restart to take effect.
#
# "Installed" means a shim exists in ~/Applications/Chrome Apps.localized —
# Chrome creates one per OS-integrated PWA and removes it on uninstall. The
# per-profile "Manifest Resources" dirs are NOT used for that decision: they
# also list Google's preinstalled apps in every profile. They are used only to
# choose the --profile-directory to launch with.
#
# Usage: generate-config.sh [--dry-run]
#
# Environment overrides (for tests and unusual layouts):
#   FINICKY_TEMPLATE     template path   (default: <this dir>/finicky.template.js)
#   FINICKY_OUTPUT       output path     (default: ~/.config/finicky/finicky.js)
#   CHROME_APPS_DIR      PWA shim dir    (default: ~/Applications/Chrome Apps.localized)
#   CHROME_PROFILE_ROOT  Chrome profiles (default: ~/Library/Application Support/Google/Chrome)
#   FINICKY_RESTART_CMD  command run after a changed install (default: restart Finicky if running)
set -euo pipefail
unset CDPATH

_gen_info() { printf '[finicky] %s\n' "$*"; }
_gen_warn() { printf '[finicky] WARN: %s\n' "$*" >&2; }
_gen_err() { printf '[finicky] ERROR: %s\n' "$*" >&2; }

MARKER='const INSTALLED_PWAS = {}; // @@INSTALLED_PWAS@@'

# Reads one string key from a shim's Info.plist. Prints nothing on failure.
_plist_string() {
  local key="$1" plist="$2"
  plutil -extract "${key}" raw -o - "${plist}" 2>/dev/null || true
}

# Picks the Chrome profile directory that has this app installed.
# Prefers Default; otherwise the first match in sorted order; otherwise
# Default with a warning (the launch will then fail, but loudly in the log).
_profile_for_app() {
  local app_id="$1" profile_root="$2" dir
  if [[ -d "${profile_root}/Default/Web Applications/Manifest Resources/${app_id}" ]]; then
    printf 'Default'
    return 0
  fi
  for dir in "${profile_root}"/*/; do
    dir="${dir%/}"
    if [[ -d "${dir}/Web Applications/Manifest Resources/${app_id}" ]]; then
      printf '%s' "$(basename "${dir}")"
      return 0
    fi
  done
  _gen_warn "app ${app_id} has a shim but no Chrome profile lists it; assuming Default"
  printf 'Default'
}

# finicky_scan_pwas <apps_dir> <profile_root>
# Emits "appId<TAB>name<TAB>profileDir" per installed PWA, sorted by appId.
finicky_scan_pwas() {
  local apps_dir="$1" profile_root="$2" shim plist app_id name profile
  [[ -d "${apps_dir}" ]] || return 0
  for shim in "${apps_dir}"/*.app; do
    [[ -d "${shim}" ]] || continue
    plist="${shim}/Contents/Info.plist"
    [[ -f "${plist}" ]] || continue
    app_id="$(_plist_string CrAppModeShortcutID "${plist}")"
    [[ -n "${app_id}" ]] || continue
    name="$(_plist_string CrAppModeShortcutName "${plist}")"
    [[ -n "${name}" ]] || name="$(basename "${shim}" .app)"
    profile="$(_profile_for_app "${app_id}" "${profile_root}")"
    printf '%s\t%s\t%s\n' "${app_id}" "${name}" "${profile}"
  done | LC_ALL=C sort
}

# Escapes a value for use inside a double-quoted JSON string.
_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "${s}"
}

# finicky_render <template_path> <scan_lines>
# Prints the template with the marker line replaced by the installed-app
# literal and a GENERATED header prepended. Fails unless exactly one marker.
finicky_render() {
  local template="$1" scan="$2" count literal="" app_id name profile sep=""
  [[ -f "${template}" ]] || { _gen_err "template not found: ${template}"; return 1; }
  count="$(grep -cF -- "${MARKER}" "${template}" || true)"
  if [[ "${count}" -ne 1 ]]; then
    _gen_err "expected exactly one marker line in ${template}, found ${count}: ${MARKER}"
    return 1
  fi
  if [[ -n "${scan}" ]]; then
    while IFS=$'\t' read -r app_id name profile; do
      [[ -n "${app_id}" ]] || continue
      literal+="${sep}\"$(_json_escape "${app_id}")\": {\"name\": \"$(_json_escape "${name}")\", \"profile\": \"$(_json_escape "${profile}")\"}"
      sep=", "
    done <<<"${scan}"
  fi
  printf '// GENERATED by finicky/generate-config.sh from %s — do not edit.\n' "$(basename "${template}")"
  printf '// Re-run install.sh --sync (or the generator) after installing or removing a Chrome PWA.\n'
  # awk with -v would reinterpret backslashes in the literal; pass via ENVIRON.
  RENDER_MARKER="${MARKER}" RENDER_LITERAL="const INSTALLED_PWAS = {${literal}};" \
    awk '$0 == ENVIRON["RENDER_MARKER"] { print ENVIRON["RENDER_LITERAL"]; next } { print }' "${template}"
}

main() {
  _gen_err "main not implemented yet"
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

Make it executable: `chmod +x finicky/generate-config.sh`.

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash bash/tests/run-tests.sh finicky-generate-config`
Expected: every `PASS:` line, exit 0.

- [ ] **Step 6: Lint and run the full suite**

Run:

```bash
shellcheck -S info finicky/generate-config.sh bash/tests/test-finicky-generate-config.sh
bash bash/tests/run-tests.sh
```

Expected: shellcheck prints nothing; the suite exits 0.

- [ ] **Step 7: Commit**

```bash
git -C /Users/andrewrich/Developer/dotfiles add finicky/generate-config.sh bash/tests/test-finicky-generate-config.sh
git -C /Users/andrewrich/Developer/dotfiles commit -F - <<'EOF'
feat(finicky): add PWA config generator scan and render

Finicky handlers for Chrome PWAs that are not installed drop the URL, and
the config cannot detect installed apps itself (goja, no filesystem, no
local imports). Introduce a generator that scans the PWA shims in
~/Applications/Chrome Apps.localized for app IDs, chooses a Chrome profile
directory per app, and substitutes an INSTALLED_PWAS literal into a
template. Install/validate/restart come in the next commit.

Claude-Session: https://claude.ai/code/session_01WqrfcuBbzrJqkieCHtcdUo
EOF
```

---

### Task 2: Template with catalog and marker

**Files:**

- Rename: `finicky/finicky.js` → `finicky/finicky.template.js` (via `git mv`), then rewrite
- Modify: `bash/tests/test-finicky-generate-config.sh` (append one section)

**Interfaces:**

- Consumes: `finicky_render` from Task 1.
- Produces: `finicky/finicky.template.js` containing exactly one marker line and a `CATALOG` object; the rendered output is a valid ES module.

- [ ] **Step 1: Append the failing test**

Append to `bash/tests/test-finicky-generate-config.sh`, before the final `exit "${fail}"`:

```bash
echo "real template:"
REAL_TEMPLATE="${REPO_ROOT}/finicky/finicky.template.js"
check "real template has exactly one marker" "1" "$(grep -cF 'const INSTALLED_PWAS = {}; // @@INSTALLED_PWAS@@' "${REAL_TEMPLATE}" 2>/dev/null || echo 0)"
check "real template catalogs GitHub" "1" "$(grep -c 'mjoklplbddabcmpepnokjaffbmgbkkgg' "${REAL_TEMPLATE}" 2>/dev/null || echo 0)"
real_rendered="$(finicky_render "${REAL_TEMPLATE}" "${scan}")"
check "real template renders with fixture scan" "1" "$(grep -cF "${GH_ID}" <<<"${real_rendered}")"
if command -v node >/dev/null 2>&1; then
  printf '%s\n' "${real_rendered}" > "${TMP}/rendered.mjs"
  if node --check "${TMP}/rendered.mjs" 2>"${TMP}/node.err"; then
    check "rendered real template passes node --check" "ok" "ok"
  else
    check "rendered real template passes node --check" "ok" "$(head -3 "${TMP}/node.err")"
  fi
  printf '%s\n' "$(finicky_render "${REAL_TEMPLATE}" "")" > "${TMP}/rendered-empty.mjs"
  if node --check "${TMP}/rendered-empty.mjs" 2>"${TMP}/node2.err"; then
    check "rendered real template with no PWAs passes node --check" "ok" "ok"
  else
    check "rendered real template with no PWAs passes node --check" "ok" "$(head -3 "${TMP}/node2.err")"
  fi
else
  echo "  SKIP: node not on PATH, syntax check not run"
fi
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash bash/tests/run-tests.sh finicky-generate-config`
Expected: FAIL on "real template has exactly one marker" (file does not exist yet).

- [ ] **Step 3: Rename and rewrite the template**

```bash
git -C /Users/andrewrich/Developer/dotfiles mv finicky/finicky.js finicky/finicky.template.js
```

Replace the entire contents of `finicky/finicky.template.js` with:

```javascript
// Finicky configuration TEMPLATE — routes opened URLs to Chrome PWAs.
// Docs: https://github.com/johnste/finicky/wiki/Configuration-(v4)
//
// This file is NOT read by Finicky. finicky/generate-config.sh renders it to
// ~/.config/finicky/finicky.js at install time (install.sh --sync), replacing
// the INSTALLED_PWAS marker line below with the PWAs actually installed on
// this machine. Edit the CATALOG here, never the generated file.
//
// Constraints that shape this file (all verified with Finicky 4.2.2):
//
//   1. Finicky evaluates config in goja, a Go JavaScript engine — not Node.
//      There is no `process` global and no filesystem access, and the
//      bundler cannot import a second file, so the installed-app list has to
//      be substituted into this one file.
//   2. A handler whose app is not installed does NOT fall back to
//      defaultBrowser — the URL is dropped. Handlers are therefore built only
//      for CATALOG entries present in INSTALLED_PWAS.
//   3. Launching a PWA by bundle ID (`open -b com.google.Chrome.app.<id>`)
//      drops the URL: Chrome's app_mode_loader opens the start page. The only
//      launch form that preserves it is Chrome itself with `--app-id=<id>`
//      plus `--app-launch-url-for-shortcuts-menu-item=<url>`. A profile must
//      be given so Finicky adds `-n` and a fresh Chrome process honors the
//      args. Recipe from the Finicky wiki (Configuration ideas), >= 4.2.1.
//   4. Chrome honors that launch URL only inside the PWA's scope. Hostnames
//      in CATALOG must be in scope: gist.github.com is NOT in GitHub's scope
//      and lost the link, so it is left to fall through to Chrome.
//   5. A config that fails to build makes Finicky send every URL to Safari.
//      The generator validates its output with `node --check` before install.
//
// App IDs come from each shim's Info.plist:
//   plutil -extract CrAppModeShortcutID raw -o - \
//     ~/Applications/Chrome\ Apps.localized/<App>.app/Contents/Info.plist
//
// To test a rendered config without opening anything:
//   /Applications/Finicky.app/Contents/MacOS/Finicky -config <file> -dry-run
//   (then `open https://github.com/...` from another shell and read the log)

// Hand-curated: app ID → hostnames to route there. Add an entry per PWA you
// install anywhere; the generator activates only the ones present locally.
const CATALOG = {
  mjoklplbddabcmpepnokjaffbmgbkkgg: { hostnames: ["github.com", "www.github.com"] },
};

// Replaced by the generator with the PWAs installed on this machine:
//   { "<appId>": { "name": "<shim name>", "profile": "<Chrome profile dir>" } }
// The profile is the directory name (Default, Profile 4, ...), never the
// account display name, so nothing user-specific is emitted.
const INSTALLED_PWAS = {}; // @@INSTALLED_PWAS@@

/** Builds a browser function that opens `url` inside a Chrome PWA. */
const chromeApp = (appId, profile) => (url) => ({
  name: "Google Chrome",
  profile,
  args: [
    `--app-id=${appId}`,
    `--app-launch-url-for-shortcuts-menu-item=${url.toString()}`,
  ],
});

const handlers = Object.keys(CATALOG)
  .filter((appId) => Object.prototype.hasOwnProperty.call(INSTALLED_PWAS, appId))
  .map((appId) => ({
    match: finicky.matchHostnames(CATALOG[appId].hostnames),
    browser: chromeApp(appId, INSTALLED_PWAS[appId].profile),
  }));

export default {
  defaultBrowser: "Google Chrome",

  options: {
    // Finicky logs every opened URL to ~/Library/Logs/Finicky by default,
    // which accumulates a plaintext record of browsing — including alert,
    // ticket and PR links that carry account and incident identifiers.
    // Diagnostics still go to the console, so `Finicky -config <file>` from a
    // terminal remains available when a handler needs debugging.
    logRequests: false,
  },

  // Anything with no matching handler falls through to defaultBrowser.
  handlers,
};
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash bash/tests/run-tests.sh finicky-generate-config`
Expected: all PASS including both `node --check` lines (node v20 is on PATH via nvm).

- [ ] **Step 5: (removed)** Foreground `Finicky -dry-run` and `open <url>` steal desktop focus; per user instruction no step launches Finicky in the foreground or opens URLs. Runtime acceptance is verified by the user clicking a link after Task 3.

- [ ] **Step 6: Format, lint, full suite**

```bash
cd /Users/andrewrich/Developer/dotfiles && npx --no-install prettier --write finicky/finicky.template.js && npx --no-install prettier --check finicky/finicky.template.js
bash bash/tests/run-tests.sh
```

Expected: prettier clean; suite exit 0. Note `~/.config/finicky/finicky.js` is now a dangling symlink (its target was renamed) — Task 3 handles it; do not run `install.sh` yet.

- [ ] **Step 7: Commit**

```bash
git -C /Users/andrewrich/Developer/dotfiles add finicky/finicky.template.js bash/tests/test-finicky-generate-config.sh
git -C /Users/andrewrich/Developer/dotfiles commit -F - <<'EOF'
feat(finicky): turn finicky.js into a template with a PWA catalog

Rename finicky.js to finicky.template.js and build handlers from a
hand-curated CATALOG filtered by an INSTALLED_PWAS literal that the
generator substitutes at install time. The template is valid config on
its own (empty INSTALLED_PWAS → every URL falls through to Chrome), so a
machine with no PWAs still gets a working file.

The template is no longer read by Finicky directly; the generated
~/.config/finicky/finicky.js is installed in the next commit.

Claude-Session: https://claude.ai/code/session_01WqrfcuBbzrJqkieCHtcdUo
EOF
```

---

### Task 3: Install, validate, restart, and wire into install.sh

**Files:**

- Modify: `finicky/generate-config.sh` (replace `main`)
- Modify: `install.sh` (new section between the config-symlink loop ending at the `done < <(git -C "${REPO_DIR}" ls-files)` line and the `# 4. HOME SYMLINKS` header)
- Modify: `bash/tests/test-finicky-generate-config.sh` (append one section)

**Interfaces:**

- Consumes: `finicky_scan_pwas`, `finicky_render` (Task 1), `finicky/finicky.template.js` (Task 2).
- Produces: `finicky/generate-config.sh [--dry-run]` as an executable; exit 0 on success, 1 on template/marker/validation error. Prints `[finicky] unchanged: <path>` or `[finicky] installed: <path>` (or `[finicky] would install: <path>` in dry-run).

- [ ] **Step 1: Append the failing test**

Append before the final `exit "${fail}"`:

```bash
echo "install:"
OUT_DIR="${TMP}/out"
mkdir -p "${OUT_DIR}"
OUT="${OUT_DIR}/finicky.js"
SENTINEL="${TMP}/restarted"
run_gen() {
  FINICKY_TEMPLATE="${TEMPLATE}" FINICKY_OUTPUT="${OUT}" \
    CHROME_APPS_DIR="${APPS}" CHROME_PROFILE_ROOT="${PROFILES}" \
    FINICKY_RESTART_CMD="touch ${SENTINEL}" \
    bash "${GEN}" "$@"
}

ln -s "${TMP}/does-not-exist" "${OUT}"
run_gen >"${TMP}/run1.out" 2>&1 || { echo "  FAIL: first run exited non-zero"; cat "${TMP}/run1.out"; fail=1; }
check "dangling symlink replaced by a regular file" "regular" "$( [[ -f "${OUT}" && ! -L "${OUT}" ]] && echo regular || echo other )"
check "installed file carries the literal" "1" "$(grep -cF "${GH_ID}" "${OUT}")"
check "first install reports installed" "1" "$(grep -c 'installed:' "${TMP}/run1.out")"
check "first install runs the restart command" "yes" "$( [[ -f "${SENTINEL}" ]] && echo yes || echo no )"

rm -f "${SENTINEL}"
run_gen >"${TMP}/run2.out" 2>&1 || { echo "  FAIL: second run exited non-zero"; fail=1; }
check "second run reports unchanged" "1" "$(grep -c 'unchanged:' "${TMP}/run2.out")"
check "second run does not restart" "no" "$( [[ -f "${SENTINEL}" ]] && echo yes || echo no )"

echo "dry-run:"
rm -rf "${APPS}/Foo.app"
run_gen --dry-run >"${TMP}/run3.out" 2>&1 || { echo "  FAIL: dry-run exited non-zero"; fail=1; }
check "dry-run reports would install" "1" "$(grep -c 'would install:' "${TMP}/run3.out")"
check "dry-run leaves the file alone" "1" "$(grep -cF "${FOO_ID}" "${OUT}")"
check "dry-run does not restart" "no" "$( [[ -f "${SENTINEL}" ]] && echo yes || echo no )"

echo "validation:"
printf '// GENERATED header stays\nconst INSTALLED_PWAS = {}; // @@INSTALLED_PWAS@@\nexport default { this is not javascript };\n' > "${TMP}/broken.template.js"
if command -v node >/dev/null 2>&1; then
  if FINICKY_TEMPLATE="${TMP}/broken.template.js" FINICKY_OUTPUT="${OUT}" CHROME_APPS_DIR="${APPS}" CHROME_PROFILE_ROOT="${PROFILES}" FINICKY_RESTART_CMD="touch ${SENTINEL}" bash "${GEN}" >/dev/null 2>&1; then
    check "invalid render is rejected" "nonzero" "0"
  else
    check "invalid render is rejected" "nonzero" "nonzero"
  fi
  check "invalid render leaves existing file intact" "1" "$(grep -cF "${FOO_ID}" "${OUT}")"
else
  echo "  SKIP: node not on PATH, validation test not run"
fi

echo "install.sh wiring:"
check "install.sh calls the generator" "1" "$(grep -c 'finicky/generate-config.sh' "${REPO_ROOT}/install.sh")"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash bash/tests/run-tests.sh finicky-generate-config`
Expected: FAIL at "first run exited non-zero" (main is a stub) and at "install.sh calls the generator".

- [ ] **Step 3: Replace `main` in the generator**

Replace the stub `main` in `finicky/generate-config.sh` with:

```bash
# Validates a rendered config with node when available. The rendered file
# is an ES module, so it is checked under an .mjs name.
_validate_rendered() {
  local rendered="$1" tmp_mjs
  if ! command -v node >/dev/null 2>&1; then
    _gen_warn "node not on PATH; skipping syntax check of rendered config"
    return 0
  fi
  tmp_mjs="$(mktemp "${TMPDIR:-/tmp}/finicky-check.XXXXXX").mjs"
  cp "${rendered}" "${tmp_mjs}"
  if node --check "${tmp_mjs}"; then
    rm -f "${tmp_mjs}"
    return 0
  fi
  rm -f "${tmp_mjs}"
  return 1
}

# Default restart: only if Finicky is running. `open -g` keeps it in the
# background. Finicky's watcher does not survive an inode replacement, so a
# restart is the only reliable way for a changed config to take effect.
_default_restart() {
  if pgrep -x Finicky >/dev/null 2>&1; then
    pkill -x Finicky || true
    sleep 1
    open -g -a Finicky || _gen_warn "could not relaunch Finicky; start it by hand"
    _gen_info "restarted Finicky so it reads the new config"
  fi
}

main() {
  local dry_run=false arg
  for arg in "$@"; do
    case "${arg}" in
      --dry-run) dry_run=true ;;
      *) _gen_err "unknown argument: ${arg}"; return 1 ;;
    esac
  done

  local script_dir template output apps_dir profile_root
  script_dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  template="${FINICKY_TEMPLATE:-${script_dir}/finicky.template.js}"
  output="${FINICKY_OUTPUT:-${HOME}/.config/finicky/finicky.js}"
  apps_dir="${CHROME_APPS_DIR:-${HOME}/Applications/Chrome Apps.localized}"
  profile_root="${CHROME_PROFILE_ROOT:-${HOME}/Library/Application Support/Google/Chrome}"

  local scan rendered
  scan="$(finicky_scan_pwas "${apps_dir}" "${profile_root}")"
  rendered="$(mktemp "${TMPDIR:-/tmp}/finicky-render.XXXXXX")"
  if ! finicky_render "${template}" "${scan}" > "${rendered}"; then
    rm -f "${rendered}"
    return 1
  fi
  if ! _validate_rendered "${rendered}"; then
    _gen_err "rendered config failed syntax check; leaving ${output} untouched"
    rm -f "${rendered}"
    return 1
  fi

  local count=0
  [[ -n "${scan}" ]] && count="$(wc -l <<<"${scan}" | tr -d ' ')"
  _gen_info "installed PWAs found: ${count}"

  # A symlink here is the pre-generator deployment (finicky.js used to be
  # tracked and linked into place). Its target was renamed, so it dangles.
  if [[ -L "${output}" ]]; then
    if ${dry_run}; then
      _gen_info "would remove symlink: ${output}"
    else
      rm -f "${output}"
      _gen_info "removed symlink: ${output}"
    fi
  elif [[ -f "${output}" ]] && cmp -s "${rendered}" "${output}"; then
    _gen_info "unchanged: ${output}"
    rm -f "${rendered}"
    return 0
  fi

  if ${dry_run}; then
    _gen_info "would install: ${output}"
    rm -f "${rendered}"
    return 0
  fi

  mkdir -p "$(dirname "${output}")"
  mv "${rendered}" "${output}"
  chmod 0644 "${output}"
  _gen_info "installed: ${output}"

  if [[ -n "${FINICKY_RESTART_CMD:-}" ]]; then
    bash -c "${FINICKY_RESTART_CMD}"
  else
    _default_restart
  fi
}
```

- [ ] **Step 4: Wire into install.sh**

In `install.sh`, immediately after the line `done < <(git -C "${REPO_DIR}" ls-files)` and before the `# 4. HOME SYMLINKS` banner, insert:

```bash
# ============================================================================
# 3b. GENERATED CONFIGS
# ============================================================================
# finicky.js is generated per machine from finicky.template.js plus the
# Chrome PWAs installed here; a handler for a PWA that is missing would drop
# URLs. The generator restarts Finicky when the file changes, because
# Finicky's watcher does not survive the file being replaced.
_info "Generating Finicky config from installed Chrome PWAs..."
if [[ "${DRY_RUN}" == true ]]; then
  if ! bash "${REPO_DIR}/finicky/generate-config.sh" --dry-run; then
    failures+=("finicky-generate:dry-run")
  fi
elif bash "${REPO_DIR}/finicky/generate-config.sh"; then
  installed+=("generated:${HOME}/.config/finicky/finicky.js")
else
  _warn "Finicky config generation failed — see messages above"
  failures+=("finicky-generate")
fi

```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash bash/tests/run-tests.sh finicky-generate-config`
Expected: all PASS.

- [ ] **Step 6: Lint and full suite**

```bash
shellcheck -S info finicky/generate-config.sh install.sh bash/tests/test-finicky-generate-config.sh
bash bash/tests/run-tests.sh
bash /Users/andrewrich/Developer/dotfiles/install.sh --sync --dry-run 2>&1 | grep -i 'finicky'
```

Expected: shellcheck silent; suite exit 0; dry-run shows `Would symlink` lines for `finicky.template.js` and `generate-config.sh`, `installed PWAs found: 8`, and `would remove symlink` + `would install` for `~/.config/finicky/finicky.js`.

- [ ] **Step 7: Deploy for real and verify without stealing focus**

Do NOT `open` any URL and do NOT launch Finicky in the foreground; the user's desktop must not lose focus. The generator's own restart uses `open -g -a Finicky`, which is allowed.

```bash
bash /Users/andrewrich/Developer/dotfiles/install.sh --sync 2>&1 | grep -i 'finicky'
ls -la ~/.config/finicky/
head -3 ~/.config/finicky/finicky.js; grep -c 'mjoklplbddabcmpepnokjaffbmgbkkgg' ~/.config/finicky/finicky.js
sleep 5; pgrep -x Finicky >/dev/null && echo "Finicky running"
B=$(python3 -c "import json,glob;print(json.load(open(sorted(glob.glob('$HOME/Library/Caches/Finicky/config_cache_*.json'))[-1]))['bundlePath'])"); echo "bundle: $B"; grep -c 'app-launch-url' "$B"
```

Expected: `~/.config/finicky/finicky.js` is a regular file whose first line says GENERATED; the template and generator are symlinks beside it; Finicky is running; the cached bundle contains `app-launch-url`. The end-to-end deep-link check is left to the user (they click a github.com PR link and confirm it opens in the PWA at that URL).

- [ ] **Step 8: Commit**

```bash
git -C /Users/andrewrich/Developer/dotfiles add finicky/generate-config.sh install.sh bash/tests/test-finicky-generate-config.sh
git -C /Users/andrewrich/Developer/dotfiles commit -F - <<'EOF'
feat(finicky): generate finicky.js from installed PWAs on install.sh --sync

Render finicky.template.js with the PWAs found in
~/Applications/Chrome Apps.localized, validate the result with
node --check, install it atomically as a plain file (replacing the old
symlink), and restart Finicky when the content changed.

The restart matters: Finicky 4.2.2 watches the config by inode, and a
replaced inode leaves it running a stale bundle that even `touch` cannot
refresh. Making the deployed file a generated regular file also stops
every git pull from replacing it.

install.sh runs the generator after the symlink pass, in --sync and
--dry-run modes, so allup keeps it current.

Claude-Session: https://claude.ai/code/session_01WqrfcuBbzrJqkieCHtcdUo
EOF
```

---

### Task 4: Docs and pre-push review

**Files:**

- Modify: `README.md` (only if it has a section listing config directories or describing `install.sh`; check with `grep -n -i 'finicky\|install.sh\|\.config' README.md`)
- Modify: `docs/plans/2026-09-01-finicky-pwa-generator-design.md` (no change expected; confirm it still matches)

**Interfaces:** none.

- [ ] **Step 1: Document the generated file where install.sh behavior is described**

If `README.md` describes what `install.sh` does, add one bullet in that list:

```markdown
- `finicky/`: `finicky.js` is **generated** per machine by `finicky/generate-config.sh` from `finicky.template.js` and the Chrome PWAs installed in `~/Applications/Chrome Apps.localized`. Edit the template's `CATALOG`, then run `install.sh --sync`. The generator restarts Finicky when the file changes.
```

If `README.md` has no such section, skip this step and say so in the task report.

- [ ] **Step 2: Run the full suite and prettier/markdownlint via pre-commit**

```bash
bash /Users/andrewrich/Developer/dotfiles/bash/tests/run-tests.sh
```

Expected: exit 0.

- [ ] **Step 3: Commit (only if README changed)**

```bash
git -C /Users/andrewrich/Developer/dotfiles add README.md
git -C /Users/andrewrich/Developer/dotfiles commit -F - <<'EOF'
docs(finicky): describe the generated finicky.js in the README

Claude-Session: https://claude.ai/code/session_01WqrfcuBbzrJqkieCHtcdUo
EOF
```

- [ ] **Step 4: Pre-push codebase review dry-run**

```bash
git -C /Users/andrewrich/Developer/dotfiles diff origin/main...HEAD | ~/.claude/hooks/run-review.sh --mode=codebase --no-file
```

Expected: `VERDICT: PASS`. Fix anything it flags, commit, and re-run until it passes.

- [ ] **Step 5: Push and open the PR**

```bash
git -C /Users/andrewrich/Developer/dotfiles push -u origin claude/feat-finicky-pwa-generator-01WqrfcuBbzrJqkieCHtcdUo
cd /Users/andrewrich/Developer/dotfiles && gh pr create --title "feat(finicky): generate finicky.js from installed Chrome PWAs" --body-file - <<'EOF'
## Problem

A Finicky handler for a Chrome PWA that is not installed drops the URL (no fallback to `defaultBrowser`), and the config cannot detect installed apps itself. So one tracked `finicky.js` cannot serve machines with different PWAs. Separately, Finicky's config watcher dies when the file's inode is replaced, which every `git pull` did while the deployed file was a symlink into the repo (seen after #295 merged).

## Change

- `finicky/finicky.js` → `finicky/finicky.template.js`: a hand-curated `CATALOG` (app ID → in-scope hostnames) plus one `INSTALLED_PWAS` marker line. Valid config on its own.
- `finicky/generate-config.sh`: scans `~/Applications/Chrome Apps.localized/*.app` shims for app IDs, picks the Chrome profile directory per app (prefers `Default`), substitutes the literal, validates with `node --check`, installs `~/.config/finicky/finicky.js` as a plain file, and restarts Finicky if the content changed. `--dry-run` supported; all paths overridable by env for tests.
- `install.sh`: runs the generator after the symlink pass (sync and dry-run modes).
- `bash/tests/test-finicky-generate-config.sh`: fixture-driven coverage of scan, profile choice, render, marker errors, install, unchanged-skip, dry-run, restart hook, validation rejection, and the real template.

Design: `docs/plans/2026-09-01-finicky-pwa-generator-design.md`.

## Verification

- Full bash suite green locally.
- `install.sh --sync` on this machine: 8 PWAs found, generated file installed, Finicky restarted, cached bundle carries the app-launch-url handler, and `https://github.com/smartwatermelon/dotfiles/pull/295` appears in Chrome history as that exact URL.

https://claude.ai/code/session_01WqrfcuBbzrJqkieCHtcdUo
EOF
```

- [ ] **Step 6: Monitor CI**

```bash
bash ~/.claude/scripts/post-push-status.sh <PR#>
```

Loop every 30 s until `CI_STATE` is not `PENDING`. Fix locally and push again if anything fails.
