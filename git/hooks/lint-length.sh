#!/usr/bin/env bash
# Length-cap check for the `length-caps` pre-commit hook.
#
# Reads the STAGED diff and fails when a code comment or docstring it ADDS is
# over personify's cap. Only added lines count: a long comment that was already
# in the file, in a file you touched elsewhere, is not this commit's problem.
# The checker is personify's scripts/length_check.py (--diff mode); this script
# finds it, builds the diff, and passes the checker's exit code through
# (0 ok, 1 over a cap and the offending path:line lines on stdout, 5 checker
# usage or internal error).
#
# Runs against the staged diff rather than file arguments, so the pre-commit
# entry sets pass_filenames: false and always_run: true.
#
# Fails CLOSED when personify is not installed: core.hooksPath is global, so a
# machine that cannot find personify blocks every commit in every repo until it
# is installed. That was chosen on purpose (2026-09-30) and is to be revisited
# if it hurts. The message names the way out.
#
# HUMAN BYPASSES
#   Whole commit:  SKIP=length-caps git commit ...        (pre-commit's own)
#   One file:      mark it in a TRACKED .gitattributes, for a license header or a
#                  vendored file whose comments you do not own:
#                      vendor/**  length-caps=off
#                  The value must be exactly `off`. `-diff` also works but hides
#                  the file from `git diff` and `git log -p`, so this uses a
#                  custom attribute that changes nothing else.
#                  Only tracked .gitattributes files count, read from the index
#                  (git check-attr --cached), so the exemption is reviewable in
#                  a diff and applies once .gitattributes is staged. The hook
#                  ignores core.attributesFile and the system attributes file.
#                  It fails if .git/info/attributes sets length-caps at all
#                  (never in a diff), and it refuses a tracked .gitattributes
#                  line that sets length-caps=off on `*`, `**` or `**/*` (that
#                  would exempt a whole repo). Every exempted path is printed
#                  to stderr on every run.
#
# A merge, cherry-pick or revert in progress is not checked: its diff is other
# people's commits, resolved, not text written for this commit.
#
# `--no-ext-diff --src-prefix=a/ --dst-prefix=b/` and `-M` pin the diff's
# shape, so diff.external, diff.noprefix, diff.mnemonicPrefix and diff.renames
# in a user's config cannot change the paths the checker reads. `-M` is forced
# on because a renamed file's unchanged comments must not read as added.

set -euo pipefail

GATE_REVIEW="${HOME}/.claude/scripts/gate-review.sh"

main() {
  local git_dir personify checker rc=0 f
  git_dir="$(git rev-parse --absolute-git-dir)"
  for f in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
    [[ -e "${git_dir}/${f}" ]] && exit 0
  done

  # Nothing staged: nothing to check, and no need for personify.
  git diff --cached --quiet && exit 0

  if [[ ! -x "${GATE_REVIEW}" ]]; then
    echo "length-caps: ${GATE_REVIEW} is missing, so personify cannot be found." >&2
    echo "length-caps: install claude-config, or bypass once with: SKIP=length-caps git commit ..." >&2
    exit 1
  fi
  if ! personify="$("${GATE_REVIEW}" personify-path)"; then
    # gate-review.sh already printed why, on stderr.
    echo "length-caps: cannot check comment lengths without personify; bypass once with: SKIP=length-caps git commit ..." >&2
    exit 1
  fi
  checker="${personify}/scripts/length_check.py"
  if [[ ! -f "${checker}" ]]; then
    echo "length-caps: no ${checker}; personify 2.1.0 or later has it, so update personify." >&2
    echo "length-caps: bypass once with: SKIP=length-caps git commit ..." >&2
    exit 1
  fi

  # info/attributes never appears in a diff, so it cannot carry an exemption.
  local info
  for info in "$(git rev-parse --path-format=absolute --git-path info/attributes)" "${git_dir}/info/attributes"; do
    if [[ -f "${info}" ]] && grep -q 'length-caps' "${info}"; then
      echo "length-caps: ${info} sets length-caps. An exemption must live in a tracked .gitattributes, where a diff shows it." >&2
      exit 1
    fi
  done

  # A tracked .gitattributes line that exempts every path is refused. The index
  # copies are read, not the working tree.
  local ga line pat rest tok
  local -a toks
  while IFS= read -r -d '' ga; do
    [[ "${ga##*/}" == ".gitattributes" ]] || continue
    while IFS= read -r line || [[ -n "${line}" ]]; do
      read -r pat rest <<<"${line}"
      [[ "${pat}" == "*" || "${pat}" == "**" || "${pat}" == "**/*" ]] || continue
      read -r -a toks <<<"${rest}"
      for tok in "${toks[@]}"; do
        if [[ "${tok}" == "length-caps=off" ]]; then
          echo "length-caps: ${ga} sets length-caps=off on '${pat}', which exempts every file. Name the paths to exempt instead." >&2
          exit 1
        fi
      done
    done < <(git show ":${ga}")
  done < <(git ls-files -z -- '*.gitattributes')

  # Files opted out with `length-caps=off` become exclude pathspecs. Only the
  # index's .gitattributes files are consulted.
  local -a excludes=()
  local path val
  local -a staged=()
  while IFS= read -r -d '' path; do
    staged+=("${path}")
  done < <(git diff --cached --name-only -M -z)
  if [[ "${#staged[@]}" -gt 0 ]]; then
    # Output is <path> NUL <attr> NUL <value> NUL per input path.
    while IFS= read -r -d '' path && IFS= read -r -d '' _ && IFS= read -r -d '' val; do
      if [[ "${val}" == "off" ]]; then
        excludes+=(":(top,exclude,literal)${path}")
        echo "length-caps: skipped ${path} (length-caps=off in .gitattributes)" >&2
      fi
    done < <(printf '%s\0' "${staged[@]}" | GIT_ATTR_NOSYSTEM=1 git -c core.attributesFile=/dev/null check-attr -z --cached --stdin length-caps)
  fi

  git diff --cached -U0 --no-color --no-ext-diff -M \
    --src-prefix=a/ --dst-prefix=b/ -- ':(top)' ${excludes[@]+"${excludes[@]}"} \
    | python3 "${checker}" --diff || rc=$?
  if [[ "${rc}" -eq 1 ]]; then
    echo "length-caps: shorten the lines above, or bypass once with: SKIP=length-caps git commit ..." >&2
  elif [[ "${rc}" -ne 0 ]]; then
    echo "length-caps: checker error (exit ${rc}), not a verdict on the text; bypass once with: SKIP=length-caps git commit ..." >&2
  fi
  exit "${rc}"
}

main "$@"
