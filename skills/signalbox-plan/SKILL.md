---
name: signalbox-plan
description: Decompose a GitHub issue into signalbox stages and disjoint shards. Use when asked to produce a signalbox plan from an issue and a codebase survey.
---

# Planning a run

Produce a decomposition of the issue into **stages** (sequential) of **shards**
(parallel). Print one JSON object. Take no other action — you are not
implementing anything, and you must not edit a single file.

## Output contract

```json
{
  "stages": [
    {
      "stage_id": "s1-modules",
      "shards": [
        {"shard_id": "s1-greet", "files": ["src/greet.rs", "tests/greet.rs"], "intent": "add the greeting module and its tests"},
        {"shard_id": "s1-farewell", "files": ["src/farewell.rs"], "intent": "add the farewell module"}
      ]
    },
    {
      "stage_id": "s2-wire",
      "shards": [
        {"shard_id": "s2-wire", "files": ["src/lib.rs"], "intent": "export both modules"}
      ]
    }
  ]
}
```

Nothing else on stdout. No prose before or after.

## The invariants your plan is checked against

These are machine-checked the moment you submit. A violation sends the plan back
to you, and after three attempts the run halts. Getting them right the first
time is most of this job.

1. **At least one stage**, and every stage has at least one shard.
2. **Every shard declares at least one file**, and every file entry is a
   non-empty string.
3. **Every shard has a non-empty `intent`.**
4. **Shards within a stage must be file-disjoint.** This is the load-bearing
   one. Two shards in the same stage may not name the same path — not even to
   both add a line to it.
5. **`stage_id` and `shard_id` are unique across the whole plan.**

Stages *may* revisit a file that an earlier stage touched. That is expected: a
wiring stage usually edits a file that a module stage created.

## How to decompose

**Sequence by dependency, parallelise by independence.** Two pieces of work go
in the same stage when neither needs the other's output. They go in different
stages when one does.

The planner receives both the codebase survey and the concurrent vault recall.
Any claim derived from recall notes must name the note it came from in the
relevant shard intent. Notes may contribute hazards and warnings, but they never
supply paths or subsystems: use only the survey for those.

The usual shape is:

- **Stage 1** — new modules, types, or files. Naturally disjoint, so this stage
  is often wide.
- **Stage 2** — the wiring that connects them: exports, registration, the call
  site. Usually one shard, because it usually edits one file.
- **Stage 3+** — only if stage 2 creates something stage 3 depends on.

Prefer **fewer, wider stages**. Every stage boundary is a full merge and a wait
for every shard in it, so a five-stage plan of one shard each is the slowest
possible arrangement and gains nothing.

## Sizing a shard

A shard is one coherent unit of work a competent engineer would do in one
sitting, with its tests. Signals you have it wrong:

- **Too big:** the intent has an "and" joining unrelated things; the file list
  spans unrelated subsystems; you cannot say what "done" means in a sentence.
- **Too small:** the shard only makes sense alongside another shard in the same
  stage; the intent is a single line change with no test.

**Tests live in the shard that creates the behaviour.** If `src/greet.rs` needs
`tests/greet.rs`, both belong to one shard. Splitting them puts a test and its
subject in different shards, which either violates disjointness or leaves a
shard that cannot verify itself.

## The disjointness trap

The most common failure is two shards that both need to edit a shared file —
a `mod.rs`, a `lib.rs`, an `__init__.py`, a router table. You cannot split that
file between them.

The fix is always the same: **move the shared file into a later stage.** The
module shards create their modules in stage 1; a single wiring shard in stage 2
edits the shared file once, for all of them.

## If the issue is not decomposable

If the issue is genuinely one indivisible change, say so with one stage
containing one shard. A one-shard plan is a valid plan. Do not manufacture
parallelism that does not exist.

If the issue is too vague to plan against, produce your best reading of it and
put the ambiguity in the shard intents. Do not ask a question — nothing is
listening for one.
