# signalbox

The TRIP workflow rebuilt as [Emergent](https://github.com/Govcraft/emergent) event topologies: plan, implement, review, and promote as deterministic wiring, with AI models at the nodes and an operator at the seams.

The name is from railway signaling. A signal box is where the interlocking lives: levers, signals, and switches wired so that conflicting movements are *physically impossible*, not merely forbidden by rule. That is this system's core idea. An approval gate here is a place where no alternative wiring exists, so no model can talk its way around it.

## Lineage: TRIP, and why signalbox exists

Signalbox descends from [TRIP](https://github.com/PiLastDigit/TRIP-workflow) by PiLastDigit, the "Simple & BS-free Dev Workflow for AI Coding Agents." Credit where it is due: TRIP put clean names and discipline around a loop I had already been running by hand (plan, implement, review, promote, with verdict sentinels and a human gate). My business partner pointed me at the upstream repo; I ran it for a few days, kept everything it got right, and then rebuilt it on Emergent, my open-source event-driven workflow engine. My fork of the original lives at [rrrodzilla/TRIP-workflow](https://github.com/rrrodzilla/TRIP-workflow).

Why a rebuild instead of a PR upstream:

- **TRIP tries to be everything for everybody.** I needed to take a stance on the models and agents in play. Signalbox commits: Codex (sol, high effort) reviews and implements; headless Claude (Opus) fixes, plans, and assesses; a Fable operator judges the phase seams and the promotion. Cross-vendor by design, so no model ever approves its own work.
- **Prompt-driven orchestration burns tokens on things that should be code.** In a skill-based workflow, the model spends tokens reading instructions, deciding which step comes next, and remembering rules it must not break. Signalbox makes everything programmatic that can be programmatic: routing, verdict parsing, round caps, plan validation, fan-in barriers, and gates are jq, flock, and wiring. Models spend tokens only where judgment is genuinely required.
- **I already keep project notes in an Obsidian vault.** TRIP's docs tree was one more filesystem format to maintain. Here `.claude/docs` is a symlink into the vault, so the workflow's architectural memory lives with the rest of my notes and every agent reads the same pages.
- **Linux is a feature, not a portability problem.** Symlinks share the vault and `.claude` across every worktree, `flock` is the fan-in barrier, and engines are plain processes with SIGTERM drain. Constraints that keep a workflow portable were solving a problem I don't have.
- **Emergent affords things prompts never could.** Deterministic orchestration (no model orchestrates; the engine routes). Real concurrency: sharded implementation in parallel worktrees, which a single chat session cannot do because it cannot be in two places at once. An event store that turns every feature into a queryable audit trail (`bin/audit.sh <correlation-id>`) instead of a scrollback. Topological gates: nothing subscribes around an approval, so trust is structural. Process lifecycle, graceful shutdown, and per-feature correlation ids for free.

What survives from upstream TRIP, gratefully: the sentinels, the review/fix bounce, architectural memory in `ARCHI.md`/`ARCHI-rules.md`/`TESTING.md`, local-only tooling under `.claude/`, and the release as the human's step. The R1-R4 situational-delegation ladder is not upstream TRIP; I added it in my fork and carried it forward here, because it answers the question every agent workflow dodges: *when* should the human stop approving? (See "Situational gate" below.)

The translation in one line: TRIP's sentinels become event topics, the review/fix bounce becomes a native feedback cycle, and the round cap becomes a jq guard instead of prose.

```
seed ──> review.requested ──> reviewer (codex exec, read-only) ──> review.raw
                 ▲                                                    │
                 │                                    ┌───────────────┴───────────────┐
                 │                              verdict-approved                verdict-changes
                 │                                    │                               │
                 │                              review.approved            review.changes_requested
                 │                                    │                               │
                 │                               docs-syncer                ┌──────────┴──────────┐
                 │                                    │               round-guard         escalation-guard
                 │                              docs.synced              (round < 4)         (round >= 4)
                 │                                    │                     │                     │
                 │                            promoter sink                │                     │
                 │                       (PROMOTION_READY → CR.md)          │                     │
                 └────────────── fixer (claude -p, acceptEdits) <── fix.requested          review.escalated
```

## Quick start, any repo, TRIP or not

```bash
# 0. prerequisites (install.sh preflights all of this and fails fast):
#    the Emergent engine + primitives, codex, claude, gh (authed), jq,
#    python3, curl,
#    and a git signing key configured in the target repo
cargo install emergent-engine   # or a prebuilt binary: github.com/Govcraft/emergent/releases
emergent marketplace install exec-source exec-handler exec-sink stream-runner

# 1. install or refresh the harness (never committed to the target; --reinstall
#    is safe for a fresh repo and refreshes an existing install in place;
#    --vault flags are only needed the first time; --gate overrides detection)
./install.sh ~/code/my-repo --vault ~/my-vault --reinstall  # [--folder TRIP/my-repo] [--gate '<command>']

# 2. fill the vault, once per repo (three researchers write ARCHI.md,
#    ARCHI-rules.md, and TESTING.md; existing docs get .proposed.md siblings;
#    the supervised runner exits on its own once all three land)
~/code/my-repo/.claude/emergent/bin/init-run.sh

# 3. per issue: one command, issue in, merged PR out
~/code/my-repo/.claude/emergent/bin/run.sh 42
```

Step 3 runs plan → implement → review → promote with Fable operating the phase seams. Releases remain human-owned, and the situational gate can park a run for human approval when its earned readiness is below the assessed floor. Run the launcher once per issue and N issues can proceed side by side in the same checkout: each gets its own run directory, engines, approval webhook port, logs, and PID files. `bin/run.sh --list` shows every recorded run and whether its recorded engine launch identity is alive. The direct `SIGNALBOX_ISSUE=42 emergent --config ~/code/my-repo/.claude/emergent/pipeline.toml` form remains available for one run at a time. Details per phase below.

Conversational entry: install.sh also installs a user-level `/signalbox` launcher skill (from `skills/signalbox/`, once, never overwriting your customizations). `/signalbox 54` picks install/init/pipeline from the repo's state and supervises with the disk-artifact discipline, so the day-to-day interface is one slash command in any repo.

## Run the prototype demo

```bash
./dev.sh emergent.toml
```

(The tracked TOMLs carry a `__SIGNALBOX_ROOT__` placeholder rather than any machine's absolute path; `dev.sh` renders against this clone into gitignored `rendered/` and launches the engine. `install.sh` does the same rendering against the target repo.)

The one-shot `seed` source fires on startup (sources start last), reviewing `demo/`, a tiny crate with a deliberate reachable panic. Expected flow: round 1 `REQUEST_CHANGES` → Claude fixes → round 2 `APPROVED` → `results/CR.md` written under the `PROMOTION_READY` sentinel.

Artifacts per round land in `logs/`: `review-round-N.md` (Codex's review), `review-round-N.jsonl` (event stream), `fix-round-N.log` (Claude's fix transcript).

## Pieces

| File | Role |
|---|---|
| `emergent.toml` | The topology, the state machine as wiring |
| `bin/review.sh` | Codex reviewer (same `codex exec` flags as TRIP's review scripts) |
| `bin/fix.sh` | Headless Claude fixer; increments `round`, closes the loop |
| `bin/promote.sh` | Writes the approved CR under `PROMOTION_READY` |
| `prompts/review.md` | Review scope + mandatory verdict contract |
| `demo/` | Sacrificial crate with a reachable `unwrap` panic |

## Thread continuity

Round 1 starts a fresh Codex session and captures the `thread_id` from the `thread.started` event; rounds 2+ run `codex exec resume` against that same thread, so the re-review carries full context of its own prior findings. The thread id travels **in the event payload** (`review.raw` → `fix.requested` → `review.requested`), not in a state file: the loop's entire state is visible in the event store. If the thread id is ever missing, the reviewer falls back to a fresh session with the prior feedback embedded in the prompt.

## Situational gate

**Why this exists.** Most agent workflows pick one of two bad answers to "does this step need a human?": always (the human rubber-stamps forever and becomes the bottleneck) or never (autonomy is granted up front, before it is earned). Neither is how anyone actually manages people. Situational Leadership (Hersey and Blanchard's model) says the right amount of supervision is not a property of the leader or a fixed policy; it is a function of the follower's demonstrated readiness for *the specific task*: a new hire gets directing (S1), then coaching (S2), then supporting (S3), and only after a track record, delegating (S4). Readiness is rated R1 through R4, it is task-specific (proven at deploys says nothing about proven at schema migrations), and it can regress. I added this to my TRIP fork as the delegation model for AI agents because agents have exactly the same shape: they need supervision proportional to demonstrated competence on the action at hand, not a blanket trust setting. Signalbox makes it mechanical.

Approval therefore follows the Situational Leadership curve: whether a transition needs a human is a function of earned readiness against a floor **the LLM sets for the action at hand**. There is no hand-authored policy table.

- **The floor is the leader's judgment, per instance**: `bin/assess.sh` hands an LLM the action's mechanics (facts: what it does, how visible, how reversible) plus the live context (round, change scope, reviewer's summary), and the LLM returns `{floor, rationale}`. Same context, different actions, different floors: promoting a local artifact assesses around R2 while pushing a shared remote assesses R3+. Every determination is appended to the repo-scoped `state/assessments.jsonl` and travels in the payload, so the event trail records not just what was decided but *why*. Fail-safe: an unparseable assessment means floor 4. When the leader can't be understood, a human decides.
- **The gate is then pure topology**: a jq handler compares earned readiness to the assessed floor. Below it, `approval.requested`: a notify sink parks the payload in the current run's `state/pending.json` (citing the floor and rationale) and prints the approval command; the human's POST to the webhook (`/approve` on that run's leased approval port; the printed approval command carries it) re-enters the fabric as `approval.granted`. Nothing subscribes around the gate, so the block is topological, not behavioral. At or above it, straight to `approval.granted`; the human observes (S4 "delegating") via narration and the event store.
- **The ladder moves on track record, per action**: clean convergence (approved in ≤ 2 rounds) promotes that action one R-level; escalation demotes it. The repo-scoped `state/readiness.json` is a map: proven R4 on `promote` says nothing about `push-remote`, which starts at the R2 default like everything else. Autonomy is earned, never granted up front, and never transfers between actions or repos.
- **Readiness goes stale**: levels above R2 decay one step per idle week (`DECAY_DAYS`, default 7) since the ladder last moved them, floored at the R2 default. This is TRIP-2's reset-toward-R2, generalized to time. Decay is observed lazily at read time (`bin/readiness-get.sh`), no daemon; staleness is a property of the moment of use. The ladder builds on the *decayed* base, so idle track record erodes before the next promotion stacks on it. R1 never heals by waiting: distrust is earned back through track record, not time.

## Implement stream (`implement.toml`)

The batched implement phase, with plan-declared concurrency sharding, something standard TRIP can't do because one Claude session can't be in two worktrees at once:

```
plan.load ─> stream-runner (stages, ack-gated = sequential dependencies)
   stage.item ── fan-out by subscription ──> worker-0 ┐  per shard: worktree off the
                └───────────────────────────> worker-1 ┘  integration tip + codex
                                                          (workspace-write) + signed
                                                          commit ──> shard.built
   shard.built ─> slice-next (pop pending shard) ─> shard.review.requested
                └> slice-done (queue empty) ──────> shard.done
   shard.review.requested ─> reviewer-N (codex, delta diff vs integration tip)
        │                                                 │
        └── fixer-N (claude -p in the shard worktree, <───┴── REQUEST_CHANGES
            signed fix commit, round+1)                       (round < 3)
        APPROVED ─> shard moved pending → done, loops back to shard.built
   shard.done ─> collector (flock barrier: all shards arrived?) ─> stage.done
   stage.done ─> merger (rebase + ff-merge each branch, remove worktree) ─> stage.ack
plan.done ─> finisher (configured gate in the integration worktree)
```

- **The plan is the DAG**: `plan.json` groups shards into stages. Shards within a stage must be conflict-free (disjoint files); that's the planner's contract. Stages express the sequential dependencies. A single-shard stage is the same code path, so "sequential" is just the degenerate case of "concurrent".
- **Fan-out by subscription**: every worker receives the same `stage.item` and takes the slice where `shard_index % worker_count == its index`. An empty slice exits silently.
- **Per-shard delta review**: nothing reaches the collector unreviewed. Each built shard is popped off a pending queue and its diff against the integration tip is reviewed by Codex (fresh thread round 1, `resume` on re-reviews, the same continuity as the code-review loop). `REQUEST_CHANGES` bounces to a headless-Claude fixer that commits on the shard branch (round cap 3, then `shard.escalated` and the stage stalls for a human). Only `APPROVED` shards join `done`/`branches`, so the merge gate is topological: the collector's input topic is only ever fed by the approved splitter. Reviewers and fixers are worker-tagged, so two shards review and fix concurrently.
- **Fan-in**: the collector counts arrivals under `flock` and stays silent until the barrier fills; the merger rebases each shard branch onto the integration tip and `--ff-only` merges. Linear history, no merge commits, worktrees and branches cleaned as they land. In an installed harness, branches are `shard/<feature>/<stage>-<shard>` and worktrees are `<repo>-wt/<feature>-<stage>-<shard>`, so two features cannot claim the same names. Every Git worktree add, remove, and prune is serialized across the repo with the repo-scoped `state/worktree.lock`.
- Run: `./dev.sh implement.toml` (the seed resets prior runs' worktrees/branches, integration branch `integration/stream-demo`).
- Like the committed-buggy `demo/` baseline, the plan is booby-trapped on purpose: the `greet` shard's prompt mandates `name.chars().next().unwrap()`, a reachable panic on empty input, so a stock run exercises the full review → fix → re-review path on one shard while the other sails through round 1.

## Feature audit trails (`correlation_id`)

Every run stamps a `correlation_id` (`<feature>-<timestamp>`) at its entry point (the review loop's seed unwrap, the implement stream's plan seed, which also stamps every stage item since stream-runner emits them verbatim) and it travels **in the payload** through every hop, exactly like `thread_id`. Nothing downstream needs to know it exists: pass-through handlers carry it for free, and the few explicit payload constructors copy it forward.

The payoff is that Emergent's event store already remembers everything, so the audit trail is one filter, not an instrumentation project. Launcher-created engine names carry the run suffix (`<repo>-pipeline-issue-42`, and likewise for the child engines), which gives each run a separate `socket_path = "auto"` socket and event-store log directory. `bin/audit.sh` discovers both those suffixed engines and the unsuffixed single-run engines:

```bash
bin/audit.sh                                              # list correlation ids across every run
bin/audit.sh demo-greeting-20260726-154029                # full trail across matching engines
bin/audit.sh --run issue-42 demo-greeting-20260726-154029 # restrict the engine set to one run
```

The trail spans every engine in scope and prints one line per event: timestamp, topic, source, and the load-bearing payload fields (stage, shard, round, verdict, decision, merge tip). The run's `results/CR.md` and the finisher's gate banner cite the id, so any artifact can be traced back to the exact sequence of events that produced it without mixing attribution between concurrent runs.

## Pipeline (`pipeline.toml`): Fable operates the phase seams

The launcher API is `bin/run.sh <issue> [--phase pipeline|plan|implement|review]`; the default `pipeline` phase runs the whole per-feature path (plan → implement → review → **promote**). At launch it renders all five child configs from `templates/` into `runs/issue-<n>/`, substituting that run's engine suffix and leased approval port. The phase-runner launches children from those configs, propagates the run slug, watches **disk artifacts** in the same run root (never engine claims) for the terminal condition (fresh `plan.json`, fresh `state/gate.json`, `results/CR.md`, or `state/pending.json`; an unparked review also records `state/docs-sync.json` before `results/CR.md` can land), then stops its exact child PID gracefully so the event trail flushes. The foreground launcher records the outer engine PID in `state/engine.pid`; each live child phase records `state/phase-<phase>.pid` and removes it after reaping. Selecting `plan`, `implement`, or `review` launches one phase through the same isolation machinery. The direct `SIGNALBOX_ISSUE=<n> emergent --config pipeline.toml` path uses the installed unsuffixed config and remains the single-run form.

The delegation boundary is explicit: a regular PR and merge after green CI is the workflow's job (headless Fable pushes the branch, opens the PR, watches checks, squash-merges on its own go/no-go judgment, cleans up; NO_GO leaves everything parked safely for one human look). Only **releases** (version bumps, tags, publishes) are gated on the human, and the promotion hands release-relevant consequences (like plan-declared breaking changes) off as a PR comment. Vault-doc maintenance is no longer part of that handoff: the review pipeline has already done it before the PR.

Between phases sits the operator: headless Fable, applying the phantom-run discipline as topology. It never trusts the runner's reported outcome. It re-verifies first-hand (plan.json shape and scope notes; branch commits exist and the diff touches *only* the shard-declared files; CR.md carries the sentinel; `state/docs-sync.json` is fresh and has `status: "OK"` before promote) and emits `PROCEED` or `HALT` with a reason that doubles as the pipeline's narration. A docs no-op is still evidence, not absence: `updated: []` is valid when the artifact records it. Only `PROCEED` re-enters the phase loop, so the advance gate is topological; an unparseable operator verdict fails safe to `HALT`. Terminals: `PIPELINE COMPLETE` (merged, or parked at the situational gate with the approval command in the reason; the gate parking is the system working, not a failure) or `PIPELINE HALTED` naming the phase, the runner outcome, and what the operator actually found.

## Shared sink service and dashboard

Every topology now carries one fire-and-forget forwarder sink per interesting topic, `bin/sse-forward.sh <engine-label> <topic>`. It receives the event payload, stamps repo, run slug, issue, feature, engine name, PID, start identity, and correlation id into an envelope, then POSTs that envelope to the shared service's `/ingest` route. Observability is deliberately unable to stall a pipeline, and nothing inside a run serves an SSE port any more.

One systemd `--user` unit, `signalbox-sink.service`, owns the whole machine's dashboard on one fixed known port: `8099` by default, overridden by `SIGNALBOX_SINK_PORT`. The override is baked into the unit as an `Environment=` line, so the service, its health probe, and the forwarders all bind and reach the same port; changing it rewrites the unit and restarts the service. `install.sh` installs and starts it idempotently through `bin/sink-service.sh ensure`. The unit runs the canonical copy at `~/.local/share/signalbox/bin/sink-serve.sh`, so installing a second repo refreshes that one copy instead of starting a competitor for the port.

Putting identity inside the event retires an entire class of attribution bug. With the old per-run listeners, a released port lease could be re-leased while a finished run's TOML still named it. Streams therefore had to be claimed by run liveness, and every SSE response had to re-assert its owner at connect time. The page now reads identity from the envelope instead of correlating an event with a separately-polled owner table, so the event and the identity that produced it cannot be drawn from different moments in external state.

The instance registry calls a run `running` only when the authoritative `/proc` start identity, `<boot epoch>:<start ticks>`, still matches the `start_id` that `bin/run.sh` recorded in `launch.json`. A PID is not enough because the kernel recycles it, and a `system.*` event is not enough on two counts: registry liveness should not depend on wildcard subscription delivery, and `system.stopped.<primitive>` reports one component shutting down rather than the end of a run, so it can never retire an instance whose engine is still up. Only that process identity produces `stopped`. An instance without launch identity — a direct or init run — stays `unknown` until it goes quiet, and the idle timeout then marks it `stale`.

Each instance is keyed for the whole machine, not just for its repository: the key is the repo basename, the run slug, and a digest of the canonical repository and harness paths. Two checkouts that share a basename and run the same issue stay two rows, with separate events, liveness, artifacts, and filter chips.

The page starts with instance filter chips labeled by repo and issue plus an all-instances firehose. Each instance then gets its own drill-down with the phase rail, disk-artifact table, and log table. The `/status` artifact snapshot still trusts disk, not narration: every envelope registers the instance's `run_dir`, and the service, on the same machine with readable paths, stats those artifacts itself on every request. That preserves the repository's standing discipline of verifying from fresh disk artifacts across the move to a machine-level service.

The remaining port allocation is deliberately narrow. The direct single-run path has one reserved approval-webhook port per repo in `~/.local/share/signalbox/ports.json`; each concurrent launcher run has one leased approval port in `~/.local/share/signalbox/leases.json`. SSE and dashboard ports no longer scale with the number of repos or concurrent runs, which is why issue #13's per-run port lease has shrunk to the single port approval actually needs. The launcher releases that lease on exit, and after a crash a stale lease is reaped by the owner's recorded `/proc` start identity rather than by PID alone, so neither a reboot nor a recycled PID can keep a dead lease alive or reject a valid launch.

## Plan (`plan.toml`): TRIP-1, one issue in, one validated plan out

Planning is part of the workflow, not a manual step before it. `SIGNALBOX_ISSUE=<n> emergent --config plan.toml` runs the whole TRIP-1 phase:

- **The seed is deterministic**: `bin/plan-request.sh` fetches the issue with `gh`, parses "Blocked by: #N" references out of the body, and fetches each blocker's current state. Event-carried context, so the planner downstream needs no network.
- **The planner is judgment**: headless Claude (Opus) reads the vault docs, explores the actual source the issue touches (never planning from issue text alone; line numbers drift, and "dead" items have call sites in tests and Display impls), scopes around open blockers, and emits the stage/shard DAG as one JSON object. Each shard declares the `files` it will touch.
- **The validator is mechanics**: pure jq. Schema, substantive self-contained prompts, declared files, and intra-stage file-disjointness. The conflict-free-shards contract stops being prose the moment shards declare their files; overlaps (including shared generated files like `Cargo.lock`) are caught before any worktree exists.
- **The gate is topological**: only `VALID` plans reach the writer that persists `plan.json`, so the file the implement stream loads is validated by wiring, not convention. `INVALID` bounces back to the planner with the validator's feedback (round cap 3); `BLOCKED` and exhausted rounds escalate to a human.

## Init (`init.toml`): the vault is the shared memory

How the harness knows a repo's architecture: it doesn't. The **vault does**. TRIP-init's contract is that `.claude/docs` symlinks into the user's Obsidian vault, and `ARCHI.md` / `ARCHI-rules.md` / `TESTING.md` are the repo's accumulated architectural memory. The init topology fills that vault: a one-shot seed fans out one read-only Codex researcher per document (architecture, rules, testing, each producing the complete file), and a dumb writer lands them. Non-destructive: TRIP-init gates `ARCHI.md` on explicit human approval, so an existing doc is never clobbered. The research arrives as a `.proposed.md` sibling to diff and adopt.

Init seeds the memory; each feature now maintains it. After approval and before the promoter can write `results/CR.md`, `docs-syncer` reads the feature diff plus all three vault docs and rewrites in place only what that diff made stale. It always records the outcome in the run's `state/docs-sync.json` — `updated`, `unchanged`, `status: "OK" | "ERROR"`, and the run identity — so a no-op is explicit and an error cannot masquerade as silence. The vault is repo-scoped, not run-scoped, so the sync takes a repo-scoped `flock` exclusively across its whole hash-read → rewrite → hash-verify transaction, and the planner takes the same lock shared while it reads: concurrent runs sync one at a time instead of overwriting each other's documentation, and no plan is ever built on a half-synced vault. The vault is git-excluded, so none of this leaks into the feature PR. This timing matters: the next issue's planner reads the vault before any human release step happens. If the feature leaves stale architecture behind, the very next plan compounds it immediately; waiting for release is already too late.

The topology has no terminal condition of its own because Emergent engines are daemons. `bin/init-run.sh` supervises it the same way `bin/phase-run.sh` supervises every pipeline phase: it watches the disk artifacts, never the engine's narration, then SIGTERMs the specific child PID so its trail flushes. A re-init's `.proposed.md` siblings count as landed, so the second run terminates too.

Every worktree the harness creates (integration and per-shard) gets the TRIP `.claude` symlink, so the same notes resolve everywhere: shard workers are told to read `ARCHI.md`/`ARCHI-rules.md`/`TESTING.md` before writing code, fixers must conform to `ARCHI-rules.md`, and the headless Claude fixers additionally pick up any committed root `CLAUDE.md` for free. One vault, every agent reading the same notes.

## Installing into a target repo

`./install.sh <repo> [--vault <vault-root> [--folder <folder>]] [--gate '<command>'] [--reinstall]` stamps a rendered harness into `<repo>/.claude/emergent/`, TRIP's local-only convention (excluded via `info/exclude`, never committed to the target).

The install works on a repo that has **never used TRIP**: preflight fails fast on missing tooling (emergent + the exec/stream primitives, codex, claude, gh auth, jq, python3, curl, a git signing key in the target repo) instead of failing twenty minutes into a run, and `--vault <obsidian-vault-root> [--folder TRIP/<repo>]` performs TRIP-init's own vault wiring (vendored `bin/vault-setup.sh`, idempotent): it creates `<vault>/<folder>/{1-plans,2-changelog,3-code-review,4-unit-tests,6-memo}`, links `.claude/docs` there absolutely, and migrates a pre-existing real `docs/` directory if one exists. A repo already TRIP-wired needs no flags.

Paths are baked and engine names are namespaced first by repo, then by run: installation renders bases such as `<repo>-pipeline`, while the launcher produces `<repo>-pipeline-issue-42` and corresponding suffixed child names. Because each topology keeps `socket_path = "auto"` and Emergent keys its event-store directory by engine name, concurrent runs do not share sockets or audit logs. The installer keeps fully rendered root TOMLs for the direct single-run form and also installs partially rendered `templates/{pipeline,plan,implement,emergent,init}.toml`; `bin/run.sh` fills their run suffix and leased approval port at launch.

Run identity is mechanical: `SIGNALBOX_RUN_SLUG` wins when supplied, otherwise `SIGNALBOX_ISSUE=<n>` yields `issue-<n>`; only a prototype or direct topology launch with neither variable falls back to the harness root. Each launcher-created issue owns `.claude/emergent/runs/issue-<n>/{launch.json,plan.json,state/,results/,logs/,*.toml}`. The generated `_env.sh` derives `feat/<plan.json .feature>`, the integration worktree `<repo>-wt/<feature>`, feature-namespaced shard worktrees, and the gate directory from that run. The readiness ladder and assessment ledger remain repo-scoped at `.claude/emergent/state/{readiness.json,assessments.jsonl}`, and the supervised init output remains once per repo rather than being duplicated into every run. Because those are the artifacts concurrent runs genuinely share, each is written under a repo-scoped `flock`: the ladder's read/compute/write is one serialized transaction ending in a rename, so two runs converging at the same moment can't both read `R2` and both write `R3`, and a reader never sees a half-written file.

The installer also records the gate command as `GATE_CMD` in that generated `_env.sh`, where it is auditable and hand-editable. `--gate '<command>'` supplies it explicitly; on a fresh install without that flag, the first matching declaration wins: a `ci` task in `Taskfile.yml` or `Taskfile.yaml` (`task ci`), a root `Cargo.toml` (`cargo clippy --all-targets -q && cargo nextest run`), a `ci` recipe in `justfile` (`just ci`), a `ci:` target in `Makefile` (`make ci`), or a `test` script in `package.json` (`pnpm test`, `yarn test`, or `npm test`, selected by lockfile). If no gate can be detected, preflight fails with instructions to re-run using `--gate '<command>'`. Order of operations in a new repo: run `bin/init-run.sh` once to fill the vault, then run `bin/run.sh <issue>` for each feature. The `--phase plan|implement|review` launcher mode supports isolated reruns, and the fully rendered phase topologies remain directly invocable for the single-run path.

An existing destination is still refused unless `--reinstall` is present; the refusal points to that flag and names the carry-list a manual removal would put at risk: `runs/`, `state/assessments.jsonl`, and `state/readiness.json`. That manual removal is the footgun `--reinstall` replaces: it can destroy in-flight run directories and discard the repo's readiness history. The flag is always safe to pass, because a target with no `.claude/emergent/` gets a normal fresh install. On an existing install it refreshes in place: `bin/`, `prompts/`, `templates/`, the rendered root TOMLs, and generated `bin/_env.sh` are rebuilt from source, including removal of stale scripts and prompts, while `runs/`, all of `state/`, `logs/`, and `results/` are never touched. Before any destructive refresh, the installer uses the same launch-liveness check as `bin/run.sh --list`: it reads `runs/*/launch.json` and verifies each recorded PID against its recorded `/proc` start identity. If any launcher-recorded run is live, reinstall aborts, lists the live runs, and tells the operator to finish or stop them first. A scan alone would only be a snapshot, so the check and the refresh both run while the installer holds `.install.lock` exclusively (`flock`, released when the installer exits). That lock file sits at the harness root rather than under `state/`, so the coordination the installer needs never writes into a directory reinstall promises not to touch; the root survives a refresh, so the lock keeps its identity across reinstalls. `bin/run.sh` takes that same lock shared for its startup window — from inspecting existing run state until `launch.json` records the new engine's PID and identity — and the engine itself is spawned with the descriptor closed, so it never holds the lock. A launcher therefore either records its run in time for the scan to refuse, or waits until the refreshed harness is whole; concurrent launchers, holding it shared, never block each other. Either side gives up after `SIGNALBOX_LOCK_WAIT` seconds (default 60) rather than waiting for ever. A lock binds only launchers that take it, and the harness already installed in the target may predate it — every first upgrade does. So before it destroys anything, the installer also withdraws the entry point: `bin/` is moved aside in one rename, after which `bin/run.sh` cannot be started, and a stale launcher mid-startup cannot reach an engine either, because it must still exec `bin/ports.sh` and `bin/check-placeholders.sh` before spawning `emergent`. A second liveness scan then runs; if it finds a run recorded since the first, `bin/` is put straight back and the refusal names that run, leaving the harness as it was found. That withdrawal binds only launchers that still have a `bin/` exec ahead of them, so one rescan is not enough: a pre-lock launcher that had already passed its last one is mid-startup at the moment of the rename and writes `launch.json` a beat later. The installer therefore watches the withdrawn tree for a quiescence window — `SIGNALBOX_REINSTALL_QUIESCE` seconds, default 5 — rescanning liveness and, against a marker dated at the withdrawal, looking for any `launch.json` (or its launcher temp file) written since. Because `run.sh` writes that metadata before the engine exists and patches the PID in afterwards, such a file names no live process yet; it is refused on its existence alone, `bin/` restored, as a startup in flight. No new startup can begin during the window, since `bin/` is gone, so the window only has to outlast the tail of one already running. When `--gate` is omitted, reinstall preserves the `GATE_CMD` recorded in the existing generated `_env.sh`, so a hand-edited gate survives.

The installed harness is a rendered copy, not a symlink, so any harness-source merge leaves it stale. Before the next pipeline run after such a merge, signalbox's own `.claude/emergent/` must be refreshed with `./install.sh <repo> --reinstall`; the ledger and run directories are preserved by construction, with no manual carrying. That reinstall is also what invokes `bin/sink-service.sh ensure` to install and start the shared sink service.
