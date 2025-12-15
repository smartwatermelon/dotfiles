# Git Configuration

Personal git configuration with custom hooks, optimized diff settings, and modern best practices.

## Overview

This directory contains centralized git configuration that applies to all repositories on this system.

**Location**: `~/.config/git/`
**XDG**: Git automatically uses `~/.config/git/config` per XDG Base Directory spec

## Structure

```
git/
├── config              # Main git configuration
├── gitignore_global    # Global gitignore patterns
├── ignore              # Additional ignore patterns
├── hooks/              # Custom git hooks
│   ├── lint-shell.sh   # Shell script linting with auto-fix
│   ├── pre-commit      # Pre-commit hook (delegates to repo or global)
│   └── pre-push        # Pre-push hook (syncs configs to GitHub repos)
└── README.md           # This file
```

## Configuration Highlights

### Diff & Merge Settings

- **Algorithm**: `histogram` - Better rename detection than default Myers algorithm
- **Conflict style**: `zdiff3` - Shows original + both sides + common ancestor
- **Custom prefixes**: `SRC` and `DST` instead of `a/` and `b/` for better readability
- **Color moved**: Highlights moved code blocks in diffs
- **Mnemonic prefixes**: Uses `i/` (index) and `w/` (working tree) prefixes

### Performance Optimizations

- **fsmonitor**: File system monitor for faster status in large repos
- **untrackedCache**: Caches list of untracked files for performance
- **Auto-correct**: Prompts before running autocorrected commands

### Workflow Settings

- **Default branch**: `main` (not `master`)
- **Pull strategy**: Rebase (cleaner history than merge commits)
- **Push behavior**:
  - `autoSetupRemote` - Automatically sets up tracking
  - `followTags` - Pushes annotated tags with commits
- **Fetch behavior**:
  - Prunes stale remote-tracking branches
  - Prunes stale tags
  - Fetches from all remotes (not just origin)

### Rebase Settings

- **autoSquash**: Automatically reorders and marks fixup! commits
- **autoStash**: Stashes uncommitted changes before rebase
- **updateRefs**: Updates branch pointers during rebase

### Conflict Resolution

- **rerere** (reuse recorded resolution): Remembers how you resolved conflicts and auto-applies them if they recur

## Git Hooks

All hooks are configured via `core.hooksPath` to use this directory instead of per-repo `.git/hooks/`.

### pre-commit

**Purpose**: Delegates to repository-local pre-commit framework configuration
**File**: `hooks/pre-commit`

**Behavior**:

1. Checks if repo has `.pre-commit-config.yaml`
2. If yes: Runs `pre-commit run` (repo-specific hooks)
3. If no: Runs global linting (fallback to `lint-shell.sh`)

**Integration**: Works with [pre-commit framework](https://pre-commit.com/) configurations in individual repos

### pre-push

**Purpose**: Syncs configuration files to GitHub repos before pushing
**File**: `hooks/pre-push`

**Behavior**:

1. Detects if remote is GitHub
2. Checks if `.github/workflows/` exists and uses config files
3. Creates/updates hardlinks from global configs to `.github/workflows/`:
   - `.shellcheckrc` → `${HOME}/.config/shellcheck/.shellcheckrc`
   - `.yamllint` → `${HOME}/.config/yamllint/config`
4. Stages updated configs for inclusion in push
5. Falls back to copying if hardlinks fail (cross-filesystem)

**Why**: Ensures CI workflows use same linting rules as local development

### lint-shell.sh

**Purpose**: Auto-fix shell scripts with shellcheck + shfmt
**File**: `hooks/lint-shell.sh`

**Tools used**:

- **shellcheck**: Static analysis and linting
- **shfmt**: Formatting (2-space indent, case indent, binary ops on left)

**Behavior**:

1. Runs shellcheck in diff mode for each shell file
2. Applies auto-fixes using patch
3. Runs shfmt for formatting
4. Reports summary: ✅ fixed, ❌ remaining issues, 🎉 clean
5. Exits non-zero if unfixable issues remain

**Exclusions**:

- SC2312 globally excluded (command substitution masking exit codes)

**Temporary files**: Creates atomic temp files in same directory, cleaned up via trap

## Ignores

### gitignore_global

System-wide gitignore patterns that apply to all repos:

- OS artifacts (.DS_Store, Thumbs.db)
- Editor files (.vscode/, .idea/, *.swp)
- Common build artifacts

**Path**: Set in `core.excludesfile`

### ignore

Additional local ignore patterns for this config directory.

## Best Practices

### When to Edit

- **User identity** (`user.name`, `user.email`): Set before first commit
- **Aliases**: Add frequently-used command shortcuts under `[alias]`
- **Diff settings**: Customize diff algorithm or color scheme
- **Hooks**: Modify hook behavior or add new hooks

### When NOT to Edit

- **Per-repo settings**: Use repo's `.git/config` for repo-specific settings
- **Credentials**: Use credential helpers, not plain config
- **Experimental settings**: Test in a scratch repo first

## Troubleshooting

### Hooks not running

Check that `core.hooksPath` points to this directory:

```bash
git config --get core.hooksPath
# Should output: /Users/andrewrich/.config/git/hooks
```

### Pre-commit hook fails

If pre-commit framework is not installed:

```bash
pipx install pre-commit
```

For repo-specific hooks, run:

```bash
pre-commit install
```

### Shellcheck issues

Install shellcheck and shfmt:

```bash
brew install shellcheck shfmt
```

### Config not applying

Verify config file location:

```bash
git config --list --show-origin | grep config
```

## References

- [Git SCM Documentation](https://git-scm.com/docs/git-config)
- [How Git Core Devs Configure Git](https://blog.gitbutler.com/how-git-core-devs-configure-git/)
- [Pre-commit Framework](https://pre-commit.com/)
- [ShellCheck](https://www.shellcheck.net/)
- [shfmt](https://github.com/mvdan/sh)
