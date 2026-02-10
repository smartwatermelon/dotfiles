#!/usr/bin/env bash
set -euo pipefail

# Track which files were modified and which have remaining issues
declare -A fixed_by_shellcheck fixed_by_shfmt failed_files
temp_files=()

# Cleanup temporary files on exit
cleanup() {
  for tmpfile in "${temp_files[@]}"; do
    rm -f "${tmpfile}"
  done
}
trap cleanup EXIT

# =========================================================
# PERMISSION VERIFICATION - Detect permission mismatches
# =========================================================
# Check for shell scripts with shebangs but missing +x permissions.
# This is a PASSIVE check - we warn and fail, but don't auto-fix.
# Claude Code CLI will handle the fix automatically.

permission_errors=()
for f in "$@"; do
  [[ -f "${f}" ]] || continue

  # Check if file has shebang but is missing +x
  if head -n1 "${f}" 2>/dev/null | grep -qE '^#!/' && [[ ! -x "${f}" ]]; then
    permission_errors+=("${f}")
  fi
done

# Report errors but don't auto-fix
if [[ ${#permission_errors[@]} -gt 0 ]]; then
  echo "" >&2
  echo "❌ Permission mismatch detected:" >&2
  for f in "${permission_errors[@]}"; do
    echo "   ${f} has shebang but is not executable" >&2
  done
  echo "" >&2
  echo "   Fix with: chmod +x <file>" >&2
  echo "   Or let Claude Code CLI handle this automatically" >&2
  echo "" >&2
  exit 1
fi

# =========================================================
# SHELLCHECK AND SHFMT PROCESSING
# =========================================================

for f in "$@"; do
  [[ -f "${f}" ]] || continue
  issues_remaining=""

  # --- ShellCheck ---
  if command -v shellcheck >/dev/null; then
    # Note: SC2312 warns about command substitutions in conditional contexts
    # where the exit code is masked. Excluded globally to reduce informational
    # noise. Re-enable with --exclude='' if stricter checking is needed.

    # Run shellcheck once in diff mode
    shellcheck_diff=$(shellcheck --severity=warning --exclude=SC2312 --format=diff "${f}" 2>&1 || true)

    if [[ -n "${shellcheck_diff}" ]]; then
      # Try to auto-fix with diff output
      # Capture original permissions before creating tmpfile (macOS BSD stat)
      original_perms=$(stat -f "%OLp" "${f}")

      # Create tmpfile in same directory for atomic mv across filesystems
      tmpfile=$(mktemp "${f}.XXXXXX")
      temp_files+=("${tmpfile}")

      if cp "${f}" "${tmpfile}" && echo "${shellcheck_diff}" | patch --quiet "${tmpfile}" 2>/dev/null; then
        # Restore original permissions before replacing file
        chmod "${original_perms}" "${tmpfile}"
        mv "${tmpfile}" "${f}"
        fixed_by_shellcheck["${f}"]=1

        # After successful auto-fix, check if any issues remain
        if ! shellcheck --severity=warning --exclude=SC2312 "${f}" >/dev/null 2>&1; then
          remaining=$(shellcheck --severity=warning --exclude=SC2312 "${f}" 2>&1 || true)
          issues_remaining+="ShellCheck:\n${remaining}\n"
        fi
      else
        # Patch failed - report original shellcheck output as issues
        rm -f "${tmpfile}"
        issues_remaining+="ShellCheck:\n${shellcheck_diff}\n"
      fi
    fi
  else
    echo "Error: shellcheck not found" >&2
    exit 1
  fi

  # --- shfmt ---
  if command -v shfmt >/dev/null; then
    # Check if formatting is needed (without modifying)
    if shfmt -d -i 2 -ci -bn "${f}" >/dev/null 2>&1; then
      # Already formatted correctly
      :
    else
      # Needs formatting - use atomic write via tmpfile
      # Capture original permissions before creating tmpfile (macOS BSD stat)
      original_perms=$(stat -f "%OLp" "${f}")

      # Create tmpfile in same directory for atomic mv across filesystems
      tmpfile=$(mktemp "${f}.XXXXXX")
      temp_files+=("${tmpfile}")

      if shfmt -i 2 -ci -bn "${f}" >"${tmpfile}"; then
        # Restore original permissions before replacing file
        chmod "${original_perms}" "${tmpfile}"
        mv "${tmpfile}" "${f}"
        fixed_by_shfmt["${f}"]=1
      else
        rm -f "${tmpfile}"
        issues_remaining+="shfmt: Failed to format file\n"
      fi
    fi
  else
    echo "Error: shfmt not found" >&2
    exit 1
  fi

  # Track files with remaining issues
  if [[ -n "${issues_remaining}" ]]; then
    failed_files["${f}"]="${issues_remaining}"
  fi
done

# --- Summary ---
echo "----------------------------------------"

# Show files fixed by each tool (deduplicated)
all_fixed=()
for f in "${!fixed_by_shellcheck[@]+"${!fixed_by_shellcheck[@]}"}"; do
  [[ -n "${f}" ]] && all_fixed+=("${f} (shellcheck)")
done
for f in "${!fixed_by_shfmt[@]+"${!fixed_by_shfmt[@]}"}"; do
  [[ -n "${f}" ]] && all_fixed+=("${f} (shfmt)")
done

if [[ ${#all_fixed[@]} -gt 0 ]]; then
  echo "✅ Auto-fixed files:"
  printf "  %s\n" "${all_fixed[@]}" | sort
fi

# Check for failed files
has_failures=false
for f in "${!failed_files[@]+"${!failed_files[@]}"}"; do
  if [[ -n "${f}" ]]; then
    if ! ${has_failures}; then
      echo "❌ Files with remaining issues:"
      has_failures=true
    fi
    printf "  %s\n" "${f}"
    printf "%b" "${failed_files[${f}]}" | sed 's/^/    /'
  fi
done

if ${has_failures}; then
  exit 1
else
  echo "🎉 All checked files are clean!"
fi
