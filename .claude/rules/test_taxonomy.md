---
paths:
  - src/**/*.zig
  - test/**
  - bench/**
---

# Test taxonomy (5 layers)

## Rule

Every test belongs to exactly one of the 5 layers per ADR-0021.
Choose the layer before writing the test.

| # | Layer             | Where                                           | When to choose                                                                                             |
|---|-------------------|-------------------------------------------------|------------------------------------------------------------------------------------------------------------|
| 1 | Unit              | `src/**/*.zig` inside `test "..."` blocks       | Single function, deterministic, no I/O. Default.                                                           |
| 2 | E2E (CLI)         | `test/e2e/*.sh`                                 | `cljw -e '...'` invocation surface, error message rendering, exit codes.                                   |
| 3 | Differential      | `test/diff/cases.yaml`                          | TreeWalk and VM must produce equal Value for the same source. ADR-0005 / 0022.                             |
| 4 | Bench (on demand) | `bench/compare_langs.sh` + `bench/run_bench.sh` | Perf measurement — run on demand, NOT a gate layer (the `quick.sh` auto-baseline was retired 2026-06-11). |
| 5 | Conformance       | `test/clj/` (Phase 11+)                         | Adapted upstream Clojure JVM test.                                                                         |

## Why

- "Where does this test go?" was a recurring review question; the
  table answers it.
- Layers 1-3 + 5 match the runner steps in `test/run_all.sh`
  (zig_build_test, e2e_*, diff_runner, test_clj). Layer 4 (bench) was
  retired from the gate 2026-06-11 — perf is measured on demand.
- ADR-0021 names 8 future layers (Integration, Golden, Property,
  Fuzz, Memleak, Concurrency, Bench full, Wasm component) — they
  open at their phase, not at Phase 4 entry.

## How to apply

### Decision rule

Ask in order:

1. Is it a single deterministic function call? → Layer 1.
2. Is it `cljw -e ...` / file invocation? → Layer 2.
3. Does it require TreeWalk and VM to agree? → Layer 3.
4. Is it a performance measurement? → Layer 4 (run on demand via
   `bench/`, not added to the gate).
5. Is it an upstream Clojure test port (Phase 11+)? → Layer 5.

If none fit, the test is in a future layer (defer or open the
future layer's directory).

### Naming

- Layer 1: `test "<verb> <object> <expected>"`
  (e.g., `test "+ on two integers"`).
- Layer 2: file name `phase<N>_<scope>.sh`, case name in the file.
- Layer 3: `cases.yaml` `name:` is `<area>_<scenario>`
  (`closure_capture_local`, `recur_loop_n3`).
- Layer 4: a benchmark dir `bench/benchmarks/NN_<name>/` (run on demand).
- Layer 5: upstream filename is preserved.

## Wall-clock assertions: lower bounds and orders of magnitude only

Layer 1 says "deterministic". Elapsed time is not, and the gate runs on shared
CI runners whose scheduling noise is larger than most effects worth measuring.

- **A lower bound is safe.** Load makes an operation slower, never faster, so
  "this sleep did not return early" holds on any machine.
- **An order-of-magnitude upper bound is safe.** "It did not wait out the whole
  10 s deadline" discriminates a real hang from a busy machine.
- **A RATIO upper bound is a flake generator.** `elapsed < want * 3/2` cannot
  separate a 20% systematic regression from a 50% busy runner, so it eventually
  fails for the one reason it was not written to detect. 2026-08-05:
  `budgetedSleep: a metered sleep … keeps its duration` asserted exactly that,
  passed every local full gate, and failed on the CI macOS runner.

A performance ratio is a **measurement**, so take it on a quiet machine (Layer 4
`bench/`, run on demand) and record the numbers in the ADR. The unit test keeps
the deterministic half.

- **A work-quantity ceiling is a hidden ratio bound.** An elapsed upper bound on
  "burn N steps / N fuel" scales with per-step cost × host speed, and per-step
  cost varies ~15x across backends (tree_walk vs vm) before hardware is even
  considered. 2026-08-05 nightly: `thread_loop_trips_shared_steps` burned 30M
  budget steps in 4 s on a mac tree-walk and 58 s on the CI Linux runner,
  failing its 45 s bound only in that one config. If the assertion needs an
  elapsed bound, make the metered work *small* (gate the burn on an explicit
  synchronisation point rather than sizing the ceiling against a race window),
  or bound against a wall-clock deadline the feature itself enforces.

## Counter-examples

Don't write a Layer 1 unit test that shells out to `cljw` (that
belongs in Layer 2).

Don't write a Layer 3 case that does not exercise the
backend boundary (TreeWalk-only behaviour belongs in Layer 1).

Don't measure performance with a Layer 1 test (Layer 4 is the
home).
