#!/usr/bin/env bash
set -euo pipefail

# ~/Developer/dotfiles/install.sh
# Idempotent bootstrap script for a new macOS machine.
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

# ── Parse arguments ──────────────────────────────────────
DRY_RUN=false
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=true ;;
    *)
      _err "Unknown argument: ${arg}"
      echo "Usage: install.sh [--dry-run]"
      exit 1
      ;;
  esac
done

if [[ "${DRY_RUN}" == true ]]; then
  _info "Dry-run mode — no changes will be made"
fi

# ============================================================================
# 1. PRE-FLIGHT CHECKS
# ============================================================================

detected_os="$(uname -s)" || true
if [[ "${detected_os}" != "Darwin" ]]; then
  _err "This script is designed for macOS (Darwin). Detected: ${detected_os}"
  exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -d "${REPO_DIR}/.git" ]]; then
  _err "Not a git repository: ${REPO_DIR}"
  _err "This script must be run from the dotfiles repo root."
  exit 1
fi

if [[ ! -f "${REPO_DIR}/git/config" ]]; then
  _err "Canary file missing: ${REPO_DIR}/git/config"
  exit 1
fi

if [[ ! -f "${REPO_DIR}/bash/main.sh" ]]; then
  _err "Canary file missing: ${REPO_DIR}/bash/main.sh"
  exit 1
fi

if [[ "${EUID}" -eq 0 ]]; then
  _err "Do not run this script as root."
  exit 1
fi

_ok "Pre-flight checks passed (macOS, git repo at ${REPO_DIR}, non-root)"

# ============================================================================
# 2. HOMEBREW
# ============================================================================

if command -v brew &>/dev/null; then
  _skip "Homebrew already installed"
else
  if [[ "${DRY_RUN}" == true ]]; then
    _dry "Would install Homebrew"
  else
    _info "Installing Homebrew..."
    # Let curl failure propagate — on a fresh machine, this IS fatal
    brew_installer="$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    /bin/bash -c "${brew_installer}"
    # Ensure brew is on PATH for the rest of this script
    brew_env="$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null)"
    eval "${brew_env}"
    installed+=("Homebrew")
  fi
fi

if [[ "${DRY_RUN}" == true ]]; then
  if ! command -v brew &>/dev/null; then
    _dry "Would verify Homebrew is on PATH (not currently available)"
  fi
elif ! command -v brew &>/dev/null; then
  _err "Homebrew is not available on PATH. Cannot continue."
  exit 1
fi

_info "Running brew bundle..."
if [[ "${DRY_RUN}" == true ]]; then
  _dry "Would run: brew bundle --file=${REPO_DIR}/Brewfile"
elif brew bundle check --file="${REPO_DIR}/Brewfile" &>/dev/null; then
  _skip "All Brewfile packages already installed"
else
  brew bundle --file="${REPO_DIR}/Brewfile"
  installed+=("Brewfile packages")
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

_is_excluded() {
  case "$1" in
    # CI / GitHub metadata
    .github/*) return 0 ;;
    # Git ignore files (repo-level, not app configs)
    .gitignore) return 0 ;;
    */.gitignore) return 0 ;;
    # Repo management files
    Brewfile) return 0 ;;
    README.md) return 0 ;;
    */README.md) return 0 ;;
    install.sh) return 0 ;;
    docs/*) return 0 ;;
    # Project metadata that may be added in the future
    LICENSE*) return 0 ;;
    CLAUDE.md) return 0 ;;
    */CLAUDE.md) return 0 ;;
    MEMORY.md) return 0 ;;
    */MEMORY.md) return 0 ;;
    .claude/*) return 0 ;;
    .pre-commit-config.yaml) return 0 ;;
    # Test files
    *.test.*) return 0 ;;
    *.bats) return 0 ;;
    tests/*) return 0 ;;
    test/*) return 0 ;;
    # Other repo-level files that may be added
    Makefile) return 0 ;;
    .editorconfig) return 0 ;;
    .gitattributes) return 0 ;;
    CONTRIBUTING.md) return 0 ;;
    CHANGELOG.md) return 0 ;;
    *) return 1 ;;
  esac
}

# Known config directories that should be symlinked into ~/.config.
# Any top-level path not in this list AND not excluded triggers a warning.
_KNOWN_CONFIG_DIRS="bash btop dig gh git liquidpromptrc markdownlint-cli pre-commit s shellcheck tidy vim yamllint yt-dlp"

_is_known_config_path() {
  local top_level
  top_level="${1%%/*}"
  # Single-file at root (e.g., liquidpromptrc) — top_level equals the file
  for known in ${_KNOWN_CONFIG_DIRS}; do
    if [[ "${top_level}" == "${known}" ]]; then
      return 0
    fi
  done
  return 1
}

_info "Creating config symlinks from repo to ~/.config..."

while IFS= read -r file; do
  if _is_excluded "${file}"; then
    continue
  fi

  # Safety net: warn about tracked files not in a known config directory
  if ! _is_known_config_path "${file}"; then
    _warn "Unrecognized config path: ${file} — add to _KNOWN_CONFIG_DIRS or _is_excluded"
    failures+=("unrecognized-path:${file}")
    continue
  fi

  link="${HOME}/.config/${file}"
  target="${REPO_DIR}/${file}"

  if [[ "${DRY_RUN}" == true ]]; then
    parent_dir="$(dirname "${link}")"
    if [[ ! -d "${parent_dir}" ]]; then
      _dry "Would create directory: ${parent_dir}"
    fi
    _dry "Would symlink: ${link} -> ${target}"
  else
    mkdir -p "$(dirname "${link}")"
    _ensure_symlink "${target}" "${link}"
  fi
done < <(git -C "${REPO_DIR}" ls-files)

# ============================================================================
# 4. HOME SYMLINKS (~/.<file> → ~/.config/<path>)
# ============================================================================

if [[ "${DRY_RUN}" == true ]]; then
  _dry "Would symlink: ~/.bash_profile -> ~/.config/bash/.bash_profile"
  _dry "Would symlink: ~/.digrc -> ~/.config/dig/digrc"
  _dry "Would symlink: ~/.shellcheckrc -> ~/.config/shellcheck/.shellcheckrc"
  _dry "Would symlink: ~/.markdownlint.json -> ~/.config/markdownlint-cli/.markdownlint.json"
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
  if [[ -d "${dir}" ]]; then
    _skip "Directory exists: ${dir}"
  elif [[ "${DRY_RUN}" == true ]]; then
    _dry "Would create directory: ${dir}"
  else
    mkdir -p "${dir}"
    _ok "Created directory: ${dir}"
    installed+=("dir:${dir}")
  fi
done

# ============================================================================
# 6. PIPX PACKAGES
# ============================================================================

if ! command -v pipx &>/dev/null; then
  _warn "pipx not found — skipping pipx packages"
  manual+=("Install pipx, then run: pipx install argcomplete")
else
  if pipx list --short 2>/dev/null | grep -q "^argcomplete "; then
    _skip "pipx package already installed: argcomplete"
  elif [[ "${DRY_RUN}" == true ]]; then
    _dry "Would install pipx package: argcomplete"
  else
    _info "Installing pipx package: argcomplete"
    pipx install argcomplete
    installed+=("pipx:argcomplete")
  fi
fi

# ============================================================================
# 7. NVM (Node Version Manager)
# ============================================================================

NVM_VERSION="v0.40.4"
if [[ -d "${HOME}/.nvm" ]]; then
  _skip "NVM already installed at ~/.nvm"
elif [[ "${DRY_RUN}" == true ]]; then
  _dry "Would install NVM ${NVM_VERSION}"
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

# ============================================================================
# 8. SECRETS STUB
# ============================================================================

SECRETS_FILE="${HOME}/.config/bash/secrets.sh"
if [[ -f "${SECRETS_FILE}" ]]; then
  _skip "Secrets file already exists: ${SECRETS_FILE}"
elif [[ "${DRY_RUN}" == true ]]; then
  _dry "Would create secrets stub: ${SECRETS_FILE}"
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

# ============================================================================
# 9. POST-INSTALL SMOKE TEST
# ============================================================================

_info "Running smoke tests..."

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

# Symlink health check — verify all config symlinks resolve
if [[ "${DRY_RUN}" == true ]]; then
  _dry "Would verify config symlink health"
else
  _info "Checking config symlink health..."
  symlink_errors=0
  while IFS= read -r file; do
    if _is_excluded "${file}"; then
      continue
    fi
    if ! _is_known_config_path "${file}"; then
      continue
    fi
    link="${HOME}/.config/${file}"
    if [[ -L "${link}" ]]; then
      if [[ ! -e "${link}" ]]; then
        _warn "Broken symlink: ${link}"
        failures+=("broken-symlink:${link}")
        ((symlink_errors += 1))
      fi
    elif [[ -e "${link}" ]]; then
      _warn "Not a symlink (expected symlink): ${link}"
      failures+=("not-symlink:${link}")
      ((symlink_errors += 1))
    else
      _warn "Missing symlink: ${link}"
      failures+=("missing-symlink:${link}")
      ((symlink_errors += 1))
    fi
  done < <(git -C "${REPO_DIR}" ls-files)

  if [[ "${symlink_errors}" -eq 0 ]]; then
    _ok "All config symlinks healthy"
  fi
fi

# ============================================================================
# 10. SUMMARY
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
if [[ "${DRY_RUN}" == true ]]; then
  _info "Dry run complete — no changes were made"
elif [[ ${#failures[@]} -eq 0 ]]; then
  _ok "Bootstrap complete!"
else
  _warn "Bootstrap complete with ${#failures[@]} issue(s) — see above."
fi
