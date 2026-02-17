# dotfiles

Unified configuration files, rooted at `~/.config/`.

## Structure

```
~/.config/
├── bash/            Shell config (profile, aliases, functions, path, prompt)
├── btop/            System monitor
├── dig/             DNS lookup defaults
├── gh/              GitHub CLI (config.yml only — auth excluded)
├── git/             Git config, global ignore, hooks, templates
├── markdownlint-cli/  Markdown linting rules
├── pre-commit/      Pre-commit framework config
├── s/               s (web search from terminal)
├── shellcheck/      Shell script linting
├── tidy/            HTML tidy
├── vim/             Vim config, plugins, colorscheme
├── yamllint/        YAML linting
└── yt-dlp/          Video downloader defaults
```

53 tracked files across 13 directories.

Directories that exist under `~/.config/` but are **not** tracked (managed by their own tools, contain secrets, or are ephemeral): `claude-code/`, `configstore/`, `iterm2/`, `jgit/`, `npm/`, `op/`, `rclone/`, `cagent/`.

## Symlinks

Some tools expect config in `~/` rather than `~/.config/`. These symlinks bridge the gap:

| Symlink | Target |
|---------|--------|
| `~/.bash_profile` | `~/.config/bash/.bash_profile` |
| `~/.digrc` | `~/.config/dig/digrc` |
| `~/.shellcheckrc` | `~/.config/shellcheck/.shellcheckrc` |

Git, vim, yamllint, btop, gh, and yt-dlp all read from `~/.config/` natively via XDG conventions or built-in support.

## Gitignore strategy

The root `.gitignore` uses a **default-ignore, explicit-allow** pattern:

```gitignore
/*              # Ignore everything by default
!bash/          # Explicitly allow tracked directories
!btop/
...
```

This means new directories added to `~/.config/` are automatically ignored. You must add an `!dirname/` entry to track a new directory. This prevents accidental commits of secrets or tool-generated state.

Additional safety layers:

- **Per-directory `.gitignore` files** in `bash/`, `git/`, `gh/`, etc. handle directory-specific exclusions (e.g., `bash/secrets.sh`, `gh/hosts.yml`)
- **Global exclusion patterns** catch secrets regardless of location: `**/*.key`, `**/*.pem`, `**/secrets.*`, `**/.env`, etc.

## History

### Previous structure (Aug 2025 -- Feb 2026)

Each config directory was its own GitHub repository:

| Repository | Commits | Visibility |
|-----------|---------|------------|
| `bash-config` | 5 | Public |
| `btop-config` | 2 | Private |
| `dig-config` | 2 | Private |
| `git-config` | 62 | Public |
| `markdownlint-config` | 3 | Private |
| `pre-commit-config` | 3 | Private |
| `shellcheck-config` | 4 | Private |
| `tidy-config` | 2 | Private |
| `vim-config` | 7 | Private |
| `yamllint-config` | 2 | Private |
| `yt-dlp-config` | 2 | Private |

This worked but had friction: 11 repos to manage, 11 sets of branches and PRs for what amounts to one machine's configuration. Cross-cutting changes (like updating lint rules that affect multiple configs) required coordinating across repos.

### Consolidation (Feb 2026)

Merged all 11 into this single `dotfiles` repo. Decisions made during the merge:

**History preservation.** `git-config` had 62 meaningful commits spanning 6 months of hook development, security hardening, and template work. Its history was preserved using `git-filter-repo`, rewriting file paths into a `git/` subdirectory. The other 10 repos had 2--7 commits each (initial commit + minor tweaks) — not worth the complexity of preserving, so they got a fresh start.

**PII scrubbing.** The preserved `git-config` history had a personal email in commit metadata (62 commits authored with `andrew.rich@gmail.com`). A mailmap rewrite replaced all instances with the GitHub noreply address. Commit messages referencing private repo names were also redacted.

**Public repo cleanup.** `git-config` and `bash-config` were public repositories. `git-config` had PII in its commit history and references to private repo names. Both were made private before archiving.

**Config fixes during migration.** `dig/digrc` had contradictory options (`+stats` immediately overridden by `+nostats`) and globally-breaking defaults (`+nssearch` and `+norecurse` change `dig`'s fundamental behavior). These were cleaned up during the consolidation. `vim/README.md` had minor markdown formatting issues fixed by the pre-commit linter.

**What didn't change.** No file paths moved. Every tool reads from the exact same `~/.config/<tool>/` path as before. Symlinks are unchanged. Git hooks at `~/.config/git/hooks/` still work. The consolidation was purely a repository structure change.

All 11 original repositories were archived on GitHub after the merge.

## Git hooks

This repo uses global git hooks from `~/.config/git/hooks/`. See `git/README.md` for details on the hook system, which includes:

- **Pre-commit**: Linting (shell, YAML, markdown, HTML), formatting (black, prettier), and automated code review
- **Pre-push**: Push-target validation (blocks direct pushes to `main`)
- **Commit-msg**: Conventional commit format enforcement

## Setup on a new machine

```bash
# Clone
git clone git@github.com:smartwatermelon/dotfiles.git ~/.config

# Create symlinks
ln -sf ~/.config/bash/.bash_profile ~/.bash_profile
ln -sf ~/.config/dig/digrc ~/.digrc
ln -sf ~/.config/shellcheck/.shellcheckrc ~/.shellcheckrc

# Reload shell
source ~/.bash_profile
```

Tools that use XDG conventions (`git`, `vim`, `btop`, `yamllint`, `gh`, `yt-dlp`) will find their config automatically.
