# ADR-0063 — Activate the reserved `.range` value (compact LongRange) for range performance

**Status**: Proposed → Accepted (2026-05-31)

**Context owner**: autonomous loop (user-directed perf pull-forward)

## Context

D-168 made `(range n)` / `(range a b)` lazy cons-seqs (correct, replacing
an eager vector that returned the wrong type). Correct, but each element
costs a cons + lazy_seq allocation, so `(count (range N))` ≈ 118 µs/element
and reduce/into/count over large ranges are pathologically slow (D-163).
The full Mac gate sits at ~244 s (borderline under the 300 s cap; load
variance tips it to timeout) largely because range-heavy e2e steps slowed.

The user directed pulling the performance finished-form forward:
*"あからさまに遅いと数々のこれからのイテレーションのボトルネックになる
ので、 前倒しでもやっておく価値があります"* (2026-05-31), having earlier
authorised speed-ups *with clear markers* and asked that cw v0's approach
be investigated.

cljw's value model **already reserves** `.range = 12` (Group A slot A12,
per F-004) — the tag round-trips through `encodeHeapPtr`/`decodePtr` and is
listed in `coll?`/`seq?`/`sequential?`/`conjOne`, but no struct, producer,
or handler exists (vestigial, like `.cons`). This ADR activates it.

cw v0 (`ClojureWasm/src/lang/builtins/sequences.zig`) solves range perf with
(1) a compact range descriptor and (2) `fusedReduce` collapsing
map/filter/take chains to a 0-alloc pass (measured 1336x on lazy_chain).
This ADR takes only (1); the fusion (2) is increment 2 — see Non-goals.

Survey: `private/notes/perf-range-value-survey.md`.

## Decision

**Activate `.range` (A12) as a compact value; its `seq` materialises a
chunked_cons (JVM `LongRange` → `LongChunk` shape). Increment 1 = the
compact value; map/filter reduce-fusion = increment 2 (deferred).**

1. **Value.** `runtime/collection/range.zig` defines
   `LongRange extern struct { header: HeapHeader; start: i64; end: i64;
   step: i64; count: u32 }` (Cons/ChunkedCons template: HeapHeader at
   offset 0, comptime align asserts). It owns no `Value` children, so its
   GC trace is **null** (the `tag_trace_table` "no outgoing pointers"
   case) — not a child-marking trace.

2. **One iteration source (F-011).** `range.zig` is the single home for
   range math: `count` (O(1), precomputed), `nth` (O(1), `start+i*step`),
   `first` (O(1)), `reduceRange` (tight i64 loop honouring `reduced`), and
   `seqChunk` (materialise ≤32 elements into a `chunked_cons` whose `next`
   is the smaller `.range` or nil). count/nth/reduce/first shortcut the raw
   `.range`; **generic traversal (`seq`/`rest`/`map`/`doseq`) goes through
   `seqChunk` → the existing `chunked_cons` machinery**, paying one
   allocation per 32 elements, not per element (the DA-A2 finding).

3. **Producer.** A `-range` `:zig-leaf` (ADR-0033 D4 pattern) is the sole
   producer. `core.clj`'s `range` 3-arg arm calls `-range` when start/end/
   step are all integers, step≠0, and the range is finite + non-empty;
   otherwise it falls through to the existing lazy `.clj` cons body.
   - `(range)` 0-arg stays `(iterate inc 0)`.
   - Empty range → **nil** (cljw has no distinct empty-seq; D-164). The
     producer never mints a count-0 `.range`.
   - Float ranges, step=0 (infinite 0s), and bigint-bounded ranges →
     lazy `.clj` fallback (the `.clj` body already handles any numeric via
     `+`/`<`). These are F-005-owner territory (F-003 defer).

4. **Call-site contract.** A `.range` arm is added to: `countFn` (O(1)),
   `nthFn` (O(1), NOT the O(n) walk arm), `firstFn` (O(1)), `seqFn`
   (→ `seqChunk`), `restFn`/`nextFn`/`seqNext`/`firstOfSeq`/`restOfSeq`
   (→ `seqChunk` then the chunked_cons ops), `reduceFn` (tight loop),
   `consFn` (range tail, via seq-view), `print` (deepRealize/printValue),
   `equal` (isSequential + Cursor + isCountable). Predicates
   (`coll?`/`seq?`/`sequential?`/`conjOne`) already list `.range`. *A
   missed arm is a crash — the nth-on-lazy_seq class of bug just fixed in
   D-168; the survey §4 checklist is the exhaustive list.*

5. **Optimization governance (user-directed).** This is the first entry
   in the new `.dev/optimizations.md` SSOT (O-001) and the first user of
   the `// PERF:` marker convention
   (`.claude/rules/perf_marker.md`): every speed-for-simplicity trade
   carries a grep-discoverable marker + a ledger row recording the naive
   contract it optimizes.

## Non-goals (explicit)

- **Map/filter/take reduce-fusion** (cw v0 `fusedReduce`). The compact
  `.range` is the *substrate* this fusion operates over (DA-A2); fusion is
  increment 2, a separate ADR in the D-163 perf window. Increment 1 must
  NOT introduce meta-annotated lazy-seqs.
- **Bigint / float range** as a `.range` value (F-005-owner; lazy `.clj`
  fallback handles them).
- **Fixing D-164** (empty≡nil), **D-165** (i48 element overflow → float),
  or **D-178** (`.list`/`.cons` conflation). All three are inherited
  unchanged — not fixed, not regressed. *(D-165 for `.range` was AMENDED
  2026-08-28 — see Revision history; the increment-1 non-goal held until the
  `int?` fix routed heap-Long bounds here.)*

## Consequences

- `count`/`nth`/`reduce`/`into`/`first` over a range become O(1) / tight
  loop; generic `seq`-walk (map/doseq) pays 1 alloc / 32 elements (was 1 /
  element under D-168's lazy-cons). The measured D-163 range pathology is
  removed; the gate's range-heavy e2e get faster.
- The lazy `.clj` range body stays as the fallback + the source of truth
  for float / infinite / bigint ranges.
- Range elements beyond ±2^47 silently become float (D-165, F-005-owner,
  inherited). Range count beyond 2^47 likewise (rare; D-165 sibling).
  **SUPERSEDED 2026-08-28 (see Revision history):** elements and the virtual
  count now box as heap Longs across the full i64 domain via `promote.wrapI64`
  — no float spill; a `.range` spans the whole Long range like JVM `LongRange`.
- A new `runtime/collection/range.zig` + the §4 call-site arms; the
  chunked-seq path reuses `chunked_cons` (no new chunk machinery).

## Alternatives considered

Sourced from a fresh-context Devil's-advocate subagent (mandatory at
depth ≥ 2), briefed with the F-002/F-004/F-005/F-011/F-003 envelope. Its
analysis is reproduced verbatim; the leading recommendation (Alt 2) is
the shape this ADR adopts.

### DA verdict on the draft

> The draft is F-NNN-compliant and is **not** the smallest-diff trap it
> could have been. Two things specifically clear it: it activates the
> *already-reserved* `.range` slot (F-004 fixes range as a standalone
> Group A slot, so a dedicated struct is the F-004-decreed shape, not a
> free design choice), and it routes count/nth/reduce/print/equal through
> one `range.zig` math module (F-011 commonisation). The Devil's
> advocate's job is therefore not "is the draft dirty" but "is the
> draft's *increment boundary* (unchunked start/end/step, lazy `.clj`
> fallback, per-step `.range` re-mint) the finished form, or a way-station
> the finished-form owner would unwind". On three of those sub-questions
> it is a way-station — and one (d, the per-step re-mint) is a latent
> performance cliff the draft's own perf goal does not survive.
>
> - **(d) is the sharp one.** `restNext` minting a fresh `.range` per
>   element means a *generic walker* — `(map f (range n))`,
>   `(doseq [x (range n)] …)`, `seqFn`-driven traversal — pays one
>   `.range` allocation per step, exactly the cost profile D-168's
>   lazy-cons range already has. The draft's O(1) win lands *only* on the
>   call sites that special-case `.range` (count/nth/reduce). The ADR's
>   own consequence ("range-using code gets fast") overclaims.
> - **(a) chunked_cons already pays for itself.** It already ships
>   O(1)-ish `count`, `first`, and a `rest` that only re-allocates at
>   chunk boundaries (every 32 elements). A range *is* the canonical
>   chunked producer in JVM (`LongRange` → `LongChunk`). A second
>   iteration vtable in `range.zig` when `chunked_cons` is the F-004
>   neighbour built for this is an F-011 tension.
> - **(e) no hard F-004/F-011 violation**, but the "ONE source" claim is
>   weaker than it reads: the draft creates a *second* seq-iteration
>   mechanism parallel to `chunked_cons`.

### Alt 1 — Smallest-diff: keep lazy-cons range, add reduce/count/nth fast-paths only

> Keep D-168's lazy-cons range; special-case the consumers (count/nth/
> reduce) via a meta-annotation or an opaque marker. **Better:** smallest
> call-site surface (3 arms, no "missed arm = crash" class). **Breaks:**
> either reintroduces meta-annotated lazy-seqs (forbidden in increment 1)
> or smuggles a half-readable `.range` (the "5 types in one slot"
> anti-pattern F-004 forbids); the generic-walker cost (d) is unchanged.
> **F-NNN:** borderline F-004, fails F-002 (the smaller-diff path the
> finished-form owner unwinds). Cycle-budget-defer smell. **Not
> recommended.**

### Alt 2 — Finished-form-clean: `.range` value whose `seq` produces a chunked_cons (RECOMMENDED)

> Activate `.range` (compact start/end/step, O(1) count/nth, tight
> reduce) — but `seq`/`rest` of a `.range`, instead of re-minting a
> `.range`, materialises a 32-element `chunked_cons` lazily, JVM
> `LongRange`→`LongChunk` style. count/nth/reduce hit `.range` directly
> (O(1)); *generic* traversal goes `.range` → `chunked_cons` at one
> allocation per 32 elements (fixes d). The seq-family call sites mostly
> **already** route `.chunked_cons`, so the new-arm surface *shrinks*
> relative to the draft — many sites need a `.range` arm only for the
> O(1) fast path and otherwise fall through to the present `.chunked_cons`
> arm via a one-line `seq`-coercion. **Better:** makes the perf win real
> for *every* range consumer, not just the three that special-case
> `.range`; honours F-011 *across the seq family* (range is a producer
> feeding the one chunk mechanism, not a parallel mechanism); lays the
> runway for increment-2 fusion (the chunk is where fused reduce
> operates). **Breaks:** larger diff (chunk-materialisation path, GC
> interplay between `.range` and the `.chunk_buffer` it spawns); the
> empty-range/D-164 handling now has two exits that must agree. Per F-002,
> diff size is not a reason to prefer the draft — recommend anyway.
> **F-NNN:** fully compliant; the *stronger* F-011 reading. **This is the
> Devil's-advocate recommended shape**, on the strength of (d): the
> draft's per-step re-mint undermines its own perf goal for the most
> common traversal, and the chunked-seq path is the finished form JVM
> itself ships.

### Alt 3 — Wildcard: all-Zig range + co-activate `.string_seq`/`.array_seq` behind a shared seq-producer vtable

> Move all of range (incl. float/step-0/bigint) into Zig, and activate
> the three adjacent Group A seq-family slots together behind one
> `SeqProducer` shape. **Better:** kills the producer-leaf/`.clj`-fallback
> seam; amortises the ~14-arm call-site surgery once across three types
> instead of three times. **Breaks:** scope explosion against F-003
> (`.string_seq`/`.array_seq` are owned by their own §9.x rows; no F-NNN
> fixes "activate the seq family together"); bigint-in-Zig range bounds
> are **F-005-owner territory** (the loop pre-empting the F-005 owner); a
> premature shared vtable risks the ROADMAP §13 `pub var` vtable ban.
> **F-NNN: partially violates F-003 and trespasses F-005's reserved
> decision** — recorded as a finding, not a recommendation. The defensible
> fragment (bigint/float in Zig) is left to the F-005 owner; the
> seq-family co-activation becomes a debt row at the `.string_seq` owning
> row, reusing Alt-2's chunked-seq substrate so the third surgery is a
> one-arm fall-through.

### DA probe answers (verbatim)

> - **(a)** Both — `.range` for the O(1) descriptor (F-004-decreed),
>   `chunked_cons` as what its `seq` *produces*. Not "instead of"; "as a
>   producer feeding".
> - **(b)** The *value* stays unchunked start/end/step (O(1) nth); its
>   *seq* should be chunked from day one (Alt-2). The draft chunks
>   neither, which is why (d) bites.
> - **(c)** Keep the producer-leaf + `.clj`-fallback split for this
>   increment — the fallback cases (float/infinite/bigint) are genuinely
>   F-005-owner territory; moving them to Zig now trespasses F-005. The
>   seam is the F-005 deferral made concrete, not smallest-diff bias.
> - **(d) YES — strongest finding.** Per-step `.range` re-mint allocates
>   per element for generic consumers; `seq` of a range should produce a
>   `chunked_cons`.
> - **(e)** No hard violation; Alt-2 is the stronger F-011 reading (one
>   chunk mechanism, range is a producer).

### Main-loop decision

Adopt **Alt 2**. Per CLAUDE.md's Cycle-budget-defer rule, the DA rating
Alt 2 finished-form-clean within the F-NNN envelope, with no F-NNN block,
means the larger-diff finished form is taken over the simpler draft. The
loop's earlier instinct toward the draft (generic-walk perf "belongs to
increment-2 fusion") was answered by the DA: the chunked-seq is the
*substrate* fusion operates over, not redundant with it. Alt 3's
seq-family co-activation insight is recorded as forward debt at the
`.string_seq`/`.array_seq` owning row (reuse Alt-2's chunked substrate).

## Affected files

- New: `src/runtime/collection/range.zig` (the value + iteration math +
  `seqChunk`), `.dev/optimizations.md` (O-001),
  `.claude/rules/perf_marker.md`.
- `src/runtime/value/value.zig` (register `.range` GC trace = null /
  decode), `src/runtime/gc/tag_ops.zig` (no trace, document the null),
  `src/runtime/runtime.zig` (registerGcHooks call if any).
- `src/lang/primitive/sequence.zig` (count/seq/first/rest/next/seqNext/
  firstOfSeq/restOfSeq + reduce path), `src/lang/primitive/collection.zig`
  (nthFn / consFn), `src/lang/primitive/higher_order.zig` (`-range` leaf +
  reduceFn `.range` arm), `src/lang/clj/clojure/core.clj` (range 3-arg
  mints `.range`).
- `src/runtime/print.zig` (`.range` print), `src/runtime/equal.zig`
  (`.range` sequential/cursor/countable).
- Tests: `test/e2e/phase14_range_indexed.sh` (extend) + a diff-oracle
  case; `range.zig` unit tests.
- Debt: D-163 (perf blueprint already recorded), a new row noting
  `.range` inherits D-165 for large elements + the Alt-3 seq-family
  co-activation forward debt.

## Cross-references

F-002 / F-004 (A12 reservation) / F-005 (numeric tower) / F-011
(commonisation) / F-003 (structural deferral scope boundary) ·
D-163 (perf window + cw v0 fusedReduce blueprint) · D-168 (range→lazy
seq, the immediate predecessor) · D-164 / D-165 / D-178 (inherited) ·
ADR-0033 D4 (`:zig-leaf` producer pattern) · survey
`private/notes/perf-range-value-survey.md`.

## Revision history

- **2026-05-31 — formalised into a ROADMAP perf campaign.** The user
  extended the one-off range pull-forward into a sustained, ROI-ordered
  speed-tuning campaign (*"ROI の高いものから自律的に判断して進め、 手戻りも
  していい … 正式な計画に組み込みましょう … クリアセッションからまっさきに
  腰を据えてやってくれるよう配線"*). This ADR's governance (the `// PERF:`
  marker + `.dev/optimizations.md` SSOT) now covers the whole campaign,
  recorded as **ROADMAP §9.2.S Performance tuning campaign** (ACTIVE
  resume target, ahead of the §9.2.R Phase-15/JIT sequence; F-003: no
  renumber). Landed since this ADR: **O-002** (reduce index-walks a
  vector, `0898ba2c`) and **O-003 / D-180** (bulk `vector.fromSlice` —
  `toPersistent` builds the HAMT trie from the transient's flat buffer
  in O(n) instead of N persistent conjs; `into`/`vec` route editable
  targets through transients; `(count (vec (range 1e6)))` 121s → 2.4s).
  NEXT: **D-163** (map/filter/take reduce-fusion — its own ADR) then
  **D-140** (startup bootstrap cache). The campaign carries its own
  focused units because D-180 touched the core Vector type (exhaustive
  boundary tests at n ∈ {0,1,31,32,33,63,64,65,1023,1024,1025,1e5}) —
  a deliberate "腰を据えて" treatment rather than a rushed mega-session
  addition.

- **2026-08-28 — `.range` spans the full i64 Long domain (D-165 completed for
  `.range`).** The increment-1 non-goal "elements/count beyond ±2^47 silently
  become float (D-165 inherited)" became a **clj-parity bug** once the
  `int?`-is-fixed-precision fix (commit `271d9bb8`) made `int?` true for heap
  Longs (a `big_int` origin `.long`): `range`'s 3-arg gate `(and (int? start)
  (int? end) (int? step) …)` now routes heap-Long bounds to `-range`, whose
  guard rejected any tag ≠ `.integer`. Repro `(range (bit-shift-left 1 55) (+ 4
  (bit-shift-left 1 55)))` → `Type error: -range: expected integer, got
  big_int`; clj yields the finite 4-element Long range. Global D-165 (ADR-0080)
  was itself DISCHARGED 2026-06-03 (C7) — the numeric tower boxes past-i48 Longs
  via `promote.wrapI64` everywhere *except* this last `.range` element/count
  site. **Amendment:** `.range` is an i64-domain value (its struct fields are
  already `i64`), and **every** projection of it to a `Value` — `elementAt`,
  `first`, `seqChunk` slot fill, and the virtual `countValue` — now crosses the
  one canonical `promote.wrapI64` lever (Single-Source-Lever
  `20260817195814-7eebeaf4`): a value past i48 boxes as a heap Long (exact,
  class Long), never a float. `rangeLeafFn` accepts heap-Long bounds via
  `error_catalog.expectI64`. `elementAt`/`first` gain `rt` + become fallible
  (the heap-Long alloc); the reduce loop already roots its accumulator (and
  `coll` via the operand stack), and `seqChunk`'s fill is already inside the
  D-244 fabrication no-collect region, so no new GC-rooting hazard. F-005-clean
  (a Long past i48 stays a Long, not an F-005 numeric-tower redesign — it reuses
  the tower's existing `wrapI64`). This is the `quality-loop floor: clj-parity`
  drain (compliance batch B3-adjacent), corpus-backed. Depth-3 amendment; the
  mandatory Devil's-advocate fork (fresh context, F-002/F-005/F-011 envelope) is
  reproduced verbatim below.

### DA alternatives (2026-08-28 amendment) — verbatim

> **Alt 1 — smallest-diff (gate-predicate reroute).** Add a `cljw.internal`
> "is-inline-`.integer`" predicate and change the core.clj gate so heap-Long
> bounds fall to the lazy cons body; `.range` element production untouched.
> *Better than A-fixed:* zero ripple — no rt/fallible signatures, no new GC
> allocation in the reduce loop, no change to the D-165/D-179 `initInteger`
> invariant. *Breaks/risks:* large-offset ranges lose O(1) `nth`/`count` and
> become O(n) lazy (ADR-0063/O-001 regression). More importantly it is the
> Nth+1 copy: `.range`'s element/count spill-to-float bug survives, merely
> dodged at one entry path — a latent lie the next `-range` caller re-hits.
> Element magnitude is bounded by the bounds, so this covers element spill, but
> the **`count`-field spill** (span > 2^47 with i48 bounds, e.g. `(range -2^47
> 2^47)`) still routes to `-range` and still floats. Smallest-diff bias per
> F-002.
>
> **Alt 2 — finished-form-clean (single wrapI64 lever; RECOMMENDED).** A-fixed
> *plus* routing the `count`→Value boxing through `promote.wrapI64` too.
> Invariant: `.range` is an i64-domain value; **every** projection to a Value
> (element, first, seqChunk slot, count) crosses through the one canonical
> `wrapI64`, retiring the scattered `initInteger` D-165 flagged. *Better than
> A-fixed:* A-fixed as scoped fixes elements but leaves `(count (range
> huge-span))` spilling to float — Alt 2 is the only option making `.range` a
> faithful JVM `LongRange` (O(1) `nth`/`count` correct across the full i64
> domain) and fully discharging D-165/D-179 for `.range`. *Breaks/risks:*
> GC-rooting — `wrapI64` allocates a heap-Long, so the reduce accumulator and
> the mid-fill `chunk_buffer` (`seqChunk` sets `cb.slots[i]` one at a time) must
> be rooted across each boxing; audit every `GC-ROOT:` site. Alloc cost is
> inherent to F-005 (a Long past i48 *is* a heap value) and matches JVM boxing —
> not a regression to dodge. `wrapI64` stays alloc-free for in-i48 elements, so
> the common hot path only gains a bounds check.
>
> **Alt 3 — wildcard (`-range` internal fallback).** Keep the clj gate calling
> `-range` for any integer+step≠0; `-range` itself mints a `.range` only when
> the range is *wholly* i48-representable, else builds the lazy heap-Long seq.
> Preserves `.range ⟺ i48` in one producer. *Better than A-fixed:* `.range`
> element/count code untouched (no ripple, no GC hazard), and spill is
> *structurally* impossible. *Risks:* wide ranges O(n) (like Alt 1); `-range`
> now sometimes returns a non-`.range` (callers already handle its `()` return,
> so tolerable); the wholly-i48 test is a new correctness-critical branch.
>
> **Recommendation:** Alt 2 — the single-`wrapI64`-lever completion of A-fixed,
> because only it also closes the `count`-field spill A-fixed leaves open and
> makes `.range` a true i64-domain `LongRange`; the GC-rooting audit is the
> price, not a reason to shrink to Alt 1/3 (F-002).

**Main-loop decision:** adopt **Alt 2**. The DA rated it finished-form-clean
within the F-NNN envelope with no F-NNN block; per CLAUDE.md's Cycle-budget-defer
rule the larger-diff finished form is taken. The GC-rooting audit the DA
demanded was performed: the reduce accumulator is rooted via `gc_roots[1]` and
`coll` via the operand stack (`args[last]`); `seqChunk`'s fill sits inside the
existing D-244 fabrication no-collect region; `elementAt` reads `start`/`step`
into i64 locals before allocating, so `coll` need not survive the alloc. No new
`GC-ROOT:` site was required.
