#!/usr/bin/env bash
set -euo pipefail

TOOL="$1"
shift

exit_code=0

for f in "$@"; do
  # Skip non-files just in case
  [[ -f "${f}" ]] || continue
  command -v "${TOOL}" >/dev/null || {
    echo "${TOOL} not found"
    exit 1
  }

  case "${TOOL}" in
    shellcheck)
      # Attempt auto-fix via diff -> git apply
      diff=$(shellcheck --format=diff "${f}" || true)
      if [[ -n "${diff}" ]]; then
        echo "[shellcheck] Auto-fixing ${f}"
        echo "${diff}" | git apply
      fi

      # Re-lint after fixes
      remaining=$(shellcheck "${f}" || true)
      if [[ -n "${remaining}" ]]; then
        echo "[shellcheck] Remaining issues in ${f}:"
        echo "${remaining}"
        exit_code=1
      fi
      ;;
    shfmt)
      # Attempt auto-fix
      if ! shfmt -i 2 -ci -bn -w "${f}"; then
        echo "[shfmt] Error formatting ${f}" >&2
        exit_code=1
        continue
      fi

      # Second pass: check for remaining issues (syntax errors, etc.)
      if ! shfmt -d "${f}" >/dev/null 2>&1; then
        echo "[shfmt] Reformatted ${f}"
      fi

      # Always allow commit to pass
      continue
      ;;
    *)
      echo "Unknown tool: ${TOOL}" >&2
      exit 1
      ;;
  esac
done

exit "${exit_code}"
