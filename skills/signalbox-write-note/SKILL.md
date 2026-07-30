---
name: signalbox-write-note
description: Rewrite one vault note for the system a CI-verified change will produce. Use when asked to write a single signalbox vault note for an open pull request awaiting merge.
---

# Writing one vault note

An open pull request has passed CI and is awaiting merge. Bring **one** note into
agreement with the code on that verified branch. Print one JSON object and stop.
Other notes are being rewritten in parallel right now; touch only yours.

## Output contract

```json
{
  "note": "shards",
  "path": "/srv/signalbox-vault/shards.md",
  "outcome": "written",
  "summary": "scope enforcement moved from the review gate to write-time announcements"
}
```

If you conclude the note did not actually need changing:

```json
{"note": "shards", "path": "/srv/signalbox-vault/shards.md", "outcome": "written", "summary": "no change needed; the note was already accurate"}
```

Nothing but the JSON object on stdout.

## Where notes live

`$SIGNALBOX_VAULT` is always present as an absolute path stamped into the
environment by the harness. One file per subsystem, `<note>.md`.

If `$SIGNALBOX_VAULT` is somehow absent, report that and stop. Do not invent a
fallback.

Never write under `.claude/`. Writes there are silently discarded while the
session reports success — the note would not exist and nothing would tell you.
If your payload's path points under `.claude/`, stop and report
`outcome: "blocked"` with the path.

## What a note is for

A durable description of how one subsystem works and why it is built that way,
read by someone who needs to change that subsystem and has not seen it before.

The code is the source of truth, and the note is not a second copy of it. A note
earns its place by holding what the code cannot state about itself: why it is
shaped this way, what it must never do, and what has already gone wrong.

Two questions to ask of any sentence you are about to write or keep:

**Would it survive a rename?** If a refactor that changed no behaviour would
falsify the sentence, you have written down the code rather than the reasoning —
and you have committed some future run to rewriting it for no gain.

**Could the reader get it faster from the file?** If a minute in the source
answers it, the note is competing with the code as a second source of truth.
They will disagree eventually, the code will be right, and the note will have
spent that whole time quietly misleading someone.

Write:

- why it is built this way — especially the alternative that was rejected, and what made it unacceptable
- the invariants it maintains, and what breaks when they are violated
- failure modes someone would otherwise rediscover, with the consequence that made them matter
- enough of the subsystem's shape to orient a newcomer toward the right file

Do not write:

- an enumeration the code already maintains: key lists, field tables, event
  catalogues, function signatures, command flags. These are the sentences that
  go stale first, so they generate most of the rewriting that
  `signalbox-plan-notes` rightly calls expensive.
- a changelog — "this change", "previously", "as of PR #N", a narrative of how
  it used to work. A *durable pointer* is different and welcome: citing
  `[[known-defects]]` #65 for a defect that still binds outlives the diff that
  produced it, where narration of that diff does not.
- anything you did not verify by reading the code

That last point is about **how you know**, not **what you select**. Verify every
claim against the code; record only what the code cannot say for itself. Those
are separate questions, and a good note answers both — it is fully grounded in
the source and almost entirely absent from it.

## Procedure

1. **Read the current note in full.** You are revising a document, not
   generating one. Its structure, voice, and level of detail are decisions
   somebody made; keep them.
2. **Read the code it describes.** Not the diff, not the issue — the code as it
   stands now. The note has to be true tomorrow, and a note written from a diff
   describes a moment rather than a system.
3. **Read `reason` in your payload.** It names the specific claim the change
   falsified. That claim is your anchor.
4. **Correct what is false; leave sound reasoning alone.** A three-line fix to
   an otherwise accurate note is a good outcome. Rewriting wholesale destroys
   the parts that were right and makes the change impossible to review.
5. **Prefer replacing duplication over re-syncing it.** If your anchor lands you
   on an enumeration that mirrors the code, do not update it to match — cut it
   and say instead why it exists or what it guarantees. Nothing else in this
   pipeline ever removes such material, so a note that is only ever corrected
   accumulates mirror text forever. Stay near your anchor; this is not licence
   to prune the whole note.
6. **Check the links.** Notes reference each other with `[[note-name]]`. If your
   change renames a concept another note links to, fix the link *in your note
   only*. Never edit another note to accommodate yours — name the problem in
   `summary` and let the next run's planner see it.

## Boundaries

- One note. Yours. Not a second one, however obviously wrong it looks.
- Do not create new notes unless your payload names one that does not exist yet.
- Do not commit.
