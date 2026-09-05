# Wasm per-call cost: findings, and the fix

Written 2026-09-05. Tracked as GitHub issues
[#13](https://github.com/BuddhiLW/ClojureWasm/issues/13) (the cost),
[#14](https://github.com/BuddhiLW/ClojureWasm/issues/14) (the fix) and
[#15](https://github.com/BuddhiLW/ClojureWasm/issues/15) (the blind spot).
Durable copy of work that would otherwise live only in hive kanban, which was
down when this was written. If hive is up, the cards
`[CLJW-WASM-ENGINE-DEFAULT]`, `[CLJW-WASM-WORKER-THREAD]`,
`[CLJW-WASM-BENCH-BLIND]`, `[CLJW-WASM-EXPORTSIG-CACHE]` and
`[ZWASM-PERCALL-TRACK]` carry the same content.

## The measurement

20k calls per cell, one process, same trivial `add` export, Ultra 9 185H,
ReleaseSafe `-Dwasm`. Reproduce with
`./zig-out/bin/cljw .dev/bench/ffi_boundary/engine_thread_matrix.clj`.

| cell                 | ns/call |
|----------------------|---------|
| JIT, main thread     | 16547   |
| JIT, worker thread   | 1181    |
| interp, main thread  | 399     |
| interp, worker thread| 413     |

For context, from `.dev/bench/ffi_boundary/`: a Clojure function call is 184 ns,
so the interpreter's 399 ns crossing is 2.1x a local call. The boundary is
cheap. The default is not.

## Two independent causes, both upstream, both already documented there

zwasm ADR-0209 (`.dev/decisions/0209_percall_latency_bench.md` in the zwasm
tree; clone at `~/PP/referential-projects/zwasm`) names both. Do not re-report
them upstream.

- **D-584** dominates on Linux. `computeStackLimit` runs on every JIT
  invocation, and glibc's `pthread_getattr_np` answers for the process's FIRST
  thread by opening and parsing `/proc/self/maps`. Any other thread answers from
  the thread descriptor. zwasm measures 26.8 us initial thread, 561-578 ns
  worker thread, 3.1-3.4 ns on aarch64-macos. The interpreter caches the value,
  which is why it is thread-indifferent above.
- **D-585** is the residual. The embedding API resolves the export by name on
  every call and `findExportFunc` parses the whole module to do it. Linear in
  module size (687-859 ns/KiB upstream). Public issue zwasm#208.

Neither is fixed as of zwasm v2.6.0 / upstream main: `computeStackLimit` is
still called at `entry.zig` 248 and 272 and `entry_buffer_write.zig` 86.

A warning worth repeating, because this session walked into it. ADR-0209 says:

> "A reviewer checking this on Linux alone will find the two paths agree within
> 2%, which reads as 'the re-parse does not matter'. That agreement is D-584's
> constant, well over 100x larger, swamping D-585."

The mirror-image error is just as easy: attributing the whole Linux cost to the
re-parse because the re-parse is the part you read. Two costs on one path cannot
be separated by reading either one. Get a number that isolates the candidate.

## The fix: cljw should not run on the initial thread

Spawn one thread in `main.zig` with an explicit stack size, run the existing
main body on it, join. The runtime stays SINGLE-THREADED; it just stops being
thread 1. One spawn at startup, tens of microseconds, once. It buys ~14x on
every JIT wasm invocation on Linux and costs nothing on macOS, where D-584 does
not exist.

The win is already reachable from Clojure with no cljw change: wrapping
crossing-heavy work in `@(future ...)` measured 12.5x. That is a workaround, not
the fix, because a user should not have to know this.

### Feasibility, already checked

- cljw's stack guard is **anchor-relative**, not an OS query:
  `stack_base - @frameAddress()` (`src/eval/backend/vm.zig:114`,
  `src/eval/backend/tree_walk.zig:449`). It measures consumption below an anchor
  captured at entry, so it works on any thread provided the anchor is captured
  there. ADR-0157's self-calibrating guard is not an obstacle.
- GC stack scanning also anchors on `@frameAddress()`
  (`src/runtime/gc/mark_sweep.zig:380`). Single-threaded on a different thread
  scans the same one stack it always did. No change in kind.

### Still to check before landing

- Explicit stack size on the spawned thread. Do not inherit a default smaller
  than the 8 MB the main thread had, or ADR-0157's calibration shifts under it.
- Signal handlers and guard pages (ADR-0019 crash policy) installed expecting
  thread 1.
- Anything assuming the initial thread: REPL / terminal handling, atexit, macOS
  specifics.
- The nREPL, `future` and agent paths already spawn threads. Confirm the move
  does not double-nest them or change their parent.

This is ADR-level, since it changes where the whole runtime executes. Draft the
ADR with the mandatory devil's-advocate fork per CLAUDE.md, then land it behind
a full gate.

### What it does not fix

Even on a worker thread the JIT is 2.9x the interpreter on a trivial callee.
That is D-585, untouched by this change. Engine choice stays shape-dependent:
the JIT wins 15.5x on compute-in-wasm (`bench/wasm_jit_vs_interp.sh`) and loses
on crossing-heavy work at any thread. A single default cannot serve both, which
is the open question in `[CLJW-WASM-ENGINE-DEFAULT]`.

## The methodological defect behind all of this

Every workload in `bench/wasm_bench.sh` calls a `*_bench` export that carries
its own iteration loop, so each run crosses the boundary exactly once. A
per-crossing cost of any size is invisible to the entire suite. That is how a
~19 us per-call cost sat behind a suite reporting cljw at 1.4-4.4x wasmtime.

zwasm reached the identical conclusion about its own harness (ADR-0209 D1) and
built `bench/latency/percall_runner.zig` in response: instantiate once, call
many times, time only the calls, report median with min and max, and record the
per-platform constant separately so a regression in it is distinguishable from a
regression in the engine. Copy that shape rather than inventing one.
