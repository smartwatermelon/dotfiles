#!/usr/bin/env bash
# git/hooks/lib-symlink-repair.sh
# Shared symlink repair logic — sourced by pre-commit hook and install.sh.
# Detects ~/.config files that should be symlinks but are regular files
# (caused by atomic writes), copies content back to repo, restores symlinks.
#
# Requires REPO_DIR to be set before sourcing.
# Sets SYMLINK_REPAIRS=() with list of repaired files.

SYMLINK_REPAIRS=()

# Files in the repo that should NOT be symlinked to ~/.config
_repair_is_excluded() {
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
    LICENSE*) return 0 ;;
    CLAUDE.md) return 0 ;;
    MEMORY.md) return 0 ;;
    .claude/*) return 0 ;;
    Makefile) return 0 ;;
    .editorconfig) return 0 ;;
    .gitattributes) return 0 ;;
    CHANGELOG*) return 0 ;;
    .pre-commit-config.yaml) return 0 ;;
    *.test.*) return 0 ;;
    *.spec.*) return 0 ;;
    *.bats) return 0 ;;
    tests/*) return 0 ;;
    test/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Repair broken symlinks in ~/.config — returns 0 if all healthy or repaired
repair_config_symlinks() {
  local stage_changes="${1:-false}"

  if [[ -z "${REPO_DIR:-}" ]]; then
    echo "[symlink-repair] ERROR: REPO_DIR not set" >&2
    return 1
  fi

  local file target link
  while IFS= read -r file; do
    _repair_is_excluded "${file}" && continue

    target="${REPO_DIR}/${file}"
    link="${HOME}/.config/${file}"

    # Skip if symlink is healthy
    if [[ -L "${link}" ]]; then
      continue
    fi

    # Skip if link doesn't exist (install.sh handles creation)
    if [[ ! -e "${link}" ]]; then
      continue
    fi

    # Regular file where symlink should be — repair needed
    if [[ -f "${link}" ]]; then
      # Check if content differs from repo
      if ! diff -q "${link}" "${target}" >/dev/null 2>&1; then
        cp "${link}" "${target}"
        echo "[symlink-repair] Copied changed content: ${file}"
      fi

      rm "${link}"
      ln -s "${target}" "${link}"
      echo "[symlink-repair] Restored symlink: ${link} -> ${target}"
      SYMLINK_REPAIRS+=("${file}")

      if [[ "${stage_changes}" == "true" ]]; then
        git -C "${REPO_DIR}" add "${file}"
      fi
    fi
  done < <(git -C "${REPO_DIR}" ls-files)

  if [[ ${#SYMLINK_REPAIRS[@]} -gt 0 ]]; then
    echo "[symlink-repair] Repaired ${#SYMLINK_REPAIRS[@]} file(s)"
  fi

  return 0
}
