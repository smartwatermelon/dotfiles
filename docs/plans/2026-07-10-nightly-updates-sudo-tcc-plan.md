# Nightly `_homebrew_update` — Eliminate Morning sudo/TCC Prompts

**Date:** 2026-07-10
**Status:** Root Cause 1 fix implemented 2026-07-12 (cask deferral); tccd work
(Root Cause 2 / Steps 0 and 2) still deferred
**Author:** Investigation session (Claude Code)

## Problem

After the unattended nightly update run, unlocking the Mac in the morning
surfaces:

1. Several **"bash wants to use local files"** TCC consent prompts.
2. Usually one **TouchID / sudo** prompt.

Both should be unnecessary: the run is meant to be fully non-interactive, and
Full Disk Access was (apparently) granted to "Bash".

## Background: how the nightly job runs

- LaunchAgent: `~/Library/LaunchAgents/com.andrewrich.updates.plist`
  → symlink to `~/Developer/LaunchAgents/com.andrewrich.updates.plist`.
- Fires at **03:55** via `StartCalendarInterval`.
- Runs: `/bin/bash -l -c "source ~/.config/bash/functions.sh && updates"`.
- `updates()` (`bash/functions.sh:652`) chains: `_homebrew_update` →
  `_softwareupdate` → `_mas_update` → `_npm_update` → `_pipx_update` →
  `_gem_update` → `_claude_update`.

Existing non-interactive protections that **work correctly**:

- `_updates_noninteractive()` (`bash/functions.sh:284`) detects the LaunchAgent
  via `[[ ! -t 0 ]]` (no controlling TTY). Confirmed correct under launchd.
- `_softwareupdate` defers its privileged download/install to interactive runs
  (`bash/functions.sh:524`).
- `_homebrew_update` installs a PATH-based `sudo` shim before `brew upgrade`
  (`bash/functions.sh:352-364`, shim built in `_updates_sudo_shim`,
  `bash/functions.sh:300`).

## Root Cause 1 — TouchID sudo prompt (DEFINITIVE)

**The PATH-based `sudo` shim is bypassed by absolute-path sudo calls.** The shim
only shadows a bare `sudo` on `PATH`. The `tunnelblick` cask invokes sudo by
full path.

Evidence — `~/.local/state/updates.out`:

```text
:65696  Error: tunnelblick: Failure while executing;
        `/usr/bin/sudo -E -- touch /Applications/Tunnelblick.app/.homebrew-write-test` exited with 1
:65697  sudo: a terminal is required to read the password
:84652  ==> Changing ownership of paths required by tunnelblick with `sudo`...
```

- `/etc/pam.d/sudo_local` contains `auth sufficient pam_tid.so`, so
  `/usr/bin/sudo` surfaces a **GUI TouchID dialog**.
- At 03:55 the screen is locked (no GUI session), so macOS **defers** the
  biometric prompt until unlock → the morning TouchID prompt.
- **Recurs every night** because `tunnelblick` installs a privileged helper and
  always runs a sudo write-test / ownership step on upgrade; it can never
  complete non-interactively, so it re-attempts nightly.

Sudo-requiring casks seen across retained logs: `tunnelblick` (current), plus
historically `blockblock` and `ransomwhere` — all security/VPN tools with
privileged components. A per-cask skiplist would therefore be a moving target.

## Root Cause 2 — "bash wants to use local files" TCC prompts (STRONG, one gap)

Why granting "Bash" Full Disk Access did not silence these:

- The LaunchAgent runs **`/bin/bash`** = Apple's **bash 3.2**
  (`com.apple.bash`, SIP-protected system binary, `-r-xr-xr-x root wheel`).
- The interactive shell is Homebrew bash 5.3 (`/opt/homebrew/bin/bash`).
  Whatever "Bash" was added to Full Disk Access is almost certainly **not this
  exact `/bin/bash`**; and a shared system interpreter is an unreliable FDA
  grantee regardless.
- Prompts **defer to unlock** (no GUI session at 03:55), same as the TouchID
  prompt.
- There are **two** overnight `/bin/bash` login-shell agents that would both
  emit "bash" prompts:
  - `com.andrewrich.updates` at 03:55
  - `com.andrewrich.headroom-learn` at 04:17
    (`headroom-learn-all.sh --apply`, which walks transcripts/repos).
  So not all "local files" prompts are necessarily from the Homebrew job.

**Open gap:** the specific folders that trigger the prompts were not captured —
the authoritative `tccd` unified-log entries from the relevant night had already
rolled off, and Homebrew's own cache (`~/Library/Caches/Homebrew`) is not a
TCC-prompted location. Naming the exact paths requires a **live capture**
(see Step 0).

## Fix Plan

Work on a branch (`claude/fix-nightly-updates-prompts-<session>`); never on
`main`. Shellcheck clean (`shellcheck -S info`), full local review, PR, CI, then
merge with authorization — per repo protocols.

### Step 0 — Live capture for Root Cause 2 (do FIRST, before any Symptom-2 code)

Goal: name the exact TCC folders and the responsible agent(s).

```bash
# Terminal 1: stream TCC decisions
log stream --predicate 'process == "tccd"' --style compact

# Terminal 2: trigger each agent on demand and watch Terminal 1
launchctl kickstart -k gui/$(id -u)/com.andrewrich.updates
launchctl kickstart -k gui/$(id -u)/com.andrewrich.headroom-learn
```

Record: which folders (Desktop / Documents / Downloads / network volume /
removable volume) and which responsible binary each prompt names. This decides
whether the Symptom-2 fix is "stop touching those paths" and/or "grant the exact
`/bin/bash` FDA".

Caveat: kicking `updates` performs real updates (brew upgrade, claude update,
etc.) and may itself trigger the tunnelblick sudo prompt. Do this at the machine,
unlocked, when able to dismiss prompts. Consider doing Step 1 first so the
capture run is sudo-quiet.

### Step 1 — Root Cause 1: defer casks in non-interactive mode (IMPLEMENTED 2026-07-12)

Implemented in `_homebrew_update` (`bash/functions.sh`): non-interactive runs
now call `brew upgrade --formula`, deferring all casks to the interactive run;
interactive behavior is unchanged. Verified with an isolated function-level
harness (interactive → `--verbose`; non-interactive → `--verbose --formula`).

Original design notes:

In `_homebrew_update` (`bash/functions.sh:320`), when `_updates_noninteractive`
is true, upgrade **formulae only** and defer **all casks** to the next
interactive run. This mirrors the existing `_softwareupdate` deferral pattern
(`bash/functions.sh:524`) and eliminates every cask-sudo prompt — current and
future — without a fragile per-cask skiplist.

Sketch:

- Non-interactive: `brew upgrade --formula` (skip casks entirely).
- Log a `_notif` line noting casks were deferred, so it is visible in
  `updates.out` and at the next interactive run.
- Interactive: keep current behavior (`brew upgrade`, casks included).
- Keep the existing sudo shim as defense-in-depth, but it is no longer the
  primary guard.

Verification:

- Run `UPDATES_NONINTERACTIVE=1 _homebrew_update` in a scratch shell; confirm
  no cask upgrade attempted, no `/usr/bin/sudo` line in output, exit 0.
- Run interactively; confirm casks still upgrade.
- Watch one real nightly run (or `launchctl kickstart`) and confirm no
  tunnelblick sudo line and no morning TouchID prompt.

Alternatives (documented, not preferred):

- Per-cask skiplist — brittle; new privileged casks reintroduce the prompt.
- `sudoers.d` passwordless rule scoped to tunnelblick's paths — weakens security
  posture, needs manual sudo to install, still cask-specific.

### Step 2 — Root Cause 2: apply the fix the capture points to

Depending on Step 0 findings, one or both:

- **(a) Stop touching protected paths.** If a specific step walks
  Desktop/Documents/Downloads or a network volume, scope it out. (Likely a cask
  relaunch or a home-dir walk — confirm via capture.)
- **(b) Grant the exact binary FDA.** Add **`/bin/bash`** (the precise path in
  the plist — not a Homebrew bash) to System Settings → Privacy & Security →
  Full Disk Access via `+` → Cmd-Shift-G → `/bin/bash`. If `headroom-learn` is
  also implicated, it runs the same `/bin/bash`, so one grant covers both.

Note: this is host configuration, not repo code — document it in the repo
(README or this plan) but it must be applied manually on each machine.

### Step 3 — Consider consolidating overnight `/bin/bash` agents (optional)

`updates` (03:55) and `headroom-learn` (04:17) share the same `/bin/bash` FDA
surface. Once Step 2 settles the FDA story, note in the repo which binary must
hold FDA so future machines are set up correctly.

## Acceptance Criteria

- [ ] Morning unlock shows **no** TouchID/sudo prompt attributable to the update
      run, verified across at least two nightly runs.
- [ ] Morning unlock shows **no** "bash wants to use local files" prompts,
      verified across at least two nightly runs.
- [ ] `updates.out` shows casks explicitly deferred in non-interactive mode and
      no `/usr/bin/sudo ... a password is required` lines.
- [ ] Interactive `updates` / `brewup` still upgrades casks normally.
- [ ] Shellcheck clean; local review clean; CI green.

## Key References

- Orchestrator: `bash/functions.sh:652` (`updates`)
- Homebrew updater + shim: `bash/functions.sh:320-398`, shim `:300`, `:352-364`
- Non-interactive detection: `bash/functions.sh:284`
- softwareupdate deferral pattern to mirror: `bash/functions.sh:524`
- LaunchAgent: `~/Developer/LaunchAgents/com.andrewrich.updates.plist`
- Evidence log: `~/.local/state/updates.out` (lines 65696-65698, 84652)
- TouchID mechanism: `/etc/pam.d/sudo_local` → `pam_tid.so`
- Other overnight `/bin/bash` agent: `com.andrewrich.headroom-learn` (04:17)
