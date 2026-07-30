---
name: signalbox-rebase
description: Rebase a completed signalbox run onto the live base branch tip before its suite and promotion gate run.
---

# Rebasing before the suite

You receive `run.built`. Rebase the run branch in its worktree, then print one
JSON object and stop. The topology routes that object; do not emit events.

## Output contract

```json
{
  "ok": true,
  "rebased_onto_sha": "the full commit SHA of origin/<base_branch>",
  "conflicts": []
}
```

On refusal or an unresolvable conflict, return the same shape with `ok: false`,
the live tip (when it was resolved), and every conflicting path:

```json
{
  "ok": false,
  "rebased_onto_sha": "the full commit SHA of origin/<base_branch>",
  "conflicts": ["src/example.py"],
  "error": "short factual explanation"
}
```

`ok` must be exactly `true` or `false`. The successful router publishes
`branch.rebased`; the conflict router publishes `branch.rebase-conflicted`.
Anything without a boolean `ok` routes to `branch.rebase-invalid-verdict`.

## Target the live base

The target is the LIVE tip of `base_branch`, never the carried `base_sha`.
Run `git fetch origin`, resolve `origin/<base_branch>` to its full commit SHA,
and rebase the run branch onto that remote-tracking ref. Record that SHA under
the new product key `rebased_onto_sha`; do not overwrite `base_sha`, which is
the run's launch identity.

Work only in the payload's worktree. Confirm the current branch is the run
branch before changing it. Preserve both the run's work and upstream changes
when resolving conflicts, and continue the rebase only after the index has no
unmerged entries.

An unresolvable conflict is data, not permission to make it disappear. Abort
the rebase to leave the worktree usable, report `ok: false`, and name all paths
that conflicted. Never resolve a conflict by dropping a hunk merely to make the
rebase complete.
