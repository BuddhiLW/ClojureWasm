# ADR-0183 — the GC trigger is steered by measured time, not a byte constant

- Status: Proposed → Accepted
- Date: 2026-08-04
- Amends: ADR-0164 (threshold-driven auto-collect; the 4 MB floor it set)
- Related: ADR-0028 (mark-sweep + adaptive threshold), F-006 (non-generational),
  D-573

## Context

cljw collects when `bytes_since_last_gc > max(threshold_floor_bytes,
last_live_bytes * 2)`, with the floor a 4 MB constant.

ADR-0164 chose that constant and, in the same breath, named why it would fail:
*"For a churn workload `last_live ≈ 0` so the adaptive `max(1MB, last_live*2)`
arm is inert → the initial threshold IS the operative number."* It then tuned
the constant against the benchmark suite — short scripts, 1 to 15 collections
each — and gated the decision on "does any of the 7 won benches regress".

Nothing measured a program that runs for minutes. On one, the constant costs a
factor of two.

**Measured** on a Rush Hour BFS (cw-arcade `apps/rush-hour`, a Clojure program
that allocates a persistent map per move and keeps a set of visited states),
identical 3.17 GB / 26.2 M allocations in every row:

| floor          | collections | wall   |
|----------------|-------------|--------|
| 4 MB (default) | 755         | 17.7 s |
| 16 MB          | 65          | 9.6 s  |
| 64 MB          | 47          | 7.6 s  |
| 256 MB         | ~40         | 7.1 s  |

A sampling profile put `collectStopTheWorld` at ~40 % of all samples. The
marginal cost of a collection, measured directly on the real workload by
forcing three different collection counts with `CLJW_GC_TORTURE_ALLOC` and
taking Δwall/Δcollects, is **13.6 ms** — and `last_live_bytes` reports
**747 KB**. So the run was spending ten of its eighteen seconds re-marking the
same graph, 755 times, because a constant said to.

## Decision

**The floor is steered by the measured GC time share.**

`collectStopTheWorld` times itself; `steerFloor` compares
`gc_ns_total / (now − first_collect_ns)` against a target and moves
`threshold_floor_bytes` by doubling or halving, bounded below by whatever the
program started with (default, or `CLJW_GC_THRESHOLD_MB`) and above by 64 MB.

The share is the right control variable on the theory as well as the
measurement: for a mark-sweep collector the GC share is
`mark_cost(live) / bytes_between_collections`, so the trigger *is* the share,
and steering on it is independent of how big the live set happens to be — which
matters here more than usual, for the reason in Consequences.

**This is the shape the established runtimes use**, which a cross-runtime survey
(`private/notes/2026-08-04-gc-heap-sizing-survey.md`) confirmed after the fact:

| runtime         | mechanism                                                                                                                        |
|-----------------|----------------------------------------------------------------------------------------------------------------------------------|
| HotSpot         | `-XX:GCTimeRatio` — goal is `1/(1+ratio)` of time in GC; the adaptive size policy grows the generations when the goal is missed |
| **SubstrateVM** | `GC_TIME_RATIO = 19` → a **5 %** budget, with the young gen *derived* from it                                                   |
| G1              | `-XX:MaxGCPauseMillis` — a time target, young-gen size the derived quantity                                                     |
| V8              | growing factor computed from measured `gc_speed` and `mutator_speed`                                                             |

The SubstrateVM row is the one that matters: **babashka is compiled with GraalVM
`native-image` and therefore runs SubstrateVM's Serial GC with its adaptive
policy** — so the runtime cljw is benchmarked against already sizes its heap
from a measured GC time fraction. Same deployment shape (AOT single binary,
startup-sensitive, no JIT warmup), same answer.

10 % rather than SubstrateVM's 5 %: cljw is non-generational (F-006), so it
re-marks the entire live set every cycle and cannot reach 5 % without holding
more heap. Measured, the two are within noise on the BFS (5 % → 7.55 s /
56 collections, 10 % → 7.54 s / 69), so the laxer target is taken for the
smaller footprint.

### What was tried first, and why it is not what landed

**A byte floor that ramps after N inert collections.** It works — but the survey
found no established collector shaped that way, and its three properties are
each wrong: one-way (never comes back down, so a long-lived REPL or nREPL
server keeps a floor its phase no longer needs), counter-triggered rather than
cost-triggered, and keyed on a quantity that under-reports (below). Go
considered and **rejected** an adaptive minimum heap for this same problem
(golang/go#22743).

An earlier version ramped on the *first* inert collection and cost
`gc_alloc_rate` **20 %** — because collecting is also what refills the free
pool, so a program short enough to finish inside a few collections wants them.
That is ADR-0164's finding, and it is why the target is a *share* rather than a
threshold: a program that collects rarely has a low share and is left alone.

## Consequences

- The BFS goes 17.9 s → 7.5 s (755 → 69 collections). `medium`-difficulty
  puzzle generation, the thing a user actually waits for, goes 57.8 s → 17.5 s.
- **No benchmark moves.** `gc_alloc_rate` 43→43 ms, `gc_large_heap` 39→39,
  `string_ops` 29→29, `gc_stress` 29→28, `map_filter_reduce` 17→16,
  `map_ops` 11→11 (best of 3 each). Their collection counts are 15, 2, 1, 4 —
  far too few to accumulate a share worth steering on.
- Peak RSS on the BFS is unchanged (2.21 → 2.23 GB); it is dominated by the
  free pool, not the trigger. Startup is unchanged at 10 ms.
- Two clock reads per collection. At 69 collections that is not measurable; at
  755 it was not either.
- **The deeper defect is NOT fixed, and this ADR is not a substitute for it.**
  `last_live_bytes` counts only the GC record block — it omits finaliser-owned
  side buffers (String bytes, BigInt limbs) and everything in
  `persistent_marks`, which is traced on every collection but never swept and
  never counted. Measured 78 MB reported against 359 MB RSS, a factor of 4.6.
  So `last_live * 2` is not a proportional-to-cost heap target, and the
  adaptive arm can read as *inert* while the collector is tracing a large
  graph. The BFS is exactly that false negative: 747 KB reported, 13.6 ms to
  collect.

  Steering on measured time works **regardless** — that is its virtue over both
  the byte floor and the ratio arm, and why it could land before the accounting
  is fixed. But with honest accounting the ratio arm may govern on its own and
  this steering may become redundant. Go's answer to precisely this problem
  (1.18) was to *complete the marginal cost model*, not to add a heuristic on
  top of an incomplete one. Tracked as D-573.

## Alternatives considered

The cross-runtime survey in
`private/notes/2026-08-04-gc-heap-sizing-survey.md` is the alternatives
analysis: it enumerates Go's pacer (same `max(min_heap, live × ratio)` shape,
same problem, documented and unfixed), HotSpot's and SubstrateVM's time
ratios, G1's pause target, V8's measured growing factor, OCaml's
`space_overhead`, Ruby's ramping `RUBY_GC_MALLOC_LIMIT`, and Boehm's
`GC_free_space_divisor` — and recommends, in priority order: (1) run the
torture-slope experiment on the real workload before anything lands; (2) fix
the live accounting; (3) replace the ramp with a GC-time-fraction target;
(4) failing that, a larger static floor; (5) fix `conservativeStackScan`.

(1) was run — 13.6 ms, which is what makes the rest apply. (3) is what landed.
(2) and (5) are D-573.

## Revision history

- 2026-08-04: Proposed → Accepted.
- 2026-08-05: the Consequences bullet "the deeper defect is NOT fixed" is now
  half-resolved: `last_live_bytes` counts finaliser-owned side buffers via a
  per-tag `ownedBytes` hook table (D-573 narrowed). The `persistent_marks`
  half turned out to be a GROWING set (every closure allocation adds a
  re-traced waypoint) and is measured but deliberately EXCLUDED from the byte
  arm — folding it in regressed gc_alloc_rate ~11% by starving the free pool.
  The division of labour stands: the byte arm sizes against the swept heap,
  this ADR's time-share arm owns total traced cost (which is why the BFS still
  needs it: its 13.6 ms/collect was waypoint tracing, invisible to any byte
  count of the swept heap). CLJW_GC_STATS=2 prints the per-tag breakdown.
