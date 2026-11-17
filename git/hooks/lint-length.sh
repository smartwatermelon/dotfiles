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
#                  line that sets length-caps=off on any all-files pattern (that
#                  would exempt a whole repo). Every exempted path is printed
#                  to stderr on every run.
#
# GENERATED FILES: a tracked `linguist-generated` (set or true) skips a file.
# A repo-wide, macro or info/attributes one is ignored, not fatal.
#
# A merge, cherry-pick or revert in progress is not checked: its diff is other
# people's commits, resolved, not text written for this commit.
#
# `--no-ext-diff --src-prefix=a/ --dst-prefix=b/` and `-M` pin the diff's
# shape, so diff.external, diff.noprefix, diff.mnemonicPrefix and diff.renames
# in a user's config cannot change the paths the checker reads. `-M` is forced
# on because a renamed file's unchanged comments must not read as added.

set -euo pipefail

# The personify length gate is a CC compensation layer, not a Codex gate.
if [[ -n "${CODEX_THREAD_ID:-}${CODEX_SESSION_ID:-}" ]]; then
  echo "length-caps: Codex session; CC-specific length gate skipped." >&2
  exit 0
fi

GATE_REVIEW="${HOME}/.claude/scripts/gate-review.sh"

# 0 if git matches the pattern to every probe path, 1 if not, 2 on error.
# The probes share no characters, so `*9*` is not read as every file.
_every_file() {
  local probe out
  probe="$(mktemp)" || return 2
  printf '%s length-caps-probe\n' "$1" >"${probe}"
  if ! out="$(GIT_ATTR_NOSYSTEM=1 git -c core.attributesFile="${probe}" \
    check-attr length-caps-probe -- zq9 .AB x/y/k_7)"; then
    rm -f "${probe}"
    return 2
  fi
  rm -f "${probe}"
  local l n=0
  while IFS= read -r l; do
    [[ "${l}" == *': set' ]] && n=$((n + 1))
  done <<<"${out}"
  [[ "${n}" == "3" ]]
}

main() {
  local git_dir personify checker rc=0 f top
  # From the top, so a root .gitattributes counts and paths stay top-relative.
  top="$(git rev-parse --show-toplevel)"
  cd "${top}"
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
  local info gen_ok=1
  for info in "$(git rev-parse --path-format=absolute --git-path info/attributes)" "${git_dir}/info/attributes"; do
    if [[ -f "${info}" ]] && grep -q 'length-caps' "${info}"; then
      echo "length-caps: ${info} sets length-caps. An exemption must live in a tracked .gitattributes, where a diff shows it." >&2
      exit 1
    fi
    if [[ "${gen_ok}" == "1" && -f "${info}" ]] && grep -q 'linguist-generated' "${info}"; then
      gen_ok=0
      echo "length-caps: ${info} sets linguist-generated, so generated files are checked this run." >&2
    fi
  done

  # A tracked .gitattributes line that exempts every path is refused. The index
  # copies are read, not the working tree.
  local ga line pat rest tok every
  local -a toks
  while IFS= read -r -d '' ga; do
    [[ "${ga##*/}" == ".gitattributes" ]] || continue
    while IFS= read -r line || [[ -n "${line}" ]]; do
      read -r pat rest <<<"${line}"
      read -r -a toks <<<"${rest}"
      for tok in "${toks[@]}"; do
        if [[ "${gen_ok}" == "1" && "${pat}" != '#'* && ("${tok}" == "linguist-generated" || "${tok}" == "linguist-generated=true") ]]; then
          every=0
          [[ "${pat}" == '[attr]'* ]] || _every_file "${pat}" || every=$?
          if [[ "${every}" != "1" ]]; then
            gen_ok=0
            echo "length-caps: ${ga} sets linguist-generated on '${pat}', which may cover every file, so generated files are checked this run." >&2
          fi
          continue
        fi
        [[ "${tok}" == "length-caps=off" ]] || continue
        every=0
        _every_file "${pat}" || every=$?
        if [[ "${every}" == "0" ]]; then
          echo "length-caps: ${ga} sets length-caps=off on '${pat}', which exempts every file. Name the paths to exempt instead." >&2
          exit 1
        elif [[ "${every}" != "1" ]]; then
          echo "length-caps: cannot tell whether '${pat}' in ${ga} exempts every file; bypass once with: SKIP=length-caps git commit ..." >&2
          exit 1
        fi
      done
    done < <(git show ":${ga}")
  done < <(git ls-files -z -- '*.gitattributes')

  # Files with `length-caps=off` or `linguist-generated` become exclude
  # pathspecs. Only the index's .gitattributes files count.
  local -a excludes=()
  local path attr val last=""
  local -a staged=()
  while IFS= read -r -d '' path; do
    staged+=("${path}")
  done < <(git diff --cached --name-only -M -z)
  if [[ "${#staged[@]}" -gt 0 ]]; then
    # Output is <path> NUL <attr> NUL <value> NUL per path and attribute.
    while IFS= read -r -d '' path && IFS= read -r -d '' attr && IFS= read -r -d '' val; do
      [[ "${path}" == "${last}" ]] && continue
      if [[ "${attr}" == "length-caps" && "${val}" == "off" ]]; then
        echo "length-caps: skipped ${path} (length-caps=off in .gitattributes)" >&2
      elif [[ "${gen_ok}" == "1" && "${attr}" == "linguist-generated" && ("${val}" == "set" || "${val}" == "true") ]]; then
        echo "length-caps: skipped ${path} (linguist-generated in .gitattributes)" >&2
      else
        continue
      fi
      excludes+=(":(top,exclude,literal)${path}")
      last="${path}"
    done < <(printf '%s\0' "${staged[@]}" | GIT_ATTR_NOSYSTEM=1 git -c core.attributesFile=/dev/null check-attr -z --cached --stdin length-caps linguist-generated)
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
