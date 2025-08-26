#!/usr/bin/env bash
set -euo pipefail

TOOL="$1"
shift

# Helper: announce auto-fix and set failure code
notify_autofix() {
  local file="$1"
  echo "[${TOOL}] ✅ Auto-fixed ${file}"
  echo "[${TOOL}] ℹ️  Please stage the changes and try the commit again." >&2
  exit_code=1
}

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
      SHFMT_OPTS="-d -i 2 -ci -bn"
      SHFMT_WRITE_OPTS="-i 2 -ci -bn -w"

      #shellcheck disable=SC2086
      if ! shfmt ${SHFMT_OPTS} "${f}"; then
        echo "[shfmt] Found issues in ${f}" >&2

        # Attempt auto-fix
        #shellcheck disable=SC2086
        if ! shfmt ${SHFMT_WRITE_OPTS} "${f}"; then
          echo "[shfmt] ❌ Couldn't auto-fix ${f}" >&2
          exit_code=1
          continue
        fi

        # Second pass: check for remaining issues (syntax errors, etc.)
        #shellcheck disable=SC2086
        if ! shfmt ${SHFMT_OPTS} "${f}"; then
          echo "[shfmt] ❌ Unfixable issues in ${f}" >&2
          exit_code=1
          continue
        fi

        # Success: auto-fixed with no further issues
        notify_autofix "${f}"
        continue
      fi

      # No issues at all
      continue
      ;;
    *)
      echo "Unknown tool: ${TOOL}" >&2
      exit 1
      ;;
  esac
done

exit "${exit_code}"
