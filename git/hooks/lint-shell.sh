#!/usr/bin/env bash
set -euo pipefail

inside_git=false
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  inside_git=true
fi

fixed_files=()
failed_files=()

for f in "$@"; do
  [[ -f "${f}" ]] || continue
  issues_remaining=""

  # --- ShellCheck ---
  if command -v shellcheck >/dev/null; then
    diff=$(shellcheck --format=diff "${f}" || true)
    if [[ -n "${diff}" ]]; then
      echo "[shellcheck] ✅ Auto-fixed ${f}"
      echo "${diff}" | git apply
      ${inside_git} && git add "${f}"
      fixed_files+=("${f}")
    fi

    remaining=$(shellcheck "${f}" || true)
    if [[ -n "${remaining}" ]]; then
      issues_remaining+="ShellCheck:\n${remaining}\n"
    fi
  else
    echo "shellcheck not found"
    exit 1
  fi

  # --- shfmt ---
  if command -v shfmt >/dev/null; then
    shfmt -w -i 2 -ci -bn "${f}"
    ${inside_git} && git add "${f}"
    if ! shfmt -d -i 2 -ci -bn "${f}"; then
      shfmt_remaining=$(shfmt -d -i 2 -ci -bn "${f}")
      issues_remaining+="shfmt:\n${shfmt_remaining}\n"
    elif [[ -n "${diff}" ]]; then
      fixed_files+=("${f}")
    fi
  else
    echo "shfmt not found"
    exit 1
  fi

  if [[ -n "${issues_remaining}" ]]; then
    failed_files+=("${f}")
    printf "[❌ Issues remain in %s]\n%s\n" "${f}" "${issues_remaining}"
  fi
done

# --- Summary ---
echo "----------------------------------------"
if [[ ${#fixed_files[@]} -gt 0 ]]; then
  echo "✅ Auto-fixed files:"
  printf "  %s\n" "${fixed_files[@]}" | sort
fi

if [[ ${#failed_files[@]} -gt 0 ]]; then
  echo "❌ Files with remaining issues:"
  printf "  %s\n" "${failed_files[@]}" | sort
  exit 1
else
  echo "🎉 All checked files are clean!"
fi
