# Research task: author ARCHI.md for this repository

Explore this repository thoroughly (Cargo workspace layout, module trees,
entry points, data flow) and write its architecture document. This is the
document every future implementer and reviewer will read FIRST before
touching the code — optimize for what a competent engineer needs to work
here without misreading the design.

Cover, with concrete file paths for every claim:

1. **Project type and purpose** — what this is, in two sentences.
2. **Crate/module map** — each crate (or top-level module) and its single
   responsibility; who depends on whom.
3. **Data flow** — how a request/message/value moves through the system,
   named types at each hop.
4. **Key types and traits** — the load-bearing abstractions and where they
   are defined; what implements what.
5. **Extension points** — where new functionality is meant to be added, and
   the pattern to follow (point at an existing example).
6. **Boundaries** — what is public API vs internal; anything semver-sensitive.

Start the file with exactly this frontmatter (run `date +%F` for the date):

```
---
created: <today>
generated-by: signalbox init
---
```

Your entire final message becomes the file verbatim — output ONLY the
document content, no preamble, no code fences around the whole document,
no commentary.
