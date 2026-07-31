---
name: signalbox-plan-notes
description: Decide which vault notes a CI-verified signalbox change will make stale. Use when asked to plan documentation notes for an open pull request awaiting merge.
---

# Planning note updates

An open pull request has passed CI and is awaiting merge. Decide which vault
notes its verified branch will make **wrong**, and name them. Print one JSON
object and stop. You are not writing the notes — each one becomes its own event
and its own session.

## Output contract

```json
{
  "notes": [
    {"note": "shards", "reason": "scope is now enforced at write time, not at review"},
    {"note": "correlation-ids", "reason": "run identity moved to a payload key"}
  ]
}
```

An empty list is a valid and common answer when the vault was reviewed and no
note was made stale. It must include a non-empty `considered` array of bare note
names that were actually read:

```json
{"notes": [], "outcome": "reviewed", "considered": ["shards", "gates"]}
```

A non-empty `notes` list is self-evidencing and does not need `considered`.

If `$SIGNALBOX_VAULT` resolved but its notes could not be read, report the
blocked outcome as JSON:

```json
{"notes": [], "outcome": "blocked", "reason": "vault notes could not be read"}
```

`blocked` halts the run; it is not a clean terminal or an escape hatch for an
empty plan. Use `reviewed` only after enumerating the vault and reading the
relevant notes.

Nothing but the JSON object on stdout.

## The vault

One note per subsystem, in the vault directory. `$SIGNALBOX_VAULT` is an
absolute path already resolved by the harness as a precondition of this
invocation. Notes are markdown, named for the subsystem they describe:
`shards.md`, `review-loop.md`, `gates.md`. If the resolved vault cannot be
enumerated or its notes cannot be read, use the `blocked` output contract and
stop. Do not invent a fallback.

Never place notes under `.claude/`. Writes there are silently dropped while the
writing session reports success, so a note written there is a note that does not
exist and nobody finds out.

## What makes a note stale

Name a note only when the change makes something it says **false**. That is the
whole test.

Stale:
- a note describes a mechanism this change replaced
- a note documents a file, event, or command this change renamed or removed
- a note states an invariant this change altered
- a subsystem gained behaviour a note claims it does not have

Not stale:
- the change touched files the note mentions, but nothing the note *says*
  changed
- the note could be written better
- the note is missing something this change did not affect
- the change added something entirely new with no existing note (unless the
  subsystem itself is new — then name a new note and say so in `reason`)

Documentation churn is expensive and hides real changes in noise. A change that
made nothing false should produce `{"notes": []}` with `outcome: "reviewed"`
and non-empty `considered` evidence, and that is a good outcome.

## How to decide

1. Read the verified pull request branch's diff. Work from the diff, not from
   the issue text — the issue describes intent, while the CI-passing branch is
   the change awaiting merge.
2. List the vault notes. Read the ones covering subsystems the diff touched.
3. For each, find a specific sentence the change falsified. If you cannot point
   at one, the note is not stale.
4. Write the `reason` as that falsified claim, concretely enough that the
   session rewriting the note knows what to look for without re-deriving the
   whole change.

## Boundaries

- Do not write or edit any note. Naming it is the whole job.
- Do not name every note that mentions a changed file. Read it and check.
- Keep `reason` to one sentence about what is now false.
