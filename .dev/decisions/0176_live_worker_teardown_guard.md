# ADR-0176 — Live-worker teardown guard (D-548(a) exit-race hard-exit)

- **Status**: **ACCEPTED 2026-07-29** (DA-fork review incorporated; both
  verification campaigns recorded in Revision history).
- **Deciders**: autonomous loop + one Devil's-advocate fork (general-purpose,
  fresh context, F-006/F-002/F-011/F-009 envelope).
- **Supersedes / relates**: ADR-0174 D6 (the daemon-Thread hard-exit idiom this
  generalises; the 2026-07-17 ubuntunote teardown-race fix), ADR-0175 (the
  sibling registration-safepoint fix; its verification campaign surfaced this
  as a distinct race), D-548 (exposure (a) — this ADR's discharge), D-244.

## Context

D-548(a): `e2e_phase14_future_promise_delay` intermittently SIGABRTs (exit
134) under parallel load — 6/32 runs on an 8-core x86_64 Linux host, the
failing case ROAMING per run, recorded since 2026-06-25 and surviving every
prior GC-race fix (D-418, D-559, ADR-0175). A stderr-capture harness (the
per-invocation wrapper on ubuntunote) finally caught the abort text:

> `malloc_consolidate(): unaligned fastbin chunk detected`
> `corrupted double-linked list`

— glibc allocator-metadata corruption, on expressions that leave a
**fire-and-forget worker** behind (`(future 1)` never deref'd; a
`(future (deref d))` whose value nobody waits for).

Root cause: **process-teardown vs detached-worker race.** After the program
body, `runSource` runs `thread.joinAllNonDaemon` — which joins only the
`(Thread. f)` registry and hard-exits only for live *daemon* Threads — then
its defers run `env.deinit()` + `rt.deinit()`, freeing the GC heap and every
gpa-backed structure. Detached future workers and agent drainers are invisible
to that barrier, so a worker still running its thunk — or, subtler, still in
its exit EPILOGUE (`join`/deref wake at the result broadcast, which happens
BEFORE the worker's `gc.unpin` + `unregisterThread`) — mutates freed memory
and corrupts the allocator. Roaming case selection (whichever invocation's
worker lags), load sensitivity (worker epilogues delayed on a busy host), and
the Linux bias (glibc's metadata checks abort; macOS malloc is quieter) all
follow.

## Decision

Generalise the established daemon hard-exit idiom: **graceful Runtime teardown
is legal only when no worker thread is live; otherwise flush and
`std.process.exit(0)`** (abandon the heap; the OS reclaims — observably
identical to today's immediate exit, minus the corruption).

1. **`root_set.live_workers`** (seq_cst atomic): the spawner increments BEFORE
   `Thread.spawn` (rolling back on spawn failure) at all four spawn sites
   (future, agent send-spawn, agent restart-spawn, Thread.start); the worker
   decrements as its very LAST action (its first-declared defer — after the
   result store, `gc.unpin`, and `unregisterThread`). Distinct from
   `registered_count`: it covers the pre-register and post-unregister spans.
   The worker's seq_cst decrement pairs with the boundary's seq_cst read, so
   count==0 proves every epilogue completed.
2. **`thread.joinAllNonDaemon` half 3**: after joining non-daemon Threads and
   the daemon check, `if (live_daemon or liveWorkerCount() > 0)` → flush +
   hard exit. The count can only drop after the program body (only live
   workers spawn workers), so a 0 read proves teardown is race-free.
3. **Every app success-exit boundary calls the barrier** (renamed
   `thread.exitBarrier` — it now owns three duties: join non-daemon Threads,
   daemon hard-exit, worker-quiescence-or-hard-exit): `runSource`,
   `runSourceCompare` OK-branch, `repl.run`, `nrepl.run`'s exit return
   (which deletes `.nrepl-port` first — a hard exit skips the defer),
   `builder.buildArtifact`, `builder.tryRunEmbedded`. `noreturn` error paths
   (`renderAndExit`/`std.process.exit`) skip teardown and are safe as-is.
4. **The teardown chokepoint is guarded too** (the DA fork's decisive
   finding): error-UNWIND paths — a broken stdout pipe mid-print, any failed
   post-eval `try` — reach `defer rt.deinit()`/`env.deinit()` WITHOUT
   passing an app barrier, reproducing the race. Both deinits now run
   `awaitQuiescentWorkers(50ms)` first: epilogue stragglers quiesce in µs →
   real teardown; a timeout (= a genuinely running thunk) → **skip all
   freeing and return** (abandon the heap; the imminent process exit
   reclaims; exit codes and the remaining unwind proceed normally). No
   `std.process.exit` inside library code, so `zig build test` can never be
   truncated.
5. **Barrier prefers graceful teardown** (DA Alt-2 shape, one counter): the
   barrier waits the same bounded 50ms — the common case (a completed
   thunk's µs epilogue) proceeds to real teardown so Debug leak reports stay
   meaningful and deterministic; only a genuinely running thunk hard-exits.
6. **Deterministic regression canaries** via `CLJW_TORTURE_TEARDOWN_DELAY_MS`
   (test-only, parsed at CLI startup): `Runtime.deinit` sleeps AFTER its
   guard and before freeing, widening the window so a guard regression
   aborts deterministically. E2e cases `exit_pending_future` (the AD-056
   pin), `exit_teardown_injected_running`, `exit_teardown_fireforget_epilogue`
   in `phase14_future_promise_delay.sh`.

**Deliberately preserved divergence — now LEDGERED as AD-056** (per the DA
fork's process finding: a header comment is not the ledger): on the JVM a
fire-and-forget future keeps the process alive (non-daemon pool threads;
`shutdown-agents`); cljw exits immediately. This ADR only makes that exit
memory-safe. The JVM-exact wait-at-exit flip is *more* F-011-compliant
(including its hang on an undelivered promise — parity, not a defect) but
would hang every fire-and-forget script and needs shutdown-agents plumbing;
rejected here as a product choice, recorded in AD-056 with the
`exit_pending_future` pin.

## Verification

Two layers (the DA fork corrected the draft's "statistical only" claim: a
WORKER-side sleep hides the race, but a TEARDOWN-side delay amplifies it):

- **Statistical, the primary measure** — the capture harness, same host,
  same 8×-parallel protocol (the pre-fix rate is load-dependent, so the
  harness must be replicated exactly): pre-fix 6/32 aborts (historically
  3/8, 1/8, 2/8 rounds); post-fix bar 0 over ≥ 64 runs. Results in Revision
  history + D-548.
- **Deterministic canaries** — the `CLJW_TORTURE_TEARDOWN_DELAY_MS`
  injection (Decision item 6) turns a guard regression into a reliable
  abort; the three e2e cases run in every gate on every platform.

## Alternatives considered (DA fork output, condensed faithfully)

The fork reviewed the six-barrier draft against the actual tree and found it
**narrowed the race rather than closing the class** — its Finding 1 (error-
unwind paths reach `defer rt.deinit()` past every barrier: broken stdout pipe
in `printResult`, failed `try`s in repl/nrepl/builder post-eval code) drove
Decision items 4-5. Its other adopted findings: the `.nrepl-port` stale-file
divergence on hard exit (fixed — cleanup before the barrier); "deterministic
red is unattainable" was overstated (the teardown-side delay injection is a
legitimate amplifier — adopted as the canary knob); the immediate-exit
divergence must be an AD row with a pin, not a header comment (AD-056); and
the `joinAllNonDaemon` name lied about its three duties (renamed
`exitBarrier`).

1. **Smallest-diff — six app barriers with `std.process.exit` only** (the
   original draft): leaves every post-eval `try` an open re-entry point for
   the bug and makes teardown-path selection racy (nondeterministic leak
   reports). Rejected as the Smallest-diff-bias shape.
2. **Finished-form (ADOPTED, combined Alt 1+2)**: the counter stays; the
   guard moves to the teardown chokepoint (`Runtime.deinit`/`Env.deinit`
   skip-freeing-and-return — no exit() in library code, no test truncation),
   with a bounded epilogue-wait so the dominant case gets REAL graceful
   teardown; the barrier keeps the hard exit for genuinely running thunks.
   The fork's full two-counter variant (`thunks_running` separate from
   `live_workers`) was simplified to one counter + bounded wait: epilogues
   cannot block, so a 50ms timeout separates the two populations with the
   same outcomes and one fewer ordering proof.
3. **Wildcard — shutdown as permanent stop-the-world** (reuse
   `safepoint.stopWorld`, never resume, then free with mutators provably
   parked): the only shape that is graceful ALWAYS, but it still needs the
   spawn-side counter (STW sees only registered workers), requires blocked-
   in-condWait workers to count as parked or it deadlocks, and freeing
   `FutureCell` condvars with live waiters is exactly the glibc-metadata
   territory being escaped. Enumerated and rejected.

Not adopted (recorded): the fork's suggestion of a Debug
`assert(liveWorkerCount()==0)` in the freeing path is subsumed by the
skip-guard itself (the guard handles the case the assert would trip on). Its
(d) note — nREPL mid-session hazards (per-message `scratch_arena.reset` vs a
still-running worker's thunk references; session-close frees) are OUT of this
ADR's scope and are NOT claimed fixed; if symptoms appear they are a separate
D-row, not a D-548 reopen.

## Consequences

- The fpd suite's `ncpu < 4` SKIP (which cites exactly this SIGABRT class)
  is removed once the campaign passes — the 3-vCPU hosted runner runs the
  suite again; the nightly is the watchdog. Exposure (b) (pmap wall-clock
  assert, `phase14_parallel_seq`) is a separate timing-envelope issue and
  keeps its gate; D-548 re-scopes to (b)-only.
- A worker that outlives the program body is now ALWAYS killed by hard exit
  (previously: killed by teardown+exit, sometimes corrupting on the way).
  Its side effects were never guaranteed; that contract is unchanged.
- `Runtime.deinit` remains a true teardown for tests; the guard lives only at
  app exit boundaries.

## Affected files

- `src/runtime/gc/root_set.zig` — `live_workers` counter + notes API.
- `src/runtime/future.zig`, `src/runtime/agent.zig`, `src/runtime/thread.zig`
  — spawner-increment + worker final-decrement.
- `src/runtime/thread.zig` — `joinAllNonDaemon` half 3.
- `src/app/{runner,repl,nrepl,builder}.zig` — barrier at success exits.
- `test/e2e/phase14_future_promise_delay.sh` — ncpu gate removal (post-camp).
- `.dev/debt.yaml` D-548 — (a) discharge + (b) re-scope.

## Revision history

- 2026-07-29: drafted alongside the fix; six-barrier mechanism verified on
  the capture harness — fpd 0/64 (pre-fix 6/32) + gc_torture drain 0/100
  regression-clean on the 4-vCPU-pinned x86_64 host.
- 2026-07-29 (same cycle): DA-fork review incorporated (chokepoint guards,
  graceful-preferred barrier, rename, AD-056, canaries) → ACCEPTED; final
  confirmation campaign on the complete shape recorded in D-548.
