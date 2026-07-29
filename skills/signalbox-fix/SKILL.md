---
name: signalbox-fix
description: Address review findings on a signalbox shard and resubmit it. Use when dispatched with a shard payload carrying findings and a round greater than one.
---

# Fixing a shard

Review sent this shard back with findings. Your job is to address them and
resubmit. You are re-entering the **same vocabulary** `signalbox-implement`
uses, so everything that guarded the first pass guards this one.

## Your action space

Unchanged from implementation:

```bash
signalbox emit shard.file-written --field path=src/foo.py
signalbox emit shard.check-ran   --field cmd="cargo check" --field exit=0
signalbox emit shard.submitted   --field verdict=done
```

## The procedure

1. **Read `findings` in your payload.** Each finding names a file, a problem,
   and usually a location. Treat the list as exhaustive: findings not in it are
   not your business this round.

2. **Read the current state of your declared files before changing them.** If
   this is round 3+, earlier rounds already rewrote them. Do not reapply a fix
   that is already there, and do not reintroduce something a previous round
   deliberately removed.

3. **Address every finding.** For each one, either fix it, or be ready to say
   why it should not be fixed (see disagreement below). Partial fixes cost a
   full extra round.

4. **Announce each file as you rewrite it**, same as implementation.

5. **Resubmit** with `shard.submitted --field verdict=done`.

## When a finding is wrong

Reviewers are sometimes wrong, and silently complying with a bad finding makes
the code worse. You have two honest options:

- **Fix it anyway** if the change is harmless and the reviewer's underlying
  concern is real even if the specific claim is not.
- **Push back in the resubmission**, by including your reasoning:

  ```bash
  signalbox emit shard.submitted --field verdict=done \
    --field disputed='[{"finding": 2, "reason": "the null check is unreachable; the caller validates at line 40"}]'
  ```

  The next review round sees your reasoning. If the reviewer still disagrees,
  the round counter runs out and a human reads both sides. That is the intended
  path for a genuine disagreement.

What you must not do is quietly ignore a finding. An unaddressed finding with no
explanation reads as a failed fix and burns the round.

## Scope conflicts

A finding may ask you to change a file your shard does not declare. You cannot
do that, and you should not try.

```bash
signalbox emit shard.submitted --field verdict=blocked \
  --field reason="finding 3 requires editing src/other.py, which shard s2-wire declares"
```

This is the correct answer, not a failure. It surfaces a planning defect that no
amount of effort inside your shard can fix.

## The round budget

Five rounds, then the shard escalates to a human. Rounds are not free: each one
costs a full review cycle. If you are on round 4 and the findings keep shifting
rather than shrinking, that is a signal the shard is mis-specified — say so with
`verdict=blocked` and a clear reason rather than burning the last round.

## Discipline

Everything from `signalbox-implement` still applies: no placeholders, no
commits, no touching another shard's files, tests count as part of the work.
