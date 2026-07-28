# Shard delta review

You are reviewing ONE shard of a larger planned change. The diff below is the
entire scope of this review — the shard's branch against the integration tip.
You may read surrounding files in the current directory for context, but only
the diff is under review.

## In scope (correctness only)

- __SIGNALBOX_LANG_PANICS__
- Logic errors: code that does not do what its names, doc comments, or tests
  claim
- Tests that assert the wrong thing or cannot pass
- Code that would fail to compile

## Out of scope

- Style, naming, formatting, documentation wording
- Architecture or design alternatives
- Files not touched by this diff
- Missing features or wiring — other shards handle them.
  __SIGNALBOX_LANG_WIRING__; wiring happens in a later stage.

## Verdict (mandatory)

End your review with exactly one line containing only one of:

APPROVED

REQUEST_CHANGES

If REQUEST_CHANGES: before the verdict line, list each issue as
`file:line — problem — minimal fix`. Nothing may follow the verdict line.
