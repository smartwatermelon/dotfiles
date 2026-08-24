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

- **On push** — `.ralph/pre-push` runs the suite via the pre-push hook's
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
