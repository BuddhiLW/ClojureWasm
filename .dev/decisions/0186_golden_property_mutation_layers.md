# 0186 — Open the golden, property and mutation test layers

- **Status**: Accepted
- **Date**: 2026-08-12
- **Author**: Pedro (BuddhiLW)
- **Tags**: test, taxonomy, golden, property, mutation, fork-foundation

## Context

ADR-0021 committed to 5 layers and named 8 more as deferred, each with a phase
that would open it. Golden ("Phase 7+"), Property ("Phase 8+") and Fuzz
("Phase 6+") never opened; the phases passed and the layers did not. What the
suite has instead is 1,249 inline unit tests, ~400 e2e shell scripts, a
dual-backend differential oracle and a clj corpus — a large, genuinely good
suite with two structural gaps.

**Nothing checks whole-program observable output.** An e2e case asserts a
chosen substring of a chosen stream, so it can only fail for the thing its
author thought to assert. The error renderer prints a source excerpt with a
caret under the offending form; no test compares that rendering as a whole, so
a regression that drops the excerpt, moves a message from stderr to stdout, or
changes an exit code passes every assertion written today.

**Nothing checks the suite itself.** 120 of 265 source files carry no inline
test. Coverage is unmeasured, and coverage would be the wrong measure anyway:
the question is not whether a line executed under test but whether changing it
makes a test fail. That question has one honest answer — change the line and
see.

The fork inherits maintenance from a solo author whose confidence came partly
from an autonomous loop with written rails. A new maintainer does not inherit
that context. What transfers is a suite that fails when behaviour changes, and
evidence about where it would not.

## Decision

Open three layers, numbered as continuations of the ADR-0021 table.

**Layer 6 — Golden snapshot** (`test/golden/`). A case is a whole program; its
snapshot is stdout, stderr and exit code in one file. `run.sh --update`
regenerates, and the resulting diff is the review surface. Determinism comes
from explicit normalisation (repo path, hex addresses, pids, durations, version
string); a case that still varies does not belong in the layer. Runs every
gate, after `build_cljw`.

**Layer 7 — Property** (`test/prop/`). Properties are stated over generated
input rather than over examples, with a fixed default seed so the gate is
deterministic, and an overridable one so a sweep can explore. A failing case
shrinks before it is reported. The oracles available here are the ones the
codebase already trusts elsewhere: an algebraic law (`conj` then `pop` is
identity), a round-trip (read then print then read), and cross-implementation
agreement (a persistent collection against a naive array model).

**Layer 8 — Mutation** (`scripts/mutation/`). Not a test layer but a
measurement OF the layers: mutate one source construct, rebuild, run the unit
suite, and record whether anything failed. A surviving mutant names a specific
line whose behaviour no test constrains. It runs on demand and in a scheduled
sweep, never in the per-commit gate — a rebuild per mutant is minutes, and the
output is a work-list, not a pass/fail.

Mutation runs in a **throwaway git worktree**, never in the working checkout.
The harness rewrites source files; pointing it at a checkout someone is editing
would destroy uncommitted work, and a mutant left behind by an interrupted run
would be indistinguishable from a real edit.

## Alternatives considered

### Alternative A — Extend the e2e layer instead of adding golden

- **Sketch**: keep writing `phase<N>_<scope>.sh` scripts with explicit asserts
  for the outputs that currently go unchecked.
- **Why rejected**: it reproduces the gap it is meant to close. An assert
  encodes what its author predicted could break; the failures that hurt are the
  unpredicted ones. A snapshot has no prediction in it. The two are
  complementary, not competing — e2e stays the layer for "this specific thing
  must hold", golden becomes the layer for "nothing about this changed".

### Alternative B — Line coverage instead of mutation

- **Sketch**: build with coverage instrumentation, report percentage per module,
  set a floor.
- **Why rejected**: it measures execution, not constraint. A line executed by a
  test that asserts nothing about its effect counts as covered, and a suite
  tuned to a coverage floor drifts toward tests that execute rather than tests
  that check. Mutation asks the question coverage is a proxy for.

### Alternative C — Fuzzing (the layer ADR-0021 actually named) instead of property tests

- **Sketch**: open `fuzz/`, run a coverage-guided fuzzer against the reader and
  the evaluator, look for crashes.
- **Why rejected**: not rejected, deferred. Fuzzing answers "does it crash",
  properties answer "is it right"; a runtime that never crashes on malformed
  input can still return the wrong number. Properties are also the cheaper
  first move, since they need no new toolchain. `fuzz/` stays open in ADR-0021's
  deferred list.

### Alternative D — Mutation in the per-commit gate

- **Sketch**: sample a handful of mutants per commit, fail the gate on a
  survivor.
- **Why rejected**: a rebuild per mutant puts it minutes past the gate's budget,
  and a survivor is not a defect — it is a question about a missing test, which
  is work to schedule rather than a commit to block. Gating it would also make
  the seed load-bearing: the same commit would pass or fail depending on which
  mutants were drawn.

## Consequences

- **Positive**: a rendering change fails the gate without anyone having
  predicted its shape; the untested regions of the tree become a named,
  ranked work-list instead of an impression; the layers ADR-0021 promised exist.
- **Negative**: snapshots have to be read when they change, and a reviewer who
  regenerates without reading converts the layer into a rubber stamp. The
  mutation harness is a source-rewriting tool, which is a foot-gun kept safe
  only by the worktree rule above.
- **Neutral / follow-ups**: the mutation sweep's first report will name modules
  with no inline test at all; those become debt rows, not a single task.
  `fuzz/` remains deferred.

## Affected files

- `.dev/decisions/0186_golden_property_mutation_layers.md` (this file)
- `test/golden/run.sh`, `test/golden/cases/**`
- `test/prop/**`
- `scripts/mutation/**` (including `report.py` and `.dev/mutation_equivalent.jsonl`)
- `test/run_all.sh` (the `golden` and `prop` steps)
- `test/README.md`, `.claude/rules/test_taxonomy.md` (the layer table)

## Revision history

- 2026-08-12: Status: Proposed -> Accepted. Layers 6 and 7 land with the ADR;
  Layer 8's harness lands beside them and its first sweep report follows.
- 2026-08-12: Layer 8 gains an equivalence register
  (`.dev/mutation_equivalent.jsonl`), consumed by `scripts/mutation/report.py`.
  The first sweep's three survivors resolved as one real gap (killed by a new
  deep-trie property) and two mutants that provably cannot be observed —
  constants feeding a `>> SHIFT_BITS` that land in the same leaf either way.
  Without a register, an unkillable mutant is re-reported every sweep and
  trains the reader to ignore survivors, which is the one thing this layer
  cannot afford. Registered entries are excluded from the score and each
  carries a written proof; an entry matching no candidate is reported STALE and
  fails the run, so a proof cannot outlive the line it was written about.
