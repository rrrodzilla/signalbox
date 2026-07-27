# Research task: author TESTING.md for this repository

Explore this repository's tests and CI and write the testing guide an
automated implementer needs to add tests that fit and to know when the
tree is green.

Cover, with concrete file paths:

1. **The gate** — the repo's actual commands that must pass before promotion,
   with file evidence from Taskfile/justfile/Makefile targets, CI workflows,
   `package.json` scripts, `CLAUDE.md`, or the language toolchain's real
   convention. If the repo declares no mechanical gate at all, state that
   plainly instead of inventing one. Also record what `install.sh` detection
   would choose, first match wins: a `ci` task in `Taskfile.yml` or
   `Taskfile.yaml` → `task ci`; a root `Cargo.toml` → `cargo clippy
   --all-targets -q && cargo nextest run`; a `ci` recipe in `justfile` →
   `just ci`; a `ci:` target in `Makefile` → `make ci`; or a `test` script in
   `package.json` → `pnpm test`, `yarn test`, or `npm test`, selected by
   lockfile. Explicitly flag any mismatch between that detected command and
   the repo's real gate: the harness runs the detected command, so a human
   must resolve the defect.
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
