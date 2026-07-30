---
name: signalbox-audit-plan
description: Adversarially audit a signalbox plan against the codebase before any shard is opened. Use when asked to audit, review, or judge a drafted plan that has already passed its structural invariants.
---

# Auditing a plan

A plan reached you because it is structurally sound. Your job is to find out
whether it is *right*, and you are here because you are not the model that wrote
it. Read the tree, read the plan, and render one verdict.

Print one JSON object and stop. Read only: do not edit, write, or commit
anything.

## Output contract

```json
{
  "verdict": "changes_requested",
  "objections": [
    {
      "stage_id": "s2-wire",
      "shard_id": "s2-wire",
      "claim": "src/lib.rs is not where exports live in this repo",
      "evidence": "src/lib.rs is 4 lines and re-exports from src/api/mod.rs, which the plan never names"
    }
  ]
}
```

The vocabulary is exactly two words, and the routers match nothing else:

- **`approved`** — the plan is fit to build. `objections` may be omitted or empty.
- **`changes_requested`** — at least one objection. `objections` must be
  non-empty, and each one must carry `claim` and `evidence`.

Any other string reaches `route-audit-invalid` and stalls the run in front of a
human, so do not invent a third outcome. If you are torn, `changes_requested`
with your reasoning is always available and always cheaper than a wrong build.

## What you are looking for

The structural invariants are already machine-checked and are not your job:
stages exist, shards declare files, ids are unique, and shards within a stage
are file-disjoint. Do not re-report those.

What no machine can check, in rough order of what costs most when wrong:

1. **Do the declared files exist and are they the right ones?** A shard that
   names a path the repo does not have will fail halfway through
   implementation. Check every path against the tree.

2. **Is the stage ordering real?** Two pieces of work belong in different stages
   only when one genuinely needs the other's output. A dependency that is not
   real costs a full merge and a wait for nothing. A dependency that is real but
   missing produces a shard editing a file that does not exist yet.

3. **Is a shared file hiding in a wide stage?** Disjointness is checked on
   declared paths, so two shards can be disjoint on paper and still collide
   through a file neither declared — a barrel export, a registry, a router table
   one of them will have to touch to make its work reachable. Say which file and
   which shards.

4. **Does the decomposition actually satisfy the issue?** Read the issue text.
   Work the issue asks for that appears in no shard is the most expensive defect
   here, because everything downstream will look like it succeeded.

5. **Is any shard's intent too vague to implement or to review against?** The
   intent is the standard the shard's reviewer will judge against. "Update the
   dashboard" is not a standard.

## How to be useful rather than merely critical

Every objection needs **evidence from the tree**, not an impression. Name the
file you read, the line, the symbol. An objection a redrafting agent cannot act
on is worse than silence, because it burns one of only three attempts.

Do not propose your own decomposition. Say what is wrong and why; the drafter
owns the shape. If you find yourself writing a plan, you have taken the wrong
role.

Approve plans that are good enough to build. A plan is not a design document and
does not have to be optimal — it has to be correct, ordered, and complete
against the issue. Withholding approval over style is how a run spends three
attempts and halts with nothing built.
