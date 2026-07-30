---
name: signalbox-implement
description: Implement one shard of a signalbox stage, announcing every file write as an event. Use when dispatched with a shard payload containing shard_id, declared files, and an intent.
---

# Implementing a shard

You are implementing **one shard**. A shard is a slice of a stage scoped to a
declared list of files, and other shards of the same stage are being implemented
**right now, in parallel, in the same worktree**. That is safe only because the
plan guaranteed your file list is disjoint from theirs. Writing outside your
declared list breaks that guarantee for someone else.

Round 1 is the cold-start implementation session for this shard. Dispatch
records that runner session so a later review fix can resume your context;
`signalbox-fix` defines the round > 1 contract.

## Your action space

Three commands. That is the whole set.

```bash
signalbox emit shard.file-written --field path=src/foo.py
signalbox emit shard.check-ran   --field cmd="cargo check" --field exit=0
signalbox emit shard.submitted   --field verdict=done
```

You do not need to pass `run_id`, `shard_id`, `round`, or `declared` — those are
stamped from the environment and cannot be set from here. Do not try.

You **cannot** approve, merge, commit, open a PR, advance a stage, or mark
anything reviewed. Those are not events you can emit. If you find yourself
wanting one, the answer is `shard.submitted` and let the topology decide.

## The procedure

1. **Read before writing.** Read every file in `declared`, plus whatever you
   need for context. Reading anything is fine; writing is what is constrained.

2. **Write one file, then announce it, immediately.**

   ```bash
   signalbox emit shard.file-written --field path=<the path you just wrote>
   ```

   Announce after *each* file, not in a batch at the end. Two things depend on
   it: the scope guard evaluates each announcement the moment it lands, so an
   out-of-scope write is caught in seconds rather than after you finish; and
   this is the only way anything outside your session learns you are making
   progress. An unannounced write is invisible work.

3. **Announce checks as you run them.**

   ```bash
   signalbox emit shard.check-ran --field cmd="cargo check" --field exit=0
   ```

   Run the narrowest check that proves your shard compiles and behaves. Do not
   run the full suite — a later stage does that once, against the whole change.

4. **Finish with exactly one terminal announcement.**

   ```bash
   signalbox emit shard.submitted --field verdict=done
   ```

   or, if you genuinely cannot complete it:

   ```bash
   signalbox emit shard.submitted --field verdict=blocked \
     --field reason="the intent requires touching src/other.py, not in my scope"
   ```

   `blocked` is a legitimate, useful outcome. It escalates to a human with your
   reason attached. It is strictly better than silence, and much better than
   widening your own scope to make the problem go away.

## Scope

Your declared file list is the contract. If the intent cannot be satisfied
inside it, that is a planning defect, and the correct response is
`verdict=blocked` naming the file you would have needed.

Two independent mechanisms enforce this, so working around one does not help:

- The scope guard reacts to each `shard.file-written` you announce.
- The merge step stages **only declared files**. A write you never announced is
  also a write that never lands.

## Discipline

- **Tests belong in your shard.** If your declared files include a test file,
  the test is part of the work, not an afterthought.
- **No placeholders.** `TODO`, `unimplemented!()`, `pass  # later`, a stubbed
  return, or a test asserting `True` will be caught at review and cost a full
  round. If you cannot implement it, `blocked` is the honest answer.
- **Do not commit.** The stage's commit happens once, after every shard in the
  stage is approved. `git add` and `git commit` are not yours to run.
- **Do not touch another shard's files** even to fix something obviously broken
  in them. Announce `blocked` and say what you saw.
- **Stay in the worktree** named in your payload.

## If this is a fix round

`round > 1` means review sent this shard back and dispatch resumed the shard's
recorded runner session. Read `findings` in your payload and address each one.
You are re-entering the same vocabulary: announce every file you rewrite, then
`shard.submitted` again. See `signalbox-fix`.
