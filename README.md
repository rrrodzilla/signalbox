# signalbox

An issue goes in, a merged pull request comes out. Plan, implement, review, and promote as one [Emergent](https://github.com/Govcraft/emergent) event topology: deterministic wiring, AI models at the nodes, and a human at the seams that need one.

The name is from railway signaling. A signal box is where the interlocking lives: levers, signals, and switches wired so that conflicting movements are *physically impossible*, not merely forbidden by rule. That is this system's core idea. An approval gate here is a place where no alternative wiring exists, so no model can talk its way around it.

## The shape

One engine. Four sources, one hundred twenty-eight handlers, eleven sinks, and no script that knows what comes next.

```
route-run-requested ─> [run.requested] ─> prepare-workspace, dashboard
[workspace.prepare-attempted]
├─< from: prepare-workspace
└─> to: route-prepare-ready, route-prepare-failed, dashboard
route-prepare-ready ─> [workspace.ready] ─> fetch-issue, dashboard
[workspace.failed (halt)]
├─< from: route-prepare-failed
└─> to: route-prepare-failed-halted, dashboard
[run.halted]
├─< from: route-prepare-failed-halted, route-fetch-failed-halted,
│         route-plan-draft-failed-halted, route-plan-exhausted,
│         route-plan-audit-failed-halted, route-audit-exhausted,
│         route-review-failed-halted, guard-ci-review-rounds-exhaust,
│         route-ci-review-invalid-halted, route-stage-dirty,
│         route-rebase-failed-halted, route-suite-error-halted,
│         route-assess-failed-halted, route-remediation-closed-halted,
│         route-remediation-invalid-halted, route-remediation-failed-halted,
│         guard-ci-rounds-exhaust, route-ci-findings-refused-terminal,
│         route-ci-commit-refused-terminal, route-ci-shard-terminal-halted,
│         route-notes-plan-failed-halted, route-notes-invalid-halted,
│         route-completion-short
└─> to: clear-pr-pending, dashboard, notify, trace
[issue.fetch-attempted]
├─< from: fetch-issue
└─> to: route-fetch-fetched, route-fetch-failed, dashboard
[issue.fetched]
├─< from: route-fetch-fetched
└─> to: draft-plan (opus; surveys the tree and reads the vault), dashboard
[issue.fetch-failed (halt)]
├─< from: route-fetch-failed
└─> to: route-fetch-failed-halted, dashboard
[plan.submitted]
├─< from: draft-plan (opus; surveys the tree and reads the vault)
└─> to: route-plan-invalid, check-plan, dashboard
[plan.invalid-verdict]
├─< from: route-plan-invalid, route-audit-invalid
└─> to: route-remediation-open, dashboard, trace
[plan.checked (halt)]
├─< from: check-plan
└─> to: route-plan-verified, route-plan-retry, route-plan-exhausted, dashboard
[plan.verified]
├─< from: route-plan-verified
└─> to: audit-plan (codex; adversarial), dashboard
[plan.rejected (attempt < 3)]
├─< from: route-plan-retry, route-audit-changes
└─> to: draft-plan (opus; surveys the tree and reads the vault), dashboard
[plan.audited (halt)]
├─< from: audit-plan (codex; adversarial)
└─> to: route-plan-approved, route-audit-changes, route-audit-exhausted,
        route-audit-invalid, dashboard
route-plan-approved ─> [plan.accepted] ─> open-first-stage, dashboard
[run.built]
├─< from: join-run, guard-remediation-resume-built
└─> to: rebase-branch, dashboard
[suite.ran]
├─< from: route-suite-ran, guard-remediation-resume-suite
└─> to: assess, dashboard
[stage.opened]
├─< from: open-first-stage, guard-stages-advance
└─> to: split-shards, dashboard
[branch.rebase-attempted]
├─< from: rebase-branch
└─> to: route-rebase-ok, route-rebase-conflict, route-rebase-invalid,
        dashboard
[gate.assessed]
├─< from: assess
└─> to: route-gate-auto, route-gate-human, route-gate-blocked,
        route-gate-invalid, dashboard
split-shards ─> [shard.opened] ─> dispatch-implement, dashboard
route-rebase-ok ─> [branch.rebased] ─> run-suite, dashboard
[branch.rebase-conflicted]
├─< from: route-rebase-conflict
└─> to: route-remediation-open, dashboard, notify
route-gate-auto ─> [gate.cleared] ─> push-branch, dashboard
[approval.requested]
├─< from: route-gate-human
└─> to: mark-approval-pending, dashboard, notify
route-file-written ─> [shard.file-written] ─> scope-guard, dashboard
route-check-ran ─> [shard.check-ran] ─> dashboard
[shard.submitted]
├─< from: route-shard-submitted
└─> to: route-shard-done, route-shard-blocked, route-shard-invalid,
        clear-pending, dashboard
[approval.granted]
├─< from: route-approval-granted
└─> to: push-branch, clear-approval-pending, dashboard
route-check-suite ─> [checks.observed] ─> rehydrate-pr, dashboard
[suite.run-attempted]
├─< from: run-suite
└─> to: route-suite-ran, route-suite-errored, dashboard
[branch.push-attempted]
├─< from: push-branch
└─> to: route-push-pushed, route-push-failed, dashboard
[checks.reported]
├─< from: rehydrate-pr
└─> to: route-checks-passed, route-checks-failed, dashboard
[scope.violated (halt)]
├─< from: scope-guard
└─> to: join-stage, route-ci-shard-terminal-halted, clear-pending, dashboard,
        notify
route-shard-done ─> [shard.built] ─> review-shard, dashboard
[stage.closed (halt)]
├─< from: join-stage
└─> to: route-stage-clean, route-stage-dirty, dashboard
[suite.errored (halt)]
├─< from: route-suite-errored
└─> to: route-suite-error-halted, dashboard, notify
route-push-pushed ─> [branch.pushed] ─> open-pr, dashboard
route-push-failed ─> [branch.push-failed] ─> route-remediation-open, dashboard
[review.submitted (halt)]
├─< from: review-shard
└─> to: route-approved, route-changes, route-review-invalid,
        route-ci-approved, route-ci-changes, route-ci-review-invalid-halted,
        dashboard
route-stage-clean ─> [stage.mergeable] ─> merge-stage, dashboard
[pr.open-attempted]
├─< from: open-pr
└─> to: route-open-opened, route-open-failed, dashboard
route-checks-passed ─> [checks.passed] ─> merge-pr, plan-notes, dashboard
route-checks-failed ─> [checks.failed] ─> detail-failed-checks, dashboard
route-approved ─> [shard.approved] ─> join-stage, dashboard
[shard.changes-requested]
├─< from: route-changes
└─> to: guard-rounds-continue, guard-rounds-exhaust, dashboard
route-ci-approved ─> [ci.fix-approved] ─> commit-ci-fix, dashboard
[ci.changes-requested (halt)]
├─< from: route-ci-changes
└─> to: guard-ci-review-rounds-continue, guard-ci-review-rounds-exhaust,
        dashboard
[merge.attempted]
├─< from: merge-stage
└─> to: route-merge-ok, route-merge-conflict, dashboard
route-open-opened ─> [pr.opened] ─> mark-pr-pending, dashboard
route-open-failed ─> [pr.open-failed] ─> route-remediation-open, dashboard
[checks.detail-attempted]
├─< from: detail-failed-checks
└─> to: route-detail-detailed, route-detail-failed, dashboard
[pr.merge-attempted]
├─< from: merge-pr
└─> to: route-merge-pr-merged, route-merge-pr-failed, dashboard
[notes.planned]
├─< from: plan-notes
└─> to: route-notes-plan-accepted, route-notes-plan-invalid, dashboard
[fix.opened]
├─< from: guard-ci-review-rounds-continue, guard-rounds-continue,
│         guard-ci-rounds-continue
└─> to: dispatch-fix, dashboard
[stage.merged]
├─< from: route-merge-ok
└─> to: guard-stages-advance, guard-stages-exhaust, join-run, dashboard
route-merge-conflict ─> [stage.conflicted] ─> split-shards, dashboard
route-detail-detailed ─> [checks.detailed] ─> map-ci-to-findings, dashboard
route-detail-failed ─> [checks.detail-failed] ─> map-ci-to-findings, dashboard
[ci.commit-attempted]
├─< from: commit-ci-fix
└─> to: route-ci-commit-ok, route-ci-commit-refused-halted, dashboard
[pr.merged]
├─< from: route-merge-pr-merged
└─> to: close-issue, join-completion, dashboard
[pr.merge-failed]
├─< from: route-merge-pr-failed
└─> to: route-remediation-open, dashboard
route-notes-plan-accepted ─> [notes.plan-accepted] ─> split-notes, dashboard
[notes.invalid-verdict (halt)]
├─< from: route-notes-plan-invalid
└─> to: route-notes-invalid-halted, dashboard, trace
guard-stages-exhaust ─> [stages.exhausted] ─> dashboard
[ci.findings-attempted]
├─< from: map-ci-to-findings
└─> to: route-ci-findings-ok, route-ci-findings-refused-halted, dashboard
route-ci-commit-ok ─> [run.rebuilt] ─> rebase-branch, dashboard
[ci.commit-refused (halt)]
├─< from: route-ci-commit-refused-halted
└─> to: route-ci-commit-refused-terminal, dashboard
[issue.close-attempted]
├─< from: close-issue
└─> to: route-issue-closed, route-issue-close-failed, dashboard
split-notes, join-notes ─> [notes.synced] ─> join-completion, dashboard
[completion.closed (halt)]
├─< from: join-completion
└─> to: route-completion-full, route-completion-short, dashboard
[ci.fix-ready (halt)]
├─< from: route-ci-findings-ok
└─> to: guard-ci-rounds-continue, guard-ci-rounds-exhaust, dashboard
[ci.findings-refused (halt)]
├─< from: route-ci-findings-refused-halted
└─> to: route-ci-findings-refused-terminal, dashboard
route-issue-closed ─> [issue.closed] ─> dashboard
route-issue-close-failed ─> [issue.close-failed] ─> dashboard
write-note ─> [note.written] ─> join-notes, dashboard
[run.completed]
├─< from: route-completion-full
└─> to: release-workspace, clear-pr-pending, dashboard, trace
```

The remaining ten formerly stranded outcomes share a bounded diagnosis path:

```
[branch.push-failed] ─> route-remediation-open
[branch.rebase-conflicted] ─> route-remediation-open
[branch.rebase-invalid-verdict] ─> route-remediation-open
[checks.silent] ─> route-remediation-open
[gate.blocked] ─> route-remediation-open
[gate.invalid-verdict] ─> route-remediation-open
[plan.invalid-verdict] ─> route-remediation-open
[pr.merge-failed] ─> route-remediation-open
[pr.open-failed] ─> route-remediation-open
[review.invalid-verdict] ─> route-remediation-open
[remediation.requested]
├─< from: route-remediation-open, guard-remediation-retry
└─> to: remediate, dashboard
[remediation.assessed]
├─< from: remediate
└─> to: guard-remediation-retry, guard-remediation-exhaust,
        guard-remediation-resume-built, guard-remediation-resume-suite,
        route-remediation-resume-refused, route-remediation-halt,
        route-remediation-invalid, dashboard
[remediation.failed (halt)]
├─< from: remediate
└─> to: route-remediation-failed-halted, dashboard
[remediation.closed (halt)]
├─< from: guard-remediation-exhaust, route-remediation-resume-refused,
│         route-remediation-halt
└─> to: route-remediation-closed-halted, dashboard
[remediation.invalid-verdict (halt)]
├─< from: route-remediation-invalid
└─> to: route-remediation-invalid-halted, dashboard, trace
```

An unrecognized verdict becomes `remediation.invalid-verdict` and a failed
invocation becomes `remediation.failed`; each has its own router to
`run.halted`.

Four feedback edges close loops nobody sequenced: a rejected plan re-enters the planner, a review that requests changes re-enters implementation, a merge conflict reopens only the shards whose declared files collide, and a red CI run becomes review findings in the vocabulary the fix loop already speaks.

Acts publish one `*.attempted` event, then two exclusive routers select the
domain outcome from the returned payload. `ok: true` means the act's requested
domain outcome succeeded; a completed refusal or conflict is `ok: false`, not
success. The `-e` edge is reserved for the primitive itself crashing or timing
out; its error payload preserves the input event's run identity for downstream routing.
`run-suite` is the deliberate exception: its routers select `errored`, not
`ok`. A failing suite is a verdict that must reach the promotion gate, rather
than a topology transition; only failure to invoke a detected suite is routed
to `suite.errored`.

`completion.closed` is the completion rendezvous's neutral result, not a claim
that the run succeeded. Two exclusive jq routers interpret it: a payload with
both arms and `timed_out: false` becomes `run.completed`; a
`timed_out: true` payload keeps its one-arm results summary, gains the reason
`completion timed out — an arm never arrived`, and becomes `run.halted`.
Completed runs release their worktrees, while halted runs retain them as
evidence of the missing arm.

The promote path waits on a push, not a poll. GitHub delivers `check_suite.completed` to a loopback `http-source` and routers turn it into the vocabulary; `gh webhook forward` opens the tunnel, since GitHub cannot reach `127.0.0.1`. What that buys is a conclusion in about a second instead of up to a poll interval, and no `gh` call per tick — but it does not remove the reaper. A push source makes arrivals observable and silence invisible, so a missing workflow, a revoked hook, and a dropped delivery are indistinguishable from "still building": all three produce zero events. `reap-prs` is what turns that into `checks.silent`.

## Principles the wiring enforces

- **Behavior lives in the topology.** There is no `run-pipeline` subcommand and no script that knows the order of phases. Delete the engine and nothing runs, which is the test that says this is an Emergent system rather than a shell pipeline with extra steps.
- **A model announces; handlers decide.** Every judging node prints one JSON verdict and stops. Deterministic routers turn that one event type into the domain vocabulary, and an unrecognized verdict becomes `*.invalid-verdict` rather than a silent drop. Swapping a model for a rule later disturbs nothing around it.
- **Identity is never typed by a model.** Run, stage, shard, declared scope, and round counters are stamped from the inbound envelope, and an acting agent reads them from its environment. A model cannot reassign a shard, widen its scope, or reset a round counter by saying so. The narrow exception is each role's declared product key: that value is model-authored, and if the produced object omits it, the merged payload drops the inbound value and reports the omission rather than silently inheriting it.
- **Scope is enforced at write time.** One predicate on `shard.file-written` publishes `scope.violated` for a path no shard declared, which closes the stage before review ever sees it.
- **Silence has a name.** An agent that crashes or refuses produces no event at all, and neither does a CI system that was never configured; a pending marker plus an interval reaper turns each absence into `shard.silent` or `checks.silent`, and the marker is cleared the moment the thing does speak. This is the one invariant that does not get easier when a path moves from polling to push — it gets harder, and matters more.
- **No sink does work with consequences.** Sinks cannot publish, so anything whose result matters is a handler. The previous implementation put work in sinks and had to route every consequence out of band through the filesystem, which is where its artifact-polling, phase runner, readiness ledger, port leasing, and vault lock all came from. Removing that one assumption removed all five.

## Models per node

Ten nodes are non-deterministic. Nothing else in the system is.

Two of them judge the same artefact on purpose. `draft-plan` writes the plan on
opus; `audit-plan` tries to break it on codex. An auditor sharing the drafter's
model shares its blind spots, so the second opinion is only worth its call if it
is genuinely a second opinion.

| Node | Role | Runner | Default model | Override precedence | Judges or acts | Fix-round continuity |
|---|---|---|---|---|---|---|
| `draft-plan` | `plan` | claude | opus | `SIGNALBOX_MODEL_PLAN`, then `SIGNALBOX_MODEL` | judges | — |
| `audit-plan` | `audit` | codex | codex's own | `SIGNALBOX_CODEX_MODEL` | judges | — |
| `review-shard` | `review` | claude | opus | `SIGNALBOX_MODEL_REVIEW`, then `SIGNALBOX_MODEL` | judges | — |
| `rebase-branch` | `rebase` | claude | opus | `SIGNALBOX_MODEL_REBASE`, then `SIGNALBOX_MODEL` | acts (rebases the branch) | — |
| `assess` | `assess` | claude | opus | `SIGNALBOX_MODEL_ASSESS`, then `SIGNALBOX_MODEL` | judges | — |
| `remediate` | `remediate` | claude | opus | `SIGNALBOX_MODEL_REMEDIATE`, then `SIGNALBOX_MODEL` | judges | — |
| `plan-notes` | `plan-notes` | claude | sonnet | `SIGNALBOX_MODEL_PLAN_NOTES`, then `SIGNALBOX_MODEL` | judges | — |
| `write-note` | `write-note` | claude | sonnet | `SIGNALBOX_MODEL_WRITE_NOTE`, then `SIGNALBOX_MODEL` | acts (writes notes) | — |
| `dispatch-implement` | `implement` | codex | codex configured default | `SIGNALBOX_CODEX_MODEL` | acts (writes code) | records the runner session |
| `dispatch-fix` | `fix` | codex | codex configured default | `SIGNALBOX_CODEX_MODEL` | acts (writes code) | resumes it: Claude `--resume ID`; Codex `exec resume … ID -` |

Cross-vendor by design: codex writes the code, Claude reviews it, so no model approves its own work.

`remediate` is a judging node, not a repair node. It diagnoses a stranded
post-workspace outcome and returns `retry` for another bounded look, `resume`
at a declared pre-gate re-entry point, or `halt` with a reason for a human. A
resume at `run.built` re-rebases the branch and re-runs the suite; a resume at
`suite.ran` does neither. In both cases the run re-enters before `assess` and
must earn a fresh gate verdict. The remediation subgraph cannot publish any
post-gate-decision event: in particular it cannot publish `gate.cleared`,
`approval.granted`, or a promote-path event. That prohibition is topological;
allowing remediation to clear the gate would restore exactly the bypass the
gate exists to remove.

The judging nodes are Shape A — one execution, one verdict event, and the routers own the transition. The acting nodes are Shape B — an `exec-sink` dispatches, and the agent re-enters through the control endpoint with `signalbox emit` as it works. That is why the scope guard can fire mid-implementation instead of at review: a thirty-minute step publishing one event at the end would be a thirty-minute hole where nothing is observable, resumable, or reactive.

Both runners resolve the same `SKILL.md` by name. Claude reads `.claude/skills/`, codex reads `.codex/skills/`, and `prepare-workspace` installs into both, so the procedure is one reviewable file rather than two copies that drift.

Every one of these ten nodes publishes `model.invoked` at the mechanical
invocation boundary, whether the invocation succeeds or fails. Its core payload
is `{event: "model.invoked", role, runner, model}`, followed by the same
mechanically carried identity as the event it explains (`run_id`, stage/shard
identity, scope, round, and the other applicable correlation keys). It also
records `produces`, `ok`, and `duration_ms`, so a failed call still leaves an
auditable edge naming what it attempted and how long it ran.

`runner` and `model` are resolved in Python by the code that constructs the
subprocess, not reported by the model. `model.invoked` is deliberately absent
from the three-event `signalbox emit` vocabulary available to acting agents:
provenance is useful only if an agent cannot forge its runner, model, or
invocation. For Claude roles, the per-role variable shown in the table wins,
then `SIGNALBOX_MODEL`, then the role default. Codex has a separate
`SIGNALBOX_CODEX_MODEL` because model names are not portable between runners.
When that variable is unset, signalbox passes no model argument and the
`model.invoked` payload contains `model: null`, meaning codex chose its own
configured default; when it is set, signalbox passes that value and records the
same value in `model`.

The dashboard consumes these events as provenance rather than displaying them
as standalone feed rows. It joins each invocation to the most specific matching
mechanical identity on ordinary feed events and renders a `runner · model`
badge; a null codex model renders as just `codex`.

At the start of each run, `draft-plan` dispatches its own subagents to survey the
tree and read the notes vault, then plans from what they return. If the vault is
missing, recall degrades to an empty result rather than failing the run.

This was two topology roles joined on a rendezvous until sb-62 halted on it,
holding one of two arms, for want of an input the surveying agent was still
producing. The barrier was never orchestrating the breadth — the surveying agent
already fanned out on its own — so removing it cost nothing and closed the one
way the phase could lose a run.

## Quick start

Prerequisites: the Emergent engine and its primitives, `claude`, `codex`, `gh` (authenticated, with the `cli/gh-webhook` extension), `git` with a signing key, `jq`, `python3`, and `uv`. The operator must also export `SIGNALBOX_VAULT` as the absolute path of an existing notes-vault directory. It has no default: notes must live outside disposable run worktrees. `bin/harness.sh preflight` checks all of it and names what is missing.

```bash
emergent marketplace install exec-source exec-handler exec-sink \
    http-source sse-sink topology-viewer
gh extension install cli/gh-webhook
export SIGNALBOX_VAULT=/absolute/path/to/notes-vault

./bin/harness.sh install      # editable CLI install, then the invariant suite
./bin/harness.sh up           # engine + dashboard
./bin/harness.sh forward owner/name   # tunnel that repo's check suites in
./bin/harness.sh status       # what is listening, and which runs have worktrees
./bin/harness.sh down         # stop only the engine this checkout started
./bin/harness.sh restart      # stop that owned engine, then start it again

./bin/harness.sh launch 42 --repo owner/name --repo-path ~/code/my-repo
```

Watch it at **http://127.0.0.1:8103** (the run board) and **http://127.0.0.1:8102** (the live topology). A run's whole trail is in the event store; the viewer exposes it read-only at `GET /history?stream=8101`, with no caching, and then follows the live SSE stream. The default maps stream 8101 to `~/.local/share/emergent/signalbox/events.db`; additional engines can be mapped with repeated `signalbox dashboard --store PORT=DB-PATH` arguments. Missing stores simply produce an empty history. `bin/harness.sh down` sends SIGTERM so that trail flushes, but only to the engine whose ownership this checkout can prove; `restart` applies the same ownership check before starting another engine. If an engine is running but ownership cannot be proven, both commands refuse with `engine ownership not proven; stop it manually, then recover with: rm -f <checkout>/.harness/engine.pid <checkout>/.harness/engine.owner`. `status` remains useful without an ownership record: it falls back to reporting live engines without treating them as safe to stop.

The harness keeps its local process state under `.harness/`: `engine.pid` and `engine.owner` identify the engine this checkout started, alongside `engine.log`, `dashboard.log`, `dashboard.pid`, and the forwarder's `forward.log`, `forward.pid`, `forward.child.pid`, `forward.ready`, `forward.repo`, and `forward.owner` files.

When a run parks at the human gate, `notify` prints the paste-ready command
`signalbox approve <run-id>`. Run that exact invocation to approve it; there is
no port to supply and no event envelope to construct. Approval enters through
the control ingress and resumes only the named run.

The forwarder is the operator's job rather than the topology's, for two reasons: a primitive that opened a tunnel would be a primitive reaching outside the topology, and the engine cannot detect its own missing deliveries. The harness supervises the `gh webhook forward` websocket with capped backoff, timestamps every restart in `.harness/forward.log`, and stops the supervisor before its child during `down` and `restart`. `status` prints a loud failure with the runnable recovery command when the loop is absent; if the loop exists but its tunnel has not connected, both `forward` and `status` say that it is retrying and point to the log instead of calling it up. When the forwarder is down, `launch` refuses only if it can resolve the remote target and detect at least one CI workflow, then names the recovery command. An explicit `--repo` is the target even when `--repo-path` is also present, and its workflows are queried through `gh`; if `gh` is unauthenticated or offline and the workflow state cannot be determined, `launch` warns and continues instead of escalating that uncertainty into a refusal. Without `--repo`, it checks the selected local checkout (the current directory unless `--repo-path` is given); that path must itself be a Git root with an origin and a `.github/workflows/*.yml` or `.yaml` file, so a nested demo directory does not accidentally inherit its enclosing checkout's remote. Pass `--no-forwarder` to explicitly downgrade a missing-forwarder refusal to the same warning and continue the launch.

The install is editable on purpose. A built wheel is the one reliable way to end up running a stale copy of the code and skills while the source in front of you reads correct, and that failure is invisible — a stale skill reports a verdict, just the wrong one. `signalbox paths` prints where the running CLI actually resolves its package, skills, state, and vault.

## Dogfooding signalbox on signalbox

```bash
./bin/harness.sh dogfood 57      # launches issue 57 against this checkout as run sb-57
```

Three things about the target being this repository. A run branches from the checkout's **current HEAD**, read at `prepare-workspace` time, so check out the branch you want as the base before launching — and that branch has to exist on the remote, because the PR opens against it by name. The CLI is installed editable, so a run in flight is using the working tree it is also reading: land your edits and restart the engine (`./bin/harness.sh restart`) rather than editing underneath a live run. And `dogfood` starts the supervised webhook forwarder itself from the `origin` remote; ordinary `launch` refuses a promote-capable target when no forwarder is running and tells you to run `./bin/harness.sh forward <owner/name>`, unless `--no-forwarder` explicitly selects the warning path.

## Run the demo

`demo/` is a sacrificial crate with a deliberate reachable panic in `parse_pairs`.

```bash
./bin/harness.sh up
./bin/harness.sh launch 1 --repo-path ./demo --run-id demo-1 \
    --body-file /path/to/issue.md    # no remote needed; the issue text comes from disk
```

A local-only run needs no `gh`: `fetch-issue` passes through when the body is already on the envelope. Because `./demo` has no remote target, the missing-forwarder classifier warns and continues.

## Layout

| Path | Role |
|---|---|
| `emergent.toml` | The topology. The whole architecture is this file. |
| `skills/` | Twelve skill directories: ten roles map to skills, plus the planner's survey and recall subagent skills. The procedures are versioned and reviewable. |
| `src/signalbox/acts.py` | The irreducible I/O acts: worktree, issue, suite, merge, push, PR. |
| `src/signalbox/agent.py` | Shape A. One verdict per execution, identity re-stamped. |
| `src/signalbox/dispatch.py` | Shape B. Runner selection, sandbox, unspoofable identity. |
| `src/signalbox/emit.py` | An acting agent's entire action space: three events. |
| `src/signalbox/plan.py` | The pure invariants that license parallel shards. |
| `src/signalbox/topology_diagram.py` | Generates the topology pictures; `signalbox topology-diagram --write` refreshes them. |
| `src/signalbox/primitives/` | Three SDK primitives: two splitters and a joiner with a real timeout. |
| `src/signalbox/dashboard.html` | The run board, a static viewer over read-only event history and the SSE stream. |
| `tests/test_topology.py` | The architectural review questions as assertions. |
| `state_dir()/pending/` | Reaped silence markers for dispatched shards and open PR checks. |
| `state_dir()/sessions/` | Per-run fixer session identities, kept beside and outside `pending/`. |
| `bin/harness.sh` | Operator lifecycle. Knows nothing about phase order, by design. |

## The invariant tests

`tests/test_topology.py` is the part worth reading first. Together with the focused dispatch and act tests, it asserts things no runtime error would ever report: that the dashboard observes every topic the topology publishes, that no SSE subscription relies on a wildcard (they are silently ignored — health said `ok` while delivering zero bytes), that every subscription has a publisher and every published event has a consumer, that both sides of every depth guard are exclusive so a loop cannot run forever *or* terminate early, that every verdict type has an exhaustiveness router, that the field a join terminates on is a carried identity key, that anything writing a pending marker has something that clears it, that resume argv has the runner-specific shape while preserving the current sandbox and scope, that the unspoofable session-key environment seam is symmetric for both runners, that session files are recorded, survive submission, and are cleared on terminal retirement or reaping, that every `signalbox` subcommand the topology calls actually exists, that `signalbox topology-diagram --write` repairs README drift from the live graph, and that no primitive is named `runner`, `pipeline`, or `orchestrator`.

Each of those is a bug that already happened once.

## Lineage

Signalbox descends from [TRIP](https://github.com/PiLastDigit/TRIP-workflow) by PiLastDigit, the "Simple & BS-free Dev Workflow for AI Coding Agents." TRIP put clean names and discipline around a loop I had already been running by hand: plan, implement, review, promote, with verdict sentinels and a human gate. My fork of the original lives at [rrrodzilla/TRIP-workflow](https://github.com/rrrodzilla/TRIP-workflow).

What survives from upstream, gratefully: the sentinels, the review/fix bounce, and the release as the human's step. The situational gate is not upstream TRIP; I added it in my fork and carried it forward, because it answers the question every agent workflow dodges: *when* should the human stop approving?

Approval follows the Situational Leadership curve. Hersey and Blanchard's model says the right amount of supervision is not a property of the leader or a fixed policy; it is a function of the follower's demonstrated readiness for *the specific task*. Agents have the same shape, so `assess` hands a model the action's mechanics and the live context and gets back a floor, and a jq predicate compares earned readiness to that floor. Below it, `approval.requested` and a human decides. Nothing subscribes around the gate, so the block is topological rather than behavioral. Proven at one action says nothing about another, and readiness can regress.

The translation in one line: TRIP's sentinels became event topics, its review/fix bounce became a native feedback cycle, and its round cap became a two-sided jq guard instead of prose.
