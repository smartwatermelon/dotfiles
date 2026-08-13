# git/gpush Wrapper Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the `git()` and `gpush()` bash functions out of `functions.sh` into their own files, following the file-organization half of the `gh-wrapper.sh` pattern (canonical implementation lives in a dedicated file, sourced from `functions.sh`), while giving `gpush` the additional standalone-executable half of that pattern (symlinked into `~/.local/bin`) since it is a fully interactive CLI tool with no dependency on being invoked as a bash function.

**Architecture:**
`functions.sh` has grown to 1278 lines, with `git()` (114 lines, `functions.sh:899-1013`) and `gpush()` (204 lines, `functions.sh:1052-1255`) together accounting for roughly a quarter of it. `gh-wrapper.sh` already demonstrates the target pattern for `gh`: canonical logic lives in one file, sourced as a bash function from `functions.sh`, with a second "standalone executable" mode for the specific case where non-bash callers need direct access to the same guard logic. `git` and `gpush` don't share that need identically:

- **`git`**: only ever needs to run inside a bash session that has `functions.sh`/`BASH_ENV` loaded (its only job is triggering a local `post-checkout` hook after `git init`, run by the same bash process that ran `git init`). No case exists — unlike `gh`'s REST/GraphQL merge-bypass risk — where an external, non-bash caller skipping the wrapper causes a correctness or safety problem large enough to justify shadowing the system `git` binary via `~/.local/bin/git`. **Extract only**, no standalone symlink.
- **`gpush`**: interactive (prompts for merge confirmation), CLI-only, never invoked by non-interactive tooling. It gets the **full dual-mode treatment** — extracted to `gpush-wrapper.sh`, sourced as a function from `functions.sh` (unchanged calling convention), AND symlinked to `~/.local/bin/gpush` via `install.sh`, purely so the file exists as a standalone, directly-runnable script too. It uses the same `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]` dual-mode dispatch as `gh-wrapper.sh`, but much simpler: no separate guard logic to duplicate between modes, since `gpush` doesn't itself do anything security-relevant — it just calls `git` and `gh`, which carry their own guards regardless of how `gpush` was invoked. The single `gpush()` function body is defined once; the branch at the bottom only decides whether to also invoke it immediately (standalone mode, `gpush "$@"`) or leave it defined for the caller to invoke later (sourced mode, `export -f gpush`).

**Tech Stack:** GNU Bash 5.x, shellcheck (`-S info`), existing bash test harness (`bash/tests/*.sh`, run directly — no framework), pre-commit `lint-shell.sh` hook (auto-runs shellcheck on any staged shell file).

## Global Constraints

- GNU Bash 5.x compatible; all shellcheck issues resolved (errors, warnings, info) — run `shellcheck -S info <script>` after every edit.
- Never use `# shellcheck disable` directives.
- Never use `((var++))` with `set -e`; use `((var += 1))` instead.
- Text files end with a newline.
- Every behavior change must have corresponding test updates (Protocol 3) — since this is pure extraction with no intended behavior change, the requirement here is that existing tests continue to pass and new tests pin the extracted functions' current behavior at their new location.
- `install.sh`'s `_KNOWN_CONFIG_DIRS` and `_is_excluded` gates (`install.sh:167-219`) determine which repo-tracked files get symlinked into `~/.config` vs. flagged as "unrecognized" — new files under `bash/` are covered automatically since `bash` is already a known top-level dir; no changes needed there.
- Follow `gh-wrapper.sh`'s header-comment convention: explain what the file is, why it's structured this way, and (for `gpush-wrapper.sh`) the two invocation modes.
- Do not change `git()`'s or `gpush()`'s behavior, flags, or output during extraction — this is a structural refactor, not a rewrite. Any bug noticed along the way gets reported, not silently fixed in the same commit.

---

### Task 1: Extract `git()` into `git-wrapper.sh`, sourced from `functions.sh`

**Files:**

- Create: `bash/git-wrapper.sh`
- Modify: `bash/functions.sh:899-1013` (delete the `git()` function body and its `export -f git` line; replace with a source block)
- Test: `bash/tests/test-git-wrapper-init-hook.sh` (new)

**Interfaces:**

- Produces: `git()` bash function (same signature/behavior as today: wraps `command git "$@"`, and on a successful `git init` — including `-C <dir>` and `git init <dir>` forms — runs `<git-dir>/hooks/post-checkout <null-sha> <null-sha> 1` if that hook exists and is executable). Exported via `export -f git`, guarded against recursion via `_GIT_WRAPPER_ACTIVE`.

- [ ] **Step 1: Create a feature branch (Protocol 1 — never commit to main)**

Run: `git checkout -b claude/refactor-git-gpush-wrapper-extraction-<session-id>` (substitute the actual session ID), then verify: `git branch --show-current` must NOT print `main`.

- [ ] **Step 2: Create `bash/git-wrapper.sh` with the extracted function body**

Copy the current `git()` function (`functions.sh:899-1012`) verbatim into a new file, with a header comment modeled on `gh-wrapper.sh`'s:

```bash
#!/usr/bin/env bash
# ~/.config/bash/git-wrapper.sh
# shellcheck shell=bash
# Canonical implementation of the `git` post-init hook trigger: after a
# successful `git init` (including `-C <dir>` and `git init <dir>` forms),
# runs the newly-created repo's post-checkout hook with null-SHA init
# parameters, since `git init` itself never fires post-checkout the way
# `git clone`/`git checkout` do.
#
# Unlike gh-wrapper.sh, this file has only one invocation mode: sourced from
# functions.sh, defining git() as a bash function. It is NOT symlinked into
# ~/.local/bin — git's wrapper logic only matters when git init is run from
# a bash session that already has this file's guard/hook-trigger behavior
# loaded via BASH_ENV, and no external (non-bash) caller invoking the raw
# git binary directly creates a correctness or safety gap worth solving by
# shadowing the system git binary for every tool on the machine.

git() {
  # Guard against recursive calls
  if [[ -n "${_GIT_WRAPPER_ACTIVE:-}" ]]; then
    command git "$@"
    return $?
  fi

  # Run the real git command first
  command git "$@"
  local git_result=$?

  # Only proceed if command succeeded and was "git init"
  # Find subcommand, -C flag, and optional directory argument
  local is_init=false
  local init_dir=""
  local c_flag_dir=""
  local found_subcommand=false
  local next_is_c_arg=false

  for arg in "$@"; do
    # Capture argument after -C flag
    if [[ "${next_is_c_arg}" == "true" ]]; then
      c_flag_dir="${arg}"
      next_is_c_arg=false
      continue
    fi

    # Check for -C flag (git only supports "-C <path>" with space, not "-C<path>")
    if [[ "${arg}" == "-C" ]]; then
      next_is_c_arg=true
      continue
    fi

    # Skip other flags
    if [[ "${arg}" == -* ]]; then
      continue
    fi

    # First non-flag is the subcommand
    if [[ "${found_subcommand}" == "false" ]]; then
      [[ "${arg}" == "init" ]] && is_init=true
      found_subcommand=true
      continue
    fi

    # Second non-flag (after "init") is the directory
    if [[ "${is_init}" == "true" && -z "${init_dir}" ]]; then
      init_dir="${arg}"
      break
    fi
  done

  # Determine the target directory: -C flag takes precedence, then init_dir
  local target_dir=""
  if [[ -n "${c_flag_dir}" && -n "${init_dir}" ]]; then
    # Both -C and directory arg: combine them
    target_dir="${c_flag_dir}/${init_dir}"
  elif [[ -n "${c_flag_dir}" ]]; then
    # Just -C flag
    target_dir="${c_flag_dir}"
  elif [[ -n "${init_dir}" ]]; then
    # Just directory arg
    target_dir="${init_dir}"
  fi

  if ((git_result != 0)) || [[ "${is_init}" != "true" ]]; then
    return "${git_result}"
  fi

  # Set guard to prevent recursion in hooks
  # Exported so child processes (hooks) also bypass wrapper
  export _GIT_WRAPPER_ACTIVE=1

  # Save current directory if we need to change it
  local original_dir=""
  if [[ -n "${target_dir}" ]]; then
    original_dir=$(pwd)
  fi

  # Trap to cleanup guard and restore directory
  # Use ${var:-} for set -u safety — locals may be out of scope in inherited contexts
  trap 'unset _GIT_WRAPPER_ACTIVE; [[ -n "${original_dir:-}" ]] && cd "${original_dir:-}" 2>/dev/null || true' RETURN

  # If init created a repo in a different directory, cd there first
  # This makes git rev-parse work from inside the new repo
  if [[ -n "${target_dir}" ]]; then
    if ! cd "${target_dir}" 2>/dev/null; then
      echo "Error: Cannot cd to ${target_dir}" >&2
      return 1 # Return failure, not git_result
    fi
  fi

  # Let git tell us where the .git directory is
  # We're now inside the repo, so this returns ".git" (relative path)
  local git_dir
  git_dir=$(command git rev-parse --git-dir 2>/dev/null)

  if [[ -n "${git_dir}" ]]; then
    local post_checkout="${git_dir}/hooks/post-checkout"

    if [[ -x "${post_checkout}" ]]; then
      # Run hook with init parameters
      # Parameters: <prev-head> <new-head> <branch-checkout-flag>
      # Both SHAs are null since there are no commits yet after git init
      # Note: We're already in repo root, no need to cd again
      local null_sha="0000000000000000000000000000000000000000"
      if ! "${post_checkout}" "${null_sha}" "${null_sha}" 1; then
        echo "Warning: post-checkout hook execution failed" >&2
      fi
    fi
  fi

  return "${git_result}"
}
export -f git # Exported - overrides system git command globally
```

- [ ] **Step 2: Run shellcheck on the new file**

Run: `shellcheck -S info bash/git-wrapper.sh`
Expected: no output (clean)

- [ ] **Step 3: Replace the extracted block in `functions.sh` with a source block**

In `functions.sh`, delete lines 899-1013 (the full `git()` function through `export -f git`) and replace with:

```bash
# ============================================================================
# Git Wrapper (post-init hook trigger)
# ============================================================================
# Canonical implementation lives in git-wrapper.sh (sourced below). See that
# file for why git, unlike gh, doesn't also get a standalone ~/.local/bin
# executable mode.

if [[ -f "${HOME}/.config/bash/git-wrapper.sh" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/.config/bash/git-wrapper.sh"
else
  echo "[git] WARNING: ${HOME}/.config/bash/git-wrapper.sh not found — git init post-checkout hook trigger is NOT active." >&2
  echo "[git] Run install.sh to restore it." >&2
fi
```

Note: unlike the `gh` fallback (which fails closed with an error-returning stub, because a missing `gh-wrapper.sh` would silently drop a security-relevant merge guard), the `git` fallback warns and leaves `git` unaliased — falling through to the real `git` binary is safe here since the only thing lost is a convenience hook trigger, not a safety guard.

- [ ] **Step 4: Verify functions.sh still sources cleanly**

Run: `bash -c 'source bash/functions.sh; type git'`
Expected: `git is a function` followed by the function body (confirms sourcing worked and `git` is still defined)

- [ ] **Step 5: Write a regression test pinning current behavior**

Create `bash/tests/test-git-wrapper-init-hook.sh`, modeled on `bash/tests/test-gh-wrapper-identity.sh`'s structure (isolated `HOME`, source in function-definition mode, assert observable side effects):

```bash
#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification for bash/git-wrapper.sh's post-init hook trigger.
# Run directly: bash bash/tests/test-git-wrapper-init-hook.sh
#
# Regression coverage for the git()->git-wrapper.sh extraction: git init
# (bare, with -C, and with a trailing directory arg) must still invoke the
# newly-created repo's post-checkout hook with null-SHA init parameters.
set -euo pipefail

unset CDPATH

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export BASH_CONFIG_DIR="${REPO_ROOT}/bash"

WORKDIR="/tmp/git-wrapper-init-hook-test-$$"
mkdir -p "${WORKDIR}"
trap 'rm -rf "${WORKDIR}"' EXIT

#shellcheck source=/dev/null
source "${BASH_CONFIG_DIR}/git-wrapper.sh"

fail=0

assert_hook_ran() {
  local desc="$1" repo_dir="$2"
  local marker="${repo_dir}/.git/hooks/post-checkout-ran"
  if [[ -f "${marker}" ]]; then
    echo "PASS: ${desc}"
  else
    echo "FAIL: ${desc} — expected ${marker} to exist"
    fail=1
  fi
}

install_hook() {
  local repo_dir="$1"
  mkdir -p "${repo_dir}/.git/hooks"
  cat >"${repo_dir}/.git/hooks/post-checkout" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "0000000000000000000000000000000000000000" ]] || exit 1
[[ "$2" == "0000000000000000000000000000000000000000" ]] || exit 1
[[ "$3" == "1" ]] || exit 1
touch "$(dirname "$0")/../post-checkout-ran"
EOF
  chmod +x "${repo_dir}/.git/hooks/post-checkout"
}

# Case 1: bare `git init` in the target directory (hook doesn't exist yet
# at init time, so we init first, then install the hook, then re-run init
# — git init is idempotent on an existing repo and still triggers our
# wrapper's post-init detection).
repo1="${WORKDIR}/repo1"
mkdir -p "${repo1}"
(cd "${repo1}" && command git init -q)
install_hook "${repo1}"
(cd "${repo1}" && git init -q)
assert_hook_ran "bare git init re-run triggers post-checkout hook" "${repo1}"

# Case 2: `git init -C <dir>`
repo2="${WORKDIR}/repo2"
mkdir -p "${repo2}"
(cd "${WORKDIR}" && command git init -q -C repo2)
install_hook "${repo2}"
git init -q -C "${repo2}"
assert_hook_ran "git init -C <dir> triggers post-checkout hook" "${repo2}"

# Case 3: `git init <dir>`
repo3="${WORKDIR}/repo3"
(cd "${WORKDIR}" && command git init -q repo3)
install_hook "${repo3}"
(cd "${WORKDIR}" && git init -q repo3)
assert_hook_ran "git init <dir> triggers post-checkout hook" "${repo3}"

if [[ "${fail}" -eq 1 ]]; then
  echo "FAILED"
  exit 1
fi
echo "All git-wrapper tests passed"
```

- [ ] **Step 6: Make the test executable and run it**

Run: `chmod +x bash/tests/test-git-wrapper-init-hook.sh && bash bash/tests/test-git-wrapper-init-hook.sh`
Expected: `All git-wrapper tests passed`

- [ ] **Step 7: Run shellcheck on the test file**

Run: `shellcheck -S info bash/tests/test-git-wrapper-init-hook.sh`
Expected: no output (clean)

- [ ] **Step 8: Add `git-wrapper.sh` to `install.sh`'s standalone-mode symlink dry-run/apply blocks — skip this step**

Not needed: `git-wrapper.sh` lives under `bash/`, which is already a known config dir (`install.sh:207`) and gets symlinked into `~/.config/bash/git-wrapper.sh` automatically by the existing `git -C "${REPO_DIR}" ls-files` loop (`install.sh:223-248`) once it's a tracked file. No `install.sh` changes needed for this task.

- [ ] **Step 9: Verify install.sh dry-run picks up the new file**

Run: `bash install.sh --dry-run 2>&1 | grep git-wrapper`
Expected: a line like `[DRY RUN] Would symlink: ~/.config/bash/git-wrapper.sh -> .../bash/git-wrapper.sh` (confirms it's picked up as a known config path, not flagged as unrecognized)

- [ ] **Step 10: Commit**

```bash
git add bash/git-wrapper.sh bash/functions.sh bash/tests/test-git-wrapper-init-hook.sh
git commit -m "refactor: extract git() post-init hook trigger into git-wrapper.sh"
```

---

### Task 2: Extract `gpush()` into `gpush-wrapper.sh`, sourced AND symlinked to `~/.local/bin/gpush`

**Files:**

- Create: `bash/gpush-wrapper.sh`
- Modify: `bash/functions.sh:1052-1255` (delete the `gpush()` function body; replace with a source block)
- Modify: `install.sh` (add the `~/.local/bin/gpush` symlink, mirroring the existing `~/.local/bin/gh` one)
- Test: `bash/tests/test-gpush-wrapper-guard.sh` (new)

**Interfaces:**

- Consumes: `git` (from `git-wrapper.sh`/Task 1, or the real binary in standalone mode), `gh` (from `gh-wrapper.sh`), `merge-lock` (external binary already on PATH).
- Produces: `gpush()` bash function when sourced (same signature/behavior as today: `gpush [--no-merge]`), AND a directly-executable script when run as `~/.local/bin/gpush` (dispatches to the same logic via `gpush "$@"` at the bottom, guarded by the sourced-vs-executed check).

- [ ] **Step 1: Create `bash/gpush-wrapper.sh` with the extracted function body plus dual-mode dispatch**

```bash
#!/usr/bin/env bash
# ~/.config/bash/gpush-wrapper.sh
# shellcheck shell=bash
# Canonical implementation of `gpush`: push the current branch, create (or
# reuse) its PR, watch CI, then optionally confirm+merge. Interactive and
# CLI-only — never invoked by non-interactive tooling. Two invocation modes,
# same idea as gh-wrapper.sh but simpler (no identity-switch/merge-bypass
# logic to duplicate, since gpush already goes through the git and gh
# wrappers for anything security-relevant):
#
#   1. Sourced from functions.sh: defines gpush() as a bash function.
#   2. Symlinked as ~/.local/bin/gpush and executed directly: runs gpush
#      with the script's own arguments. This exists purely so gpush can be
#      invoked as a standalone command outside a shell that has
#      functions.sh sourced (e.g. BASH_ENV unset) — gpush has no need for a
#      guard/bypass distinction the way gh does, so this mode is just a
#      thin dispatch, not a separate implementation.

gpush() {
  # Validate arguments
  case "${1:-}" in
    --no-merge) ;;
    "") ;;
    *)
      echo "Usage: gpush [--no-merge]" >&2
      return 1
      ;;
  esac

  local no_merge=false
  if [[ "${1:-}" == "--no-merge" ]]; then
    no_merge=true
  fi

  local GREEN='\033[0;32m'
  local RED='\033[0;31m'
  local BLUE='\033[0;34m'
  local NC='\033[0m'

  # Step 1: Guard — refuse to run on main/master
  local branch
  branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
  if [[ -z "${branch}" || "${branch}" == "main" || "${branch}" == "master" ]]; then
    echo -e "${RED}[gpush]${NC} Refusing to run on ${branch:-detached HEAD}. Create a branch first." >&2
    return 1
  fi
  echo -e "${BLUE}[gpush]${NC} Branch: ${branch}"

  # Step 2: Push
  echo -e "${BLUE}[gpush]${NC} Pushing to origin..."
  if ! git push -u origin HEAD; then
    echo -e "${RED}[gpush]${NC} Push failed." >&2
    return 1
  fi

  # Step 3: Create PR (or detect existing one)
  local pr_number=""
  local pr_output
  echo -e "${BLUE}[gpush]${NC} Creating PR..."
  if pr_output=$(gh pr create --fill 2>&1); then
    # Extract PR number from URL in output (last line is typically the URL)
    pr_number=$(echo "${pr_output}" | grep -oE '/pull/[0-9]+' | tail -1 | grep -oE '[0-9]+')
    if [[ -z "${pr_number}" ]]; then
      echo -e "${RED}[gpush]${NC} Could not parse PR number from create output." >&2
      echo "${pr_output}" >&2
      return 1
    fi
    echo -e "${GREEN}[gpush]${NC} Created PR #${pr_number}"
  else
    # PR may already exist
    if echo "${pr_output}" | grep -qi "already exists"; then
      pr_number=$(gh pr view --json number -q .number 2>/dev/null)
      if [[ -n "${pr_number}" ]]; then
        echo -e "${BLUE}[gpush]${NC} PR #${pr_number} already exists, continuing"
      else
        echo -e "${RED}[gpush]${NC} PR already exists but could not retrieve its number — check 'gh pr view' manually." >&2
        return 1
      fi
    fi
    if [[ -z "${pr_number}" ]]; then
      echo -e "${RED}[gpush]${NC} Failed to create PR:" >&2
      echo "${pr_output}" >&2
      return 1
    fi
  fi

  # Step 4: Watch CI (use gh run watch — gh pr checks fails with PAT errors)
  # Anchor on the pushed commit SHA to avoid watching a stale run from a prior push.
  # A push can trigger multiple workflow runs (e.g. "Claude Blocking Review" +
  # "Dependabot Auto-Merge"). We fetch all runs for the commit, watch each one,
  # and skip runs whose workflow name matches ignorable_when_skipped when their
  # conclusion is "skipped" (e.g. Dependabot workflows on non-Dependabot branches).
  local head_sha
  head_sha=$(git rev-parse HEAD)
  echo -e "${BLUE}[gpush]${NC} Waiting for CI runs on ${head_sha:0:7}..."

  local ignorable_when_skipped=("Dependabot")
  local all_runs=""
  local attempts=0
  while [[ -z "${all_runs}" && ${attempts} -lt 15 ]]; do
    all_runs=$(gh run list --branch "${branch}" --commit "${head_sha}" --json databaseId,name -q '.[] | (.databaseId | tostring) + "\t" + .name' 2>/dev/null || true)
    if [[ -z "${all_runs}" ]]; then
      ((attempts += 1))
      sleep 2
    fi
  done
  if [[ -z "${all_runs}" ]]; then
    echo -e "${RED}[gpush]${NC} No CI runs found for ${head_sha:0:7} after 30s. Check GitHub Actions." >&2
    return 1
  fi

  # Re-poll after a short delay to catch late-registering workflows.
  # Only adopt the result if non-empty — a transient API failure must not
  # discard the known-good first poll.
  sleep 3
  local repoll
  repoll=$(gh run list --branch "${branch}" --commit "${head_sha}" --json databaseId,name -q '.[] | (.databaseId | tostring) + "\t" + .name' 2>/dev/null || true)
  if [[ -n "${repoll}" ]]; then
    all_runs=$(printf '%s\n%s\n' "${all_runs}" "${repoll}" | sort -u -t$'\t' -k1,1)
  fi

  local ci_passed=false
  local ci_failed=false
  local fail_detail=""
  local run_id run_name pattern
  while IFS=$'\t' read -r run_id run_name; do
    [[ -z "${run_id}" ]] && continue
    echo -e "${BLUE}[gpush]${NC} Watching run ${run_id} (${run_name})..."
    timeout 3600 gh run watch "${run_id}" >/dev/null 2>&1 || true

    local run_conclusion
    run_conclusion=$(gh run view "${run_id}" --json conclusion --jq '.conclusion') || {
      echo -e "${RED}[gpush]${NC} Failed to query run ${run_id} status." >&2
      return 1
    }

    if [[ -z "${run_conclusion}" || "${run_conclusion}" == "null" ]]; then
      echo -e "${RED}[gpush]${NC} CI run ${run_id} did not complete within 1 hour — check status manually: gh run view ${run_id}" >&2
      return 1
    fi

    if [[ "${run_conclusion}" == "success" ]]; then
      echo -e "${GREEN}[gpush]${NC} Passed: ${run_name}"
      ci_passed=true
    elif [[ "${run_conclusion}" == "skipped" ]]; then
      local ignorable=false
      for pattern in "${ignorable_when_skipped[@]}"; do
        if [[ "${run_name}" == *"${pattern}"* ]]; then
          ignorable=true
          break
        fi
      done
      if [[ "${ignorable}" == true ]]; then
        echo -e "${BLUE}[gpush]${NC} Ignoring skipped run: ${run_name}"
      else
        ci_failed=true
        fail_detail+="${run_name}: ${run_conclusion}; "
      fi
    else
      ci_failed=true
      fail_detail+="${run_name}: ${run_conclusion}; "
    fi
  done <<<"${all_runs}"

  if [[ "${ci_failed}" == true ]]; then
    fail_detail="${fail_detail%; }"
    echo -e "${RED}[gpush]${NC} CI failed (${fail_detail}). Fix and re-run gpush." >&2
    return 1
  fi
  if [[ "${ci_passed}" == false ]]; then
    echo -e "${RED}[gpush]${NC} No CI runs succeeded (all were skipped). Check GitHub Actions." >&2
    return 1
  fi
  echo -e "${GREEN}[gpush]${NC} CI passed"

  if [[ "${no_merge}" == true ]]; then
    echo -e "${GREEN}[gpush]${NC} --no-merge: stopping after CI. PR #${pr_number} is ready."
    return 0
  fi

  # Step 5: Confirm and authorize merge
  local confirm
  echo ""
  read -r -p "[gpush] Merge PR #${pr_number}? [y/N] " confirm
  if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}[gpush]${NC} Merge cancelled. PR #${pr_number} is ready for manual merge."
    return 0
  fi

  if ! command -v merge-lock &>/dev/null; then
    echo -e "${RED}[gpush]${NC} merge-lock not found on PATH." >&2
    return 1
  fi
  if ! merge-lock auth "${pr_number}" "gpush"; then
    echo -e "${RED}[gpush]${NC} merge-lock authorization failed." >&2
    return 1
  fi

  # Step 6: Merge (goes through gh wrapper → pre-merge-review.sh)
  echo -e "${BLUE}[gpush]${NC} Merging PR #${pr_number}..."
  if ! gh pr merge "${pr_number}" --squash --delete-branch; then
    echo -e "${RED}[gpush]${NC} Merge failed. Check pre-merge review output above." >&2
    return 1
  fi
  echo -e "${GREEN}[gpush]${NC} PR #${pr_number} merged"

  # Step 7: Cleanup — handle each step independently
  local default_branch
  default_branch=$(git remote show origin 2>/dev/null | awk '/HEAD branch/ {print $NF}')
  default_branch="${default_branch:-main}"
  echo -e "${BLUE}[gpush]${NC} Cleaning up..."
  if ! git switch "${default_branch}"; then
    echo -e "${RED}[gpush]${NC} Failed to switch to ${default_branch}." >&2
    return 1
  fi
  if ! git pull --ff-only; then
    echo -e "${RED}[gpush]${NC} Fast-forward pull of ${default_branch} failed — local branch has diverged from origin. Resolve manually with 'git pull' or 'git rebase'." >&2
    return 1
  fi
  git branch -D "${branch}" 2>/dev/null || true
  echo -e "${GREEN}[gpush]${NC} Done. Back on ${default_branch}."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # --- Standalone-executable mode (executed directly, e.g. via the
  # ~/.local/bin/gpush symlink) ---
  set -euo pipefail
  gpush "$@"
else
  # --- Function-definition mode (sourced from functions.sh) ---
  export -f gpush
fi
```

- [ ] **Step 2: Run shellcheck on the new file**

Run: `shellcheck -S info bash/gpush-wrapper.sh`
Expected: no output (clean)

- [ ] **Step 3: Replace the extracted block in `functions.sh` with a source block**

In `functions.sh`, delete lines 1052-1255 (the full `gpush()` function) and replace with:

```bash
# ============================================================================
# gpush — push, PR, watch CI, confirm+merge
# ============================================================================
# Canonical implementation lives in gpush-wrapper.sh (sourced below), which
# also doubles as the standalone ~/.local/bin/gpush executable when
# symlinked and run directly. See that file for how the two modes work.

if [[ -f "${HOME}/.config/bash/gpush-wrapper.sh" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/.config/bash/gpush-wrapper.sh"
else
  echo "[gpush] WARNING: ${HOME}/.config/bash/gpush-wrapper.sh not found — gpush is unavailable." >&2
  echo "[gpush] Run install.sh to restore it." >&2
fi
```

- [ ] **Step 4: Verify functions.sh still sources cleanly and gpush is defined**

Run: `bash -c 'source bash/functions.sh; type gpush'`
Expected: `gpush is a function` followed by the function body

- [ ] **Step 5: Add the `~/.local/bin/gpush` symlink to `install.sh`**

In `install.sh`, immediately after the existing `~/.local/bin/gh` symlink block (around line 269), add the mirrored `gpush` symlink. First update the dry-run block:

Find (around line 259-260):

```bash
  _dry "Would create directory: ~/.local/bin"
  _dry "Would symlink: ~/.local/bin/gh -> ~/.config/bash/gh-wrapper.sh"
```

Replace with:

```bash
  _dry "Would create directory: ~/.local/bin"
  _dry "Would symlink: ~/.local/bin/gh -> ~/.config/bash/gh-wrapper.sh"
  _dry "Would symlink: ~/.local/bin/gpush -> ~/.config/bash/gpush-wrapper.sh"
```

Then update the apply block (around line 266-270):

Find:

```bash
  # ~/.local/bin must exist before this symlink is created; section 5
  # (CREATE DIRECTORIES) runs after this block, so it's created here instead.
  mkdir -p "${HOME}/.local/bin"
  _ensure_symlink "${HOME}/.config/bash/gh-wrapper.sh" "${HOME}/.local/bin/gh"
fi
```

Replace with:

```bash
  # ~/.local/bin must exist before this symlink is created; section 5
  # (CREATE DIRECTORIES) runs after this block, so it's created here instead.
  mkdir -p "${HOME}/.local/bin"
  _ensure_symlink "${HOME}/.config/bash/gh-wrapper.sh" "${HOME}/.local/bin/gh"
  _ensure_symlink "${HOME}/.config/bash/gpush-wrapper.sh" "${HOME}/.local/bin/gpush"
fi
```

- [ ] **Step 6: Run shellcheck on install.sh**

Run: `shellcheck -S info install.sh`
Expected: no output (clean)

- [ ] **Step 7: Verify install.sh dry-run picks up both changes**

Run: `bash install.sh --dry-run 2>&1 | grep -E "gpush-wrapper|local/bin/gpush"`
Expected: two lines — one for the `~/.config/bash/gpush-wrapper.sh` config symlink (from the generic `ls-files` loop, since `bash/` is a known dir), one for the `~/.local/bin/gpush` symlink just added

- [ ] **Step 8: Write a regression test pinning current guard/argument-validation behavior**

`gpush` mutates real git/GitHub state (pushes, creates PRs, merges) so a full integration test isn't appropriate here. Pin the parts that are pure logic: argument validation and the main-branch guard, using the same isolated-environment + function-stubbing approach as `test-gh-wrapper-identity.sh`.

Create `bash/tests/test-gpush-wrapper-guard.sh`:

```bash
#!/usr/bin/env bash
#shellcheck shell=bash
# Standalone verification for bash/gpush-wrapper.sh's argument validation
# and main-branch guard. Run directly: bash bash/tests/test-gpush-wrapper-guard.sh
#
# Regression coverage for the gpush()->gpush-wrapper.sh extraction: gpush
# must still reject unknown flags and refuse to run on main/master/detached
# HEAD, without touching real git remotes or GitHub state.
set -uo pipefail

unset CDPATH

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export BASH_CONFIG_DIR="${REPO_ROOT}/bash"

#shellcheck source=/dev/null
source "${BASH_CONFIG_DIR}/gpush-wrapper.sh"

fail=0

assert_fails() {
  local desc="$1"
  shift
  if "$@" >/tmp/gpush-test-out-$$ 2>&1; then
    echo "FAIL: ${desc} — expected non-zero exit, got 0"
    fail=1
  else
    echo "PASS: ${desc}"
  fi
  rm -f "/tmp/gpush-test-out-$$"
}

# Case 1: unknown flag rejected
assert_fails "gpush --bogus-flag rejected" gpush --bogus-flag

# Case 2: too many args rejected (case statement only matches empty or
# --no-merge in position 1; anything else, including valid-looking extra
# args, falls to the *) branch)
assert_fails "gpush --no-merge extra-arg rejected" bash -c 'source '"${BASH_CONFIG_DIR}"'/gpush-wrapper.sh; gpush --no-merge extra-arg'

# Case 3: refuses to run on main — stub `git symbolic-ref` to report main
WORKDIR="/tmp/gpush-wrapper-guard-test-$$"
mkdir -p "${WORKDIR}"
trap 'rm -rf "${WORKDIR}"' EXIT
(cd "${WORKDIR}" && command git init -q -b main && command git commit -q --allow-empty -m init)
(
  cd "${WORKDIR}" || exit 1
  #shellcheck source=/dev/null
  source "${BASH_CONFIG_DIR}/gpush-wrapper.sh"
  if gpush >/tmp/gpush-test-main-$$ 2>&1; then
    echo "FAIL: gpush on main branch — expected non-zero exit, got 0"
    fail=1
  else
    if grep -q "Refusing to run on main" /tmp/gpush-test-main-$$; then
      echo "PASS: gpush on main branch refuses with expected message"
    else
      echo "FAIL: gpush on main branch — wrong error message: $(cat /tmp/gpush-test-main-$$)"
      fail=1
    fi
  fi
  rm -f "/tmp/gpush-test-main-$$"
)

if [[ "${fail}" -eq 1 ]]; then
  echo "FAILED"
  exit 1
fi
echo "All gpush-wrapper guard tests passed"
```

- [ ] **Step 9: Make the test executable and run it**

Run: `chmod +x bash/tests/test-gpush-wrapper-guard.sh && bash bash/tests/test-gpush-wrapper-guard.sh`
Expected: `All gpush-wrapper guard tests passed`

- [ ] **Step 10: Run shellcheck on the test file**

Run: `shellcheck -S info bash/tests/test-gpush-wrapper-guard.sh`
Expected: no output (clean)

- [ ] **Step 11: Manually verify standalone-executable mode works**

Run: `bash bash/gpush-wrapper.sh --bogus-flag; echo "exit: $?"`
Expected: prints `Usage: gpush [--no-merge]` to stderr and `exit: 1` (confirms the `BASH_SOURCE[0]` == `${0}` dispatch at the bottom correctly invokes `gpush "$@"` when executed directly, not just when sourced)

- [ ] **Step 12: Commit**

```bash
git add bash/gpush-wrapper.sh bash/functions.sh install.sh bash/tests/test-gpush-wrapper-guard.sh
git commit -m "refactor: extract gpush() into gpush-wrapper.sh, symlink to ~/.local/bin/gpush"
```

---

### Task 3: Full local verification and functions.sh size check

**Files:**

- No new files; this task only runs verification across everything touched in Tasks 1-2.

**Interfaces:**

- Consumes: everything produced by Tasks 1 and 2.

- [ ] **Step 1: Confirm functions.sh shrank as expected**

Run: `wc -l bash/functions.sh`
Expected: roughly 1278 - 114 (git block, minus the ~10-line replacement) - 204 (gpush block, minus the ~10-line replacement) ≈ 960 lines (exact number will vary slightly based on comment lines added; the point is a meaningful reduction, not an exact match)

- [ ] **Step 2: Run the full existing test suite plus the two new tests**

Run:

```bash
for t in bash/tests/*.sh; do
  echo "=== ${t} ==="
  bash "${t}" || echo "FAILED: ${t}"
done
```

Expected: every test prints its own pass output; no `FAILED:` lines

- [ ] **Step 3: Run shellcheck across every touched/created file one more time as a batch**

Run: `shellcheck -S info bash/git-wrapper.sh bash/gpush-wrapper.sh bash/functions.sh install.sh bash/tests/test-git-wrapper-init-hook.sh bash/tests/test-gpush-wrapper-guard.sh`
Expected: no output (clean)

- [ ] **Step 4: Full dry-run install to confirm no unrecognized-path warnings**

Run: `bash install.sh --dry-run 2>&1 | grep -i "unrecognized"`
Expected: no output (both new `bash/*.sh` files are covered by the existing `bash` entry in `_KNOWN_CONFIG_DIRS`)

- [ ] **Step 5: Open a fresh interactive-equivalent shell and manually exercise both wrappers**

Run: `bash -l -c 'type git; type gpush; type gh'`
Expected: all three report `is a function`, confirming `.bash_profile` → `main.sh` → `functions.sh` still wires up all three wrappers correctly end-to-end after the extraction

This plan does not push, open a PR, or merge — per Protocol 6 (PR lifecycle), that happens after both commits from Tasks 1 and 2 exist on the branch created in Task 1 Step 1, followed by local review (Protocol 4) before any push.
