# ADR-0185 — One gate configuration, everywhere

- **Status**: Proposed → **Accepted** (2026-08-12)
- **Supersedes**: the tiering half of [ADR-0107](0107_pipeline_gate_smoke_authorized.md)
  (revision 2026-07-21) and the nightly leg of
  [ADR-0049](0049_orbstack_linux_gate_retired.md)'s batched-Linux arrangement.
  ADR-0107's *local* smoke tier is untouched.
- **Affected files**: `.github/workflows/ci.yml`, `scripts/ci_gate.sh`,
  `scripts/check_gate_parity.sh`, `scripts/check_vm_parity.sh`,
  `scripts/run_remote_ubuntu.sh`, `.claude/rules/gate_cadence.md`,
  `test/e2e/phase14_nrepl*.sh`, `test/e2e/entrypoint_eval_parity.sh`

## Context

CI ran three configurations and called all three "the gate":

| trigger      | what ran                                                                                        |
|--------------|-------------------------------------------------------------------------------------------------|
| pull_request | `test/run_all.sh --smoke` (no e2e shell suite)                                                  |
| push to main | `test/run_all.sh --serial-e2e` (== the local full gate)                                         |
| nightly cron | the above **plus** `check_vm_parity.sh` (corpus + every e2e on a `-Dbackend=tree_walk` rebuild) |

`scripts/check_gate_parity.sh` already existed because this class had bitten
before: for months `ci_gate.sh` passed `--serial-e2e` while `run_gate.sh` passed
nothing, so "the local gate is green" and "CI is green" were statements about
two different runs, and an e2e that died on SIGPIPE under serial passed under
parallel — green locally, red on every push. That check fixed the flag; the
tiers stayed.

The nightly then produced the argument against itself. Its last run
(2026-08-12, `376f81c8`) failed on **`phase14_nrepl`: `.nrepl-port` not created
within 5s**, on the tree_walk build, on a loaded shared runner. The six nightlies
before it passed. Measured locally on that same tree_walk ReleaseSafe build, the
bind takes **0.08 / 0.14 / 0.08 s** — 35-60x under the bound. So the failure was
a fact about the runner, reported a day late, in a configuration no ordinary gate
run reproduces. `.claude/rules/test_taxonomy.md` had already written down why
("a RATIO upper bound is a flake generator … it eventually fails for the one
reason it was not written to detect"); the nightly was the only place positioned
to collect on it.

The project is also no longer maintained (README, 2026-08-12), so a schedule that
wakes up daily to re-run a config nobody will triage is pure liability.

## Decision

**One configuration. PR, push, dispatch and `scripts/run_gate.sh` all run
`zig fmt --check src/` + `test/run_all.sh --serial-e2e`.**

1. `ci.yml` loses the `schedule:` trigger and both `CLJW_CI_*` env switches.
2. `ci_gate.sh` loses its tier branches — one unconditional `run_all.sh` call.
3. `check_gate_parity.sh` is extended from "both pass `--serial-e2e`" to
   "there is exactly ONE configuration": exactly one `run_all.sh` invocation in
   `ci_gate.sh`, no `CLJW_CI_FULL`/`CLJW_CI_PARITY` in the script or the
   workflow, no `check_vm_parity.sh` wired into a launcher. The greps read code,
   not comments, so the headers can still name the retired switches to explain
   them.
4. `check_vm_parity.sh` survives as an **on-demand** tool, its header saying so.
5. The nREPL port-file bounds go 5 s / 10 s / 15 s → **30 s**, with the reason
   in the comment: an order-of-magnitude bound still separates "never came up"
   from "busy runner", which is all the assertion is for.

## Consequences

- "Green" means one run, wherever it is said. A tier cannot return without
  failing `gate_parity`.
- PR CI gets slower (smoke → full). Irrelevant here: PRs are disabled on this
  repo, and the project is not taking new work.
- **The e2e shell suite no longer runs on the non-default backend in CI.** This
  is the one real loss, and it is smaller than the sweep's name suggests: the
  F-012 dual-backend differential oracle — the thing that actually pins
  tree_walk ≡ vm semantics — runs inside `zig build test` on **both** backends
  in every gate (`zig_build_test_vm` + `zig_build_test_tree_walk`). What is gone
  is e2e *shell* coverage of the non-default backend, recoverable on demand with
  `bash scripts/check_vm_parity.sh` (or `run_remote_ubuntu.sh --parity` for
  Linux × tree_walk, the slowest combination and where timing bounds break
  first).
- A genuine tree_walk-only e2e regression would now be found by a person running
  that script, not by a schedule. Accepted: for an unmaintained project, a
  finding nobody triages is not coverage.

## What the unification turned up on its way in

Removing the tier did not make the first full gate green — `entrypoint_eval_parity`
died with exit 137 and no explanation. Two real defects were behind it, both
found because the oracle was made to survive a dying entry point instead of
inheriting its status:

1. **The oracle aborted instead of reporting.** `got=$(run_$ep …)` under
   `set -e` propagates a killed child's 137 and takes the step with it — in the
   one test whose entire job is to notice that an entry point behaved
   differently. It now captures status and raw output per entry point, so a
   death is a named divergence with the last 20 lines attached. That change is
   what produced the diagnosis in one run.
2. **Every nREPL e2e leaked its server.** `( cd "$WORK" && "$BIN" nrepl … ) &`
   makes `$!` the subshell, not the runtime, so `kill $!` orphaned one `cljw`
   per start: 3 left behind by `phase14_nrepl_classpath`, 4 by
   `phase14_nrepl_toplevel_do`, plus one per case in the new oracle. Enough
   accumulated memory that macOS SIGKILLed an unrelated freshly-built binary —
   a leak presenting as a crash. All three now reap by scoped port pattern, and
   all four nREPL e2e end with zero surviving processes.
   `.claude/rules/orphan_prevention.md` carries the pattern as rule 4.

The CI runner had been reporting this leak all along, as a "Terminate orphan
process: pid (…) (cljw)" flood at job cleanup. Nobody read it as a finding.

## Alternatives considered

1. **Keep the nightly, raise the bound only** (smallest diff). Fixes this
   symptom, keeps the class: CI still verifies something the local gate does not,
   so the next divergence is again found a day late by a config nobody runs. It
   also leaves a daily job on a repo that is winding down.
2. **Keep the nightly, run it in the local gate too** (parity by addition).
   Genuinely closes the divergence and keeps the coverage — at a second
   ReleaseSafe rebuild plus a full serial e2e pass (~5 min) on *every* gate,
   local included. Rejected on the coverage/cost ratio given the diff oracle
   already covers dual-backend semantics, and doubly so for a project that has
   stopped.
3. **Delete `check_vm_parity.sh` outright.** Simplest final state, but it throws
   away a diagnostic that costs nothing to keep and that a forker may want. The
   divergence was the schedule, not the script.
