# Pre-commit Framework Configuration

Centralized linting configuration using the [pre-commit framework](https://pre-commit.com/) for consistent code quality across all projects.

## Overview

This directory contains the default pre-commit configuration that can be used as a template or fallback for projects that don't have their own `.pre-commit-config.yaml`.

**Location**: `~/.config/pre-commit/`
**Framework**: [pre-commit.com](https://pre-commit.com/)

## Structure

```
pre-commit/
├── config.yaml    # Pre-commit hooks configuration
└── README.md      # This file
```

## Configured Linters

### Python

**Black** (Formatter)

- **Repo**: <https://github.com/psf/black>
- **Version**: 25.1.0
- **Args**: `--quiet`
- **Purpose**: Opinionated Python code formatter
- **When**: Runs on all Python files

**Flake8** (Linter)

- **Repo**: <https://github.com/PyCQA/flake8>
- **Version**: 7.3.0
- **Extensions**: flake8-bugbear (additional checks for common bugs)
- **Purpose**: Style guide enforcement (PEP 8)
- **When**: Runs on all Python files

### Shell Scripts

**Shell Lint & Auto-Fix**

- **Type**: Local hook
- **Entry**: `$HOME/.config/git/hooks/lint-shell.sh`
- **Tools**: shellcheck (static analysis) + shfmt (formatting)
- **Purpose**: Lint and auto-format shell scripts
- **Settings**:
  - 2-space indentation
  - Case statement indentation
  - Binary operators on left side
  - SC2312 excluded (command substitution exit codes)
- **When**: Runs on all shell script files
- **Output**: Summary with ✅ (fixed), ❌ (issues), 🎉 (clean)

### YAML

**yamllint**

- **Type**: System tool
- **Entry**: `yamllint`
- **Config**: Uses `~/.config/yamllint/config`
- **Purpose**: Lints YAML syntax and style
- **When**: Runs on all YAML files
- **Settings**:
  - Extends "relaxed" ruleset
  - Max line length: 120 characters

### HTML

**HTML Tidy**

- **Type**: System tool
- **Entry**: `tidy -q -e`
- **Config**: Uses `$HOME/.config/tidy/tidyrc`
- **Purpose**: Validates HTML5 syntax
- **When**: Runs on all HTML files
- **Settings**:
  - HTML5 doctype
  - Allows modern attributes (decoding, loading, etc.)
  - Quiet mode (errors only)

### Markdown

**markdownlint-cli**

- **Repo**: <https://github.com/igorshubovych/markdownlint-cli>
- **Version**: v0.45.0
- **Args**: `--fix`, `--config ~/.config/markdownlint-cli/.markdownlint.json`
- **Purpose**: Lints and fixes Markdown style
- **When**: Runs on all Markdown files
- **Settings**:
  - MD013 disabled (line length - too strict for prose)
  - MD024 siblings_only (allows duplicate headings in different sections)
  - Other rules disabled for documentation flexibility

## Usage

### In a New Project

Copy this config to your project root:

```bash
cp ~/.config/pre-commit/config.yaml .pre-commit-config.yaml
```

Install the hooks:

```bash
pre-commit install
```

### Testing Hooks

Run all hooks on all files:

```bash
pre-commit run --all-files
```

Run specific hook:

```bash
pre-commit run black --all-files
pre-commit run shell-lint-fix --all-files
```

Run on staged files only (normal behavior):

```bash
pre-commit run
```

### Updating Hook Versions

Update to latest versions:

```bash
pre-commit autoupdate
```

This updates the `rev:` fields in the config to the latest tags.

## Hook Dependencies

### Required System Tools

**For shell linting**:

```bash
brew install shellcheck shfmt
```

**For YAML linting**:

```bash
brew install yamllint
```

**For HTML validation**:

```bash
brew install tidy-html5
```

### Framework Installation

Install pre-commit itself (recommended via pipx):

```bash
pipx install pre-commit
```

Or via Homebrew:

```bash
brew install pre-commit
```

## Configuration Details

### Local vs Remote Hooks

**Remote hooks** (Python, Markdown):

- Downloaded and managed by pre-commit framework
- Isolated in their own virtualenvs
- Versioned via git tags
- Automatically cached

**Local/System hooks** (Shell, YAML, HTML):

- Use system-installed tools
- Faster execution (no virtual environment overhead)
- Must be manually installed on all machines

### Pass Filenames

All hooks use `pass_filenames: true`, meaning:

- Only modified files are checked (fast)
- Can be overridden with `--all-files`

### Verbose Mode

All hooks use `verbose: true` for detailed output during runs.

## Integration with Git Hooks

This config works with the global git `pre-commit` hook at `~/.config/git/hooks/pre-commit`, which:

1. Checks if a repo has `.pre-commit-config.yaml`
2. If yes: runs `pre-commit run` (repo-specific config)
3. If no: uses this global config as fallback

This means repos can override these settings with their own `.pre-commit-config.yaml`, while repos without one still get basic linting.

## Customization

### Per-Project Overrides

Projects can override these settings by:

1. Creating `.pre-commit-config.yaml` in repo root
2. Modifying hook `args` or adding new hooks
3. Disabling specific hooks with `exclude` patterns

### Adding New Hooks

Find more hooks at:

- [Pre-commit hooks repository](https://github.com/pre-commit/pre-commit-hooks)
- [Supported hooks catalog](https://pre-commit.com/hooks.html)

Example of adding a new hook:

```yaml
- repo: https://github.com/pre-commit/mirrors-prettier
  rev: v3.0.0
  hooks:
    - id: prettier
      name: Prettier (JS/JSON formatter)
```

### Excluding Files

Use `exclude` to skip specific files:

```yaml
- id: black
  exclude: ^migrations/
```

## Troubleshooting

### Hook fails with "command not found"

Install the required system tool:

```bash
# For shellcheck issues
brew install shellcheck shfmt

# For yamllint issues
brew install yamllint

# For tidy issues
brew install tidy-html5
```

### Hooks not running

Ensure pre-commit is installed in the repo:

```bash
pre-commit install
```

### Slow hook execution

Skip expensive hooks temporarily:

```bash
SKIP=black,flake8 git commit -m "message"
```

### Hook auto-fix conflicts

If a hook auto-fixes files, you'll need to:

1. Review the changes
2. Stage them: `git add -u`
3. Re-run: `git commit`

### Clear hook cache

If hooks are behaving strangely:

```bash
pre-commit clean
pre-commit install --install-hooks
```

## References

- [Pre-commit Documentation](https://pre-commit.com/)
- [Supported Hooks](https://pre-commit.com/hooks.html)
- [Black Formatter](https://black.readthedocs.io/)
- [Flake8 Docs](https://flake8.pycqa.org/)
- [ShellCheck Wiki](https://www.shellcheck.net/wiki/)
- [yamllint Docs](https://yamllint.readthedocs.io/)
- [markdownlint Rules](https://github.com/DavidAnson/markdownlint/blob/main/doc/Rules.md)
