---
name: signalbox
description: Launch the signalbox workflow (the emergent successor to TRIP) in the current repo. Use whenever the user says "/signalbox", "run signalbox", "signalbox issue 54", "trip 54", "run trip", "trip init", "install signalbox here", or asks to run the automated plan/implement/review/promote pipeline on a GitHub issue. The phases are event topologies, not prompts; this skill only launches and supervises them.
---

# Signalbox launcher

Signalbox runs the TRIP workflow as Emergent event topologies installed per-repo under `.claude/emergent/`. One feature = one command; the phases (plan → implement → review → promote) are wired, not prompted. Your job is to launch the right engine, supervise via disk artifacts, and report, not to re-implement any phase inline.

Locate the signalbox source checkout first (the repo containing `install.sh` and the topology TOMLs); ask the user if you cannot find it.

## Decide the mode from the repo's state

Work from the current repo's root (primary checkout, not a worktree; `.claude` must not be a symlink).

1. **No `.claude/emergent/`, or a stale installed harness**: install or refresh first.
   `<signalbox>/install.sh <repo> [--vault <vault-root> [--folder TRIP/<repo>]] [--gate '<command>']`
   The `--vault` flags are needed only if `.claude/docs` doesn't exist yet (a repo that has never used TRIP). The vault root is the directory containing `.obsidian`. On a fresh install the gate is detected per repo and recorded in the generated `_env.sh`; if preflight reports that it cannot detect one, ask the user for the repo's gate command and re-run with `--gate '<command>'`. Preflight failures print exactly what to fix.
   When `.claude/emergent/` exists but the signalbox source has moved on after any harness-source merge, refresh it with `<signalbox>/install.sh <repo> --reinstall`. This keeps `runs/` and the repo-scoped readiness ledger; without `--gate`, it also keeps the existing generated `_env.sh` gate.
2. **Vault docs missing or stale** (no `ARCHI.md` in `.claude/docs/`, or the user says "init"): fill the vault.
   `.claude/emergent/bin/init-run.sh`
   This runner supervises and stops the init engine itself, exiting non-zero if the three documents never land, so the launcher does not need to babysit the engine or SIGTERM it by hand for this phase. Three read-only researchers write `ARCHI.md`, `ARCHI-rules.md`, `TESTING.md`; existing docs get `.proposed.md` siblings. When adoption is delegated to you: archive originals first (`_archive/<doc>-<date>-pre-init.md`; the vault is NOT under git), and prefer merging over swapping when the existing doc holds knowledge a repo researcher cannot see (issue-tracker state, external pointers, decision history).
3. **An issue number** (e.g. "/signalbox 54"): run the pipeline.
   `.claude/emergent/bin/run.sh <n>`
   This is the whole feature path; a headless operator verifies each phase seam and a promotion executor opens and merges the PR after green CI. The only human-gated outcomes are a situational-gate park and a release.
4. **Recovery after a HALT**: fix the reported cause, relaunch the halted engine phase with `.claude/emergent/bin/run.sh <n> --phase plan|implement|review`, and wait for `state/complete.json`. Verify the resulting artifacts first-hand; after review, inspect `results/CR.md` and the feature diff yourself, then run `.claude/emergent/bin/run.sh <n> --phase promote`. Promote launches no engine, leases no port, and writes no phase stamp; it fails closed without a sentinel-bearing, correlation-stamped CR and the existing review stamp, still enforces docs-sync, and may halt with `NO_GO`.

## Supervision discipline (non-negotiable)

- Launch the per-run supervisor as a background task; monitor **disk artifacts**, never notifications or engine claims. For issue `<n>`, the phase evidence is `.claude/emergent/runs/issue-<n>/{plan.json,state/gate.json,results/CR.md,state/pending.json,state/complete.json,state/halted.json}`. Pipeline and standalone `--phase` launches share the last two as their only terminal evidence, and `run.sh` removes both before each launch, so whichever appears belongs to the launch being supervised. `state/complete.json` means an artifact or park was observed; `state/halted.json` records `ESCALATED`, `GATE_RED`, `TIMEOUT`, `ENGINE_DIED`, or promotion `NO_GO`. A standalone terminal is not a verdict: only the pipeline topology runs the independent operator, so verify its artifacts first-hand before reporting completion or invoking `--phase promote`. If you drive an engine some other way (a direct `emergent --config` launch, for instance), remove both terminal files yourself before monitoring, or the previous run's terminal will be read as this one's. Init evidence remains the `.proposed.md` files in the repo-scoped vault; pipeline narration is in that run's logs.
- Before launching or reinstalling, run `.claude/emergent/bin/run.sh --list` when the harness exists, then check for OTHER live Emergent processes (`pgrep -x emergent`, then `ps` the PIDs). The user may have multiple runs in flight. `--reinstall` itself refuses when a launcher-recorded run is live, and holds `.install.lock` at the harness root (which `bin/run.sh` also takes while starting) across both the check and the refresh, so a run cannot slip into the gap; a harness installed before that lock existed is excluded instead by having its `bin/` withdrawn before anything is destroyed, after which three deterministic checks refuse the refresh: any process still holding an open file from the withdrawn `bin/` (a stale launcher keeps its script descriptor open for its whole lifetime), any run recorded since the first liveness scan, and any `launch.json` created or changed against a pre-withdrawal snapshot — while metadata that merely predates the reinstall never blocks it. If it reports a lock timeout, a launcher is mid-startup — re-list and try again. If it reports a startup in flight, a pre-lock launcher is spawning right now — wait for it, `--list`, and try again. The discipline is therefore enforced as well as expected, but it is never a licence to skip this check: the installer knows only about runs it launched, not an engine started by hand or through a direct `emergent --config` invocation. Never reinstall or modify a harness while ANY run from it is live.
- The engine buffers its event-store JSONL. To stop issue `<n>`, read `.claude/emergent/runs/issue-<n>/state/engine.pid` and send SIGTERM to that exact PID; never use `pkill -f` or another name pattern. The launcher will reap its child, release the run's ports, and remove the PID file so the trail flushes cleanly.
- Verify every completion first-hand from the filesystem/git/gh before reporting it. A monitor saying "done" is a claim, not evidence.
- Feature trails: `.claude/emergent/bin/audit.sh <correlation-id>` (no args lists known ids).

## Reporting

Report terminals with what YOU verified: merged PR URL and squash commit for promote; floor/rationale and the approval command for a park; the operator's reason plus the on-disk evidence for a HALT. If the pipeline parks or halts, that is the system's judgment working; brief the user, don't override it. Releases (version bump, tag, publish) are always the human's; when a run hands one off, surface it explicitly.
