# ADR-0143 — LazySeq.force thread-safety (inline atomic CAS-claim)

- **Status**: Accepted (2026-06-15)
- **Context tier**: structural (concurrency primitive; gap area I)
- **Supersedes / amends**: discharges debt **D-046** (the "Phase 15 entry —
  STM activation contention bench" barrier is MET — STM/threads are live at
  HEAD). Amends `lazy_seq.zig`'s `## Mutex shape` module doc in place. Extends
  the race-hardening ADR-0142 credits to Phase 15 concurrency with the
  remaining unsynchronized once-only-memo path.

## Context

`lazy_seq.zig`'s `force()` realizes a LazySeq's thunk (a 0-arity `Fn`) on
first access, caches it in `realized: Value`, and sets `realized_flag: u8 = 1`
so later calls short-circuit. It shipped with **no synchronization** under a
single-thread invariant. That invariant no longer holds: `future.zig` and
`agent.zig` spawn real `std.Thread` OS threads. Two threads can now race in
`force()`:

- both observe `realized_flag == 0` and both invoke the thunk — JVM Clojure
  guarantees **at-most-once** (observable for a side-effecting
  `(lazy-seq (do (effect) …))` body);
- the `realized` / `realized_flag` writes can tear or be observed out of order
  (no fence), so a reader can see `flag == 1` with a stale `realized`.

`seq`/`first`/`rest` all loop through `force`, so **every** lazy-seq element
walk crosses this path — and LazySeq is the highest-cardinality heap object in
the language (one per `map`/`filter`/`range`/`iterate`/`cons`-over-lazy step).
This is exactly the workload (a `future`/`pmap` over a shared lazy-seq) that
gap area I (concurrency-hardening) exists to harden, so "document the footgun"
is no longer acceptable (F-015).

## Decision

Make `force()` thread-safe with an **inline lock-free double-checked atomic
flag + CAS-claim**, matching the established cljw lock-free concurrency idiom
(atom/volatile/ref-doGet/safepoint, D-246) — NOT the off-heap `Io.Mutex` cell
that delay/promise/future use.

The existing `realized_flag: u8` becomes a 3-state atomic word (accessed via
the `@atomicLoad`/`@cmpxchgStrong`/`@atomicStore` builtins on the plain field,
the atom.zig idiom — **no `std.atomic.Value` wrapper, no new field, no struct
growth, no off-heap allocation, no GC finaliser**):

- `PENDING = 0`, `REALISED = 1` (unchanged — `isRealised`/`(realized? ls)` and
  the pre-cache test semantics are preserved), `CLAIMING = 2`.
- **Fast-path read** (lock-free, the steady state): `if
  (@atomicLoad(u8, &ls.realized_flag, .acquire) == REALISED) return
  ls.realized;`. A realised-seq walk pays one acquire-load — clj's actual
  shape (clj nulls a `volatile Lock` so steady-state reads are lock-free).
- **Claim**: `@cmpxchgStrong(u8, &ls.realized_flag, PENDING, CLAIMING,
  .acq_rel, .acquire)`. The single winner runs the thunk, writes `realized`,
  then publishes `@atomicStore(u8, &ls.realized_flag, REALISED, .release)`.
  The release/acquire pair on the flag fences the plain `realized` write
  (clj's volatile-lock trick). At-most-once is preserved (exactly one CAS
  winner).
- **Loser**: spins `while (@atomicLoad(u8, &ls.realized_flag, .acquire) !=
  REALISED)`, and on each iteration honors the ADR-0092 §2 safepoint protocol
  (`if (safepoint.gc_requested.load(.monotonic)) safepoint.park();` then
  `std.atomic.spinLoopHint()`) — the thunk eval is exclusion-bearing, so a
  non-parking busy-spin would delay/deadlock a stop-the-world collector. This
  is the one piece of delay's `lockMutexAtSafepoint` discipline (D-244 #4)
  that carries over even in the lock-free shape.

The winner runs the thunk via the normal eval path (`vt.callFn`), which polls
safepoints at its own alloc/back-edges, so the winner is STW-cooperative
during the thunk; only the loser's spin needs the explicit poll added.

### Why not block the loser (the crux)

JVM clj blocks the loser on a `ReentrantLock` (the loser yields its core). A
blocking wait in Zig 0.16 requires `std.Io.Mutex`/`Io.Condition` — both are
non-`extern` so they must live in an **off-heap cell** (the delay/promise
shape), which on the language's highest-cardinality object means a per-element
heap allocation + a per-element GC finaliser. `std.Thread.Futex` (which would
allow a blocking wait on the inline flag word with no off-heap cell) **does
not exist in Zig 0.16.0** — all `std.Thread.*` sync primitives are gone
(verified against the pinned stdlib; ROADMAP §13 bans them regardless). So the
only blocking shapes force the off-heap cell. The spin's rare-contention core
cost is the right trade against a steady-state per-element allocation cost on
the hot object (runtime perf of the hottest object IS a finished-form
property; F-002 protects diff size, not runtime perf).

## Amendment 1 — complete realization and coherent copies (2026-09-07)

ADR-0197 extends the claimed window through Seqable coercion. The entry node
caches the normalized terminal sequence; iteratively invoked inner nodes retain
immutable links. Publish the result and clear the thunk before the release-store.
A thunk or coercion error resets PENDING and retains the callable for retry;
AD-067 records the measured JVM state/retry differences this preserves.

The raw body has a one-slot manual EvalFrame across nested invocation and
allocating coercion (`.dev/gc_rooting.md` A8). Metadata/fusion copies now claim
a pending source while copying, or wait for an active realization and acquire
its immutable payload. Copying state before an allocation and fields afterwards
could otherwise pair PENDING with a concurrently cleared thunk. The copy claim
runs no user code and is released on allocation failure too.

## Alternatives considered

> Verbatim output of a fresh-context Devil's-advocate `general-purpose`
> subagent fork (CLAUDE.md § ADR-level designs are handled inline). The
> deciding fact it flagged — `std.Thread.Futex` legality — was then resolved:
> the type does **not exist** in Zig 0.16.0, which removes Alt 3 and confirms
> the b1 ship.

### Preface: F-NNN envelope check on the current b1 draft

The b1 draft is F-NNN-clean: zero struct growth (reuses `realized_flag` + the existing `_pad: [5]u8`), no off-heap cell, no finaliser (F-006 friendly — no sweep-time `destroy`), lock-free steady-state read (F-011-faithful to JVM's volatile-null'd lock), at-most-once via CAS-claim (F-011 side-effect contract), and the safepoint-honoring spin (F-006/ADR-0092 STW-safe). It does NOT route through the header `lock_state` machinery (ADR-0009 respected). I found no F-NNN violation in the draft itself. My job is therefore to pressure the *design choice among legal shapes*, not to find an illegality.

### Alt 1 — Smallest-diff: relaxed at-most-once, lock-free flag only (NO CAS-claim)

**Shape.** Make `realized_flag` a 2-state `atomic.Value(u8)` (0=pending, 1=realised). Fast-path read `if (flag.load(.acquire) == 1) return realized;` exactly as b1. But on the cold path, DROP the CAS-claim entirely: every thread that sees 0 just runs the thunk, then does `realized = result; flag.store(1, .release);`. Last writer wins. No 3-state, no spin, no safepoint coupling on this path (the thunk eval still self-parks via the existing `alloc`/back-edge polls, so STW is unaffected).

(a) **Better than b1:** Dramatically simpler — no spin loop, so the worst-case-core-waste critique (below) literally cannot occur; no `claiming` state to reason about; no safepoint coupling *added* to `force` (the thunk's own alloc-poll already covers STW); reentrant self-force just works (the thread sees 0, runs its own thunk, no self-deadlock — see the reentrancy section). It is the *closest* shape to the actual single-thread code on disk (lines 114/130/131): literally make the flag atomic and add `.acquire`/`.release`.

(b) **Breaks / costs:** Violates clj's **at-most-once** guarantee. Two threads concurrently first-forcing the same LazySeq both run the thunk. For pure thunks (the overwhelming majority) this is invisible and wasteful-but-correct. For a side-effecting `(lazy-seq (do (println "x") (cons 1 ...)))` body — which clj's ReentrantLock guarantees prints once — this prints twice. There's also a `realized` tear window: thread A stores `realized=resultA, flag=1`; thread B (started later) overwrites `realized=resultB` AFTER A's reader already returned resultA — two callers see DIFFERENT seq head objects. They're `=`-equal in value but not identity-equal, which can surprise identity-sensitive code (rare in idiomatic Clojure, but `(identical? (first s) (first s))` across threads could flip).

(c) **F-NNN:** **Violates F-011** (behavioural equivalence — clj's at-most-once is observable for side-effecting bodies). This is a real, named violation, so per the brief it is NOT the recommendation. I record it as a legal-but-inferior shape; it is the honest "smallest diff" but it ships a clj divergence that would need an AD-NNN to be defensible, and there is no project invariant that *mandates* dropping at-most-once — so it would be an *accepted divergence of convenience*, which `accepted_divergences.md` explicitly forbids ("If you cannot name the invariant, it is not accepted — it is a bug").

### Alt 2 — Finished-form-clean: off-heap `Io.Mutex` realise-cell, exactly like `delay.zig`

**Shape.** Add a `cell: *LazySeqCell` field (an off-heap `struct { mutex: std.Io.Mutex }`), allocated in `alloc`, freed in a new `finaliseLazySeq`. `force` becomes a near-verbatim copy of `delay.zig force()`: lock-free `if (flag.load(.acquire) == 1) return realized;` pre-check, then `safepoint.lockMutexAtSafepoint(&ls.cell.mutex)`, re-check under lock, run thunk, store, unlock. The loser BLOCKS on the mutex (parked at a safepoint via `lockMutexAtSafepoint`) and yields its core — no spin.

(a) **Better than b1:** (1) **The loser never burns a core** — it blocks and the OS deschedules it. This is the single biggest advantage and the crux of the whole review (see pressure-test). (2) It is **identical in shape to the existing `delay.zig` precedent** — one realise-memo primitive, one locking pattern, one mental model; a reader who understands `delay.zig` understands this for free. That uniformity is itself a finished-form virtue (the project prizes "one way"). (3) `lockMutexAtSafepoint` is already the audited STW-safe blocking primitive (D-244 #4); b1 re-derives a *second* STW-safe waiting mechanism (safepoint-polling spin) that has to be re-audited against the same hazard. Fewer distinct concurrency mechanisms = smaller correctness surface.

(b) **Breaks / costs:** (1) **Per-LazySeq off-heap allocation + a GC finaliser.** LazySeq is the highest-cardinality heap object in the language (one per map/filter/range/iterate step). Every `(map inc (range 1e6))` would `gpa.create(LazySeqCell)` a million times and register a million finalisers. This is a *severe* allocation/GC-pressure regression versus b1's zero-alloc reuse of `_pad`. The `delay.zig` precedent is safe *because Delays are rare* (one per `(delay …)` form); LazySeqs are not. (2) `Io.Mutex` is non-extern, so it genuinely cannot live inline in the `extern struct` — the off-heap cell is forced, you can't shrink it away. (3) Finaliser cost at sweep time scales with live-LazySeq count.

(c) **F-NNN:** F-NNN-clean (no violation). But the allocation explosion makes it a *finished-form-clean shape that the finished-form owner would unwind on perf grounds* — and crucially, **perf is NOT an F-NNN constraint** (F-002 says cycle/diff/LOC isn't a constraint; it does NOT say runtime perf isn't). Runtime performance of the hottest object in the language IS a finished-form property. So this is the rare case where "finished-form-clean" cuts *against* the heavyweight option: the cleanest *final shape* for a million-cardinality object is the zero-alloc one, not the one that mirrors the rare-object precedent. I rate Alt 2 **inferior to b1 on finished-form grounds**, not superior.

### Alt 3 — Wildcard: futex-style block on the flag word itself (lock-free read, blocking cold wait, zero off-heap)

**Shape.** Keep b1's 3-state atomic `realized_flag` inline (zero struct growth, zero off-heap). Keep b1's lock-free fast read and CAS-claim winner. The ONLY change is what the *loser* does: instead of `while (...) spinLoopHint()`, the loser **blocks on the flag word** via a futex-style wait — `std.Thread.Futex.wait(&flag_as_u32, claiming_value)` (or the Zig 0.16 `Io`-mediated equivalent if `std.Thread.Futex` is among the removed primitives — needs verification against the ROADMAP §13 ban; if futex is banned, this Alt collapses into Alt 2). The winner, after `flag.store(1, .release)`, does `Futex.wake(&flag, all)`. The loser still polls `safepoint.gc_requested` before each (re)wait and routes the block through `enterBlocked`/`exitBlocked` so a STW collector counts it as parked.

(a) **Better than b1:** Combines b1's zero-alloc inline flag with Alt 2's core-yielding block — the loser sleeps instead of spinning, but there is NO per-LazySeq off-heap cell and NO finaliser. It is strictly the hybrid the brief asks for: lock-free read + real blocking wait *only* on the cold realise-contention path, with none of Alt 2's allocation cost.

(b) **Breaks / costs:** (1) **Futex layering against the safepoint protocol is subtle.** A futex wait that is interrupted by a STW signal must wake, park, and re-wait — interleaving futex-wake with safepoint-park correctly is genuinely tricky and is a fresh concurrency mechanism the project has never audited (vs `lockMutexAtSafepoint` which is audited). (2) **`std.Thread.Futex` may be banned** — ROADMAP §13 / the zig_tips table bans all `std.Thread.*` *sync primitives* (`Mutex`/`RwLock`/`Condition`/`Semaphore`/`WaitGroup`). Futex is a borderline case (it's lower-level than those); if the ban is read broadly it's forbidden and this Alt is illegal-by-rule (not by F-NNN, by ROADMAP §13 — a level-3 amendable rule, but still a barrier). (3) Cross-platform futex semantics differ; the project would own that portability surface for its hottest object. (4) Contention on first-realise is genuinely rare, so the machinery may rarely fire — paying audit complexity for a cold path.

(c) **F-NNN:** F-NNN-clean. The risk is ROADMAP §13 (level 3, amendable but real) on the `std.Thread.Futex` question. If §13's ban covers futex, prefer the `Io`-mediated wait, which lands back near Alt 2's off-heap requirement — so the wildcard's whole advantage (zero-alloc + blocking) hinges on futex being legal. **Needs a one-line ROADMAP §13 verification before adoption.**

### Pressure-test of b1's weakest point: the loser busy-spins for the whole thunk-eval

This is b1's real soft spot and the brief is right to flag it. The assumption "lazy-seq thunks are trivial cons-cells, concurrent-first-realise is rare, so a brief spin is fine" is **NOT uniformly safe**:

- **Thunk does I/O / derefs a promise / blocks.** `(lazy-seq (cons (deref some-promise) ...))` or a thunk that reads a file. The winner's thunk eval can take *milliseconds to seconds*. Every losing thread spins a full core for that entire duration. With `pmap` over a shared lazy-seq (the brief's exact example), N-1 cores can spin-burn while one core blocks on I/O. This is a pathological core-waste: the machine is "busy" at 100%×(N-1) doing nothing. JVM clj here BLOCKS the losers on the ReentrantLock — they yield, the OS schedules other work, total throughput is far higher.
- **Thunk triggers GC.** Worse than waste: the winner's thunk allocates, hits `gc_requested`, and the winner parks at the alloc safepoint to let the collector run. The losing spinners, IF correctly safepoint-polling per the draft, also park — fine. But if the safepoint poll in the spin loop is *ever* mis-placed (polled once per outer iteration but the thunk eval is one long call that doesn't return to the spin loop), the losers spin THROUGH the STW window holding no lock but pinning cores, *delaying* the collection the winner is waiting to finish → a throughput cliff, not a deadlock. The draft's correctness here depends entirely on the spin's poll being airtight; Alt 2's `lockMutexAtSafepoint` gets this right by construction (the blocked thread is definitionally parked).
- **Is the "rare" assumption safe?** For sequential single-consumer code, first-realise contention is zero (no second thread). The contention ONLY appears when the SAME LazySeq head is shared across threads and forced concurrently — which is *exactly* what `pmap`, `future` over a shared seq, and `(let [s (map …)] (future (reduce + s)) (reduce * s))` do. These are not exotic; they are the marquee use cases of the concurrency gap-area (I) this ADR serves. So the spin's worst case lands precisely on the workloads gap-area I exists to harden. That is uncomfortable.

**Verdict on the spin:** acceptable for trivial pure thunks under low contention; *bad* for I/O/blocking thunks under `pmap`-style sharing. Since b1 cannot tell the two apart at the spin site, it pays the worst case whenever contention happens to be high. **A hybrid that blocks (Alt 3 if futex is legal; else Alt 2's mutex on the cold path only) strictly dominates the spin on the bad workloads and is no worse on the good ones** (uncontended first-force never reaches the wait at all — the CAS winner just runs). The brief's instinct — "could the loser block on a condition instead of spinning?" — is correct, and the answer is yes, and it's better.

### Reentrant self-force: b1 self-deadlocks; is the divergence acceptable?

A thunk that forces its own LazySeq (`(def s (lazy-seq (cons 1 s)))` forced) is degenerate. clj's ReentrantLock permits re-entry → the body recurses → **StackOverflowError**. b1's non-reentrant CAS-claim: the same thread that won the claim (`flag==2`) re-enters `force`, sees `flag==2` (not 1), and spins forever waiting for *itself* to publish → **hang** (a livelock, since the spin also safepoint-polls, so it's a *parking* hang, not a frozen core — but a hang nonetheless). `delay.zig`'s `Io.Mutex` has the identical self-deadlock (non-reentrant mutex, same thread re-locks → deadlock). So:

- b1 diverges from clj: **hang vs StackOverflowError**. Both are "the program is broken"; neither is a useful result. But clj's StackOverflow is *observable and recoverable* (it's a throwable the user can catch in principle), whereas b1's hang is **not observable** — the program just stops, and under STW it parks silently. That is a *worse* failure mode for debugging.
- **Is it an F-011 problem?** Marginally. The input `(lazy-seq (cons 1 s))` self-referencing-forced is genuinely degenerate user code; clj's own behaviour (StackOverflow) is itself a crash, so "behavioural equivalence" on a crash input is weak. BUT F-011 + `accepted_divergences.md` say a DIFF must be *classified*, not left floating. A silent hang vs a throwable is a real observable DIFF. The clean disposition: **classify it as an accepted divergence (AD-NNN) with `derives_from: <this ADR> + the non-reentrant-realise invariant`, and a pin test** asserting cljw hangs-bounded (or, better, *detect* the self-claim: if the CAS-claiming thread re-enters and sees `flag==2` set by its OWN thread-id, raise a `stack-overflow`-flavoured error instead of spinning). The last option — record the claiming thread-id and raise on self-re-entry — would make cljw STRICTLY BETTER than clj (a clean error vs a StackOverflow) at the cost of one thread-id field. That is worth considering as a b1 amendment regardless of which alt ships; it converts a silent hang into a diagnosable error and is finished-form-clean. Alt 1 (no claim) sidesteps this entirely (self-force just recurses → Zig stack overflow → same as clj, modulo message), which is a minor point in Alt 1's favour.

### Recommendation

**Ship a hybrid: b1's inline zero-alloc 3-state flag + lock-free read + CAS-claim, but replace the loser's busy-spin with a blocking wait — Alt 3 (futex on the flag word) IF ROADMAP §13 permits `std.Thread.Futex`; otherwise the b1 spin is the pragmatic ship with a mandatory self-re-entry guard.**

Reasoning, finished-form-first per F-002 (and noting cycle/diff size is explicitly NOT a downgrade reason):

1. **Alt 2 is out** despite being "precedent-uniform" — the per-LazySeq off-heap cell + finaliser is a real perf regression on the language's highest-cardinality object, and runtime perf of the hot object IS a finished-form property (F-002 does not protect it; it protects *diff size*, the opposite). Do not mirror the rare-`Delay` shape onto a million-cardinality object just for uniformity.
2. **Alt 1 is out** — it's the only option that violates a *named* F-NNN (F-011 at-most-once), and the divergence is one of convenience, not invariant, so `accepted_divergences.md` forbids accepting it.
3. **Between b1-spin and Alt 3-block**, Alt 3 strictly dominates on the `pmap`/I/O-thunk workloads that gap-area I exists to serve, with no off-heap cost. The *only* thing blocking Alt 3 is the §13 futex-legality question. **Resolve that first** (one grep of ROADMAP §13 + the zig_tips ban scope). If futex is legal, ship Alt 3. If §13 bans it, the `Io`-mediated block forces an off-heap cell (= Alt 2's cost), at which point **b1's spin becomes the right ship** — because then the choice is "spin on the cold contended path" vs "off-heap-allocate the hottest object in the language", and the latter's steady-state cost outweighs the former's rare-contention cost.
4. **Regardless of which ships, add the self-re-entry guard**: record the claiming thread-id; on self-re-entry while `flag==2`, raise a stack-overflow-flavoured error rather than hang/spin. This converts b1's silent-hang divergence into a diagnosable error that is *better* than clj's StackOverflow, and lets the reentrancy DIFF be classified as an AD-NNN with a pin test rather than left floating.

Net: the draft's b1 is F-NNN-legal and a defensible ship, but its busy-spin is a measurable footgun on exactly the concurrency workloads this ADR targets, and its silent self-deadlock is an unclassified DIFF. The cleanest final shape is "b1's inline flag, but the loser blocks not spins, and self-re-entry errors instead of hangs." Verify the §13 futex question; that single fact decides spin-vs-futex.

## Resolution of the DA's open questions

1. **`std.Thread.Futex` legality (the deciding fact).** Verified against the
   pinned Zig 0.16.0 stdlib: `std.Thread` exposes **no** `Futex` (and no
   `Mutex`/`Condition`) — every `std.Thread.*` sync primitive is gone (ROADMAP
   §13 bans them anyway). **Alt 3 is therefore not implementable in Zig
   0.16.** Per the DA's own decision tree (point 3), with futex unavailable the
   only blocking shape is the `Io`-mediated wait, which forces Alt 2's off-heap
   cell — so **b1's spin is the right ship**. The spin's rare-contention core
   cost beats a per-element off-heap allocation on the hottest object.
2. **The spin's poll must be airtight.** The DA's GC-throughput-cliff concern
   is real and is addressed: the loser polls `safepoint.gc_requested` + `park`
   on *every* spin iteration (the canonical worker-loop poll from
   `safepoint.zig`), and the winner runs the thunk through the normal eval path
   which self-parks at its own alloc safepoints. No code path spins through an
   STW window.
3. **Reentrant self-force guard — deliberately NOT added.** The DA's thread-id
   guard would make cljw strictly better than clj, but: (a) `delay`/`promise`/
   `future` already carry the **identical** non-reentrant self-deadlock and the
   survey's mandate is to *match that precedent*, not diverge from it on
   LazySeq alone; (b) a thread-id field risks struct growth or a truncated-tid
   false-positive (wrongly raising on a real cross-thread contention with a
   colliding truncated id) on the language's highest-cardinality object. The
   finished-form choice that matches the memo-once family is to **not** special-
   case LazySeq. The self-forcing input (`(lazy-seq (seq s))` forced) is
   degenerate (clj StackOverflows on it). It is recorded as a known limitation
   of the once-only-memo family below, not opened as an AD-NNN with an
   untestable hang-pin.

## Consequences

- `force()` becomes thread-safe: at-most-once thunk invocation + a
  release/acquire-fenced result, with a lock-free steady-state read. The data
  race that real `future`/`agent`/`pmap` sharing exposed is closed.
- **Zero cost on the realised steady state** beyond one acquire-load (was a
  plain load); zero struct growth; zero off-heap allocation; zero finaliser.
- `isRealised` reads the flag with an acquire-load for visibility (was a plain
  read — a benign stale-false race before, now correctly fenced).
- **Known limitation (shared with delay/promise/future):** a thunk that forces
  its *own* LazySeq (degenerate self-reference) hangs (the claiming thread
  spins for a publish that can only come from itself) rather than clj's
  StackOverflowError. Not guarded, for consistency with the memo-once family
  and to avoid per-element cost on the hot object. clj also crashes on this
  input (StackOverflow); the divergence is hang-vs-throwable on degenerate
  code.
- The loser's spin can burn a core while a *slow* thunk realises under high
  contention (the DA's pressure-test). Accepted as the right trade vs a
  per-element off-heap allocation, given Zig 0.16 offers no inline blocking
  wait. If a future Zig brings back a futex (or a measured `pmap`-over-
  slow-lazy-seq workload proves the spin pathological), revisit per Alt 3 —
  recorded as a recall note, not a debt row (no present barrier).

## Affected files

- `src/runtime/lazy_seq.zig` — `force()` rewrite (CAS-claim + safepoint spin),
  `isRealised` acquire-load, `## Mutex shape` module-doc update, the
  concurrent-force unit test.
- `.dev/debt.yaml` — D-046 → discharged.
