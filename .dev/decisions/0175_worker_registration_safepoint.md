# ADR-0175 — Worker registration is a GC safepoint (spawn-to-register window)

- **Status**: **ACCEPTED 2026-07-29.**
- **Deciders**: autonomous loop + one Devil's-advocate fork (general-purpose,
  fresh context, F-006/F-002/F-011/F-009 envelope; output reflected verbatim
  in Alternatives considered).
- **Supersedes / relates**: ADR-0090 (the STW safepoint rendezvous this
  extends), ADR-0150 + am1 (fabrication region / park semantics — sibling
  park-site rule), D-244 #4, D-548 (the load-flake ledger this explains a leg
  of), D-418/D-559 (the two previously-fixed agent-path GC races).

## Context

The scheduled full-gate CI on x86_64-linux (run 30333558512, 2026-07-28) failed
`e2e_phase16_gc_torture` with SIGABRT (exit 134) in the alloc-torture agent
block (`agent_alloc 'drain'`), on a commit whose previous six nightly runs were
green — an intermittent race, not a regression. Reproduced on a 4-vCPU-pinned
x86_64 host at ~1.5%/run; a `-Dprofile` build captured the crash four times
with one identical signature:

> General protection exception in `root_set.nextThreadRoots`
> (the thread-roots walk), on the MAIN thread, inside the STW collect injected
> by `agent.tortureCollectInWindow` during `send`.

Root cause: **`safepoint.stopWorld` computes its park-rendezvous target from
`registered_count`, but a worker thread that has been SPAWNED and not yet
REGISTERED is invisible to it.** The agent drain case churns drainers (each
queue-empty exit + next send spawns a fresh one) while the alloc-torture
injects a collect at every enqueue, so this interleaving fires readily on a
slow/loaded runner:

1. `send` #k: queue empty → spawn drainer D. `std.Thread.spawn` returns; main
   continues while D is still starting up (OS scheduling delay — the reason
   this is a 4-vCPU-Linux flake and a 10-core-Mac never).
2. `send` #k+1: the injected collect runs `stopWorld` → `registered_count` is
   0 (D not yet registered) → target 0 → returns immediately → the collector
   begins the root walk + sweep.
3. D comes to life, `registerThread` succeeds (it never looked at
   `gc_requested`), D pops an action and runs it — pushing binding/eval frames
   that the collector's `nextThreadRoots` is concurrently reading through the
   published TLS slot pointers (torn frame chain → GP fault, the observed
   crash), while the popped action itself has left the queue's traceGc range
   (swept-in-use → the drainer-side UAF variant, also observed as a heap-address
   SIGSEGV).

The walk's stated safety justification — "the safepoint guarantees no
concurrent register/unregister during collect" — was false for exactly this
window. Every prior fix in this family (D-418 enqueue-window rooting, D-559
park-honors-fabrication) assumed the rendezvous itself was sound; this is the
rendezvous's own hole.

## Decision

**Registration is itself a GC safepoint, and the registration handshake is
seq_cst.** Concretely (all landed in this arc):

1. **`registerThread` parks the newborn** (root_set.zig): after publishing its
   slot + count (under `registry_mutex`) and releasing the mutex, the worker
   loads `gc_requested` (seq_cst) and calls `safepoint.park()` if set — so a
   worker born while a collect is arming/running quiesces before its first
   mutator step. A freshly registered ctx publishes only empty TLS roots, so a
   collector already mid-walk reading its slot sees an empty contribution.
2. **Seq_cst Dekker pairing**: `stopWorld`'s `gc_requested.store(true)` + its
   `registeredCountLockFree()` read, and `registerThread`'s
   `registered_count.fetchAdd` + its `gc_requested` load, are all seq_cst.
   The count add sits under `registry_mutex` and the collector's count read
   under `sp_mutex` — no common lock, so without seq_cst the both-sides-miss
   interleaving (store-buffer/Dekker) is real. Under seq_cst either the
   collector waits for the newborn's park, or the newborn parks at
   registration — never both-miss. **Do not relax these four orderings** —
   both sides carry comments naming the pair.
3. **Atomic registry-slot access**: `threadContextAt` / `markRegisteredTxs`
   read slots with `@atomicLoad(.acquire)`, register/unregister write with
   `@atomicStore(.release)`. A newborn may legally publish its slot mid-walk
   (it then parks); mid-collect slots only transition null→ctx (unregistration
   is impossible mid-collect — every already-registered worker is parked or
   blocked-counted for the rendezvous to have completed).
4. **The `TooManyThreads` fallthrough is closed** (the DA fork's finding — the
   same corruption class, deterministically reachable at the 64-worker cap,
   e.g. `(dotimes [i 100] (future …))`): `future.worker` and `thread.worker`
   previously ran their thunk UNREGISTERED when registration failed. Now: a
   future realises as `realised_error` with nil cached (no allocation — an
   unregistered thread may not touch the GC heap; `errorValue`'s new nil-guard
   routes `deref` to the generic `future_thunk_failed` raise), and a Thread
   reports one non-allocating stderr line + falls through to its done-epilogue.
   The agent drainer already bailed correctly (releases the drainer slot; the
   queued actions wait for the next send-spawned drainer).
5. **Shared worker-context builder**: `root_set.workerContext(tx_slot)` builds
   the standard 5-slot ctx from the calling thread's own TLS; the three worker
   families (agent drainer / future / Thread) use it, so a future worker family
   cannot silently drop a slot.

### Invariants this ADR makes explicit (previously unwritten)

- **Pre-registration code touches only spawner-pinned objects + pure bit-ops.**
  Every spawn site `gc.pin`s the object the worker will address before
  `Thread.spawn` (agent/future/thread all do); under F-006 non-moving GC that
  makes the newborn's pre-register reads safe. A new spawn site must keep this.
- **No lock may be held at a `registerThread` call site** (the registration
  park would strand it). True at all sites today; documented as a contract on
  `registerThread`.
- **On `TooManyThreads` the worker must NOT run its mutator body**, and its
  failure report must not allocate on the GC heap.

## Verification

- New deterministic unit test (safepoint.zig, "registerThread during an active
  STW collect parks the newborn until resumeWorld"): red pre-fix (the newborn
  observably runs between stopWorld-return and resumeWorld), green post-fix.
- The seq_cst half is not deterministically testable; the statistical guard is
  the e2e repro: pre-fix `agent_alloc 'drain'` crashed 3/221 and 4/600 (two
  campaigns) on a 4-vCPU-pinned x86_64 host; post-fix the same harness must run
  clean (recorded in D-548 on landing).
- The existing `phase16_gc_torture` agent block remains the standing e2e guard
  (it is what caught this on CI).

## Alternatives considered (DA fork output, condensed faithfully)

The fork's leading finding: **no alternative avoids the core mechanism** — every
shape ends up needing the newborn to check `gc_requested` at its first
GC-visible act; the alternatives only vary the fence spelling and walk
protection. No F-NNN conflict exists in any shape.

1. **Smallest-diff — collector-held `registry_mutex` + rendezvous
   re-validation**: collector re-reads the count under `registry_mutex` after
   the rendezvous, re-waits if it grew, and holds the mutex across walk+sweep;
   registration simply blocks. Better: one synchronization vocabulary (no
   seq_cst reasoning), the old quiescence comments become true again. Breaks:
   the re-validation loop bounces between `sp_mutex` and `registry_mutex`
   (choreography arguably worse), creates a latent hold-order hazard against
   `noteWorkerLeft`, and does nothing for the `TooManyThreads` hole. The naive
   no-re-validation variant deadlocks (a tiny-action worker blocks in
   `unregisterThread` on the held lock) — rejected.
2. **Finished-form-clean (ADOPTED)**: the mechanism above + fallthrough
   closure + shared ctx builder + documented invariants. The fork also
   recommended a safe-build assert in `gc_heap.alloc` ("allocating thread is
   main or registered") — deferred to **D-566**: the survey found in-tree unit
   tests (e.g. lazy_seq's force-race workers) that alloc from unregistered
   test threads, so the assert needs a test-audit sweep first; nrepl/http are
   serial on the calling thread, so production is assert-clean today.
3. **Wildcard — spawner-side accounting**: (a) a pending-registration counter
   `stopWorld` waits on self-deadlocks when the collector IS the spawner
   inside the window (exactly the reproduced topology: the injected collect
   fires between counter-increment and `Thread.spawn`); (b) register-before-
   spawn is structurally impossible (the ctx holds pointers to the newborn's
   threadlocals) and its placeholder-adopt repair re-derives the registration
   park plus extra machinery. Both rejected; the salvageable boilerplate-
   collapse instinct became the shared ctx builder.

## Consequences

- STW pause acquires no new waits: the collector never waits for unborn
  threads (they cannot touch the heap); it only refuses to let them START
  mid-collect.
- `registeredCountRelaxed` renamed `registeredCountLockFree` (it is seq_cst
  now; the old name lied).
- D-548 exposure (a) — the future/promise SIGABRT residual — was a plausible
  beneficiary, but the post-fix protocol run (4 rounds of 8× parallel
  `phase14_future_promise_delay` on 8-core linux) still reproduced 6/32 at
  the pre-fix baseline rate: **(a) is a distinct race and stays open**,
  signature unchanged (recorded in the row).
- Deferred hardening: **D-566** (alloc-side unregistered-mutator assert after
  a test-audit sweep). The dormant worker-initiated-collect gap (main thread
  unregistered — root_set.zig `is_registered_worker` doc) is pre-existing and
  out of scope here.

## Affected files

- `src/runtime/gc/root_set.zig` — registration safepoint + contract docs +
  `workerContext` + atomic slots + walk-safety comment rewrite + rename.
- `src/runtime/concurrency/safepoint.zig` — seq_cst arm + doc + the new
  deterministic unit test.
- `src/runtime/future.zig` — fallthrough closure + `errorValue` nil-guard +
  ctx builder adoption.
- `src/runtime/thread.zig` — fallthrough closure + ctx builder adoption.
- `src/runtime/agent.zig` — ctx builder adoption.
- `.dev/gc_rooting.md` — E3/E4 rows note the registration safepoint.
- `.dev/debt.yaml` — D-548 recurrence note; new D-566.
