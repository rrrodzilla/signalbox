---
name: signalbox-survey
description: Survey a codebase for the files and subsystems an issue touches, before planning. Use when asked to survey a repository against a fetched issue.
---

# Surveying a codebase for an issue

Find what this issue actually touches, so the planner decomposes against reality
rather than a guess. Print one JSON object and stop. Read anything; change
nothing.

## Output contract

```json
{
  "paths": ["src/greet.rs", "src/lib.rs", "tests/greet.rs"],
  "subsystems": [
    {"name": "greeting", "paths": ["src/greet.rs"], "role": "the module the issue asks to add"}
  ],
  "conventions": ["tests live beside the module in tests/", "errors use thiserror"],
  "shared_files": ["src/lib.rs"],
  "uncertainty": ["the issue does not say whether the old API stays"]
}
```

Nothing but the JSON object on stdout.

## What the planner needs from you

**`paths`** — every file a plan might reasonably need to create or edit. Err
toward including a file the plan turns out not to need; a missing path becomes a
shard that has to report itself blocked halfway through implementation.

**`shared_files`** is the field that most changes the plan. These are files
several pieces of work would each want to edit: `lib.rs`, `mod.rs`,
`__init__.py`, a router table, a registry, a barrel export. Shards in one stage
must be file-disjoint, so every shared file forces a later wiring stage. Naming
them here is what lets the planner get the stage boundaries right the first
time instead of failing an invariant and retrying.

**`conventions`** — what the surrounding code already does, so implementation
matches it: test layout and naming, error handling idiom, module structure,
logging, how dependencies are declared. Read the neighbours and report what you
see rather than what the ecosystem usually does.

**`uncertainty`** — anything genuinely ambiguous in the issue. The planner will
encode your reading into shard intents, so an ambiguity you record is one the
plan handles deliberately rather than accidentally.

## How to survey

1. Read the issue body in your payload closely, including anything it links or
   references by name.
2. Locate the subsystem it names. Grep for the symbols, types, and strings the
   issue mentions rather than guessing from directory names.
3. Read the files you find, and the files they import.
4. Find the tests for that subsystem, and read one to learn the conventions.
5. Identify which of the files you found are shared entry points.

Be thorough here. This is cheap, and it is the only step that sees the whole
picture — every step after it is scoped to a shard.

## Boundaries

- Do not propose a decomposition. Stages and shards are the planner's job, and
  a survey that pre-commits to a shape usually commits to a wrong one.
- Do not edit anything, including formatting.
- Do not ask questions. Record them in `uncertainty`.
