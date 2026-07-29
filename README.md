# signalbox

An issue goes in, a merged pull request comes out. Plan, implement, review, and promote as one [Emergent](https://github.com/Govcraft/emergent) event topology: deterministic wiring, AI models at the nodes, and a human at the seams that need one.

The name is from railway signaling. A signal box is where the interlocking lives: levers, signals, and switches wired so that conflicting movements are *physically impossible*, not merely forbidden by rule. That is this system's core idea. An approval gate here is a place where no alternative wiring exists, so no model can talk its way around it.

## The shape

One engine. Three sources, fifty-two handlers, seven sinks, and no script that knows what comes next.

```
run.requested ─> workspace.ready ─> issue.fetched ─> codebase.surveyed
                                                          │
                                       ┌──────────────────┘
                                       ▼
                                  plan.submitted ─> plan.checked
                                       ▲                  │
                                       │        ┌─────────┴─────────┐
                                  plan.rejected ◄─ (attempt < 3)   plan.accepted
                                                                     │
                    pace-stages (one stage at a time, ack on merge) ◄─┘
                                       │
                                  stage.opened ─> split-shards ─> shard.opened
                                       ▲                              │
                                       │                       dispatch-implement
                              stage.conflicted                        │
                                       │            shard.file-written ─> scope.violated
                                       │            shard.check-ran        │
                                       │            shard.submitted        └─> stage.closed
                                       │                    │
                                       │              shard.built ─> review.submitted
                                       │                                  │
                                       │              ┌───────────────────┴────────────────┐
                                       │        shard.approved         shard.changes-requested
                                       │              │                      │      (round < 5)
                                       │         join-stage                  └─> fix.opened
                                       │              │
                                       │       stage.mergeable ─> merge.attempted
                                       │                                │
                                       └── stage.conflicted ◄───────────┴──────> stage.merged
                                                                                     │
                                                   join-run (stage_count) ◄───────────┘
                                                         │
                                             run.built ─> suite.ran ─> gate.assessed
                                                                            │
                                   ┌────────────────────────────────────────┤
                             gate.cleared                         approval.requested
                                   │                                        │
                                   └──────────> branch.pushed <── approval.granted
                                                     │
                                                 pr.opened
                                                     │
                        (GitHub check_suite) ─> checks.observed ─> checks.reported
                                                     │                   │
                                          ┌──────────┴──────┐       checks.failed
                                     pr.merged        notes.planned      │
                                          │                │      checks.detailed
                                          │          note.written        │
                                          │                │   shard.changes-requested
                                          │          notes.synced        │
                                          │                │      (fix.opened)
                                          └────────> run.completed
```

Four feedback edges close loops nobody sequenced: a rejected plan re-enters the planner, a review that requests changes re-enters implementation, a merge conflict reopens only the shards whose declared files collide, and a red CI run becomes review findings in the vocabulary the fix loop already speaks.

The promote path waits on a push, not a poll. GitHub delivers `check_suite.completed` to a loopback `http-source` and routers turn it into the vocabulary; `gh webhook forward` opens the tunnel, since GitHub cannot reach `127.0.0.1`. What that buys is a conclusion in about a second instead of up to a poll interval, and no `gh` call per tick — but it does not remove the reaper. A push source makes arrivals observable and silence invisible, so a missing workflow, a revoked hook, and a dropped delivery are indistinguishable from "still building": all three produce zero events. `reap-prs` is what turns that into `checks.silent`.

## Principles the wiring enforces

- **Behavior lives in the topology.** There is no `run-pipeline` subcommand and no script that knows the order of phases. Delete the engine and nothing runs, which is the test that says this is an Emergent system rather than a shell pipeline with extra steps.
- **A model announces; handlers decide.** Every judging node prints one JSON verdict and stops. Deterministic routers turn that one event type into the domain vocabulary, and an unrecognized verdict becomes `*.invalid-verdict` rather than a silent drop. Swapping a model for a rule later disturbs nothing around it.
- **Identity is never typed by a model.** Run, stage, shard, declared scope, and round counters are stamped from the inbound envelope, and an acting agent reads them from its environment. A model cannot reassign a shard, widen its scope, or reset a round counter by saying so.
- **Scope is enforced at write time.** One predicate on `shard.file-written` publishes `scope.violated` for a path no shard declared, which closes the stage before review ever sees it.
- **Silence has a name.** An agent that crashes or refuses produces no event at all, and neither does a CI system that was never configured; a pending marker plus an interval reaper turns each absence into `shard.silent` or `checks.silent`, and the marker is cleared the moment the thing does speak. This is the one invariant that does not get easier when a path moves from polling to push — it gets harder, and matters more.
- **No sink does work with consequences.** Sinks cannot publish, so anything whose result matters is a handler. The previous implementation put work in sinks and had to route every consequence out of band through the filesystem, which is where its artifact-polling, phase runner, readiness ledger, port leasing, and vault lock all came from. Removing that one assumption removed all five.

## Models per node

Eight nodes are non-deterministic. Nothing else in the system is.

| Node | Runner | Model | Judges or acts |
|---|---|---|---|
| `survey-codebase` | claude | fable | judges |
| `draft-plan` | claude | fable | judges |
| `review-shard` | claude | fable | judges |
| `assess` | claude | fable | judges |
| `plan-notes` | claude | sonnet | judges |
| `write-note` | claude | sonnet | acts (writes notes) |
| `dispatch-implement` | codex | codex default | acts (writes code) |
| `dispatch-fix` | codex | codex default | acts (writes code) |

Cross-vendor by design: codex writes the code, Claude reviews it, so no model approves its own work.

The judging nodes are Shape A — one execution, one verdict event, and the routers own the transition. The acting nodes are Shape B — an `exec-sink` dispatches, and the agent re-enters through the control endpoint with `signalbox emit` as it works. That is why the scope guard can fire mid-implementation instead of at review: a thirty-minute step publishing one event at the end would be a thirty-minute hole where nothing is observable, resumable, or reactive.

Both runners resolve the same `SKILL.md` by name. Claude reads `.claude/skills/`, codex reads `.codex/skills/`, and `prepare-workspace` installs into both, so the procedure is one reviewable file rather than two copies that drift.

Per-role overrides: `SIGNALBOX_MODEL_REVIEW` and friends for one role, `SIGNALBOX_MODEL` for every Claude role, `SIGNALBOX_CODEX_MODEL` for codex. The last is deliberately a separate variable, because model names are not portable between the runners.

## Quick start

Prerequisites: the Emergent engine and its primitives, `claude`, `codex`, `gh` (authenticated, with the `cli/gh-webhook` extension), `git` with a signing key, `jq`, `python3`, and `uv`. `bin/harness.sh preflight` checks all of it and names what is missing.

```bash
emergent marketplace install exec-source exec-handler exec-sink \
    stream-runner http-source sse-sink topology-viewer
gh extension install cli/gh-webhook

./bin/harness.sh install      # editable CLI install, then the invariant suite
./bin/harness.sh up           # engine + dashboard
./bin/harness.sh forward owner/name   # tunnel that repo's check suites in
./bin/harness.sh status       # what is listening, and which runs have worktrees

./bin/harness.sh launch 42 --repo owner/name --repo-path ~/code/my-repo
```

Watch it at **http://127.0.0.1:8103** (the run board) and **http://127.0.0.1:8102** (the live topology). A run's whole trail is in the event store; `bin/harness.sh down` sends SIGTERM so that trail flushes.

The forwarder is the operator's job rather than the topology's, for two reasons: a primitive that opened a tunnel would be a primitive reaching outside the topology, and the engine cannot detect its own missing deliveries. Without it a run reaches `pr.opened` and waits for the reaper. `status` says plainly whether it is up, and the target repo needs a CI workflow at all — with none configured, GitHub creates no check suite and there is nothing to forward.

The install is editable on purpose. A built wheel is the one reliable way to end up running a stale copy of the code and skills while the source in front of you reads correct, and that failure is invisible — a stale skill reports a verdict, just the wrong one. `signalbox paths` prints where the running CLI actually resolves its package, skills, and state.

## Dogfooding signalbox on signalbox

```bash
./bin/harness.sh dogfood 57      # launches issue 57 against this checkout as run sb-57
```

Three things about the target being this repository. A run branches from the checkout's **current HEAD**, read at `prepare-workspace` time, so check out the branch you want as the base before launching — and that branch has to exist on the remote, because the PR opens against it by name. The CLI is installed editable, so a run in flight is using the working tree it is also reading: land your edits and restart the engine (`./bin/harness.sh restart`) rather than editing underneath a live run. And `dogfood` starts the webhook forwarder itself from the `origin` remote, which `launch` does not.

## Run the demo

`demo/` is a sacrificial crate with a deliberate reachable panic in `parse_pairs`.

```bash
./bin/harness.sh up
./bin/harness.sh launch 1 --repo-path ./demo --run-id demo-1 \
    --body-file /path/to/issue.md    # no remote needed; the issue text comes from disk
```

A local-only run needs no `gh`: `fetch-issue` passes through when the body is already on the envelope.

## Layout

| Path | Role |
|---|---|
| `emergent.toml` | The topology. The whole architecture is this file. |
| `skills/` | Eight skills, one per model node. The procedures, versioned and reviewable. |
| `src/signalbox/acts.py` | The irreducible I/O acts: worktree, issue, suite, merge, push, PR. |
| `src/signalbox/agent.py` | Shape A. One verdict per execution, identity re-stamped. |
| `src/signalbox/dispatch.py` | Shape B. Runner selection, sandbox, unspoofable identity. |
| `src/signalbox/emit.py` | An acting agent's entire action space: three events. |
| `src/signalbox/plan.py` | The pure invariants that license parallel shards. |
| `src/signalbox/primitives/` | Three SDK primitives: two splitters and a joiner with a real timeout. |
| `src/signalbox/dashboard.html` | The run board, a static viewer over the SSE stream. |
| `tests/test_topology.py` | The architectural review questions as assertions. |
| `bin/harness.sh` | Operator lifecycle. Knows nothing about phase order, by design. |

## The invariant tests

`tests/test_topology.py` is the part worth reading first. It asserts things no runtime error would ever report: that the dashboard observes every topic the topology publishes, that no SSE subscription relies on a wildcard (they are silently ignored — health said `ok` while delivering zero bytes), that every subscription has a publisher and every published event has a consumer, that both sides of every depth guard are exclusive so a loop cannot run forever *or* terminate early, that every verdict type has an exhaustiveness router, that the field a join terminates on is a carried identity key, that anything writing a pending marker has something that clears it, that every `signalbox` subcommand the topology calls actually exists, and that no primitive is named `runner`, `pipeline`, or `orchestrator`.

Each of those is a bug that already happened once.

## Lineage

Signalbox descends from [TRIP](https://github.com/PiLastDigit/TRIP-workflow) by PiLastDigit, the "Simple & BS-free Dev Workflow for AI Coding Agents." TRIP put clean names and discipline around a loop I had already been running by hand: plan, implement, review, promote, with verdict sentinels and a human gate. My fork of the original lives at [rrrodzilla/TRIP-workflow](https://github.com/rrrodzilla/TRIP-workflow).

What survives from upstream, gratefully: the sentinels, the review/fix bounce, and the release as the human's step. The situational gate is not upstream TRIP; I added it in my fork and carried it forward, because it answers the question every agent workflow dodges: *when* should the human stop approving?

Approval follows the Situational Leadership curve. Hersey and Blanchard's model says the right amount of supervision is not a property of the leader or a fixed policy; it is a function of the follower's demonstrated readiness for *the specific task*. Agents have the same shape, so `assess` hands a model the action's mechanics and the live context and gets back a floor, and a jq predicate compares earned readiness to that floor. Below it, `approval.requested` and a human decides. Nothing subscribes around the gate, so the block is topological rather than behavioral. Proven at one action says nothing about another, and readiness can regress.

The translation in one line: TRIP's sentinels became event topics, its review/fix bounce became a native feedback cycle, and its round cap became a two-sided jq guard instead of prose.
