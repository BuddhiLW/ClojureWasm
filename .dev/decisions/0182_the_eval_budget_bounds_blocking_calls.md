# ADR-0182 — the eval budget's wall clock must bound blocking calls, not just back-edges

- Status: Proposed → Accepted
- Date: 2026-08-04
- Related: ADR-0125 (in-process eval budget), ADR-0153 / D-442 (future-cancel
  slicing), D-571

## Context

`cljw.eval/with-budget` advertises three axes: steps, wall-clock deadline, heap.
The deadline did not bound wall clock. It bounded *back-edges that happen to
cross a deadline check*.

`EvalBudget.tick` runs at the back-edge safe points of both backends. A blocking
primitive makes no back-edges, so it consumes time without consuming steps, and
the deadline never fires. Measured:

```clojure
(cljw.eval/with-budget {:deadline-ms 2000 :max-steps 50000000}
  (fn [] (Thread/sleep 20000) :finished))
;; before: returned :finished after 20.0 s
```

That is not a slow check — it is no check. The value came back *normally*, so a
caller cannot even tell the budget was exceeded.

**Found on the ClojureWasm playground**, which is a public demo evaluating
untrusted submissions in-process and relies on this budget for isolation. Two
measurements, on a locally-run instance with `PG_EVAL_DEADLINE_MS=3000`:

- `POST /api/eval` with `(Thread/sleep 25000)` returned `:done` after
  **25,004 ms** — the advertised 3,000 ms bound did nothing.
- `GET /api/health` issued while that eval was parked took **22.0 s**
  (baseline 0.01 s), because `cljw.http.server` accepts serially (D-117(a)).

Together those are a denial of service reachable by one unauthenticated request,
with the sleep argument — and therefore the outage length — chosen by the
caller. The budget is the only thing standing between that endpoint and the
process, and on this axis it was not standing.

## Decision

**Every blocking primitive waits on a LATCH, bounded by an instant.**

Every blocking call cljw has is the same sentence: *wait until a fact becomes
true, no later than some instant*. A future is realised; a promise is delivered;
a thread is done; a cancel is requested. Each of those facts is **monotonic** —
false, then true once, never false again. That is a latch, and `std.Io.Event` is
a latch. These were all built on `std.Io.Condition`, which is the wrong shape for
a monotonic fact and, more to the point, has no timed wait.

`runtime/concurrency/latch.zig` is the primitive:

```zig
pub fn wait(self: *Latch, deadline_ns: ?i64) bool
```

built on `std.Io.Event.waitTimeout`, with the bound carried as an **absolute
instant** rather than a duration — `waitTimeout` also returns `error.Timeout` on
a spurious wakeup, so a duration would silently restart on every one.

`FutureCell` and `PromiseCell` keep their mutex — it guards the *payload* — and
gain a latch for the *edge*. Publish under the mutex, then signal; `Event.set`
releases prior writes, so a waiter that observes the latch observes the payload.
`deref` then waits outside the mutex and takes it only to read.

`EvalBudget` contributes the other instant. `deadlineOf(rt)` is the budget's
deadline; every blocking call passes `min(its own bound, that)` to `Latch.wait`
and calls `checkDeadlineNow` after, which converts "I waited out the deadline"
into the budget error. `Thread/sleep` is the degenerate case — a latch nobody
sets — and its cancel latch is the future's own `settled`, because cancellation
is one of the terminal states a deref'er waits for anyway.

### Why not the smaller shape (and why the first draft of this ADR was wrong)

The first version of this change added `budgetedSleep`, a helper that sliced a
sleep against the deadline, and deferred the rest of the family to D-571 on the
grounds that:

> `future`/`promise` deref and `Thread.join` block on
> `std.Io.Condition.waitUncancelable`, and Zig 0.16 has no timed condition wait
> — which is why `future.waitRealised` already polls `isRealised` in 1 ms sleeps
> rather than waiting with a timeout. A sleep helper cannot bound a condvar wait;
> they need a *bounded wait* primitive of their own.

**That premise is false.** A devil's-advocate fork checked it against the pinned
toolchain: `std.Io.Event.waitTimeout` (`Io.zig` L1827) is a timed wait, and
`Io.Timeout` (L1132) carries an absolute `.deadline` — the very concept this ADR
describes and the first version implemented by hand as a loop. Verified by
execution: a `.deadline` bound returns `error.Timeout` at 201 ms for a 200 ms
deadline, and a 30 s bound wakes at 105 ms when another thread sets the latch.
The 1 ms poll was a cljw choice, not a platform constraint, and the ADR had
rationalised it into one.

So the deferral was not a scoping decision, it was a mistake resting on an
unchecked claim — in a cycle whose entire justification was that the previous
behaviour had never been checked.

## Consequences

Measured on the built ReleaseSafe binary.

- **`@(promise)` under a deadline no longer hangs.** It returns
  `#:cljw.eval{:exhausted :deadline}`. The first draft's Consequences section
  listed this, `(await agent)` and `(read-line)` as *not fixed* and pointed at
  D-571; the whole family now goes through the bounded wait.

- **A live clj-parity break is closed, and it was never about budgets.** With no
  budget armed at all, `@(future (Thread/sleep 2000))` measured **2321-2358 ms**
  — 17% long, on the most idiomatic metered-blocking expression in Clojure —
  because `future-cancel` had to notice a cancel promptly and the only way to do
  that with a condition variable was to wake every 20 ms and look. Each wakeup
  overshoots by a few ms.

  |                                 | before       | after            |
  |---------------------------------|--------------|------------------|
  | `@(future (Thread/sleep 2000))` | 2321-2358 ms | **2000-2001 ms** |
  | `(Thread/sleep 2000)` on main   | 2002-2005 ms | 2004-2005 ms     |
  | `future-cancel` latency         | ≤ 20 ms     | **0 ms**         |

  A latch is woken *by* the cancel, so there is nothing to look for. This is the
  argument for the larger diff: the smaller shape left this untouched while
  stating the principle that condemns it.

- **`(Thread/sleep 25000)` under a 3000 ms deadline returns the exhausted
  marker**, which is the bug this cycle started from. It is the UNCATCHABLE
  budget error, so evaluated code cannot swallow its own timeout — verified that
  `(try (Thread/sleep 3000) (catch Throwable t :SWALLOWED))` under a 500 ms
  deadline still yields the marker.

- **`@(future (Thread/sleep 20000))` under a deadline returns the marker rather
  than escaping.** Under the first version it exited 1 with an uncaught
  `Exception: evaluation exceeded its time budget` unless the user happened to
  wrap it in a `try`, so the playground would have rendered a crash rather than
  "execution exceeded its deadline budget".

- **`(Thread/sleep 100000000000000)` no longer aborts the process.** A legal
  `long` that JVM Clojure simply sleeps on used to panic on integer overflow
  (`ms * ns_per_ms` overflowing `u64`); the conversion saturates and the value
  is clamped again before the instant arithmetic.

- Semantics are unchanged where they should be: timed deref
  (`[:timed-out 42 :p-to]`), cross-thread delivery (`[:hi true]`), cancel
  (`[true true :cancelled-on-deref]`), a failed future re-raising the worker's
  real error (`"boom"`), and `(await agent)`.

- **What is still NOT closed**, named so this ADR cannot be read as closing it:
  a `Thread.` started INSIDE a `with-budget` extent outlives it unmetered, and
  cljw's join-at-exit barrier keeps the process alive with it. More broadly,
  `rt.eval_budget` is one non-atomic slot shared by every thread — a worker's
  back-edges charge the *main* thread's step counter — so the budget needs a
  thread-ownership story now that more threads read it. D-571.

- The playground's *serial accept* half is untouched: a legitimately long eval
  still blocks the next request for up to the deadline (D-117(a)). An in-process
  budget is a resource governor, not an isolation boundary — it cannot bound what
  the metered thread spawned or an abort. The demo-layer answer is a subprocess
  under an OS timeout; D-572.

## Alternatives considered

*(Devil's-advocate fork, fresh context. Its verification of this ADR's two
load-bearing claims is what caused the rewrite above; its Alternative B is what
landed. Reproduced with the measurement tables condensed — the numbers it
produced are in Consequences.)*

**No alternative required violating any F-NNN.** F-005 / F-006 / F-009 are not
engaged. F-002 and the clj-parity floor both point away from the first version
and toward Alternative B. Diff size was the only thing separating them, and diff
size is not a project constraint.

**Verification of claim 1 — "metered sleeps keep their duration."** The claim
holds; the numbers in the draft did not. Ten runs each, sorted, idle machine:
unmetered 2000/2001.5/2005, steps-only 2000/2004.5/2005, deadline-armed
2000/2004/2006 (min/median/max). Indistinguishable — which is the honest form of
the point. The draft's single-shot table reported the *metered* rows as faster
than the unmetered one, a physically impossible ordering and a tell that the
numbers were not repeated. The claim was also incomplete: `budgetedSleep` clamped
to 20 ms whenever a cancellable worker was present regardless of any budget, so
`@(future (Thread/sleep 2000))` ran +17% — the exact parity break the ADR names
as unacceptable, live, on the most idiomatic shape. Pre-existing (D-442 /
ADR-0153), but the ADR named two *other* pre-existing holes so it "cannot be read
as closing them" and was silent on this one.

**Verification of claim 2 — "Zig 0.16 has no timed condition wait."** True of
`std.Io.Condition` specifically; the conclusion drawn from it is wrong.
`std.Io.Event` (L1766) exposes `waitTimeout` (L1827); `Io.Timeout` (L1132) is
`union(enum){none, duration, deadline: Clock.Timestamp}`; `Io.futexWaitTimeout`
(L1558) is the general mechanism, and `Condition.waitInner` is thirty lines over
`io.futexWait`. Verified by execution under the pinned toolchain: `.duration`
150 ms → `error.Timeout` at 151 ms; `.deadline` t0+200 → `error.Timeout` at
201 ms; a 30 s bound with `set()` from another thread at 100 ms → returned at
105 ms, no polling. `waitRealised`'s 1 ms poll *is* the existing shape, but it is
a cljw choice, not a platform constraint, and it was the load-bearing premise for
deferring the whole family.

**Alternative A — smallest-diff: no helper; compute the cut once, inside
`Thread/sleep`.** Cap the requested duration to `deadline − now`, sleep once.
~8 lines, no loop, no callback parameter; ADR-0153's cancel loop stays where it
is. *Better*: it cannot regress sleep duration anywhere, and the landed loop's
degenerate edges disappear — with a deadline armed and a cancel poll present,
`wait` can be computed as 0 when `now == deadline_ns` exactly and the loop spins
until the clock advances; and `remaining` was decremented by the *requested*
slice rather than the elapsed one, an accounting drift that exists only because
there is a loop. *Breaks*: it is exactly the shape the draft's own "why the
helper" section argues against, and that argument is correct — `Thread/sleep`
ends up with two hand-composed bounding mechanisms three lines apart, which is
the precise configuration that let this bug survive. It fixes one primitive and
leaves the family, and leaves the 17% overshoot and the 20 ms cancel latency
untouched. **Do not take this one.** Listed because the brief asks for it, and
because its diagnosis of the loop's edges is worth folding in.

**Alternative B — finished-form-clean: one bounded wait over
`std.Io.Event.waitTimeout`, and the whole family expressed through it.** Every
blocking primitive is the same sentence — wait for a latch, no later than
`min(caller timeout, budget deadline)`, waking immediately on cancel — and
`Thread/sleep` is its degenerate case. *Better*: it fixes the family the draft
names and defers, so D-571 shrinks from "design a bounded wait" to "convert the
remaining call sites"; **all polling disappears**, so `future-cancel` latency
goes from ≤20 ms to ~0 and the future-wrapped sleep goes back to ~2005 ms, i.e.
it *actually* delivers the parity property the ADR claims on the path where cljw
did not have it; one wait lands on the deadline instead of a loop of sleeps, so
"the deadline is not polled for" becomes structurally true rather than
true-by-arithmetic; the callback parameter disappears, since with a wakeable
cancel latch there is nothing to poll. *Breaks*: substantially larger diff —
future, promise, thread, plus the budget. `Io.Event` carries no payload, so the
mutex stays for the value handoff and the two must be kept consistent (set the
Event *after* publishing under the mutex, which `Event.set`'s release ordering
supports). `waitTimeout` returns `error.Timeout` on spurious wakeups, so callers
re-check against the same absolute deadline. `Io.Event.reset` asserts no pending
waiter, so any reusable latch needs care. **This is the recommendation, per
F-002.** The diff is larger by a wide margin; that is not a reason to prefer A.
The draft's whole justification is that "the next blocking primitive added would
re-open the hole silently" — and it closed that by adding a helper only one
primitive can use, whose doc comment tells the next author that the family needs
something else that does not exist. It does exist.

**Alternative C — wildcard: stop making the budget the callee's business.**
Zig 0.16 has first-class cooperative cancellation (`Io.Cancelable`, `io.async` /
`Io.Future.cancel`, `io.checkCancel`), and every blocking `std.Io` call that is a
cancellation point already unwinds with `error.Canceled`. Run the metered thunk
under `io.async`, cancel it at the deadline, map `error.Canceled` to the budget
raise at exactly one boundary. *Better*: the only shape where "the next blocking
primitive re-opens the hole" is structurally impossible, because nothing opts in;
it makes the budget a property of the evaluation *context*, which also dissolves
the shared-slot race by construction. *Breaks*: cljw calls `waitUncancelable`
everywhere and hands out a process-global `std.Io`; C means moving the tree onto
cancelable variants and threading real `io` through. Cancellation is cooperative,
so a compute loop still needs `tick` — C sits beside ADR-0125, not in place of
it. Most seriously it interacts with F-006: an unwind can now originate inside a
blocking wait on a worker, and every published GC root and pin on that path
(`.dev/gc_rooting.md`) has to survive it. *Disposition*: record C as the
direction, not this cycle's shape. B is a strict subset of the work C needs, so
none of B is wasted if C later lands.

## Revision history

- 2026-08-04: Proposed.
- 2026-08-05: Proposed → Accepted, as Alternative B rather than the drafted
  helper. The devil's-advocate fork falsified the draft's load-bearing premise
  (`std.Io.Event.waitTimeout` exists and was verified by execution), so the
  deferral of the blocking family to D-571 was a mistake, not a scope decision.
  Decision and Consequences rewritten against the landed diff and re-measured.
- 2026-08-05 (b): the "still NOT closed" Consequences bullet is now closed —
  D-571 discharged. The budget is a refcounted per-evaluation object
  (threadlocal `current`, spawner-captured references for `Thread.` / `future`
  / each agent action), the step counter is a shared atomic total, and a worker
  that outlives the extent trips on the same budget. This also lands the
  precondition Alternative C names (a budget object owned by the evaluation,
  not the Runtime).
