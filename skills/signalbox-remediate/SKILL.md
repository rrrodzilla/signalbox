---
name: signalbox-remediate
description: Diagnose a stranded signalbox run and decide whether to halt it or retry the diagnosis once the condition may have cleared.
---

# Diagnosing a stranded run

Read the failing payload and the run's worktree, decide whether the fault needs
a human or may clear on another bounded look, and print one verdict. This is a
read-only judgment: diagnose the worktree but never edit it.

## Output contract

```json
{
  "remediation": "halt",
  "reason": "a specific diagnosis and the action a human should take"
}
```

`remediation` must be exactly `halt` or `retry`. These are the literal strings
the routers match. `reason` must be a non-empty string grounded in evidence you
read during this invocation.

## Read the failure payload

Read the topic that stranded the run and all identity and attempt fields in the
payload. For a primitive's `-e` topic, failure detail is nested under `error`:
read `.error.stderr`, `.error.exit_code`, and `.error.command` when present, not
top-level `.stderr`. An exit code may be null for timeout, spawn, or stdin
failures, so do not treat a missing numeric code as evidence that nothing
failed.

Do not accept a summary that the condition is transient or permanent. Read the
actual error fields and state which observed detail supports the verdict.

## Read the worktree

Inspect the run's own worktree read-only. Read the relevant files, git status,
diff, and logs needed to connect the failure payload to the repository state.
Do not edit, create, delete, commit, reset, rebase, or otherwise repair files.

This role is invoked only after `workspace.ready`: its runner requires the
run's worktree and must never fall back to the engine checkout or another run's
directory.

## Decision table

| Verified condition | Verdict |
|---|---|
| The fault requires a code, configuration, credential, permission, conflict, or operator decision | `halt` |
| The payload or worktree lacks enough evidence for a safe retry | `halt` |
| A second observation may succeed without changing the worktree or pipeline state | `retry` |
| The same condition remains after retry | `halt` |

## Halt

Choose `halt` when a human must intervene or when another observation would
only repeat a known failure. The `reason` must stand alone: name the failing
topic, the personally verified evidence, and the concrete action the human
should take. Do not claim to have repaired anything.

## Retry

Choose `retry` only for a condition that may clear on a second look without any
write or pipeline re-entry. The topology owns and bounds retries; do not alter,
reset, or invent its attempt counter. A retry means "judge the current
condition again," not "repair and rerun the pipeline."

## Containment

Never publish or request `gate.cleared`, `approval.granted`, `run.completed`, or
any promote-path event. Never use `signalbox emit`. If a run were repaired, it
would have to traverse the normal suite and `assess` path and re-earn its
verdict; this role neither repairs nor re-enters that path.

## Bias

Prefer `halt` when the case for a harmless second observation is uncertain.
Retries are bounded diagnostic capacity, not permission to speculate, mutate
state, or postpone an actionable human diagnosis.

## Evidence

Every factual statement in `reason` must have been personally verified in this
session from the inbound payload or this run's worktree. Do not cite inherited
claims, assumptions, or files you did not read.

Print exactly one JSON object on stdout and nothing else.
