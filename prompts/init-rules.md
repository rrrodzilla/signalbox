# Research task: author ARCHI-rules.md for this repository

Explore this repository and distill the HARD conventions its code actually
follows — the rules an automated implementer must obey for its diff to look
native. Derive every rule from observed evidence, not from generic Rust
advice; cite `file:line` examples for each.

Cover:

1. **Error handling** — the error types in use, how errors propagate, whether
   unwrap/expect ever appear outside tests (and the repo's stance).
2. **Naming and layout** — module organization, file naming, where tests
   live, visibility habits (pub vs pub(crate)).
3. **Logging/observability** — the facade in use and its idioms.
4. **Dependency discipline** — how dependencies are added, feature-flag
   habits, workspace-level version management.
5. **Anti-patterns** — things the codebase deliberately avoids (with evidence
   of the avoided pattern being handled another way).
6. **Commit and API discipline** — anything observable from history or docs
   (conventional commits, semver habits, changelog).

Write each rule as one imperative line, followed by its evidence. A rule
without evidence does not belong in this file.

Start the file with exactly this frontmatter (run `date +%F` for the date):

```
---
created: <today>
generated-by: signalbox init
---
```

Your entire final message becomes the file verbatim — output ONLY the
document content, no preamble, no commentary.
