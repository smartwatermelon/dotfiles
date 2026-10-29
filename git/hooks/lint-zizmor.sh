#!/usr/bin/env bash
# GitHub Actions security lint wrapper for the `zizmor` pre-commit hook.
#
# Resolves the config the way CI does (standards/run-standards.sh:267 in
# smartwatermelon/github-workflows):
#
#   cfg="${repo}/zizmor.yml"; [[ -f "${cfg}" ]] || cfg="${config_dir}/../zizmor.yml"
#
# The hook this replaces passed no --config at all, so zizmor fell back to its
# own discovery. In a repo with no zizmor.yml that means the blanket
# `hash-pin` default, which rejects first-party reusable-workflow refs like
# `smartwatermelon/github-workflows/...@v3` that the fleet policy explicitly
# allows via `unpinned-uses.config.policies`.
#
# That is not cosmetic. It is what forced
# nightowlstudiollc/financial-agent#175 to convert floating refs to raw commit
# SHAs — a permanent opt-out from coordinated fleet remediation, since an
# immutable ref cannot carry a fix published after it was cut. Measured
# 2026-09-17 against the live fleet with per-owner tokens: 21 of the 42
# non-archived repos have workflows but no zizmor.yml, across all three
# owners. (twistedmelonman/claude-config#531 states 7, all nightowlstudiollc;
# that count was low and org-scoped. The fix shape is unchanged.)
#
# UNLIKE the markdownlint wrapper next door, this does NOT merge configs.
# zizmor's --config "loads a single configuration file" (zizmor 1.30.1
# --help), and CI's own resolution at run-standards.sh:267 is likewise
# either/or. Matching CI is the whole point, so either/or is correct here.
# Do not port lint-markdown.sh's jq merge into this file: for markdownlint CI
# merges, and the hook's failure to merge was the bug (claude-config#533).
# The two wrappers differ because the two linters differ.
#
# Discovery discrepancy, deliberate: zizmor also honours `.github/zizmor.yml`,
# and prefers it over the repo root when both exist (measured, zizmor 1.30.1).
# run-standards.sh:267 checks the repo root only. This wrapper matches CI
# rather than zizmor, so a repo keeping its config at `.github/zizmor.yml`
# would get the canonical policy here and its own config in CI. No repo in the
# fleet does that today (every config found lives at the repo root), so the
# case is unexercised — but it is a real divergence, and widening this wrapper
# alone would make local and CI disagree in the opposite direction. If it ever
# matters, fix run-standards.sh first and follow it here.
#
# Canonical policy: github-workflows' zizmor.yml is the only copy (dotfiles#345).
#
# Flags: --offline runs CI's --no-online-audits audits; the online client crashes in the macOS sandbox.

set -euo pipefail

CANONICAL="${ZIZMOR_CANONICAL_CONFIG:-${HOME}/Developer/github-workflows/zizmor.yml}"

main() {
  # Nothing staged for this hook: pre-commit still invokes it. zizmor with no
  # inputs is not a meaningful run, so exit clean rather than inventing a
  # failure. Mirrors lint-markdown.sh.
  (($# > 0)) || exit 0

  # A repo-local config wins, exactly as in CI. zizmor's own discovery would
  # find this file too; passing it explicitly keeps this wrapper's resolution
  # legible and identical to run-standards.sh rather than implicit.
  if [[ -f zizmor.yml ]]; then
    exec zizmor --config zizmor.yml --min-severity low --offline "$@"
  fi

  # No repo config and no canonical file: a machine without the
  # github-workflows checkout. Passing a nonexistent path makes zizmor
  # fail on a path the user never configured, blocking the commit with a
  # confusing error. Warn and fall back to zizmor's built-in defaults, which
  # still lint — they are merely stricter than fleet policy about
  # first-party refs. Same shape as the fix in dotfiles#343.
  if [[ ! -f "${CANONICAL}" ]]; then
    printf 'lint-zizmor: canonical config not found at %s; using zizmor defaults\n' \
      "${CANONICAL}" >&2
    printf 'lint-zizmor: clone smartwatermelon/github-workflows into ~/Developer to get the fleet policy\n' >&2
    printf 'lint-zizmor: first-party reusable-workflow refs may report unpinned-uses\n' >&2
    exec zizmor --min-severity low --offline "$@"
  fi

  exec zizmor --config "${CANONICAL}" --min-severity low --offline "$@"
}

main "$@"
