---
name: signalbox-recall
description: Recall relevant vault knowledge and attributed warnings before a signalbox run is planned.
---

# Recalling prior knowledge

Read the notes in `$SIGNALBOX_VAULT` that may bear on the current issue, without
modifying them. Recall runs concurrently with the codebase survey; the planner
consumes both results.

Print one JSON object on stdout and nothing else.

## Output contract

```json
{
  "hazards": [
    {"note": "identity.md", "claim": "the identity record has fifteen keys"}
  ],
  "warnings": [
    {"note": "known-defects.md", "claim": "issue #70 is still open"}
  ],
  "contradictions": [
    {"note": "known-defects.md", "claim": "issue #70 is still open", "evidence": "the issue payload says #70 is closed"}
  ],
  "contradictions_omitted": 0
}
```

Every hazard, warning, and contradiction must identify the note it came from.
Use the note's vault-relative name for attribution, never an absolute filename.
Return empty arrays and `0` when there is nothing to report.

## Procedure

1. Read the issue payload closely.
2. Inspect `$SIGNALBOX_VAULT` for relevant notes. Read notes only; never create,
   edit, rename, or delete them.
3. If `$SIGNALBOX_VAULT` is unset, absent, unreadable because it does not exist,
   or contains no notes, treat recall as empty and return the empty result. Do
   not invent another vault location.
4. Report note-derived hazards and warnings that may affect the issue. Preserve
   uncertainty: a note is prior knowledge, not proof that the repository still
   has the described state.
5. When the issue payload directly contradicts a note, report the contradiction
   with its note attribution and concise evidence.

## Boundaries

- Emit at most 10 contradictions. Put the number not emitted in
  `contradictions_omitted`. The first recall may encounter many stale notes at
  once; do not flood the planner with the whole backlog.
- Never emit `paths`, `subsystems`, or `conventions`, and never infer or supply
  them in another field. Those facts belong exclusively to the codebase survey.
- Do not inspect the codebase to validate notes. Recall contributes historical
  context; the concurrent survey contributes current repository facts.
- Never write under `.claude/`. The vault is read-only during recall, wherever
  `$SIGNALBOX_VAULT` points.
- Do not ask questions and do not print commentary around the JSON object.
