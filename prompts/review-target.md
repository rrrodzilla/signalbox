# Code Review — correctness only

The current directory is a git worktree on a feature branch. Review ONLY the
changes this branch introduces relative to the repository's default branch —
discover the scope yourself (`git log --oneline main..HEAD` or the repo's
default branch, then `git diff main...HEAD`). Read enough surrounding code to
judge the changes in context, but pre-existing code outside the diff is not
under review.

## In scope

- __SIGNALBOX_LANG_PANICS__ introduced or made reachable by this diff
- Wrong results on valid input; unhandled edge cases the diff introduces
- Behavior that contradicts the doc comments, commit messages, or test names
  in the diff
- Tests in the diff that assert the wrong thing or cannot pass
- Changes that would fail to compile, or break callers UNINTENTIONALLY —
  see the intent rule below

## The intent rule

If a "Feature intent" section is attached below, it is the validated plan for
this branch and it is authoritative about WHAT the change is supposed to do.
API removals or breaking changes the plan declares deliberate are not defects
— versioning and release consequences are the release step's job, not this
review's. Judge whether the diff implements the declared intent correctly;
do not request that declared-intentional removals be restored, deprecated,
or version-gated. Breakage the plan does NOT declare is still in scope.

## Out of scope — do NOT request changes for these

Style, naming, documentation wording, performance, restructuring, additional
features, missing tests, pre-existing issues in code the diff does not touch,
semver/release management for changes the plan declares deliberate.
Requesting an out-of-scope change is a review error.

## Report format

For each real issue: `file:line — problem — why it is wrong — what correct
behavior looks like`. If the previous round's feedback is attached below,
verify each prior issue was actually addressed before anything else.

## Verdict contract (mandatory)

End your review with exactly one line containing only one of:

APPROVED

REQUEST_CHANGES

Nothing may follow the verdict line.
