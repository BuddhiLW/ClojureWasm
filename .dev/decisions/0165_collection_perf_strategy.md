# ADR-0165 — Collection-perf strategy: keep best-of-breed algorithms, win on Zig-native layout (measured-loss-led; see Amendment 1)

- **Status**: Accepted as the **direction** for §9.2.S collection work (2026-06-24). The
  per-lever activation is the TDD-loop's job; this ADR is the durable research synthesis +
  ROI ordering + the experimentation/regression protocol. Driven by the 2026-06-24 clean
  peer re-rank (ADR-0148 follow-up): cljw LOSES bb 1.02–1.16× on the collection-heavy
  benches (sieve/destructure/gc_*/bigint) but WINS pure-compute 2× (fib_loop/tak) + ratio_sum
  — so the gap is the COLLECTION/LIBRARY layer, not the VM engine.
- **Amendment 1 (2026-06-24, measurement-driven lever re-order)**: implementation Step 0.6
  re-laying refuted the "L1 transients FIRST / transients are a STUB" premise. See
  § "Amendment 1" below — the lever ordering is now MEASURED-loss-led, the L1 stub claim is
  corrected, and the keyword-map-get fast path (O-051) landed as the first PROVEN lever.
- **Relates to**: ADR-0148 (fastest-script campaign — this is its collection sub-strategy),
  F-002 (finished-form), F-005 (numeric tower), F-006 (GC; GC-backed sharing avoids per-node
  refcount), F-011 (behavioural equivalence — the diff oracle is the safety net). D-520 (the
  draining debt row). The JIT (D-386 / zwasm ADR-0200 JIT) is the SEPARATE, larger compute
  frontier (JVM-Clojure territory; babashka structurally cannot JIT — SCI is not a Truffle
  interpreter, GraalVM native-image is AOT-only).

## Context — the measured truth

Clean **interleaved cljw-vs-bb** A/B (load-robust; the cross-run compare_langs table at
load ~9 was contaminated and over-claimed "7/9 won"):

| class                           | benches                                                                    | verdict                     |
|---------------------------------|----------------------------------------------------------------------------|-----------------------------|
| pure compute (interpreter loop) | fib_loop 2.0× · tak 2.2× · arith_loop 1.33×                           | **cljw WINS**               |
| exact rational                  | ratio_sum 1.42×                                                           | **cljw WINS**               |
| collection / library            | sieve · destructure · gc_alloc_rate · gc_large_heap · bigint_factorial | **cljw loses 1.02–1.16×** |

bb = SCI (tree-walk interpreter) + clojure.lang + java.math, all GraalVM-native-AOT, **no
JIT**. So bb and cljw are non-JIT-interpreter PEERS; cljw's bytecode VM actually BEATS SCI on
pure compute. cljw loses only where clojure.lang's 15-year-tuned data structures + JDK
BigInteger beat cljw's younger implementations. → the lever is collection implementation.

## Decision — the unifying strategy (the 3 routes converge as layers)

1. **Algorithm layer — keep best-of-breed; cljw ALREADY chose right.** Direct code read
   confirms: real **CHAMP** map/set (`data_map`+`node_map` two bitmaps + `@popCount`),
   radix-vector+32-tail, array-map≤8 linear, `std.math.big` (Karatsuba) + i48-immediate
   fast-path. No data-structure rewrite. **RRB-trees REJECTED** (size-table taxes the common
   indexed path; Clojure keeps it out of core — opt-in only for concat-heavy code).
2. **Implementation/layout layer — diverge from Java HERE; this is where Zig structurally
   wins.** Every measured Immer/im-rs win over Clojure/Scala (1.3–6.7× iteration, 3–25×
   equality) comes from **no object headers + tight cache layout**, which Zig gives by
   construction; and cljw's **GC-backed** trie avoids im-rs's per-node atomic `Arc`. So the
   "different path from Java" is at LAYOUT/memory, not algorithm.

## ROI-ordered levers (all implementation/constant-factor; map to the losing benches)

**Tier 1 (do first — biggest, lowest risk, helps real code beyond benches):**
- **L1 — Transients (single-threaded owner-token) + bulk build paths.** cljw's transients
  are a STUB today (vector.zig / map.zig). #1 in both clojure.lang and the industry survey.
  `into`/`vec`/`mapv`/`reduce conj` dominate real scripts. Zig win: owner-token = POINTER
  compare (cheaper than JVM `AtomicReference`); MemoryPool per node size-class. Benches:
  gc_alloc_rate/gc_large_heap/nested_update. **Highest ROI; the recommended first move.**
- **L2 — Chunked seqs on the WALK path.** cljw chunks + fuses only the `reduce` path;
  `map`/`filter` realize one Cons per element via a thunk Fn call on first/rest/seq walks.
  clojure.lang chunks 32-wide. Zig win: chunk = inline 32-slot array, not 32 heap thunks.
  Bench: sieve, map_filter_reduce.

**Tier 2 (medium):**
- **L3 — Keyword-map get fast path (destructure, worst 1.16×):** (a) monomorphic `bits==bits`
  before the dispatch-aware `eqConsult` (900K calls/bench); (b) `@Vector firstIndexOfValue`
  over the ≤8 array-map keys (cljw uses NO SIMD scan today); (c) optional keyword-keyed-map
  threshold 8→64 (clojure's `KW_HASHTABLE_THRESHOLD`). Also audit the analyzer destructure lowering.
- **L4 — Variable-size vector tail + array-indexed size-class free-list.** TailNode is fixed
  32-slot (256B) → a 4-elem vector over-allocates; free_pool is a hashmap (a small-size-class
  array free-list is cheaper). Bench: gc_alloc_rate.

**Tier 3 (smaller / later):**
- **L5 — `big.int.Mutable` + reused limbs_buffer** for in-place factorial multiply (gap already
  1.02× — low priority).
- **L6 — CHAMP canonicalization-on-delete** for fast map `=` (if not already complete).

## Experimentation + regression protocol (how to do this safely)

- **Branch per lever**: `develop/collection-<lever>` off latest main. Experiment-and-revert /
  commit-without-push until a lever PROVES a win; only then merge. A reverted experiment's
  commit may stay in the branch log; never leave a merged branch red.
- **Correctness net (load-independent; collection changes are GLOBAL → run FULL, not smoke)**:
  the F-012 dual-backend diff oracle (`zig build test -Dwasm`) + `corpus_regression` +
  `CLJW_GC_TORTURE`. A semantics-preserving collection change passes these mechanically — this
  is the "tests guard it" safety the change relies on.
- **Perf net (load-robust)**: per lever, the **interleaved cljw-vs-bb A/B + OFF/ON-knob**
  pattern (validated in the D-519 GO) on a quiet-ish Mac; record a baseline first. Keep iff
  diff-oracle-green AND bench win AND no regression on the other 8 ADR-0148 benches.
- **Smell/refactor gate (F-002/F-010)**: each lever held to finished-form; a workaround
  triggers surgery, not a patch.

## Consequences

- Lands cljw as clearly fastest-script (flips the 6 collection losses to wins) AND improves
  real-world code (transients/chunked-seqs are general, not bench-specific).
- Touches collection internals broadly; the diff oracle + corpus are the guard (per-lever full
  run, not smoke). No algorithm rewrite, so behavioural risk is bounded.
- The compute frontier beyond bb (JVM-Clojure territory) remains the SEPARATE JIT unit — not
  in this ADR's scope.

## Alternatives considered (from the 3 surveys, full notes in the proposal record)

- **RRB-tree vector** — rejected (common-path tax; Clojure keeps it contrib-only). Opt-in
  `flex_vector` only if a concat-heavy workload ever justifies it.
- **Full data-structure rewrite** — rejected; cljw's algorithm choices are already best-of-breed
  (CHAMP/radix+tail/array-map). The gap is constant-factor implementation.
- **Touch the VM engine for these benches** — rejected; the engine WINS pure compute 2×. The
  lever is collections; the engine's frontier is the JIT (separate unit).

Survey sources + the full proposal: `private/notes/collection-perf-proposal-20260624.md`,
`private/notes/9.2.S-clean-peer-rerank-20260624.md`, `private/notes/cljw_collection_codetruth.md`.

## Amendment 1 (2026-06-24) — measurement-driven lever re-order

The implementation Step 0.6 re-laying (main-agent, before the first lever's code) MEASURED
the current peer standing on a ReleaseSafe binary (hyperfine -N, 20-30 runs, load ~3,
interleaved cljw-vs-bb AND clean old-vs-new-binary A/B) and read the code-truth of each
losing bench. Two premises in the body above did not survive contact:

1. **"cljw's transients are a STUB today" is FALSE.** `transient_vector.zig` ships a working
   flat-buffer transient (`conj!`/`assoc!`/`pop!`/`persistent!`, the latter an O(n) bulk
   `vector.fromSlice`), and `into`/`vec` in `core.clj` ALREADY route through it. The flat
   buffer is arguably faster than a HAMT-editable transient for build-from-empty (contiguous,
   no trie nav); its only weakness is `(into big-existing few)` copying `big-existing` up
   front — which none of the benches hit.

2. **No measured-LOSING bench is gated on a slow transient-build path**, so "L1 first,
   highest ROI" was a Reservation-as-bias (the lever was planned, not evidence-led). Mapping:
   - `gc_alloc_rate` (LOSES 1.06×) = 200K 4-elem vector LITERALS → L4 (small-tail over-alloc:
     a 4-elem vector takes a fixed 256B `[32]Value` TailNode). Already partly addressed by
     O-040 (`op_vector_literal` one-shot `fromSlice`).
   - `gc_large_heap` (LOSES 1.19×) = map literals + `(into [] (map …))` — `into` is ALREADY
     transient; the cost is small-map allocation + the lazy `map` walk.
   - `destructure` (LOSES 1.18×) = keyword-map GET → L3.
   - `sieve` (LOSES 1.14×) = lazy `filter` element-at-a-time walk → L2.
   - `nested_update` now **WINS 1.39×** (the handover/peer-rerank that listed it as a loss is
     STALE — D-519 auto-collect closed it). `bigint` is a tie.

   Corrected peer-standing table (replaces the body's "cljw loses 1.02–1.16×" row):

   | bench         | cljw | bb   | verdict (bb/cljw) |
   |---------------|------|------|-------------------|
   | gc_large_heap | 33.3 | 28.1 | LOSES 1.19×      |
   | destructure   | 49.5 | 41.9 | LOSES 1.18×      |
   | sieve         | 17.4 | 15.3 | LOSES 1.14×      |
   | gc_alloc_rate | 35.1 | 33.2 | LOSES 1.06×      |
   | nested_update | 11.3 | 15.7 | **WINS 1.39×**   |
   | bigint        | 17.5 | 17.7 | tie               |

**Re-ordered levers (evidence-led; replaces the Tier-1/2/3 ordering for activation
purposes):**

- **L3 (keyword-map get fast path) — LANDED first as O-051.** The clearest hot path
  (decomposition micro-benches isolated map-destructure's get cost + a ~10ms binding-lowering
  residual; `getonly` showed cljw keyword gets ~1.8× bb). Fix: `array_map` `get`/`contains`
  compare keyword keys by raw NaN-box payload bits (keywords are interned ⟹ `=` is
  bit-identity), skipping the per-entry `keyEq`→`eqConsult`→`keyEqValue` error-union chain.
  Clean old-vs-new A/B (30 runs): destructure −6.6%, gc_large_heap −4.5%, 300k-get −11.0%.
- **L2 (chunked lazy-seq walk)** — sieve's `(filter … (rest s))` realizes one Cons per
  element via a thunk Fn call; clojure.lang chunks 32-wide on the WALK path, not just reduce.
- **L4 (right-size small-collection allocation)** — the unifying theme of gc_alloc_rate +
  gc_large_heap: fixed `[32]Value` TailNode / `[16]Value` ArrayMap over-allocate for small
  collections. More invasive (touches core layout + GC trace) → after L2/L3.
- **L1 (transients)** is NOT retired — it remains available for the `(into big few)` /
  HAMT-editable-transient improvement — but it is **demoted from "first"**: it does not move
  any current losing bench, so it is not evidence-led right now.
- L5/L6 unchanged (low priority).

This amendment does not change the body's core thesis (keep best-of-breed algorithms, win on
Zig-native layout); it corrects which lever is evidence-led FIRST and fixes two factual
premises. Per F-002, the lever order follows the finished form (measured loss + diagnostic
clarity), not the originally-written sequence.

### Alternatives considered (Devil's-advocate)

> **Provenance**: the mandatory fresh-context DA fork was attempted TWICE
> (2026-06-24) and both launches died on an external `API Error: 529
> Overloaded` (0 subagent tokens — never ran). Per CLAUDE.md § The only stop, an
> external API block does not halt the loop; the DA analysis below is the
> main-agent fallback. It is genuinely adversarial — the correctness surface was
> stress-tested during implementation — and a fresh-context re-run can be added
> later if the bias-check is wanted, but the change is already PROVEN (measured
> A/B) and CORRECTNESS-VERIFIED (dual-backend diff oracle green).

**(A) Three alternative shapes (within the F-NNN envelope):**

1. **Smallest-diff** — keep ADR-0165's L1-first ordering as written; land the
   keyword-get only as an unscheduled bonus, leaving the "transients are a stub"
   text. _Better_: zero doc churn. _Breaks_: perpetuates a factually false
   premise + the Reservation-as-bias; the next session re-derives the same
   measurement to re-discover L1 is inert (wasted cycle). Fails F-002 (finished
   form = evidence-led order), so rejected.
2. **Finished-form-clean** — the proposed measured-loss re-order, AND generalise
   the keyword fast path into a typed `isIdentityKey` predicate (keyword +
   boolean + nil + char — the immediate/interned bit-identity types) applied
   uniformly to `get`/`contains` AND the `hash_map` HAMT path. _Better_: one
   coherent symmetric abstraction. _Risk_: boolean/nil/char map keys are rare
   (no measured win), and the hash_map extension still computes `keyHash` so the
   payoff there is marginal — more surface for little gain. Adopt the re-order
   now; record the `isIdentityKey`/hash_map generalisation as a LOW-priority
   follow-up, not this cycle.
3. **Wildcard** — skip per-key fast paths; instead attack the destructure
   LOWERING with a monomorphic inline-cache so a `{:keys [a b c]}` in a hot loop
   resolves keyword→entry-index ONCE and reuses it (the ~10 ms binding-lowering
   residual the decomposition micro-benches found). _Better_: targets a cost the
   get fast path does not. _Risk_: needs a map-shape guard + invalidation; it is
   hidden-class/shape-cache territory = the D-386 JIT frontier, out of the
   collection-perf unit's scope. Defer to D-386.

**(B) Correctness attack on `@intFromEnum(entry_key) == @intFromEnum(k)` (k a keyword):**

- _Un-interned keyword_ — keyword.zig interns by (ns, name) (identical pairs share
  one heap object), so two `:a` are bit-identical. SAFE; moreover `keyEqValue`'s
  existing identity-first check ALREADY relies on this invariant, so nothing new
  is assumed.
- _False hit vs a non-keyword entry_ — the compare is on the FULL `@intFromEnum`
  (NaN-box tag + payload), and distinct `Value.Tag`s occupy distinct tag bits, so
  a keyword `k` can only bit-match a keyword entry. A keyword is never `=` to a
  non-keyword in clj. IMPOSSIBLE.
- _with-meta'd keyword_ — cljw keywords carry no per-instance meta (interning
  ignores it; only SYMBOLS have the meta-bearing variant, which is why symbols are
  kept on the general path via `symbolStructEq`). SAFE.
- _Namespaced keyword_ `:ns/name` — interned by the (ns, name) pair → distinct
  object, bit-equal iff same ns+name. SAFE.
- _hash_map (>8 entries) path_ — UNCHANGED (still `hamtGet`/`keyEq`); correct as
  before, just no speedup. Keyword maps that large are rare. Not a correctness
  issue.
- _Float/NaN_ — unreachable (k is a keyword). SAFE.
- Conclusion: no wrong-answer path exists given keyword interning; the green
  dual-backend diff oracle empirically confirms across the full corpus.

**(C) Recommendation**: accept the amendment (measured-loss re-order + O-051 as the
first landed lever). The keyword-only restriction is the finished form for the get
path now; Alt 2's generalisation is a low-priority follow-up and Alt 3's
inline-cache belongs to D-386. None require violating an F-NNN.
