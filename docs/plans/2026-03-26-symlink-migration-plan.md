# Symlink Migration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Sync diverged files between `~/Developer/dotfiles` and `~/.config`, then rewrite `install.sh` to create per-file symlinks from `~/.config` into the repo.

**Architecture:** First reconcile 5 diverged files (live→repo for 3 hooks, repo cleanup for bun PATH, repo→live happens automatically once symlinks are in place). Then rewrite `install.sh` to use `git ls-files` for dynamic symlink discovery. The existing `_ensure_symlink` function handles backups.

**Tech Stack:** Bash 5.x, git

---

## Task 1: Sync pre-commit hook (live → repo)

**Files:**

- Modify: `git/hooks/pre-commit` — replace with live version from `~/.config/git/hooks/pre-commit`

The live version has two additions over the repo version:

1. A semgrep static analysis section (after pre-commit framework, before code review)
2. `-U10` context flag on `git diff --cached` for the review script

**Step 1: Copy live version into repo**

Run:

```bash
cp ~/.config/git/hooks/pre-commit ~/Developer/dotfiles/git/hooks/pre-commit
```

**Step 2: Verify the copy**

Run:

```bash
diff ~/Developer/dotfiles/git/hooks/pre-commit ~/.config/git/hooks/pre-commit
```

Expected: No output (files are identical)

**Step 3: Run shellcheck on it**

Run:

```bash
shellcheck --severity=warning ~/Developer/dotfiles/git/hooks/pre-commit
```

Expected: Clean (exit 0)

**Step 4: Commit**

```bash
git add git/hooks/pre-commit
git commit -m "sync(pre-commit): pull semgrep integration and -U10 diff context from live

Reconciles drift: live ~/.config version added semgrep static analysis
and increased diff context for code review. Pulling into repo before
symlink migration."
```

---

## Task 2: Sync pre-push hook (live → repo)

**Files:**

- Modify: `git/hooks/pre-push` — replace with live version from `~/.config/git/hooks/pre-push`

The live version has two additions:

1. `run_full_diff_review()` — adversarial-reviewer on `main...HEAD` diff (inserted after `protected_branch_check`, before PR review checkpoint)
2. `run_project_extensions()` — runs `.ralph/pre-push` if present in the repo root

**Step 1: Copy live version into repo**

Run:

```bash
cp ~/.config/git/hooks/pre-push ~/Developer/dotfiles/git/hooks/pre-push
```

**Step 2: Verify the copy**

Run:

```bash
diff ~/Developer/dotfiles/git/hooks/pre-push ~/.config/git/hooks/pre-push
```

Expected: No output (files are identical)

**Step 3: Run shellcheck on it**

Run:

```bash
shellcheck --severity=warning ~/Developer/dotfiles/git/hooks/pre-push
```

Expected: Clean (exit 0)

**Step 4: Commit**

```bash
git add git/hooks/pre-push
git commit -m "sync(pre-push): pull full-diff review and project extensions from live

Reconciles drift: live ~/.config version added full-diff review
(adversarial-reviewer on main...HEAD) and project-local pre-push
extensions (.ralph/pre-push). Pulling into repo before symlink
migration."
```

---

## Task 3: Move bun PATH into path.sh and clean .bash_profile

**Files:**

- Modify: `bash/path.sh:61-63` — add bun PATH entry at priority 2
- Modify: `bash/.bash_profile:69-71` — remove bun lines

The bun installer appended raw `export` lines to `.bash_profile`. These belong in `path.sh` using the existing `_prepend_path_once` helper at priority 2 (language-specific tools), between Ruby/Gem and Homebrew sbin.

**Step 1: Add bun to path.sh**

In `bash/path.sh`, after the Ruby/Gem block (after line 87 `fi`) and before the Step 3 comment (line 89), add:

```bash

# Bun JavaScript runtime
if [[ -d "${HOME}/.bun/bin" ]]; then
  _prepend_path_once "${HOME}/.bun/bin"
fi
```

**Step 2: Remove bun lines from .bash_profile**

In `bash/.bash_profile`, delete lines 68-71 (the empty line, comment, and two export lines):

```
(blank line)
# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"
```

The file should end at line 67 (the `fi` closing the NVM bash_completion block) plus a trailing newline.

**Step 3: Verify syntax**

Run:

```bash
bash -n ~/Developer/dotfiles/bash/path.sh && bash -n ~/Developer/dotfiles/bash/.bash_profile
```

Expected: Both clean (exit 0)

**Step 4: Run shellcheck**

Run:

```bash
shellcheck --severity=warning ~/Developer/dotfiles/bash/path.sh
shellcheck --severity=warning ~/Developer/dotfiles/bash/.bash_profile
```

Expected: Both clean

**Step 5: Commit**

```bash
git add bash/path.sh bash/.bash_profile
git commit -m "refactor(bash): move bun PATH from .bash_profile to path.sh

Bun installer appended raw export lines to .bash_profile. Moved to
path.sh at priority 2 (language-specific tools) using the existing
_prepend_path_once helper, consistent with Ruby/Gem handling."
```

---

## Task 4: Rewrite install.sh for symlink deployment

**Files:**

- Modify: `install.sh` — rewrite pre-flight check and symlink section

This is the largest task. The key changes:

1. **Pre-flight**: replace `~/.config` check with git repo root check
2. **Add `REPO_DIR` variable**: set to the script's directory (the repo root)
3. **Add `--dry-run` flag**: show what would be done without making changes
4. **Add exclusion list**: repo-only files that don't get symlinked
5. **Add config symlink loop**: iterate `git ls-files`, create per-file symlinks in `~/.config`
6. **Update Brewfile path**: reference `${REPO_DIR}/Brewfile` instead of `${HOME}/.config/Brewfile`
7. **Keep home symlinks**: the 4 `~/` → `~/.config/` symlinks stay as-is

**Step 1: Rewrite install.sh**

Replace the entire file with the following. Key differences from the original are marked with `# CHANGED` or `# NEW` comments:

```bash
#!/usr/bin/env bash
set -euo pipefail

# ~/Developer/dotfiles/install.sh
# Idempotent bootstrap script for a new macOS machine.
# Creates per-file symlinks from ~/.config into this repo.
# Every step checks before acting — safe to re-run at any time.

# ── Formatting helpers ───────────────────────────────────
_info() { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
_ok() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
_warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
_err() { printf '\033[1;31m[ERR]\033[0m   %s\n' "$*" >&2; }
_skip() {
  printf '\033[0;90m[SKIP]\033[0m  %s\n' "$*"
  skipped+=("$*")
}
_dry() { printf '\033[1;35m[DRY]\033[0m   %s\n' "$*"; }

installed=()
skipped=()
manual=()
failures=()

# ── Parse flags ──────────────────────────────────────────
DRY_RUN=false
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=true ;;
    *) _err "Unknown flag: ${arg}"; exit 1 ;;
  esac
done

# ============================================================================
# 1. PRE-FLIGHT CHECKS
# ============================================================================

detected_os="$(uname -s)" || true
if [[ "${detected_os}" != "Darwin" ]]; then
  _err "This script is designed for macOS (Darwin). Detected: ${detected_os}"
  exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Verify we're in the dotfiles repo (not some random directory)
if [[ ! -d "${REPO_DIR}/.git" ]]; then
  _err "Not a git repository: ${REPO_DIR}"
  exit 1
fi
# Canary check: verify expected files exist
if [[ ! -f "${REPO_DIR}/git/config" || ! -f "${REPO_DIR}/bash/main.sh" ]]; then
  _err "Missing expected files — is this the dotfiles repo?"
  exit 1
fi

if [[ "${EUID}" -eq 0 ]]; then
  _err "Do not run this script as root."
  exit 1
fi

_ok "Pre-flight checks passed (macOS, dotfiles repo at ${REPO_DIR}, non-root)"

if ${DRY_RUN}; then
  _info "DRY RUN — no changes will be made"
  echo ""
fi

# ============================================================================
# 2. HOMEBREW
# ============================================================================

if ${DRY_RUN}; then
  _dry "Would check/install Homebrew"
  _dry "Would run brew bundle with ${REPO_DIR}/Brewfile"
else
  if command -v brew &>/dev/null; then
    _skip "Homebrew already installed"
  else
    _info "Installing Homebrew..."
    brew_installer="$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    /bin/bash -c "${brew_installer}"
    brew_env="$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null)"
    eval "${brew_env}"
    installed+=("Homebrew")
  fi

  if ! command -v brew &>/dev/null; then
    _err "Homebrew is not available on PATH. Cannot continue."
    exit 1
  fi

  _info "Running brew bundle..."
  if brew bundle check --file="${REPO_DIR}/Brewfile" &>/dev/null; then
    _skip "All Brewfile packages already installed"
  else
    brew bundle --file="${REPO_DIR}/Brewfile"
    installed+=("Brewfile packages")
  fi
fi

# ============================================================================
# 3. CONFIG SYMLINKS (repo → ~/.config)
# ============================================================================

BACKUP_DIR="${HOME}/.config/backup"

_ensure_symlink() {
  local target="$1" link="$2"

  if [[ -L "${link}" ]]; then
    local current
    current="$(readlink "${link}")"
    if [[ "${current}" == "${target}" ]]; then
      _skip "Symlink already correct: ${link}"
      return
    fi
    _warn "Symlink ${link} points to ${current}, replacing"
  fi

  # Back up existing file/symlink if it exists and isn't the correct link
  if [[ -e "${link}" || -L "${link}" ]]; then
    mkdir -p "${BACKUP_DIR}"
    local backup_name
    backup_name="$(basename "${link}").$(date +%Y%m%d%H%M%S)"
    mv "${link}" "${BACKUP_DIR}/${backup_name}"
    _warn "Backed up ${link} to ${BACKUP_DIR}/${backup_name}"
  fi

  ln -s "${target}" "${link}"
  _ok "Created symlink: ${link} -> ${target}"
  installed+=("symlink:${link}")
}

# Files in the repo that should NOT be symlinked to ~/.config
# (repo metadata, documentation, CI workflows)
_is_excluded() {
  local file="$1"
  case "${file}" in
    .github/*) return 0 ;;
    .gitignore) return 0 ;;
    */.gitignore) return 0 ;;
    Brewfile) return 0 ;;
    README.md) return 0 ;;
    */README.md) return 0 ;;
    install.sh) return 0 ;;
    docs/*) return 0 ;;
    *) return 1 ;;
  esac
}

_info "Symlinking config files from repo to ~/.config..."

while IFS= read -r file; do
  if _is_excluded "${file}"; then
    continue
  fi

  target="${REPO_DIR}/${file}"
  link="${HOME}/.config/${file}"

  # Ensure parent directory exists in ~/.config
  link_dir="$(dirname "${link}")"
  if [[ ! -d "${link_dir}" ]]; then
    if ${DRY_RUN}; then
      _dry "Would create directory: ${link_dir}"
    else
      mkdir -p "${link_dir}"
    fi
  fi

  if ${DRY_RUN}; then
    if [[ -L "${link}" ]]; then
      local current
      current="$(readlink "${link}")"
      if [[ "${current}" == "${target}" ]]; then
        _skip "Symlink already correct: ${link}"
      else
        _dry "Would replace symlink: ${link} (currently -> ${current})"
      fi
    elif [[ -f "${link}" ]]; then
      _dry "Would backup and replace: ${link}"
    else
      _dry "Would create symlink: ${link} -> ${target}"
    fi
  else
    _ensure_symlink "${target}" "${link}"
  fi
done < <(git -C "${REPO_DIR}" ls-files)

# ============================================================================
# 4. HOME DIRECTORY SYMLINKS (~ → ~/.config)
# ============================================================================
# These tools look for config files in ~/ rather than ~/.config/

_info "Ensuring home directory symlinks..."

if ${DRY_RUN}; then
  _dry "Would ensure: ~/.bash_profile -> ~/.config/bash/.bash_profile"
  _dry "Would ensure: ~/.digrc -> ~/.config/dig/digrc"
  _dry "Would ensure: ~/.shellcheckrc -> ~/.config/shellcheck/.shellcheckrc"
  _dry "Would ensure: ~/.markdownlint.json -> ~/.config/markdownlint-cli/.markdownlint.json"
else
  _ensure_symlink "${HOME}/.config/bash/.bash_profile" "${HOME}/.bash_profile"
  _ensure_symlink "${HOME}/.config/dig/digrc" "${HOME}/.digrc"
  _ensure_symlink "${HOME}/.config/shellcheck/.shellcheckrc" "${HOME}/.shellcheckrc"
  _ensure_symlink "${HOME}/.config/markdownlint-cli/.markdownlint.json" "${HOME}/.markdownlint.json"
fi

# ============================================================================
# 5. CREATE DIRECTORIES
# ============================================================================

for dir in "${HOME}/.local/bin" "${HOME}/.local/state/bash"; do
  if ${DRY_RUN}; then
    if [[ -d "${dir}" ]]; then
      _skip "Directory exists: ${dir}"
    else
      _dry "Would create directory: ${dir}"
    fi
  else
    if [[ -d "${dir}" ]]; then
      _skip "Directory exists: ${dir}"
    else
      mkdir -p "${dir}"
      _ok "Created directory: ${dir}"
      installed+=("dir:${dir}")
    fi
  fi
done

# ============================================================================
# 6. PIPX PACKAGES
# ============================================================================

if ${DRY_RUN}; then
  _dry "Would check/install pipx package: argcomplete"
else
  if ! command -v pipx &>/dev/null; then
    _warn "pipx not found — skipping pipx packages"
    manual+=("Install pipx, then run: pipx install argcomplete")
  else
    if pipx list --short 2>/dev/null | grep -q "^argcomplete "; then
      _skip "pipx package already installed: argcomplete"
    else
      _info "Installing pipx package: argcomplete"
      pipx install argcomplete
      installed+=("pipx:argcomplete")
    fi
  fi
fi

# ============================================================================
# 7. NVM (Node Version Manager)
# ============================================================================

NVM_VERSION="v0.40.4"
if ${DRY_RUN}; then
  if [[ -d "${HOME}/.nvm" ]]; then
    _skip "NVM already installed at ~/.nvm"
  else
    _dry "Would install NVM ${NVM_VERSION}"
  fi
else
  if [[ -d "${HOME}/.nvm" ]]; then
    _skip "NVM already installed at ~/.nvm"
  else
    _info "Installing NVM ${NVM_VERSION}..."
    nvm_installer="$(curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh")"
    PROFILE=/dev/null bash -c "${nvm_installer}"
    if [[ ! -d "${HOME}/.nvm" ]]; then
      _warn "NVM installation may have failed — ~/.nvm not found"
      failures+=("nvm-install")
    else
      installed+=("NVM ${NVM_VERSION}")
    fi
  fi
fi

# ============================================================================
# 8. SECRETS STUB
# ============================================================================

SECRETS_FILE="${HOME}/.config/bash/secrets.sh"
if ${DRY_RUN}; then
  if [[ -f "${SECRETS_FILE}" ]]; then
    _skip "Secrets file already exists: ${SECRETS_FILE}"
  else
    _dry "Would create secrets stub: ${SECRETS_FILE}"
  fi
else
  if [[ -f "${SECRETS_FILE}" ]]; then
    _skip "Secrets file already exists: ${SECRETS_FILE}"
  else
    cat >"${SECRETS_FILE}" <<'SECRETS_EOF'
# ~/.config/bash/secrets.sh
#shellcheck shell=bash
# This file is sourced by main.sh but EXCLUDED from git.
# Put API keys, tokens, and other secrets here.
# Example:
#   export GITHUB_TOKEN="ghp_..."
#   export OPENAI_API_KEY="sk-..."
SECRETS_EOF
    chmod 600 "${SECRETS_FILE}"
    _ok "Created secrets stub: ${SECRETS_FILE} (mode 600)"
    installed+=("secrets stub")
  fi
fi

# ============================================================================
# 9. POST-INSTALL SMOKE TEST
# ============================================================================

if ${DRY_RUN}; then
  _dry "Would run smoke tests"
else
  _info "Running smoke tests..."

  for cmd in git bash shellcheck shfmt pre-commit vim gh; do
    if command -v "${cmd}" &>/dev/null; then
      _ok "Found: ${cmd}"
    else
      _warn "Missing: ${cmd}"
      failures+=("${cmd}")
    fi
  done

  bash_version="$(bash --version | head -1)"
  if [[ "${bash_version}" == *"version 5"* || "${bash_version}" == *"version 6"* ]]; then
    _ok "Bash 5+ detected"
  else
    _warn "Bash may not be 5+: ${bash_version}"
    failures+=("bash-version")
  fi

  hooks_path="$(git config --global core.hooksPath 2>/dev/null || true)"
  if [[ -n "${hooks_path}" ]]; then
    _ok "Git hooksPath configured: ${hooks_path}"
  else
    _warn "Git core.hooksPath not set"
    failures+=("git-hooksPath")
  fi

  # Verify symlinks resolve correctly
  _info "Verifying symlink chain..."
  broken_links=0
  while IFS= read -r file; do
    if _is_excluded "${file}"; then
      continue
    fi
    link="${HOME}/.config/${file}"
    if [[ -L "${link}" ]] && [[ ! -e "${link}" ]]; then
      _warn "Broken symlink: ${link}"
      broken_links=$((broken_links + 1))
    fi
  done < <(git -C "${REPO_DIR}" ls-files)
  if [[ "${broken_links}" -eq 0 ]]; then
    _ok "All config symlinks resolve correctly"
  else
    _warn "${broken_links} broken symlink(s) found"
    failures+=("broken-symlinks")
  fi
fi

# ============================================================================
# 10. SUMMARY
# ============================================================================

echo ""
echo "═══════════════════════════════════════════════════════"
echo " Bootstrap Summary"
echo "═══════════════════════════════════════════════════════"

if ${DRY_RUN}; then
  _info "DRY RUN complete — no changes were made"
fi

if [[ ${#installed[@]} -gt 0 ]]; then
  _info "Installed/created:"
  for item in "${installed[@]}"; do
    echo "  + ${item}"
  done
fi

if [[ ${#skipped[@]} -gt 0 ]]; then
  echo ""
  _info "Skipped (already present):"
  for item in "${skipped[@]}"; do
    echo "  - ${item}"
  done
fi

if [[ ${#failures[@]} -gt 0 ]]; then
  echo ""
  _warn "Smoke test issues:"
  for item in "${failures[@]}"; do
    echo "  ! ${item}"
  done
fi

echo ""
echo "── Manual steps (cannot be automated) ──────────────"
echo "  1. Claude Code setup (~/.claude/ infrastructure)"
echo "  2. Headroom LaunchAgent configuration"
echo "  3. iTerm2 shell integration (Install Shell Integration from menu)"
echo "  4. source ~/.bash_profile   # activate the new shell config"

if [[ ${#manual[@]} -gt 0 ]]; then
  for item in "${manual[@]}"; do
    echo "  * ${item}"
  done
fi

echo ""
if [[ ${#failures[@]} -eq 0 ]]; then
  _ok "Bootstrap complete!"
else
  _warn "Bootstrap complete with ${#failures[@]} issue(s) — see above."
fi
```

**Step 2: Verify syntax**

Run:

```bash
bash -n ~/Developer/dotfiles/install.sh
```

Expected: Clean (exit 0)

**Step 3: Run shellcheck**

Run:

```bash
shellcheck --severity=warning ~/Developer/dotfiles/install.sh
```

Expected: Clean (exit 0). Note: if shellcheck flags the `local current` inside the dry-run `if` block, extract it or suppress as needed.

**Step 4: Commit**

```bash
git add install.sh
git commit -m "feat(install): rewrite for symlink deployment from repo to ~/.config

install.sh now runs from ~/Developer/dotfiles (any repo location) and
creates per-file symlinks in ~/.config using dynamic discovery via
git ls-files. Repo-only files (.github/*, README, docs/*, etc.) are
excluded. Existing files are backed up before replacement.

New features:
- --dry-run flag shows what would be done
- Symlink health check in smoke tests
- No longer requires repo to be cloned to ~/.config"
```

---

## Task 5: Update README.md setup instructions

**Files:**

- Modify: `README.md` — update clone path and install instructions

**Step 1: Find and update the setup instructions**

In `README.md`, find the setup/installation section. Change:

```
git clone git@github.com:smartwatermelon/dotfiles.git ~/.config
~/.config/install.sh
```

To:

```
git clone git@github.com:smartwatermelon/dotfiles.git ~/Developer/dotfiles
~/Developer/dotfiles/install.sh
```

Also update any references to "rooted at `~/.config/`" to explain the symlink model: files live in `~/Developer/dotfiles` and are symlinked into `~/.config`.

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: update setup instructions for symlink-based deployment"
```

---

## Task 6: Dry-run and verify

**Step 1: Run install.sh --dry-run**

Run:

```bash
bash ~/Developer/dotfiles/install.sh --dry-run
```

Expected: Lists all files that would be symlinked, directories that would be created, and backup operations. No actual changes made. Review the output carefully — every tracked config file should appear, and no repo-only files (README, .gitignore, etc.) should appear.

**Step 2: Verify exclusions are correct**

Run:

```bash
git -C ~/Developer/dotfiles ls-files | while read -r f; do
  case "${f}" in
    .github/*|.gitignore|*/.gitignore|Brewfile|README.md|*/README.md|install.sh|docs/*) echo "EXCLUDE: ${f}" ;;
    *) echo "SYMLINK: ${f}" ;;
  esac
done
```

Expected: All repo-only files show as EXCLUDE, all config files show as SYMLINK. Spot-check: `git/config` → SYMLINK, `README.md` → EXCLUDE, `bash/main.sh` → SYMLINK, `.github/workflows/claude.yml` → EXCLUDE.

---

## Task 7: Run install.sh for real

**Step 1: Run install.sh**

Run:

```bash
bash ~/Developer/dotfiles/install.sh
```

Expected: Each config file in `~/.config` that was a regular file gets backed up and replaced with a symlink. Files that were already correct symlinks are skipped. Summary shows installed/skipped counts.

**Step 2: Verify symlinks**

Run:

```bash
ls -la ~/.config/git/config ~/.config/bash/main.sh ~/.config/git/hooks/lint-shell.sh
```

Expected: All three show as symlinks pointing to `~/Developer/dotfiles/...`

**Step 3: Verify non-tracked files are untouched**

Run:

```bash
ls -la ~/.config/karabiner/karabiner.json ~/.config/gh/hosts.yml ~/.config/bash/secrets.sh
```

Expected: All three are regular files (not symlinks), unchanged.

**Step 4: Source bash profile and verify**

Run:

```bash
source ~/.bash_profile
echo $PATH | tr ':' '\n' | grep -i bun
```

Expected: Shows bun path (loaded from `path.sh` now, not `.bash_profile`)

**Step 5: Test git hooks still work**

Run:

```bash
echo "test" >> /tmp/test-hook.sh && shellcheck /tmp/test-hook.sh 2>&1; rm /tmp/test-hook.sh
```

The real test is that the next commit in any repo uses the symlinked hooks. This will be verified naturally when we commit.

---

## Task 8: Remove old repo metadata from ~/.config

**Step 1: Check if ~/.config/.git exists and matches our repo**

Run:

```bash
if [[ -d ~/.config/.git ]]; then
  remote="$(git -C ~/.config remote get-url origin 2>/dev/null || echo 'unknown')"
  echo "Found .git in ~/.config, remote: ${remote}"
else
  echo "No .git directory in ~/.config — nothing to do"
fi
```

**Step 2: If it exists and matches, prompt user and remove**

Only proceed if the remote contains `smartwatermelon/dotfiles`. Ask the user for confirmation before running:

```bash
rm -rf ~/.config/.git
```

**Step 3: Commit the full migration (on the branch)**

```bash
git add -A
git commit -m "chore: complete symlink migration from ~/.config to ~/Developer/dotfiles"
```

(Only if there are any remaining changes from the migration.)

---

## Verification Checklist

- [ ] `diff` between repo and `~/.config` for synced files shows no differences (they're the same file via symlink)
- [ ] `git/hooks/lint-shell.sh` in `~/.config` has the issue #18 fix (symlinked from repo)
- [ ] `git/hooks/pre-commit` in `~/.config` has semgrep integration (synced into repo, then symlinked)
- [ ] `git/hooks/pre-push` in `~/.config` has full-diff review (synced into repo, then symlinked)
- [ ] `bash/path.sh` includes bun PATH at priority 2
- [ ] `bash/.bash_profile` has no bun lines
- [ ] `~/.config/karabiner/`, `~/.config/claude-code/`, etc. are untouched
- [ ] `~/.config/gh/hosts.yml` is untouched (not symlinked, not deleted)
- [ ] `~/.config/bash/secrets.sh` is untouched
- [ ] `install.sh --dry-run` works without making changes
- [ ] `source ~/.bash_profile` works
- [ ] Git hooks fire on next commit
- [ ] `shellcheck` and `shfmt` clean on all modified shell scripts
