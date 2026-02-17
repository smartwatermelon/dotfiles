#!/usr/bin/env bash
set -euo pipefail

# ~/.config/install.sh
# Idempotent bootstrap script for a new macOS machine.
# Every step checks before acting — safe to re-run at any time.

# ── Formatting helpers ───────────────────────────────────
_info() { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
_ok() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
_warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
_err() { printf '\033[1;31m[ERR]\033[0m   %s\n' "$*" >&2; }
_skip() { printf '\033[0;90m[SKIP]\033[0m  %s\n' "$*"; }

installed=()
skipped=()
manual=()

# ============================================================================
# 1. PRE-FLIGHT CHECKS
# ============================================================================

detected_os="$(uname -s)" || true
if [[ "${detected_os}" != "Darwin" ]]; then
  _err "This script is designed for macOS (Darwin). Detected: ${detected_os}"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${SCRIPT_DIR}" != "${HOME}/.config" ]]; then
  _err "This script must be run from ~/.config (got ${SCRIPT_DIR})"
  _err "Clone the repo first: git clone git@github.com:smartwatermelon/dotfiles.git ~/.config"
  exit 1
fi

if [[ "${EUID}" -eq 0 ]]; then
  _err "Do not run this script as root."
  exit 1
fi

_ok "Pre-flight checks passed (macOS, ~/.config, non-root)"

# ============================================================================
# 2. HOMEBREW
# ============================================================================

if command -v brew &>/dev/null; then
  _skip "Homebrew already installed"
else
  _info "Installing Homebrew..."
  brew_installer="$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || true
  /bin/bash -c "${brew_installer}"
  # Ensure brew is on PATH for the rest of this script
  brew_env="$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null)" || true
  eval "${brew_env}"
  installed+=("Homebrew")
fi

_info "Running brew bundle..."
if brew bundle check --file="${HOME}/.config/Brewfile" &>/dev/null; then
  _skip "All Brewfile packages already installed"
else
  brew bundle --file="${HOME}/.config/Brewfile"
  installed+=("Brewfile packages")
fi

# ============================================================================
# 3. SYMLINKS
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

_ensure_symlink "${HOME}/.config/bash/.bash_profile" "${HOME}/.bash_profile"
_ensure_symlink "${HOME}/.config/dig/digrc" "${HOME}/.digrc"
_ensure_symlink "${HOME}/.config/shellcheck/.shellcheckrc" "${HOME}/.shellcheckrc"
_ensure_symlink "${HOME}/.config/markdownlint-cli/.markdownlint.json" "${HOME}/.markdownlint.json"

# ============================================================================
# 4. CREATE DIRECTORIES
# ============================================================================

for dir in "${HOME}/.local/bin" "${HOME}/.local/state/bash"; do
  if [[ -d "${dir}" ]]; then
    _skip "Directory exists: ${dir}"
  else
    mkdir -p "${dir}"
    _ok "Created directory: ${dir}"
    installed+=("dir:${dir}")
  fi
done

# ============================================================================
# 5. PIPX PACKAGES
# ============================================================================

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

# ============================================================================
# 6. NVM (Node Version Manager)
# ============================================================================

if [[ -d "${HOME}/.nvm" ]]; then
  _skip "NVM already installed at ~/.nvm"
else
  _info "Installing NVM..."
  PROFILE=/dev/null bash -c 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash'
  installed+=("NVM")
fi

# ============================================================================
# 7. SECRETS STUB
# ============================================================================

SECRETS_FILE="${HOME}/.config/bash/secrets.sh"
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
  _ok "Created secrets stub: ${SECRETS_FILE}"
  installed+=("secrets stub")
fi

# ============================================================================
# 8. POST-INSTALL SMOKE TEST
# ============================================================================

_info "Running smoke tests..."
failures=()

# Check key commands exist
for cmd in git bash shellcheck shfmt pre-commit vim gh; do
  if command -v "${cmd}" &>/dev/null; then
    _ok "Found: ${cmd}"
  else
    _warn "Missing: ${cmd}"
    failures+=("${cmd}")
  fi
done

# Check bash version (need 5+)
bash_version="$(bash --version | head -1)"
if [[ "${bash_version}" == *"version 5"* || "${bash_version}" == *"version 6"* ]]; then
  _ok "Bash 5+ detected"
else
  _warn "Bash may not be 5+: ${bash_version}"
  failures+=("bash-version")
fi

# Check git hooks path
hooks_path="$(git config --global core.hooksPath 2>/dev/null || true)"
if [[ -n "${hooks_path}" ]]; then
  _ok "Git hooksPath configured: ${hooks_path}"
else
  _warn "Git core.hooksPath not set"
  failures+=("git-hooksPath")
fi

# ============================================================================
# 9. SUMMARY
# ============================================================================

echo ""
echo "═══════════════════════════════════════════════════════"
echo " Bootstrap Summary"
echo "═══════════════════════════════════════════════════════"

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
