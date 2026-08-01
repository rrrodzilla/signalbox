---
name: signalbox-remediate
description: Diagnose a stranded signalbox run and decide whether to halt, retry the diagnosis, or resume at a declared pre-gate topic.
---

# Diagnosing a stranded run

Read the failing payload and the run's worktree, decide whether the fault needs
a human, may clear on another bounded look, or permits the existing run to
resume at a declared pre-gate topic, and print one verdict. This is a read-only
judgment: diagnose the worktree but never edit it.

## Output contract

```json
{
  "remediation": "halt",
  "reason": "a specific diagnosis and the action a human should take"
}
```

`remediation` must be exactly `halt`, `retry`, or `resume`. These are the
literal strings the routers match. `reason` must be a non-empty string grounded
in evidence you read during this invocation.

For `resume`, also include `"resume_topic": "run.built"`. `resume_topic` is the
carried key that records the chosen re-entry point. This is the complete
declared re-entry allowlist; the topology refuses every other topic.

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
| The condition has cleared and the unchanged worktree can safely rebase and rerun its suite | `resume` with `resume_topic` set to `run.built` |
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

## Resume

Choose `resume` only when evidence shows the condition has cleared without any
filesystem repair and the existing run can safely execute again from the
declared pre-gate re-entry point, `run.built`, which rebases the run and reruns
its suite. A re-observable condition calls for `retry`; a re-runnable condition
calls for `resume`.

Name the chosen point in `resume_topic`, but do not publish it or perform the
re-entry yourself. The model announces its judgment; fixed topology handlers
decide whether and where the run re-enters. Do not edit, create, delete, commit,
reset, rebase, or otherwise repair files before choosing `resume`.

## Containment

Never publish or request `gate.cleared`, `approval.granted`, `run.completed`, or
any promote-path event. Never use `signalbox emit`. This role remains read-only
and cannot perform re-entry; it may only announce an allowlisted pre-gate
`resume_topic` for topology handlers to evaluate. Every resumed run must reach
a fresh `gate.assessed` before it can progress toward `pr.merged`.

## Bias

Prefer `halt` when the case for a harmless retry or resume is uncertain.
Retries and resumes are bounded capacity, not permission to speculate, mutate
state, or postpone an actionable human diagnosis.

## Evidence

Every factual statement in `reason` must have been personally verified in this
session from the inbound payload or this run's worktree. Do not cite inherited
claims, assumptions, or files you did not read.

Print exactly one JSON object on stdout and nothing else.
