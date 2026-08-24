#!/usr/bin/env bash
# git/hooks/lib-symlink-repair.sh
# Shared symlink repair logic — sourced by pre-commit hook and install.sh.
# Detects ~/.config files that should be symlinks but are regular files
# (caused by atomic writes), copies content back to repo, restores symlinks.
#
# Requires REPO_DIR to be set before sourcing.
# Sources lib-symlink-exclusions.sh (same directory) for the exclusion list.
# Sets SYMLINK_REPAIRS=() with list of repaired files.

SYMLINK_REPAIRS=()

# Exclusion list is shared with install.sh — see lib-symlink-exclusions.sh.
#
# Resolution has to survive the pre-commit hook, which sources the DEPLOYED
# copy at ~/.config/git/hooks/lib-symlink-repair.sh. That deployed path is a
# symlink into the repo, and bash sets BASH_SOURCE to the symlink, not its
# target — so a plain sibling lookup finds ~/.config/git/hooks/, which only
# holds the exclusions file after install.sh has deployed it. On a machine
# mid-upgrade that lookup misses.
#
# So: try the sibling of the fully-resolved (symlink-followed) path first,
# which always lands inside the repo, then the literal sibling, then
# ${REPO_DIR}. Never assume the caller's cwd or shell environment.
# Capture this file's own path at source time. Inside the function below,
# BASH_SOURCE[0] would be this file too, but only because the function is
# defined here — reading it from a variable set at the top level makes that
# independent of where the function is called from, so moving or wrapping the
# call cannot silently change which file gets resolved.
_SYMLINK_REPAIR_SELF="${BASH_SOURCE[0]}"

_symlink_exclusions_lib() {
  local self="${_SYMLINK_REPAIR_SELF}" dir resolved candidate
  dir="$(CDPATH='' cd "$(dirname "${self}")" && pwd)"

  resolved="${self}"
  while [[ -L "${resolved}" ]]; do
    local link
    link="$(readlink "${resolved}")"
    if [[ "${link}" == /* ]]; then
      resolved="${link}"
    else
      resolved="$(dirname "${resolved}")/${link}"
    fi
  done

  for candidate in \
    "$(dirname "${resolved}")/lib-symlink-exclusions.sh" \
    "${dir}/lib-symlink-exclusions.sh" \
    "${REPO_DIR:-}/git/hooks/lib-symlink-exclusions.sh"; do
    if [[ -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

_SYMLINK_EXCLUSIONS_LIB="$(_symlink_exclusions_lib)" || {
  echo "[symlink-repair] ERROR: cannot locate lib-symlink-exclusions.sh" >&2
  echo "[symlink-repair] Run install.sh --sync to deploy it." >&2
}

if [[ -n "${_SYMLINK_EXCLUSIONS_LIB:-}" ]]; then
  # shellcheck source=git/hooks/lib-symlink-exclusions.sh
  source "${_SYMLINK_EXCLUSIONS_LIB}"
fi

# Fail closed: if the exclusion list could not be loaded, treat every file as
# excluded rather than as includable. A missing list must never cause the
# repair pass to start managing files it has no business touching.
if ! declare -F _symlink_is_excluded >/dev/null 2>&1; then
  _symlink_is_excluded() { return 0; }
fi

# Repair broken symlinks in ~/.config — returns 0 if all healthy or repaired
repair_config_symlinks() {
  local stage_changes="${1:-false}"

  if [[ -z "${REPO_DIR:-}" ]]; then
    echo "[symlink-repair] ERROR: REPO_DIR not set" >&2
    return 1
  fi

  local file target link
  while IFS= read -r file; do
    _symlink_is_excluded "${file}" && continue

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
