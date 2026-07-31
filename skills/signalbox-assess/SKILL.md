---
name: signalbox-assess
description: Decide whether a completed signalbox run may be promoted, based on the suite result and the change itself. Use when asked to assess a run after its suite has been run.
---

# Assessing a run for promotion

Decide whether this change can be promoted automatically, needs a human, or must
be blocked. Print one JSON object and stop.

## Output contract

```json
{
  "decision": "clear",
  "rationale": "one paragraph: what changed, and why that is safe to land",
  "evidence": ["suite: 46 passed 0 failed", "diff confined to declared shard files"]
}
```

`decision` must be **exactly** `clear`, `needs_human`, or `block`. Any other
string routes to an invalid-verdict event and stops the run.

## The suite is an observation, not a claim

Your payload carries the actual suite result: `ran`, `ok`, `errored`,
`exit_code`, `command`, `passed`, `failed`, and `output`. These come from the
process that ran it. On a suite payload, `ok` means the suite passed.

Read those fields. Do not read a summary of them, and do not accept any
statement anywhere that the suite passed. Decide on `ran` before `ok`: if `ran`
is `false`, the suite did not run, whatever else the payload says.

| Suite state | Decision |
|---|---|
| `ran: true`, `ok: true`, `failed: 0` | eligible for `clear` |
| `ran: true`, `ok: false` | **`block`** |
| `ran: false` | **`needs_human`**, never `clear` |
| `errored: true` | never reaches the assessor; routing sends `suite.errored` to a human |

A repository with no detectable suite is a real situation and reports
`ran: false` with a reason. That is not a pass. It means nobody can tell whether
this change works, which is exactly the case a human should look at.

A detected suite whose runner could not be invoked reports `errored: true`.
Stage s2-routing sends that payload to `suite.errored` and then to a human, so
the assessor must not invent a verdict for a payload it will never receive.

## Then look at the change

With a green suite, the decision is about risk, not correctness.

**`clear`** — every one of these holds:
- suite reports `ran: true`, `ok: true`, and `failed: 0`
- the diff stays inside the files the plan declared
- no shard escalated, was abandoned, or violated scope
- the change does not touch credentials, auth, permissions, migrations,
  deletion paths, or CI configuration
- no dependency was added or upgraded

**`needs_human`** — any of:
- the suite did not run
- a shard escalated or was abandoned, even though the stage later closed
- the change touches security-relevant code, data migration, or destructive
  operations
- a dependency changed
- the diff is large or sprawling enough that you cannot summarise it in a
  paragraph
- you are genuinely unsure

**`block`** — any of:
- the suite failed
- the diff contains files no shard declared
- placeholders survived into the final state (`TODO`, `unimplemented!()`,
  stubbed returns) — check, do not assume review caught them
- the change would obviously break the base branch

## Bias

`needs_human` is cheap: it posts a link and waits. `clear` on something that
should not have landed is expensive and hard to reverse. When the case for
`clear` and the case for `needs_human` feel close, choose `needs_human`.

Do not choose `clear` because a run took a long time or went through many fix
rounds. Effort already spent is not evidence of safety, and a shard that needed
five rounds is a reason for more scrutiny, not less.

## Evidence

`evidence` is a list of short factual strings, each of which you personally
verified in this session — a suite line, a diff observation, a file you read.
Do not put conclusions there, and do not put anything you inferred rather than
checked. Suite evidence must name the suite `command`, its `exit_code`, and its
`passed` and `failed` counts.
