#!/usr/bin/env bash
# shellcheck shell=bash
# Trash broken symlinks in ~/.local/bin (dotfiles#417). See --help.

set -euo pipefail
unset CDPATH

usage() {
  cat <<'USAGE'
Usage: prune-dead-bin-links.sh [--dry-run] [--yes | -y] [DIR]

Find broken symlinks directly inside DIR (default: ~/.local/bin), list them
with their targets, and move them to the Trash with `trash`. Nothing is
ever removed with rm.

  --dry-run   List what would be trashed and stop. Changes nothing.
  --yes, -y   Trash without asking. Without it, you must answer y.

Only symlinks whose target is missing are touched. Regular files, working
symlinks, and subdirectories are never touched. A link into an unmounted
volume looks broken, so read the list before you answer y.
USAGE
}

dry_run=false
assume_yes=false
dir=""
for arg in "$@"; do
  case "${arg}" in
    --dry-run) dry_run=true ;;
    --yes | -y) assume_yes=true ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "prune-dead-bin-links: unknown option: ${arg}" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "${dir}" ]]; then
        echo "prune-dead-bin-links: only one DIR allowed" >&2
        exit 2
      fi
      dir="${arg}"
      ;;
  esac
done
dir="${dir:-${HOME}/.local/bin}"

if [[ ! -d "${dir}" ]]; then
  echo "prune-dead-bin-links: not a directory: ${dir}" >&2
  exit 1
fi
# Absolute path, so no entry name can start with a dash when given to trash.
dir="$(cd "${dir}" && pwd -P)"

# A broken link is a symlink whose target does not resolve (-e follows it).
is_dead_link() {
  [[ -L "$1" && ! -e "$1" ]]
}

dead=()
# Glob, not find: direct children only, dotfiles included, any filename.
shopt -s nullglob dotglob
for entry in "${dir}"/*; do
  if is_dead_link "${entry}"; then
    dead+=("${entry}")
  fi
done
shopt -u nullglob dotglob

if [[ ${#dead[@]} -eq 0 ]]; then
  echo "No broken symlinks in ${dir}."
  exit 0
fi

echo "Broken symlinks in ${dir}:"
for entry in "${dead[@]}"; do
  target="$(readlink "${entry}")"
  printf '  %s -> %s\n' "${entry##*/}" "${target}"
done

if [[ "${dry_run}" == true ]]; then
  echo "--dry-run: would move ${#dead[@]} link(s) to the Trash. Nothing changed."
  exit 0
fi

if ! command -v trash >/dev/null 2>&1; then
  echo "prune-dead-bin-links: 'trash' not found on PATH; nothing was changed." >&2
  exit 1
fi

if [[ "${assume_yes}" != true ]]; then
  answer=""
  read -r -p "Move ${#dead[@]} link(s) to the Trash? [y/N] " answer || true
  if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
    echo "Cancelled. Nothing changed."
    exit 0
  fi
fi

trashed=0
failed=0
for entry in "${dead[@]}"; do
  # Re-check right before acting: the link may have changed since the scan.
  if ! is_dead_link "${entry}"; then
    echo "  skipped (no longer a broken symlink): ${entry}" >&2
    continue
  fi
  if trash "${entry}"; then
    trashed=$((trashed + 1))
  else
    echo "  failed to trash: ${entry}" >&2
    failed=$((failed + 1))
  fi
done

echo "Moved ${trashed} link(s) to the Trash."
if [[ ${failed} -gt 0 ]]; then
  echo "prune-dead-bin-links: ${failed} link(s) could not be trashed." >&2
  exit 1
fi
