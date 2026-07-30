# PATH structure rationalization

## Problem

Investigating a `brew doctor` PATH-shadowing warning surfaced three separate issues:

1. **Two files share PATH responsibility.** `env.sh` runs `brew shellenv` (which
   mutates PATH) and `path.sh` re-layers priority on top via prepend/append
   helpers. Reasoning about final PATH order requires reading both files plus
   knowing `brew shellenv`'s behavior.
2. **Implicit ordering.** `path.sh`'s "prepend in reverse priority order"
   comment-documented convention means the final PATH order isn't visible in
   one place — it must be mentally simulated by reading prepend calls
   bottom-to-top.
3. **Fragile dependency on `brew shellenv` succeeding.** If `brew shellenv`
   times out or fails (observed once in `~/.local/state/updates.err`:
   `brew shellenv timed out after 5s, skipping Homebrew setup`), `env.sh`
   skips its whole Homebrew PATH block, and `path.sh` never prepends
   `${HOMEBREW_ROOT}/bin` (only `sbin`) — so `/opt/homebrew/bin` stays wherever
   macOS's `path_helper` put it (after `/usr/bin`), for the whole shell
   session, with no fallback.

Separately, the nightly `com.andrewrich.updates` LaunchAgent hardcodes
`/bin/bash` (macOS system bash 3.2) in `ProgramArguments`, an absolute path
that bypasses PATH resolution entirely. The interactive login shell is
unaffected (`UserShell` is `/opt/homebrew/bin/bash` 5.3.15, invoked directly by
absolute path), but the nightly automation runs its login-shell startup files
(`functions.sh`, `path.sh`, etc.) under bash 3.2 regardless of any PATH fix.

`com.andrewrich.headroom-learn.plist` has the same `/bin/bash` pattern but is
out of scope here — Headroom has been removed from the stack; that plist (and
any other Headroom leftovers, including the auto-generated section in
`CLAUDE.md`) needs a separate cleanup spike.

`install.sh`'s two `/bin/bash -c` installer invocations (Homebrew installer,
NVM installer) are intentionally left alone: at the point they run, Homebrew
bash may not exist yet.

## Design

### 1. `path.sh` becomes sole owner of PATH

Replace the prepend-in-reverse-priority scheme with one explicit array, read
top-to-bottom in actual final priority order:

```bash
_path_tiers=(
  "${HOME}/.local/bin"
  "${GEM_EXE_DIR:-}"
  "${HOME}/.bun/bin"
  "${HOME}/.asdf/shims"
  "${HOMEBREW_ROOT}/opt/ruby/bin"
  "${HOMEBREW_ROOT}/bin"
  "${HOMEBREW_ROOT}/sbin"
)
for dir in "${_path_tiers[@]}"; do
  _prepend_path_once "${dir}"
done
```

Each iteration prepends further left, so array order *is* final PATH
priority — no simulation needed. `HOMEBREW_ROOT` comes from
`_get_homebrew_root` (`functions.sh`), a pure `[[ -d /opt/homebrew ]]` check —
no `brew` invocation, cannot time out. The existing Android SDK append logic
at the bottom of `path.sh` (lowest priority, appended not prepended) is
unchanged.

### 2. `env.sh` stops touching PATH

Drop reliance on `brew shellenv`'s PATH mutation. Keep evaluating
`brew shellenv` for the non-PATH exports it still usefully provides
(`HOMEBREW_PREFIX`, `HOMEBREW_CELLAR`, `HOMEBREW_REPOSITORY`), but move this
to run *after* `path.sh` sources, so it can never affect PATH order. If it
times out or fails, only those secondary vars are missing — PATH is already
correct and unaffected. This fully absorbs the "fallback" requirement: PATH
correctness no longer depends on `brew shellenv` succeeding at all.

### 3. Fix the `updates` LaunchAgent's bash

Change `com.andrewrich.updates.plist`'s `ProgramArguments[0]` from
`/bin/bash` to `/opt/homebrew/bin/bash`, matching `UserShell`. This is
independent of the PATH changes above — no PATH fix can correct it, since
launchd invokes the named executable directly without PATH resolution.

## Testing

- Script-level test sourcing `path.sh` with `HOMEBREW_ROOT` forced to a known
  value, asserting final `PATH` array order matches the declared tier list.
- `plutil -lint` on the edited plist.
- `launchctl bootstrap`/`kickstart` the `updates` agent and confirm
  `bash --version` in its log output reports 5.x.
