# PATH Rationalization Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make `path.sh` the single, explicit-order owner of PATH construction (independent of `brew shellenv` succeeding), stop `env.sh` from mutating PATH, and fix the `updates` LaunchAgent to run under Homebrew bash instead of macOS system bash 3.2.

**Architecture:** Replace `path.sh`'s prepend-in-reverse-priority convention with one literal array walked top-to-bottom (array order = final PATH order). Neutralize `env.sh`'s `brew shellenv` eval so it can never touch PATH (filter its output before eval), and delete a stray duplicate `export PATH=` line found at the end of `env.sh`. Point the `com.andrewrich.updates` LaunchAgent at `/opt/homebrew/bin/bash`.

**Tech Stack:** Bash 5.x (`bash/*.sh`, sourced via `~/.config/bash/main.sh`), shellcheck, macOS `launchd` plist.

**Background:** See `docs/plans/2026-07-29-path-rationalization-design.md` for the full investigation and rationale.

---

## Task 1: Rewrite `path.sh` to explicit-order tier array

**Files:**

- Modify: `bash/path.sh` (full rewrite of the prepend section, lines ~15–105)
- Test: `bash/tests/test-path-order.sh` (new — no test framework exists in this repo; this is a standalone script run manually, matching the repo's existing shellcheck-only verification convention)

**Step 1: Write the failing test**

Create `bash/tests/test-path-order.sh`:

```bash
#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification for bash/path.sh PATH ordering.
# Run directly: bash bash/tests/test-path-order.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export BASH_CONFIG_DIR="${REPO_ROOT}/bash"

# Isolate from the real environment so the test is deterministic regardless
# of what's actually installed on the machine running it.
export HOME="/tmp/path-order-test-home-$$"
mkdir -p "${HOME}/.local/bin" "${HOME}/.bun/bin"
trap 'rm -rf "${HOME}"' EXIT

# functions.sh defines _get_homebrew_root, _prepend_path_once, etc.
#shellcheck source=/dev/null
source "${BASH_CONFIG_DIR}/functions.sh"

export PATH="/usr/bin:/bin"
#shellcheck source=/dev/null
source "${BASH_CONFIG_DIR}/path.sh"

fail=0
assert_before() {
  local first="$1" second="$2"
  local first_idx second_idx idx=0
  first_idx=-1
  second_idx=-1
  IFS=':' read -ra parts <<<"${PATH}"
  for p in "${parts[@]}"; do
    [[ "${p}" == "${first}" ]] && first_idx=${idx}
    [[ "${p}" == "${second}" ]] && second_idx=${idx}
    ((idx += 1))
  done
  if [[ ${first_idx} -eq -1 || ${second_idx} -eq -1 ]]; then
    echo "FAIL: expected both '${first}' and '${second}' in PATH: ${PATH}"
    fail=1
  elif [[ ${first_idx} -ge ${second_idx} ]]; then
    echo "FAIL: expected '${first}' before '${second}' in PATH: ${PATH}"
    fail=1
  else
    echo "PASS: '${first}' before '${second}'"
  fi
}

assert_before "${HOME}/.local/bin" "${HOME}/.bun/bin"
assert_before "${HOME}/.bun/bin" "$(_get_homebrew_root)/bin"
assert_before "$(_get_homebrew_root)/bin" "/usr/bin"

exit "${fail}"
```

**Step 2: Run test to verify current behavior**

Run: `bash bash/tests/test-path-order.sh`
Expected: FAILs on the `"$(_get_homebrew_root)/bin" before "/usr/bin"` assertion, since current `path.sh` never prepends `${HOMEBREW_ROOT}/bin` (only `sbin`) — it relies entirely on `env.sh`'s `brew shellenv`, which this test deliberately doesn't source.

**Step 3: Rewrite `path.sh`**

Replace the body of `bash/path.sh` (keep the two helper functions `_prepend_path_once`/`_append_path_once` and the header comment) with:

```bash
# ~/.config/bash/path.sh
#shellcheck shell=bash
# Consolidated PATH management — this file is the ONLY place PATH priority
# is decided. env.sh does not touch PATH.
#
# _path_tiers below is the final PATH order, highest priority first.
# Read top-to-bottom: that IS the resulting search order. No mental
# simulation of prepend calls required.

# Prepend to PATH, ensuring it's at the front (moves existing entry if needed)
# macOS path_helper pre-populates PATH from /etc/paths.d, often placing user
# directories after system ones. This function corrects that ordering.
_prepend_path_once() {
  local dir="$1"
  [[ -d "${dir}" ]] || return 0

  if [[ "${PATH}" == "${dir}" ]]; then
    export PATH="${dir}"
    return 0
  fi
  PATH="${PATH/#${dir}:/}"
  PATH="${PATH//:${dir}:/:}"
  PATH="${PATH/%:${dir}/}"

  export PATH="${dir}:${PATH}"
}

# Append to PATH only if not already present (prevents duplicates)
_append_path_once() {
  local dir="$1"
  if [[ -d "${dir}" ]] && [[ ":${PATH}:" != *":${dir}:"* ]]; then
    export PATH="${PATH}:${dir}"
  fi
}

# ============================================================================
# EXPLICIT PATH ORDER — highest priority first
# ============================================================================

HOMEBREW_ROOT=$(_get_homebrew_root)

GEM_EXE_DIR=""
if command -v ruby &>/dev/null; then
  if [[ $(type -t _profile_time) == "function" ]] && [[ "$-" == *i* ]]; then
    _pf_start=$(date +%s.%N)
  fi
  GEM_EXE_DIR="$(ruby -e 'puts Gem.bindir' 2>/dev/null)"
  if [[ $(type -t _profile_time) == "function" ]] && [[ "$-" == *i* ]]; then
    _pf_end=$(date +%s.%N)
    _pf_duration=$(awk "BEGIN {printf \"%.3f\", ${_pf_end} - ${_pf_start}}")
    if (($(awk "BEGIN {print (${_pf_duration} > 1.0)}"))); then
      echo "[PROFILE] ruby Gem.bindir took ${_pf_duration}s" >&2
    fi
    unset _pf_start _pf_end _pf_duration
  fi
fi

# Written highest-priority-first. The loop below does a single forward
# pass, appending each existing directory to a new prefix in this exact
# order, then puts that prefix in front of whatever's left of the old
# PATH. Array order above IS the resulting PATH order — read top to
# bottom, no need to simulate anything.
_path_tiers=(
  "${HOME}/.local/bin"
  "${GEM_EXE_DIR}"
  "${HOME}/.bun/bin"
  "${HOME}/.asdf/shims"
  "${HOMEBREW_ROOT}/opt/ruby/bin"
  "${HOMEBREW_ROOT}/bin"
  "${HOMEBREW_ROOT}/sbin"
)

_new_path=""
for _dir in "${_path_tiers[@]}"; do
  [[ -n "${_dir}" && -d "${_dir}" ]] || continue
  # Strip any existing occurrence first so it isn't duplicated below.
  PATH="${PATH//:${_dir}:/:}"
  PATH="${PATH/#${_dir}:/}"
  PATH="${PATH/%:${_dir}/}"
  [[ "${PATH}" == "${_dir}" ]] && PATH=""
  _new_path="${_new_path:+${_new_path}:}${_dir}"
done
export PATH="${_new_path}${_new_path:+:}${PATH}"
unset _path_tiers _dir _new_path GEM_EXE_DIR

# ============================================================================
# LOWEST PRIORITY — appended, not prepended
# ============================================================================

# Android SDK (only if installed)
if [[ -d "${HOME}/Library/Android/sdk" ]]; then
  export ANDROID_HOME="${HOME}/Library/Android/sdk"
  _append_path_once "${ANDROID_HOME}/emulator"
  _append_path_once "${ANDROID_HOME}/platform-tools"
fi
```

`_prepend_path_once`/`_append_path_once` are kept for the Android SDK
low-priority append and for any future one-off caller, but the tier
construction itself no longer uses `_prepend_path_once` — repeated prepend
calls are exactly the "simulate the order in your head" pattern this
rewrite removes.

**Step 4: Run test to verify it passes**

Run: `bash bash/tests/test-path-order.sh`
Expected: All three `PASS` lines, exit 0.

**Step 5: Shellcheck**

Run: `shellcheck -S info bash/path.sh bash/tests/test-path-order.sh`
Expected: no issues.

**Step 6: Commit**

```bash
git add bash/path.sh bash/tests/test-path-order.sh
git commit -m "refactor(path): make path.sh the sole explicit-order PATH owner"
```

---

## Task 2: Stop `env.sh` from touching PATH

**Files:**

- Modify: `bash/env.sh:56-97` (brew shellenv block), `bash/env.sh:171` (stray export)

**Step 1: Filter PATH/MANPATH/INFOPATH out of the `brew shellenv` eval**

In `bash/env.sh`, change the `eval "${BREW_SHELLENV}"` branch (around line 87)
so it strips any line that assigns those three variables before eval'ing —
`path.sh` already owns them and must not be re-mutated by whatever
`brew shellenv` decides to emit:

```bash
  else
    eval "$(grep -vE '^export (PATH|MANPATH|INFOPATH)=' <<<"${BREW_SHELLENV}")"
  fi
```

**Step 2: Delete the stray duplicate PATH export**

Remove line 171 entirely:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

This was a leftover direct PATH mutation that both duplicated and could
reorder what `path.sh` already establishes — `path.sh` already prepends
`${HOME}/.local/bin` at the correct (highest) priority.

**Step 3: Verify no other PATH/MANPATH/INFOPATH references remain in `env.sh`**

Run: `grep -n 'PATH=' bash/env.sh`
Expected: no output (all removed/filtered).

**Step 4: Shellcheck**

Run: `shellcheck -S info bash/env.sh`
Expected: no issues.

**Step 5: Manual verification**

Run: `bash -c 'source bash/functions.sh && source bash/env.sh && source bash/path.sh && echo "${PATH}" | tr ":" "\n" | head -10'`
Expected: `${HOME}/.local/bin` first, `${HOMEBREW_ROOT}/bin` ahead of `/usr/bin`, no duplicate entries.

**Step 6: Commit**

```bash
git add bash/env.sh
git commit -m "fix(env): stop env.sh from mutating PATH, remove stray duplicate export"
```

---

## Task 3: `updates` LaunchAgent's bash — REJECTED, not implemented

Originally planned to change `com.andrewrich.updates.plist`'s
`ProgramArguments[0]` from `/bin/bash` to `/opt/homebrew/bin/bash`. **Do not
do this.** Homebrew's `bash` binary's real path changes on every
`brew upgrade bash` (versioned Cellar target), and TCC/Full Disk Access
grants for that binary don't survive the change — pinning the unattended
nightly job to Homebrew bash would silently lose FDA after any bash upgrade
and reintroduce the "bash wants to use local files" TCC prompts documented in
`2026-07-10-nightly-updates-sudo-tcc-plan.md`. `/bin/bash` (system bash 3.2,
SIP-protected, permanent) is the only stable FDA grantee for this job. See
the design doc's §3 for full rationale.

This doesn't block the rest of the plan: Tasks 1–2 fix the actual reported
symptom (the `brew doctor` PATH warning) using plain bash-3.2-compatible
syntax, so the nightly job gets correct PATH ordering under system bash with
no plist change needed.

---

## Task 4: Full regression check

**Step 1:** Run `shellcheck -S info bash/path.sh bash/env.sh bash/functions.sh bash/main.sh bash/tests/test-path-order.sh`
Expected: no issues.

**Step 2:** Run `bash bash/tests/test-path-order.sh`
Expected: exit 0, all PASS.

**Step 3:** Open a fresh interactive login shell (`/opt/homebrew/bin/bash -l`) and run `echo $PATH | tr ':' '\n' | head -5`
Expected: `${HOME}/.local/bin`, then homebrew paths, before any `/usr/bin`.

**Step 4:** Report results; do not push until this task's checks are clean (Protocol 4).
