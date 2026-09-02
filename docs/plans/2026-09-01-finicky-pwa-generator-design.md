# Finicky PWA config generator — design

**Date:** 2026-09-01
**Follows:** smartwatermelon/dotfiles#295 (GitHub deep links in the PWA)

## Problem

`finicky/finicky.js` routes URLs to Chrome PWAs. Three facts, all verified
empirically with Finicky 4.2.2 on 2026-09-01, constrain how it can do that
across machines where different PWAs are installed:

1. **A handler for an app that is not installed drops the URL.** Finicky runs
   `open -a 'Google Chrome' -n --args --app-id=<id> ...`; Chrome opens nothing
   and no visit is recorded. There is no fallback to `defaultBrowser`.
2. **The config cannot detect installed apps.** It runs in goja with only
   `finicky.matchHostnames`, `getModifierKeys`, `getSystemInfo`,
   `getPowerInfo`, `isAppRunning`. No filesystem, no `process`, and the
   bundler rejects `import "./local.js"` — the config must be one file.
3. **A config that fails to build sends every URL to Safari.** Finicky logs
   "No configuration available, using default configuration".

And one operational fact:

4. **Finicky's file watcher dies when the config's inode is replaced.** The
   deployed file is a symlink into the repo checkout, so every `git pull`
   replaces the inode. After that, the running Finicky keeps a stale bundle
   and even `touch` does not reload it. Only a restart re-reads the file.

## Design

Generate `~/.config/finicky/finicky.js` per machine at install time from a
tracked template plus a scan of the PWAs that are actually installed.

### Source of truth for "installed"

`~/Applications/Chrome Apps.localized/*.app`. Chrome creates one of these
shims for every PWA installed with OS integration, and removes it on
uninstall. Each shim's `Contents/Info.plist` carries `CrAppModeShortcutID`
(the Chrome app ID), `CrAppModeShortcutName` and `CrAppModeShortcutURL`.

Not used: the per-profile `Web Applications/Manifest Resources/<id>` dirs.
They also list Google's preinstalled apps (Docs, Sheets, Drive, Gmail,
YouTube) in every profile whether or not the user installed them, so they
over-report. They are used only to pick which profile to launch with.

### Which profile

The launch needs `--profile-directory=<dir>`. For each installed app ID,
the generator looks for `<profile>/Web Applications/Manifest Resources/<id>`
under `~/Library/Application Support/Google/Chrome/`, prefers `Default`,
otherwise takes the first match in sorted order, and falls back to
`Default` with a warning if none matches. The profile *directory* name is
used, never the display name, so nothing account-specific is emitted.

### Template contract

`finicky/finicky.template.js` is valid Finicky config on its own. It
contains:

- `CATALOG`: app ID → `{ hostnames: [...] }`. Hand-curated. Hostnames must
  be inside the PWA's scope (Chrome honors the launch URL only in scope;
  `gist.github.com` is *not* in GitHub's scope and loses the link).
- Exactly one marker line:
  `const INSTALLED_PWAS = {}; // @@INSTALLED_PWAS@@`
- Handlers built at load time from `CATALOG` filtered by `INSTALLED_PWAS`.

The generator replaces the marker line with
`const INSTALLED_PWAS = {"<id>": {"name": "<name>", "profile": "<dir>"}, ...};`
and prepends a "GENERATED — do not edit" header. Everything else is copied
verbatim. If the marker is missing, or present more than once, the
generator exits non-zero without touching the output.

### Deployment

- `finicky/finicky.template.js` and `finicky/generate-config.sh` are tracked
  and symlinked into `~/.config/finicky/` like any other config file.
  Finicky only reads `finicky.js` / `finicky.ts`, so the template is inert.
- `~/.config/finicky/finicky.js` becomes an untracked regular file written
  by the generator. It is not in `git ls-files`, so the symlink-repair hook
  ignores it. If a symlink is found at that path (the pre-generator
  deployment left one, now dangling), it is removed first.
- `install.sh` runs the generator after the symlink pass and before the
  `--sync` early exit, so `allup` regenerates on every sync. `--dry-run`
  passes through.

### Safety

- Validate before install: `node --check` on a `.mjs` copy of the rendered
  output when `node` is on PATH; otherwise warn and continue (the only
  generated content is one JSON literal; the template itself is covered by
  the test suite).
- Write to a temp file and `mv` into place; compare with `cmp` first and
  skip the write if unchanged.
- **Restart Finicky when the output changed** (`pkill -x Finicky` then
  `open -g -a Finicky`) if it is running. Verification reads
  `~/Library/Caches/Finicky/config_cache_*.json` → `bundlePath` and greps
  the bundle, never the file on disk.

### Non-goals

- Auto-discovering hostnames from `CrAppModeShortcutURL`. The start URL for
  Airtable is one specific base; routing all of `airtable.com` there is the
  over-broad behavior #295 removed. Hostnames stay hand-curated.
- Watching `~/Applications/Chrome Apps.localized` for live changes. A
  LaunchAgent could do it later; `allup` is frequent enough for now.
- Any PWA beyond GitHub in the initial catalog. Gmail
  (`fmgjjmmmlfnkbppncabfkddbjimcfncm`, `mail.google.com`) is the obvious
  next entry and is a one-line change once GitHub is proven in daily use.
