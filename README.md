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
                 │                            promoter sink                ┌──────────┴──────────┐
                 │                       (PROMOTION_READY → CR.md)    round-guard         escalation-guard
                 │                                                      (round < 4)         (round >= 4)
                 │                                                          │                     │
                 └────────────── fixer (claude -p, acceptEdits) <── fix.requested          review.escalated
```

## Quick start, any repo, TRIP or not

```bash
# 0. prerequisites (install.sh preflights all of this and fails fast):
#    the Emergent engine + primitives, codex, claude, gh (authed), jq,
#    and a git signing key configured in the target repo
cargo install emergent-engine   # or a prebuilt binary: github.com/Govcraft/emergent/releases
emergent marketplace install exec-source exec-handler exec-sink stream-runner

# 1. install the harness (never committed to the target; --vault flags are
#    only needed the first time on a repo that has never used TRIP;
#    --gate '<command>' overrides automatic gate detection)
./install.sh ~/code/my-repo --vault ~/my-vault  # [--folder TRIP/my-repo] [--gate '<command>']

# 2. fill the vault, once per repo (three researchers write ARCHI.md,
#    ARCHI-rules.md, TESTING.md; existing docs get .proposed.md siblings)
emergent --config ~/code/my-repo/.claude/emergent/init.toml

# 3. per feature: one command, issue in, merged PR out
SIGNALBOX_ISSUE=42 emergent --config ~/code/my-repo/.claude/emergent/pipeline.toml
```

Step 3 runs plan → implement → review → promote with Fable operating the phase seams; the only human-gated step is a release. Details per phase below.

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

- **The floor is the leader's judgment, per instance**: `bin/assess.sh` hands an LLM the action's mechanics (facts: what it does, how visible, how reversible) plus the live context (round, change scope, reviewer's summary), and the LLM returns `{floor, rationale}`. Same context, different actions, different floors: promoting a local artifact assesses around R2 while pushing a shared remote assesses R3+. Every determination is appended to `state/assessments.jsonl` and travels in the payload, so the event trail records not just what was decided but *why*. Fail-safe: an unparseable assessment means floor 4. When the leader can't be understood, a human decides.
- **The gate is then pure topology**: a jq handler compares earned readiness to the assessed floor. Below it, `approval.requested`: a notify sink parks the payload in `state/pending.json` (citing the floor and rationale) and prints the approval command; the human's POST to the webhook (`/approve` on the repo's allocated approval port; the printed approval command carries it) re-enters the fabric as `approval.granted`. Nothing subscribes around the gate, so the block is topological, not behavioral. At or above it, straight to `approval.granted`; the human observes (S4 "delegating") via narration and the event store.
- **The ladder moves on track record, per action**: clean convergence (approved in ≤ 2 rounds) promotes that action one R-level; escalation demotes it. `state/readiness.json` is a map: proven R4 on `promote` says nothing about `push-remote`, which starts at the R2 default like everything else. Autonomy is earned, never granted up front, and never transfers between actions.
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
- **Fan-in**: the collector counts arrivals under `flock` and stays silent until the barrier fills; the merger rebases each shard branch onto the integration tip and `--ff-only` merges. Linear history, no merge commits, worktrees and branches cleaned as they land.
- Run: `./dev.sh implement.toml` (the seed resets prior runs' worktrees/branches, integration branch `integration/stream-demo`).
- Like the committed-buggy `demo/` baseline, the plan is booby-trapped on purpose: the `greet` shard's prompt mandates `name.chars().next().unwrap()`, a reachable panic on empty input, so a stock run exercises the full review → fix → re-review path on one shard while the other sails through round 1.

## Feature audit trails (`correlation_id`)

Every run stamps a `correlation_id` (`<feature>-<timestamp>`) at its entry point (the review loop's seed unwrap, the implement stream's plan seed, which also stamps every stage item since stream-runner emits them verbatim) and it travels **in the payload** through every hop, exactly like `thread_id`. Nothing downstream needs to know it exists: pass-through handlers carry it for free, and the few explicit payload constructors copy it forward.

The payoff is that Emergent's event store already remembers everything, so the audit trail is one filter, not an instrumentation project:

```bash
bin/audit.sh                                   # list correlation ids seen in the store
bin/audit.sh demo-greeting-20260726-154029     # full trail for one feature run
```

The trail spans every engine and prints one line per event: timestamp, topic, source, and the load-bearing payload fields (stage, shard, round, verdict, decision, merge tip). `results/CR.md` and the finisher's gate banner cite the id, so any artifact can be traced back to the exact sequence of events that produced it.

## Pipeline (`pipeline.toml`): Fable operates the phase seams

`SIGNALBOX_ISSUE=<n> emergent --config pipeline.toml` runs the whole per-feature path (plan → implement → review → **promote**) as one engine. The delegation boundary is explicit: a regular PR and merge after green CI is the workflow's job (headless Fable pushes the branch, opens the PR, watches checks, squash-merges on its own go/no-go judgment, cleans up; NO_GO leaves everything parked safely for one human look). Only **releases** (version bumps, tags, publishes) are gated on the human, and the promotion hands release-relevant consequences (like plan-declared breaking changes) off as a PR comment. Each phase still runs as its own engine: the phase-runner launches it as a child, watches **disk artifacts** (never engine claims) for the terminal condition (fresh `plan.json`, fresh `state/gate.json`, `CR.md`, or `pending.json`), then stops it gracefully by PID so its event trail flushes.

Between phases sits the operator: headless Fable, applying the phantom-run discipline as topology. It never trusts the runner's reported outcome. It re-verifies first-hand (plan.json shape and scope notes; branch commits exist and the diff touches *only* the shard-declared files; CR.md carries the sentinel) and emits `PROCEED` or `HALT` with a reason that doubles as the pipeline's narration. Only `PROCEED` re-enters the phase loop, so the advance gate is topological; an unparseable operator verdict fails safe to `HALT`. Terminals: `PIPELINE COMPLETE` (merged, or parked at the situational gate with the approval command in the reason; the gate parking is the system working, not a failure) or `PIPELINE HALTED` naming the phase, the runner outcome, and what the operator actually found.

## Watching a run (`bin/watch.sh`)

Every topology carries a `watchtower` sse-sink streaming its interesting topics (phase seams and operator verdicts, shard builds and review rounds, gate decisions, researcher doc writes). `bin/watch.sh [harness-dir]` serves a live dashboard: a phase rail derived from the same disk artifacts the runner and operator trust, an artifact table with the gate verdict, and a live event feed fed by proxying each watchtower through one origin (no CORS). The dashboard assumes no port numbers: `install.sh` allocates each repo a port block (registry in `~/.local/share/signalbox/ports.json`, so concurrent repos never collide), watch.sh discovers the rendered ports from the harness TOMLs, and its own page port is `WATCH_PORT` if set, else 8099, else an ephemeral port — the URL actually bound is always printed. The artifact rail works even for engines started without watchtowers; streams light up whenever a sink-equipped engine is running.

## Plan (`plan.toml`): TRIP-1, one issue in, one validated plan out

Planning is part of the workflow, not a manual step before it. `SIGNALBOX_ISSUE=<n> emergent --config plan.toml` runs the whole TRIP-1 phase:

- **The seed is deterministic**: `bin/plan-request.sh` fetches the issue with `gh`, parses "Blocked by: #N" references out of the body, and fetches each blocker's current state. Event-carried context, so the planner downstream needs no network.
- **The planner is judgment**: headless Claude (Opus) reads the vault docs, explores the actual source the issue touches (never planning from issue text alone; line numbers drift, and "dead" items have call sites in tests and Display impls), scopes around open blockers, and emits the stage/shard DAG as one JSON object. Each shard declares the `files` it will touch.
- **The validator is mechanics**: pure jq. Schema, substantive self-contained prompts, declared files, and intra-stage file-disjointness. The conflict-free-shards contract stops being prose the moment shards declare their files; overlaps (including shared generated files like `Cargo.lock`) are caught before any worktree exists.
- **The gate is topological**: only `VALID` plans reach the writer that persists `plan.json`, so the file the implement stream loads is validated by wiring, not convention. `INVALID` bounces back to the planner with the validator's feedback (round cap 3); `BLOCKED` and exhausted rounds escalate to a human.

## Init (`init.toml`): the vault is the shared memory

How the harness knows a repo's architecture: it doesn't. The **vault does**. TRIP-init's contract is that `.claude/docs` symlinks into the user's Obsidian vault, and `ARCHI.md` / `ARCHI-rules.md` / `TESTING.md` are the repo's accumulated architectural memory. The init topology fills that vault: a one-shot seed fans out one read-only Codex researcher per document (architecture, rules, testing, each producing the complete file), and a dumb writer lands them. Non-destructive: TRIP-init gates `ARCHI.md` on explicit human approval, so an existing doc is never clobbered. The research arrives as a `.proposed.md` sibling to diff and adopt.

Every worktree the harness creates (integration and per-shard) gets the TRIP `.claude` symlink, so the same notes resolve everywhere: shard workers are told to read `ARCHI.md`/`ARCHI-rules.md`/`TESTING.md` before writing code, fixers must conform to `ARCHI-rules.md`, and the headless Claude fixers additionally pick up any committed root `CLAUDE.md` for free. One vault, every agent reading the same notes.

## Installing into a target repo

`./install.sh <repo>` stamps a rendered harness into `<repo>/.claude/emergent/`, TRIP's local-only convention (excluded via `info/exclude`, never committed to the target).

The install works on a repo that has **never used TRIP**: preflight fails fast on missing tooling (emergent + the exec/stream primitives, codex, claude, gh auth, jq, a git signing key in the target repo) instead of failing twenty minutes into a run, and `--vault <obsidian-vault-root> [--folder TRIP/<repo>]` performs TRIP-init's own vault wiring (vendored `bin/vault-setup.sh`, idempotent): it creates `<vault>/<folder>/{1-plans,2-changelog,3-code-review,4-unit-tests,6-memo}`, links `.claude/docs` there absolutely, and migrates a pre-existing real `docs/` directory if one exists. A repo already TRIP-wired needs no flags.

Paths are baked, engines are namespaced by repo (`<repo>-pipeline`, `<repo>-plan`, `<repo>-implement-stream`, `<repo>-review-loop`, `<repo>-init`, so no socket or event-log collisions), and the generated `_env.sh` derives everything from location: feature branch `feat/<plan.json .feature>`, worktrees in the TRIP `<repo>-wt/` home, gate at the workspace root, fresh per-repo readiness/assessment state (autonomy re-earned from R2 per repo). The installer also records the gate command as `GATE_CMD` in that generated `_env.sh`, where it is auditable and hand-editable. `--gate '<command>'` overrides detection; otherwise the first matching declaration wins: a `ci` task in `Taskfile.yml` or `Taskfile.yaml` (`task ci`), a root `Cargo.toml` (`cargo clippy --all-targets -q && cargo nextest run`), a `ci` recipe in `justfile` (`just ci`), a `ci:` target in `Makefile` (`make ci`), or a `test` script in `package.json` (`pnpm test`, `yarn test`, or `npm test`, selected by lockfile). If no gate can be detected, preflight fails with instructions to re-run using `--gate '<command>'`. Order of operations in a new repo: run `init.toml` once to fill the vault, then per feature just `SIGNALBOX_ISSUE=<n> emergent --config pipeline.toml`. The phase topologies remain individually runnable for surgical reruns.
