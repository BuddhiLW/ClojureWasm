# 0195 — The runtime thread owns its stack geometry; cljw does not run on the initial thread

- **Status**: Proposed -> Accepted
- **Date**: 2026-09-05
- **Author**: BuddhiLW
- **Tags**: threads, stack, startup, wasm, ffi, jit, zwasm/D-584, ADR-0157, ADR-0193, ADR-0200, F-001, F-002, F-009

## Context

### The trigger: a 14x per-call cost that exists only on thread 1

`wasm/call` on the default `.auto` (JIT) engine costs 16.5-18.9 us per call on
Linux, against 392 ns on `:engine :interp` and 184 ns for a Clojure function
call (`.dev/wasm_percall_findings.md`, `.dev/bench/ffi_boundary/`). The cause
is upstream **zwasm/D-584**: `computeStackLimit` runs on every JIT invocation,
and on Linux the stack-limit query for the process's INITIAL thread parses
`/proc/self/maps` (~26 us). Any other thread answers from its thread
descriptor. Measured in cljw itself, same process, same trivial `add` export,
20k calls per cell (`engine_thread_matrix.clj`):

| cell                   | ns/call |
|------------------------|---------|
| JIT, initial thread    | 16547   |
| JIT, worker thread     | 1181    |
| interp, initial thread | 399     |
| interp, worker thread  | 413     |

zwasm v2.6.0 (the current pin) does not fix it. Per F-001 a zwasm-side issue
is an upstream report, never a cljw-side edit of zwasm. The cljw-side
question is where cljw runs, and the answer turns out to be a finished-form
gap that predates the measurement.

### The gap the trigger exposed: nothing owns the runtime thread's stack

ADR-0157's self-calibrating guard raises a catchable `StackOverflowError`
once `stack_base - @frameAddress()` exceeds `STACK_BUDGET_BYTES` (6 MiB,
`src/eval/backend/vm.zig`, duplicated in `src/eval/backend/tree_walk.zig`).
That budget is sound only by a prose convention: "8 MiB main / ~16 MiB worker
stacks". The 8 MiB is `ulimit -s`, which cljw neither sets nor reads
(`getrlimit` is absent from `src/`). Under `ulimit -s 4096` the guard trips
at 6 MiB on a 4 MiB stack: a SIGSEGV today. Workers get their 16 MiB from
`std.Thread.SpawnConfig.default_stack_size` through an empty `.{}` in
`src/runtime/concurrency/spawn.zig`, an implicit inheritance nobody wrote
down. The thread that runs every user program is the only thread whose stack
geometry cljw does not choose.

### Facts the design rests on (verified in source, see the DA report)

- Nothing in cljw binds to the initial thread. The REPL's raw mode is per
  terminal fd (`src/app/repl/line_editor.zig`), there are no signal handlers
  or `sigaltstack`, `std.process.exit` is process-wide from any thread, and
  the GC's "main" is a ROLE (the unregistered thread reading its own TLS,
  `src/runtime/gc/root_set.zig`), not a thread id. The stop-the-world
  rendezvous counts registered workers minus the collector; the exit barrier
  joins only threads registered through `Thread.start` / `noteWorkerSpawned`.
- The stack guard, the GC's conservative stack scan and the VM arena are all
  threadlocal, anchored on whatever thread first enters `eval`.
- `-Dwasm` builds link libc: zwasm sets `.link_libc = true` on every module it
  exports. The gate binary is a glibc pthreads program; the non-wasm build is
  not. Both spawn threads through `std.Thread` either way.
- `std.process.Init.arena` and `.environ_map` are pointers into the start
  frame, alive while the initial thread blocks in `join`; `gpa` and `io` are
  documented thread-safe.
- wasm32-wasi (ADR-0193) is `builtin.single_threaded`; `std.Thread.spawn` is
  a compile error there and `spawn.zig` already carries the comptime shape.
- There is no cold-start gate step; one `pthread_create` with a lazily
  committed 16 MiB reserve is ~20-60 us, once per process.

## Decision

1. **One module owns runtime-thread geometry:
   `src/runtime/concurrency/runtime_thread.zig`** (namespace-neutral, F-009).
   It defines `RUNTIME_STACK_BYTES` (16 MiB), the `std.Thread.SpawnConfig`
   built from it, and `STACK_BUDGET_BYTES` (6 MiB). `spawn.zig` spawns
   workers with that config, so the runtime thread and every worker have
   identical geometry (Single-Source Lever). `vm.zig` and `tree_walk.zig`
   read the budget from here. The margin is asserted at comptime in the
   module itself, `STACK_BUDGET_BYTES + TLS_RESERVE_BYTES + STACK_SLACK_BYTES
   <= RUNTIME_STACK_BYTES` (2 MiB reserve, 1 MiB slack), replacing the prose
   margin; `vm.zig` asserts its own `@sizeOf(VmArena)` against the reserve
   (`assertTlsFits`), so the dominant TLS consumer is checked where it is
   declared and the margin arithmetic lives in one place. The TLS term
   matters: under glibc pthreads the static TLS block (the threadlocal
   `VmArena`, roughly 1 MiB) is carved out of the thread's stack allocation.
2. **`main.zig` runs `cli.dispatch` on a spawned runtime thread**:
   `runtime_thread.runMain(cli.dispatch, .{init})` spawns with that config,
   joins, and returns the callback's error so `wrapMain` reports it exactly
   as before. On `builtin.single_threaded` targets it is a direct call. On
   spawn failure (a container with a tiny `RLIMIT_AS`) it degrades to a
   direct call after one stderr line, the same graceful-disable posture zwasm
   takes for its own stack probe. The entry thread never registers a
   `ThreadGcContext` and never touches `noteWorkerSpawned`, so it is not a
   worker to the exit barrier or the safepoint; a unit test pins that, along
   with: the callback observes a different `std.Thread.getCurrentId()` than
   the caller, and a returned error propagates.
3. **The engine default is NOT decided here.** After (2) the JIT's per-call
   overhead on Linux drops from ~16.1 us to ~0.8 us over interp, which moves
   the compute break-even from ~17 us of wasm body to ~0.8 us (using the
   15.5x body speedup from `bench/wasm_jit_vs_interp.sh`). That is the
   strongest argument for keeping `.auto`, but cljw's own **D-585** (void
   exports of some arities TRAP on the JIT and `.auto` cannot downgrade) is a
   correctness fact that outranks it. `[CLJW-WASM-ENGINE-DEFAULT]` decides
   with D-585 ranked above the 2.9x; this ADR only removes the 14x.
4. **zwasm/D-584 gets a cljw ledger row** with the barrier "zwasm memoises
   `computeStackLimit` per thread (re-check `engine/codegen/shared/entry.zig`
   at every pin bump)". The measurement device is
   `.dev/bench/ffi_boundary/engine_thread_matrix.clj`, run on demand; a
   timing ratio in the gate would be a flake generator (test_taxonomy), so
   there is deliberately no gated gap-lock. When the barrier dissolves the
   trigger paragraph above is history and the geometry decision stands on
   its own.
5. **Residual attribution, corrected.** Of the 1181 ns a worker-thread JIT
   call costs, ~570 ns is STILL zwasm/D-584 (the glibc query on a non-initial
   thread, zwasm ADR-0209). zwasm/D-585 (export re-resolved by name per call)
   plus cljw's own double resolve in `wasmCallFn` (`exportSig` then `invoke`,
   both by name) is the remaining ~200 ns. The upstream report, when filed
   (user nod required, `[ZWASM-PERCALL-TRACK]`), asks for per-thread
   memoisation and notes the musl hygiene point below.

## Alternatives considered

The Devil's-advocate report (`private/notes/adr-0195-da.md`, fresh context,
read-only) is reflected verbatim. Its recommendation (Alt B) is the decision
above; its three corrections to the draft (geometry as the reason, the
residual split, the libc link model) are absorbed.

### Leading finding

No F-NNN conflict. F-001's live text (2026-08-12 entry) forbids editing zwasm
and pinning a non-release; a zwasm-side finding "is now an ordinary upstream
report". The 2026-06-05 clause "no cljw-side code change to work around a
zwasm-side issue" is explicitly RETIRED by that entry. The draft edits no
zwasm code and keeps the v2.6.0 pin, so it is F-001-legal.

Three corrections the draft must absorb before Accepted, or it is the
Workaround smell wearing an ADR:

1. Its only stated rationale evaporates the day upstream lands a threadlocal
   memo in `stack_limit.zig`. After that, the entry hop is vestigial unless
   the ADR carries an independent finished-form reason. One exists (Alt B):
   the runtime thread's stack geometry is today owned by nothing. ADR-0157's
   6 MiB guard is sound only by the prose convention "8 MiB main / 16 MiB
   worker"; `ulimit -s 4096` makes it a SIGSEGV today. Frame the ADR on
   geometry ownership with D-584 as the trigger, not the reason.
2. The residual attribution is wrong. zwasm ADR-0209 measures the
   worker-thread glibc query at 561-578 ns per call. Of the post-fix 1181 ns,
   about 570 ns is STILL D-584; D-585 plus cljw's own double resolve is only
   ~200 ns. The upstream report must ask for per-thread memoisation, which
   would put a trivial JIT call near 600 ns (~1.5x interp), not 2.9x.
3. cljw `-Dwasm` links libc. zwasm sets `.link_libc = true` on every module it
   exports, so the gate binary is a glibc pthreads program. The brief's "does
   not appear to link libc" holds only for the non-wasm build.

Also missing from the draft: no cljw ledger row references D-584 at all, and
no gap-lock exists for it. Without both, the rationale cannot be retired when
upstream fixes it.

### Alt A: smallest-diff

Keep the runtime on thread 1. Document `@(future ...)` (measured 12.5x) and
`{:engine :interp}` in the wasm docs; add the cljw `exportSig` cache; file the
upstream issue. Better than the draft: zero structural change, zero risk to
exit/REPL paths, no comptime branch for wasm32-wasi. Breaks: the `.auto`
default keeps choosing an engine ~41x slower than interp for trivial calls on
the platform the gate runs on, and the user has to know a threading trick to
get the documented engine's speed. This is the Smallest-diff bias smell and
fails F-002; rejected.

### Alt B: finished-form-clean (recommended, taken)

Own runtime-thread geometry as a single-sourced property, with the
initial-thread hop as a consequence. New `runtime_thread.zig` holding ONE
16 MiB `SpawnConfig`, consumed by both the entry hop and `spawn.zig`;
`STACK_BUDGET_BYTES` shared with a comptime assertion against the stack size
minus the static TLS reserve; `runMain` degrading to a direct call on
`single_threaded` and on spawn failure; a ledger row for the upstream cost;
the residual paragraph corrected. Better than the draft: survives the
upstream fix without becoming a fossil; removes the `ulimit -s` dependence of
ADR-0157's calibration; turns a prose invariant into a compile-time one; the
zwasm JIT stack probe gets a precise pthread bound for the runtime thread
instead of the top-minus-rlimit estimate, so a wasm stack-overflow trap is
deterministic. Breaks: a larger diff; unit tests still run on thread 1 (they
do not enter `main.zig`), which is fine. Diff size is not a project
constraint; F-002 says take it.

### Alt C: wildcard

Symbol interposition: cljw exports its own `pthread_getattr_np` that memoises
per thread and delegates to glibc via `dlsym(RTLD_NEXT)`. Fixes the cost on
thread 1 AND on every worker. Breaks: the Workaround smell in pure form
(patching glibc underneath zwasm), glibc-only, silently wrong under static
linking, invisible to zwasm's own bench, and it removes the pressure that
gets the upstream memo landed. Rejected; recorded so the section shows it was
seen.

### Attack answers (condensed; file:line citations in the report)

1. Initial-thread assumptions: none found. termios is per fd; no
   `sigaction`/`sigaltstack`/`getCurrentId`/`main_thread` in production
   `src/`; `std.process.exit` is process-wide from any thread. One visible
   change: an error RETURNED by `dispatch` (not exited) currently prints the
   failing thread's error-return trace; re-returned from `main` it prints the
   initial thread's one-frame trace. `Init.arena`/`environ_map` point into
   the start frame, alive while the initial thread blocks in `join`.
   `exitBarrier` joins `rt.user_threads` then waits on `live_workers`; the
   dispatch thread touches neither. root_set's "main" is a role. safepoint's
   rendezvous target is a registered count, not a thread id. wasm32-wasi:
   `std.Thread.spawn` is `@compileError` under `single_threaded`; the comptime
   shape exists in `spawn.zig`. nrepl spawns no threads; `future`/agent/Thread
   workers become children of the runtime thread, which changes nothing they
   observe.
2. Stack size: no `getrlimit` in cljw `src/`. `ulimit -s` today bounds thread
   1's growth; after the change it bounds nothing in cljw. The hazard is
   INVERTED: today a small ulimit defeats the 6 MiB guard; after, the guard is
   sound regardless. Upstream hygiene: zwasm's `stack_limit.zig` parses
   `[stack]` for ANY thread on non-glibc Linux, which is thread 1's mapping,
   so on a musl/static build the JIT probe on a non-initial thread would
   compare SP against thread 1's bounds. cljw has no musl target; a musl
   target re-opens this, and the upstream report should include it.
3. Dedicated wasm worker + per-call hop: never better. A cross-thread futex
   handoff is two context switches, 5-20 us, against a 1 us threshold, and a
   host import calling back into Clojure would run on a thread with no
   `ThreadGcContext`, invisible to stop-the-world. It re-creates the D-244 #4
   territory for a loss.
4. Flip the default to `:interp`? On perf alone, no: the fix moves the
   compute break-even by ~20x. But cljw's open D-585 row is a correctness
   fact perf does not answer. Keep the default OUT of this ADR (Decision 3).
5. Startup cost: no `cold_start` run step exists; the only perf-cliff guard
   is `assert_e2e_releasesafe`. One spawn is under 1.5% of cold start; across
   the ~3200-spawn e2e suite that is +0.1-0.2 s total. Applying it to
   non-wasm builds is the POINT (uniform geometry), not a cost.

## Consequences

- Positive: JIT `wasm/call` on Linux drops ~14x with no zwasm change and no
  user-visible API; macOS unaffected (zwasm/D-584 does not exist there).
  `@(future ...)` stops being a needed workaround. Measured after landing
  (2026-09-06, `engine_thread_matrix.clj`, min of 6 on a loaded host): JIT
  main thread 16547 -> 1150 ns, now equal to the worker cell (1262); interp
  409 / 479, unchanged within noise.
- Positive: ADR-0157's margin becomes a compile-time fact instead of an
  `ulimit` assumption; every cljw thread has the same, chosen stack.
- Positive: the zwasm JIT stack probe sees a precise pthread bound on the
  runtime thread, so a guest stack-overflow trap is deterministic.
- Negative: one thread spawn per process start (tens of microseconds, once);
  an error returned (not exited) from `dispatch` loses the worker's
  error-return trace in favour of the initial thread's one-frame trace.
- Neutral: exit codes, `std.process.exit` sites and panics behave as before;
  the runtime remains single-threaded; unit tests still run on thread 1.
- Follow-ups kept separate: `[CLJW-WASM-ENGINE-DEFAULT]` (Decision 3),
  `[CLJW-WASM-EXPORTSIG-CACHE]` (the cljw half of the residual),
  `[CLJW-WASM-BENCH-BLIND]` (the crossing-dominated bench axis).

## Affected files

- `src/main.zig`: `runtime_thread.runMain(cli.dispatch, .{init})`; test
  aggregator imports the new module.
- `src/runtime/concurrency/runtime_thread.zig` (new): the geometry SSOT,
  `runMain`, unit tests.
- `src/runtime/concurrency/spawn.zig`: workers spawn with the shared config.
- `src/eval/backend/vm.zig`, `src/eval/backend/tree_walk.zig`: budget read
  from the SSOT; vm.zig asserts `@sizeOf(VmArena)` fits the TLS reserve; the
  prose margin comment retired.
- `.dev/debt.yaml`: the zwasm/D-584 tracking row.
- `.dev/wasm_percall_findings.md`, `.dev/bench/ffi_boundary/README.md`:
  residual attribution corrected; after-numbers recorded when measured.
- `CHANGELOG.md`: user-visible entry (the per-call cost on Linux).

## References

- `.dev/wasm_percall_findings.md`; GitHub issues #13, #14, #15.
- zwasm ADR-0209, zwasm/D-584, zwasm/D-585 (`~/PP/referential-projects/zwasm`).
- ADR-0157 (self-calibrating stack guard), ADR-0193 (wasm32-wasi target),
  ADR-0200 (JIT adoption), D-488 (the `.auto` flip), cljw D-585 (JIT
  zero-result gap, ADR-0192).
- Kanban `[CLJW-WASM-WORKER-THREAD]` (`20260905012150-05dc6702`),
  `[CLJW-WASM-ENGINE-DEFAULT]` (`20260905005755-11afa056`),
  `[ZWASM-PERCALL-TRACK]` (`20260905005855-3d34a890`).
- `.dev/principle.md`: Workaround smell, Smallest-diff bias smell,
  Cycle-budget defer smell (all three named in the DA report).
