# Research task: author TESTING.md for this repository

Explore this repository's tests and CI and write the testing guide an
automated implementer needs to add tests that fit and to know when the
tree is green.

Cover, with concrete file paths:

1. **The gate** — the exact commands that must pass before promotion
   (check CI workflows, justfile/Makefile, CLAUDE.md). If the repo shows no
   explicit gate, state the workspace defaults: `cargo clippy --all-targets`
   clean and `cargo nextest run` passing.
2. **Test layout** — unit tests vs integration tests vs doctests: where each
   lives, with examples.
3. **Test patterns** — fixtures, builders, helpers the tests share; how
   async tests are written if applicable; what a well-formed new test looks
   like here (point at a model example).
4. **Coverage expectations** — observable habits: do bug fixes come with
   regression tests, do new modules ship with tests.
5. **What NOT to do** — testing anti-patterns this repo avoids (sleeps,
   network in unit tests, order dependence), with evidence where visible.

Start the file with exactly this frontmatter (run `date +%F` for the date):

```
---
created: <today>
generated-by: signalbox init
---
```

Your entire final message becomes the file verbatim — output ONLY the
document content, no preamble, no commentary.
