# Bash Configuration

A modular, organized bash configuration setup for macOS development environments.

## Overview

This repository contains my personal bash configuration files, designed with modularity and maintainability in mind. It separates various aspects of the bash environment into discrete, purpose-specific files for easier management and customization.

## Structure

- `.bash_profile`: Main entry point that sources other configuration files
- `main.sh`: Core configuration and settings
- `env.sh`: Environment variables and path configuration
- `aliases.sh`: Command shortcuts and aliases
- `functions.sh`: Custom bash functions
- `completion.sh`: Tab completion configuration
- `history.sh`: Command history settings
- `prompt.sh`: Command prompt customization
- `secrets.sh`: Private environment variables and tokens (not tracked in git)
- `backups/`: Directory containing configuration backups

## Features

- Modular design with separation of concerns
- Organized file structure for easy maintenance
- Custom prompt configuration
- Useful aliases and functions for development workflows
- Tab completion enhancements
- History optimization settings

## Installation

Files are maintained individually and can be sourced directly from your `.bash_profile` or `.bashrc`. Each module can be loaded independently based on your needs.

## Usage

After installation, the configuration will be loaded automatically when opening a new terminal. The modular design allows for easy customization:

- Add new aliases to `aliases.sh`
- Define custom functions in `functions.sh`
- Set environment variables in `env.sh`
- Store sensitive information in `secrets.sh` (which is git-ignored)

## Testing

Regression tests live in `tests/`. Each is a standalone script that sets up its
own sandbox (scratch `$HOME`, scratch git repos, mocked `gh`), asserts, cleans
up after itself, and reports via its exit code.

Run the whole suite:

```bash
"$(brew --prefix)/bin/bash" bash/tests/run-tests.sh
```

The runner discovers every `bash/tests/test-*.sh` automatically, prints each
test's output, and exits non-zero if any fail — so there is no list to keep in
sync when a test is added.

Run a single test, by passing a substring of its name:

```bash
"$(brew --prefix)/bin/bash" bash/tests/run-tests.sh path-order   # runs test-path-order.sh
```

Or invoke the file directly:

```bash
"$(brew --prefix)/bin/bash" bash/tests/test-path-order.sh
```

**Bash 4.4 or newer is required.** Some tests use `mapfile -d`, and the `-d`
option arrived in bash 4.4 — the bash 3.2 that macOS ships at `/bin/bash` has
no `mapfile` builtin at all. The runner checks the version and refuses to run
on anything older rather than letting those tests quietly produce empty
results and appear to pass.

Invoke the runner with an explicit modern bash rather than a bare `bash`,
which resolves through `PATH` and on macOS can still find 3.2:

```bash
"$(brew --prefix)/bin/bash" bash/tests/run-tests.sh
```

The runner passes its own interpreter down to each child test, so whichever
bash you start it with is the one every test runs under. On macOS, Homebrew
is how you get a modern bash; it installs bash 5, comfortably above the 4.4
floor.

### When these run automatically

- **On push** — `.project-hooks/pre-push` runs the suite via the pre-push hook's
  project-extension seam (see `git/hooks/pre-push`). A failure blocks the push.
- **In CI** — `.github/workflows/bash-tests.yml` runs it on every pull request
  and on pushes to `main`. It uses a **macOS** runner: the tests assert against
  macOS assumptions (Homebrew-rooted PATH tiers, macOS-only paths in `env.sh`),
  so a Linux runner would fail for reasons that say nothing about the code.

### The one test that inspects the real repo

`tests/test-git-config-hygiene.sh` is the exception to the isolation rule
below: it deliberately asserts against this checkout's own `.git/config`
rather than a scratch fixture, because that is the thing it guards.

It fails if the local config picks up a `user.email` / `user.name` override,
an empty `core.hooksPath`, or any remote besides `origin` — all states this
repo has actually been found in (see #239). It never writes; it only reads.

The `core.hooksPath` case is the one worth knowing about independently: an
empty value does **not** mean "unset". Git resolves it to `./`, the repo
root, where the `pre-commit/` *directory* satisfies an `[[ -x ]]` check while
git still finds no executable file to run — so every hook silently stops
firing, and local review stops with it. The test therefore checks that a
`pre-commit` regular file actually resolves, not merely that the key is unset.

That last check is machine-local, and it is skipped where no global
`core.hooksPath` is configured — a CI runner, or a machine that has not run
`install.sh` yet. The precondition is the absence of a global hooks setting
rather than `$CI`, so it states the real dependency. The config-hygiene
assertions are portable and always run; the empty-`hooksPath` bug is still
caught in a skipping environment, because that is a config check rather than
a resolution check.

### Git environment isolation (#239)

A test that creates fixture repositories must clear git's
repository-selection environment first. `tests/lib/git-env-isolation.sh`
does this:

```bash
_tests_dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-env-isolation.sh
source "${_tests_dir}/lib/git-env-isolation.sh"
isolate_git_env "${WORKDIR}"
```

**Why `cd` and `-C` are not enough.** `GIT_DIR` outranks both the process
working directory and `git -C`:

```
GIT_DIR=/elsewhere/.git git -C /tmp/scratch config user.email x@y.z
  -> writes to /elsewhere/.git/config, not /tmp/scratch
```

**Where the inherited value came from.** Git exports `GIT_DIR` into a hook's
environment when — and only when — the hook runs from a linked worktree.
`.project-hooks/pre-push` execs `tests/run-tests.sh`, so every test inherited
it, and fixture writes landed in the worktree's administrative git directory.
Linked worktrees share the common `.git/config`, so the real checkout was
contaminated with `core.hooksPath=` (empty), `core.bare=true`, a fake
identity, and a bogus `upstream` remote.

This is why the bug looked intermittent and survived three investigations: a
test run by hand has no hook, therefore no `GIT_DIR`, therefore no
contamination. Only a hook-invoked run from a worktree reproduces it.
`tests/test-git-env-isolation.sh` injects that condition deliberately, and
keeps a control case that must contaminate — otherwise the guarded assertions
would pass vacuously if the injection ever stopped working.

The helper derives its unset list from `git rev-parse --local-env-vars`
rather than hardcoding one, unioned with a fallback for older git. It
deliberately leaves `GIT_CONFIG_GLOBAL` / `GIT_CONFIG_SYSTEM` alone: those
are not repository-selection variables, and several tests set them on purpose
to point git at a sandboxed global config. Call `isolate_git_env` *before*
exporting those.

### Adding a test

Name the file `tests/test-<subject>.sh` and make it executable — that is the
whole registration step; the runner and CI pick it up on the next run.

Follow the conventions the existing tests share:

- `#!/usr/bin/env bash` shebang, then `set -euo pipefail` (or `set -uo pipefail`
  where a case deliberately expects a non-zero exit).
- `unset CDPATH` before any `cd` — with `CDPATH` set, `cd` echoes the resolved
  path to stdout and corrupts command substitutions.
- Resolve the repo root rather than assuming a working directory:
  `REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"`.
- Isolate from the real machine: scratch `$HOME` or `mktemp -d`, with a
  `trap 'rm -rf ...' EXIT` for cleanup. Never touch real git remotes, real
  `gh` auth, or the developer's actual config.
- **If the test creates or mutates a git repository, source
  `tests/lib/git-env-isolation.sh` and call `isolate_git_env "${WORKDIR}"`
  before the first git call.** A scratch directory is not a scratch repository
  when `GIT_DIR` is already set — see the section below.
- Print `PASS: <case>` / `FAIL: <case>` per assertion, track a `fail` variable,
  and `exit "${fail}"` at the end.
- Prove a stub or mock is actually intercepting before relying on it — a clean
  result from a stub that never fired proves nothing.
- Open with a comment explaining the regression the test covers and, where
  there is one, the issue number.

## Requirements

- macOS
- Bash 4.4 or newer (macOS ships 3.2; `brew install bash` gets you 5)

## License

Personal use - see LICENSE file for details.
