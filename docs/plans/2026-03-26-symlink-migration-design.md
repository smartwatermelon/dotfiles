# Symlink Migration Design

## Goal

Decouple the dotfiles repo (`~/Developer/dotfiles`) from the live config directory (`~/.config`) by replacing copied files with per-file symlinks. Eliminate drift, protect non-tracked files, and allow the repo to live in a normal development location.

## Current State

- Repo at `~/Developer/dotfiles`, live config at `~/.config` — two independent copies
- 53 tracked files, 5 have drifted between copies
- `~/.config` also contains 10+ unrelated app config directories (karabiner, claude-code, op, etc.)
- `install.sh` requires being cloned directly to `~/.config`
- 4 home directory symlinks (`~/.bash_profile`, etc.) point into `~/.config`

## Architecture

**Per-file symlinks from `~/.config/<path>` to `~/Developer/dotfiles/<path>`.**

- Directories in `~/.config` are real directories (created by `install.sh` if missing)
- Only tracked config files become symlinks — non-tracked files in the same directories are untouched
- Home directory symlinks (`~/.bash_profile` → `~/.config/bash/.bash_profile`) stay as-is, creating a two-hop chain that resolves transparently
- Symlink list is derived dynamically from `git ls-files` with an exclusion list for repo-only files

**Exclusion list** (repo meta-files, no symlink created):

```
.github/*
.gitignore
*/.gitignore
Brewfile
README.md
*/README.md
install.sh
docs/*
```

## Two-Way Sync (pre-migration)

Before creating symlinks, reconcile the 5 diverged files in a single commit:

| File | Direction | Detail |
|------|-----------|--------|
| `git/hooks/pre-commit` | Live → Repo | Adds semgrep integration, `-U10` diff context |
| `git/hooks/pre-push` | Live → Repo | Adds full-diff review, project-local extensions |
| `bash/path.sh` | Add to Repo | Bun PATH entry at priority 2 via `_prepend_path_once` |
| `bash/.bash_profile` | Clean up | Remove bun lines (moved to `path.sh`) |
| `git/hooks/lint-shell.sh` | Repo → Live | Issue #18 fix, deployed via symlink |
| `.github/workflows/*` | Repo → Live | Newer blocking review version, deployed via symlink |

## install.sh Rewrite

New flow:

1. **Pre-flight** — macOS, non-root, verify git repo root (check for `.git`, canary files `git/config` and `bash/main.sh`)
2. **Homebrew + Brewfile** — unchanged
3. **Config symlinks** — for each file from `git ls-files` minus exclusions, ensure `~/.config/<path>` symlinks to `~/Developer/dotfiles/<path>`. Create parent directories as needed. Back up any existing regular file to `~/.config/backup/` before replacing.
4. **Home symlinks** — the 4 existing `~/` → `~/.config/` symlinks, unchanged
5. **Directories, pipx, NVM, secrets stub** — unchanged
6. **Smoke tests + summary** — unchanged

**New flag:** `--dry-run` shows what would be done without making changes.

## Cutover Procedure

1. **Sync commit** — copy 3 live-ahead files into repo, add bun to `path.sh`, remove bun from `.bash_profile`
2. **Rewrite `install.sh`** — dynamic discovery, repo-root pre-flight, per-file symlinks, `--dry-run` flag
3. **Dry-run** — `install.sh --dry-run`, review output
4. **Run `install.sh`** — replaces regular files with symlinks, backs up originals
5. **Verify** — source `~/.bash_profile`, smoke tests, spot-check symlinks
6. **Remove old repo metadata** — only if `~/.config/.git` exists and its origin remote matches `smartwatermelon/dotfiles`. Prompt for confirmation. Never touch `.git` directories in subdirectories.

**Rollback:** restore any file from `~/.config/backup/`.
