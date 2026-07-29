---
name: signalbox-write-note
description: Rewrite one vault note so it describes the system as it now is. Use when asked to write a single signalbox vault note after a change landed.
---

# Writing one vault note

Bring **one** note back into agreement with the code. Print one JSON object and
stop. Other notes are being rewritten in parallel right now; touch only yours.

## Output contract

```json
{
  "note": "shards",
  "path": "docs/vault/shards.md",
  "outcome": "written",
  "summary": "scope enforcement moved from the review gate to write-time announcements"
}
```

If you conclude the note did not actually need changing:

```json
{"note": "shards", "path": "docs/vault/shards.md", "outcome": "written", "summary": "no change needed; the note was already accurate"}
```

Nothing but the JSON object on stdout.

## Where notes live

`$SIGNALBOX_VAULT`, defaulting to `docs/vault/`. One file per subsystem,
`<note>.md`.

Never write under `.claude/`. Writes there are silently discarded while the
session reports success — the note would not exist and nothing would tell you.
If your payload's path points under `.claude/`, stop and report
`outcome: "blocked"` with the path.

## Procedure

1. **Read the current note in full.** You are revising a document, not
   generating one. Its structure, voice, and level of detail are decisions
   somebody made; keep them.
2. **Read the code it describes.** Not the diff, not the issue — the code as it
   stands now. The note has to be true tomorrow, and a note written from a diff
   describes a moment rather than a system.
3. **Read `reason` in your payload.** It names the specific claim the change
   falsified. That claim is your anchor.
4. **Change what is false. Leave the rest alone.** A three-line correction to a
   still-accurate note is a good outcome. Rewriting a note wholesale destroys
   the parts that were right and makes the change impossible to review.
5. **Check the links.** Notes reference each other with `[[note-name]]`. If your
   change renames a concept another note links to, fix the link *in your note
   only*. Never edit another note to accommodate yours — name the problem in
   `summary` and let the next run's planner see it.

## What a vault note is

A durable description of how one subsystem works and why it is built that way.
It is read by someone who needs to change that subsystem and has not seen it
before.

Write:
- what the subsystem does, and the shape of it
- the invariants it maintains, and what breaks if they are violated
- why it is built this way, when the reason is not obvious
- the failure modes someone would otherwise rediscover

Do not write:
- a changelog, or any reference to "this change", a PR, or an issue number
- a narrative of how it used to work, unless the previous design explains a
  constraint that still binds
- API documentation that duplicates the code
- anything you did not verify by reading the code

## Boundaries

- One note. Yours. Not a second one, however obviously wrong it looks.
- Do not create new notes unless your payload names one that does not exist yet.
- Do not commit. A later step handles that.
