# Code Review — correctness only

Review the Rust crate in the current directory. Read every file under `src/` fully before judging.

## In scope

- Panics reachable from library code (`unwrap`, `expect`, indexing, division, arithmetic overflow)
- Wrong results on valid input; unhandled edge cases (empty input, missing separators, duplicate separators)
- Behavior that contradicts the doc comments

## Out of scope — do NOT request changes for these

Style, naming, documentation wording, performance, restructuring, additional features, missing tests. Requesting an out-of-scope change is a review error.

## Report format

For each real issue: `file:line — problem — why it is wrong — what correct behavior looks like`. If the previous round's feedback is attached below, verify each prior issue was actually addressed before anything else.

## Verdict contract (mandatory)

The FINAL line of your reply must be exactly one of:

APPROVED
REQUEST_CHANGES

`APPROVED` when no in-scope issues remain. `REQUEST_CHANGES` otherwise. No other text on that line.
