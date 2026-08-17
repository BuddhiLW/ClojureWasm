# 0190 — SubVector: O(1) subvec via a repurposed .subvec heap tag

- **Status**: Proposed (design + Devil's-advocate complete; implementation D-044 pending — deferred 2026-08-17 under a build-environment memory constraint; flips to Accepted when the impl lands)
- **Date**: 2026-08-17
- **Author**: BuddhiLW (autonomous loop)
- **Tags**: collections, nan-box, heap-tag, subvec, F-004, OCP, gc

## Context

`clojure.core/subvec` builds a fresh dense vector via
`(into [] (take (- end start) (drop start v)))` — O(n), measured **7480x**
slower than clj (9215 ms / 2000 ops at n=16000 vs clj 1.06 ms; D-044). JVM
Clojure returns an `APersistentVector$SubVector` sharing the parent's root+tail.
The Zig `vector.zig::subvec` (eager copy) is reached ONLY by
`clojure.core/subvec` today; the LinkedBlockingQueue's use of it is a separate
concern (see Decision). The NaN-box tag space (F-004, ADR-0027) is a 64-slot
census with 9 producerless `unallocated` names; `heap_tag.zig`'s own doc marks
spending one a user-owned F-004-adjacent decision.

Pedro approved option (a) — a new heap_tag slot — on 2026-08-17 (memory
`20260817105025-46230807`).

## Decision

Repurpose the producerless `.box` slot (D11, 59) → `.subvec`. New representation
`SubVector { parent: *Vector, start: u32, len: u32, meta }` in
`runtime/collection/subvec.zig`, sharing the parent's root+tail and answering
the vector protocol by offset-delegating into the parent. Direct structural
mirror of **O-058** (`.array_seq`, commit 4a295706): a new representation
satisfying an existing protocol, dispatched by **additive** `.subvec` arms next
to `.vector`, changing no existing consumer's contract.

`clojure.core/subvec` keeps its bounds-check + IndexOutOfBounds throw, then
calls a new `cljw.internal/__subvec` primitive. The former eager-copy
`vector.subvec` is renamed `vector.copyRange` and RETAINED for
LinkedBlockingQueue compaction (a view would leak dropped elements).
`seq(subvec)` reuses `.array_seq` (array_seq already views any backing via
`backingCount`/`elementAt`/`viewable` — a `.subvec` arm on those three
suffices). SubVector is IObj / Indexed / Associative / IPersistentStack /
Reversible / Counted / Comparable / IHashEq / IFn / Sequential but NOT
IEditableCollection / IKVReduce / IReduceInit / ISeq (clj class-hierarchy
parity → `transient`/`reduce-kv` on a subvec throw). GC: `traceSubVector` marks
`parent`+`meta`; `conj`/`assoc` (a two-alloc window) run in a fabrication
no-collect region.

### Three non-obvious correctness requirements (DA-surfaced; LSP checklist)

1. **`nth` is offset + INDEPENDENT bounds, not bare delegation.** `nth(sv, i)`
   bounds-checks against the SubVector's own `len` BEFORE delegating —
   `(nth (subvec v 0 3) 5)` is nil even though `parent[start+5]` is live
   (existing `vector.zig:851` pattern).
2. **Empty-subvec returns a real empty Vector, NOT a count-0 SubVector.**
   `(subvec v k k)` → `vector.empty()`. The O-058 "never-empty → nil at
   construction" invariant does NOT carry over.
3. **Nested-subvec collapses onto the ORIGINAL parent.**
   `(subvec (subvec v a b) c d)` folds offsets onto `v`; `parent` is always
   typed `*Vector`, never `*SubVector` (matches clj; keeps the trace one hop).

The "~18-file fan-out" is a **FLOOR**: the IPersistentVector surface is wider
than ArraySeq's ISeq. The landing must enumerate the exact runtime protocol
subset (rubric `20260817105712`). A SubVector never arises from a reader `[…]`
literal — only at runtime from `(subvec …)` — so reader/analyzer/serialize
literal-paths are out of the surface.

## Consequences

`subvec` O(n)→O(1) (view); `pop`/`peek`/`nth`/`count`/`seq` O(1); `conj`/`assoc`
O(log32 n) via a parent assoc (clj parity). Unallocated slots 9→8. A SubVector
pins its whole parent alive (clj-identical liveness). `(class (subvec …))` →
`"APersistentVector$SubVector"` (a new AD-067, ADR-0059/AD-003 simple-class-name
family). Enables the chunked vector-seq follow-up (memory
`20260814102851-4cd92d07`). Review surface = the additive arm fan-out (isolated,
OCP); GC parent-rooting is the single high-risk seam, closed by the registered
trace + fabrication brackets + a `CLJW_GC_TORTURE` e2e.

## Affected files

`runtime/value/heap_tag.zig`, `runtime/value/value.zig`,
`runtime/collection/subvec.zig` (new), `runtime/collection/vector.zig`,
`runtime/collection/array_seq.zig`, `runtime/runtime.zig`, `main.zig`,
`runtime/java/util/concurrent/LinkedBlockingQueue.zig`,
`runtime/interface_membership.zig`, `runtime/equal.zig`, `runtime/print.zig`,
`runtime/compare.zig`, `runtime/class_name.zig`, `runtime/meta.zig`,
`runtime/metadata.zig`, `runtime/collection/lookup.zig`,
`eval/backend/tree_walk.zig`, `eval/backend/clojure_lang_method.zig`,
`lang/primitive/collection.zig`, `lang/primitive/sequence.zig`,
`lang/primitive/core.zig`, `lang/clj/clojure/core.clj`; docs `.dev/debt.yaml`
(D-044 discharge), `.dev/gc_rooting.md`, `.dev/accepted_divergences.yaml`
(AD-067), `.dev/bench/README.md`; tests `test/e2e/phase14_subvec.sh`,
`test/diff/clj_corpus/subvec_substring_bounds.txt`.

## Alternatives considered

Verbatim from the mandatory Devil's-advocate fork (fresh context, F-004-briefed,
2026-08-17):

**Leading finding — no option violates F-004.** All three shapes stay within the
64-slot budget. (a) spends one of the 9 producerless `unallocated` slots
(`box`=59/D11, boxable, zero production references — confirmed by
`assertCensusCloses`). (b) spends zero slots (reuses `Vector._pad[6]`). The
wildcard still builds the `.subvec` repr for the views it creates, so it spends
the same one slot as (a). No F-004 block; the choice is a cleanliness/correctness
call, where F-002 governs. The design space for a first-class O(1) vector *view*
inside F-004 is essentially binary: **mint a distinct tag (a)** or **overload the
existing `.vector` representation (b)**; any wildcard is a scheduling/threshold
wrapper on top of (a), not a fourth representation.

**Alt 1 — (a) CHOSEN: new `.subvec` slot (finished-form-clean).** Better than
(b): additive/OCP, fails LOUD not silent (a `.subvec` value never satisfies
`decodePtr(*const Vector)`, so a missed site trips an assert/new-arm, never a
silent-wrong read); zero existing consumers change semantics (pure-Vector fast
paths untouched — LSP); GC seam is the pre-trodden ArraySeq template (single
`gc.alloc`, caller-rooted parent → no bracket for `make`; `isGcManaged` via the
default else-arm; one §F trace row). Costs: spends 1 of 9 slots (justified — a
vector view is genuinely a distinct first-class type: `vector?`=true, must answer
nth/assoc/pop/peek/invoke/rseq, an ISeq cannot stand in); the LSP surface is
WIDER than O-058's and "~18 files" is a floor; the three correctness pitfalls
above (independent `nth` bounds, empty→real-empty-Vector, nested-collapse-onto-
original) must be got right.

**Alt 2 — (b) smallest-diff: `start:u32` in `Vector._pad[6]` (REJECTED).**
Better: zero slots, less struct churn. Worse (decisive): it changes the MEANING
of the incumbent `.vector` representation — every site that reads
`root`/`tail`/`count` directly becomes obligated to honour `start`, and any that
forgets passes every type check and returns wrong data SILENTLY (the F-011 class
F-004/F-002 most want to avoid; (a)'s missed site is a build error, (b)'s is a
corrupt read that ships). The review surface is the entire vector subsystem,
unbounded and permanent (anti-OCP), plus a serialize/`_pad`-zeroing hazard.
Trading one slot for a diffuse silent-failure mutation of the most-depended-on
collection is the more expensive price under F-002. Reject.

**Alt 3 — WILDCARD: small-slice-copies + large-slice-views threshold (REJECTED).**
Better: shrinks the hot LSP surface in practice (common tiny slices stay pure
`.vector`); bounds worst-case parent-liveness retention. Worse: does NOT avoid
the slot or the repr (large slices still build SubVector → (a)+a branch, strictly
more code); introduces an OBSERVABLE behaviour cliff clj lacks (class/instance?/
identity/liveness/perf flip at a magic N → a fresh F-011 divergence to accept or
chase); the materialize-on-mutation sub-variant re-introduces an O(n) first-
mutation cost cliff; a tuning threshold baked into a *representation* is the
"works-for-the-benchmark" knob F-002 rejects. Reject.

**Recommendation (non-binding; (a) stands within F-004).** Proceed with (a) —
the finished-form-clean pole of a binary design space; it converts (b)'s
silent-corruption into loud build/test failures (OCP+LSP) and rides the O-058
GC/trace template. The one binding landing condition: an explicit enumeration of
the IPersistentVector protocol surface (treat "~18 files" as a floor), with
particular care on the three DA-surfaced points (independent `nth` bounds;
empty-subvec → real empty Vector; nested collapse onto the original `*Vector`).

## Revision history

- 2026-08-17: Proposed. Design + DA complete; source implementation (D-044) is
  drafted (`private`/scratch landing plan) but DEFERRED — the ~18-file fan-out
  needs a dual-backend smoke, and the shared machine was under a severe memory
  constraint (concurrent-session JVM + zig builds, swap exhausted). Flips to
  Accepted in the commit that lands the implementation.
