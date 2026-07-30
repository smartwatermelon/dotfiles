# Scoped Worktree Policy — Design Proposal

**Status:** Draft, not yet approved
**Author:** Claude (session 2026-07-30), for Andrew Rich
**Scope:** Beacon-owned repos only. Does **not** touch the personal-side worktree
prohibition.

## Background

`git worktree` commands are currently hard-blocked everywhere by
`~/.claude/scripts/hook-block-all.sh`, following a past incident where a
worktree was removed while it held the only copy of some work. The commits
may have technically survived in the reflog for a while, but reflog is a
time-bombed safety net — it expires and gets garbage-collected — not a real
backstop. Practically, the work was gone.

That incident's actual failure mode was narrower than "worktrees are
dangerous": a worktree became the *sole copy* of some commits, and it was
deleted before those commits existed anywhere else. The blanket ban is a
reasonable response for solo, personally-funded work, where there's no
upside to the added process and parallel agents directly burn a
personally-paid token budget.

At Beacon, the calculus is different:

- Token budget is generous ($500/mo baseline, more with justification) and
  org-funded, not personal — parallel agents are a cost trade-off, not a
  fixed constraint.
- Work is collaborative — teammates may have the main checkout of a repo
  in a state you don't want to disturb, so an isolated working tree per
  task has real value, not just convenience.
- The `Agent` tool's `isolation: "worktree"` option depends on worktrees
  existing as an available mechanism at all.

This proposal scopes an exception to Beacon repos, with mechanical
safeguards designed to make the specific failure mode from the past
incident structurally impossible, rather than relying on remembering not
to do it again.

## Non-goals

- Does not change `~/.claude/CLAUDE.md` (global, personal instructions).
- Does not change `hook-block-all.sh`'s default-deny behavior for any repo
  not explicitly opted in.
- Does not attempt to make worktrees fully safe for arbitrary use — only
  for the specific "isolated task branch, later merged or discarded"
  pattern that's actually needed.

## Core safety principle

> **Local commits are not durable. A pushed remote branch is.**

Every rule below is a restatement of this one idea: a worktree may be
deleted freely once its branch exists on a remote, and must never be
deleted before that, regardless of how many local commits it has or how
"probably fine" it looks.

This mirrors how the session on 2026-07-30 actually played out by
accident: worktrees were only `rm -rf`'d after their branches were pushed,
reviewed, merged into `main` on GitHub, and the remote branch deleted by
the merge itself. By that point the local worktree was a redundant
checkout of history that already existed in at least two other places
(GitHub's `main`, and the reflog). Nothing was at risk. The goal here is
to make that sequencing mandatory and mechanically enforced, not
incidental.

## Proposed mechanism

### 1. Scope the exception per-repo, not globally

Reuse the pattern already built for `gh` identity auto-switching
(`_gh_sync_identity` in `bash/functions.sh`, #121/#122): detect "is this a
Beacon-owned repo" (by remote owner/org, or an explicit marker file) and
gate worktree permission on that, rather than editing the global hook.

Concretely:

- `hook-block-all.sh` gains a check: if the current repo's `origin` remote
  resolves to a known Beacon org/owner (same detection Andrew already uses
  for `gh` identity switching), and a repo-local opt-in file is present
  (e.g. `.claude/worktrees-allowed`), allow `git worktree` subcommands
  through to the next check (see #2). Otherwise, block exactly as today.
- The personal dotfiles repo, and any other personal repo, has no such
  marker and no Beacon-owner remote — the ban is untouched there by
  construction, not by a carve-out that has to be remembered.

### 2. Never delete by hand — always `git worktree remove`

Even in Beacon repos, raw `rm -rf` on a worktree directory is banned
without exception. `git worktree remove` must be used instead, because it
gives a real safety check for free: it refuses to remove a worktree with
uncommitted changes unless `--force` is passed.

`--force` is only permitted after independently checking
`git -C <worktree> status --porcelain` is empty. If it's not empty, stop
and ask — don't force through it.

### 3. Push-before-remove gate (the actual enforcement)

A repo-local wrapper/hook around `git worktree remove` (and around any
agent-driven cleanup step) checks, before allowing removal:

```
current_branch_sha=$(git -C "$worktree_path" rev-parse HEAD)
git branch -r --contains "$current_branch_sha" | grep -q origin/
```

If the current `HEAD` of the worktree's branch is **not** reachable from
any remote branch, block the removal and require one of:

- push the branch first, or
- an explicit human confirmation that the work is intentionally being
  discarded (not just "an agent decided this was done").

This is the one rule that directly prevents a repeat of the original
incident: it makes "worktree gets deleted while it's the only copy"
structurally unreachable rather than a matter of discipline.

### 4. No same-turn "merge then immediately clean up everything"

Cleanup of a merged worktree should be its own explicit step, ideally
after the coordinator or user has had a chance to see that CI passed and
the merge is final — not fused into the same tool-call batch as the
merge. This is a process habit, not a technical control, but worth
stating: today's session did this correctly by pausing for explicit
merge-lock authorization before merging, and only removing worktrees
after merge completion was independently confirmed via `gh pr view
--json state,mergedAt`.

### 5. Token-quota guardrail (separate concern from data safety)

Worktree isolation is what enables fanning out N parallel agents. Even
with a generous budget, unbounded fan-out isn't free or automatically
justified. Proposed soft rule: no more than 3-4 concurrent
worktree-isolated agents per task without an explicit reason stated up
front (mirroring the "more as needed with good justification" framing of
the Beacon token policy itself — the justification should exist for
*this* session, not be assumed from the org-level allowance).

## Summary of the four hard rules

1. Worktrees are allowed only in repos that are both Beacon-owned (by
   remote) **and** have opted in locally.
2. Removal is always via `git worktree remove`, never raw `rm -rf`.
3. Removal is blocked unless the worktree's current commit is reachable
   from a remote branch — pushed work is the durability boundary, not
   local commits.
4. `--force` requires an independently-verified clean `git status`
   first, never blind.

## Open questions for Andrew

- What's the actual Beacon-owner detection signal — same one used for
  `_gh_sync_identity`, or something simpler (a config list of known
  Beacon org names)?
- Should the opt-in marker (`.claude/worktrees-allowed` or similar) be
  something Andrew adds by hand per-repo, or should it be inferred purely
  from remote ownership with no extra marker file?
- Is 3-4 concurrent agents the right default soft cap, or does it depend
  heavily on task shape?
- Do you want the push-before-remove check to be a git hook (enforced
  even for manual `git worktree remove` outside of Claude Code), or is
  gating it at the Claude Code hook layer (`hook-block-all.sh`-adjacent)
  sufficient since manual worktree use isn't really the concern here?
