# ADR-0179 — The NaN-box tag space is measured by use, not counted by name

- **Status**: Proposed → **Accepted** (2026-08-04)
- **Amends**: ADR-0027 (NaN-box slot map) — adds the boxable/heap-only
  distinction and its enforcement. Does **not** amend F-004.
- **Related**: F-004 (NaN-box layout, user-owned), F-002, F-003, ADR-0012,
  ADR-0178 (derive rather than maintain), D-043 (the Group-D renumber
  precedent), D-259 (the deferred wasm-value decision).

## Context

The 2026-08-04 cross-project audit counted the 64 named entries in
`src/runtime/value/heap_tag.zig` and concluded: *"the tag space is 100 % full;
core.async's channel, java.time, WeakRef and WasmGC refs have nowhere to go;
F-004 must be amended, and that is a user decision."* It was recorded as the
single structural problem the loop could not solve alone.

**That conclusion was reached by counting names.** Names are not uses. Measured
by use, the space is not full.

### The corrected census (mechanical, and it closes)

| Class | Count | Test |
|---|---|---|
| NaN-boxed as a `Value` in production | **53** | reachable `Value.encodeHeapPtr` |
| Heap-only — `HeapHeader.tag` only, never a `Value` | **2** | `tail_node`, `tval` |
| Named but with zero production reference | **9** | `reader_conditional`, `class`, `array_chunk`, `matcher`, `tuple`, `box`, `wasm_fn`, `wasm_funcref`, `wasm_externref` |
| **Total** | **64** | |

So **11 of 64 addresses are not doing NaN-box work**, and the "nowhere to go"
premise is false.

Two of the nine are subsumed by a different representation, verified by running
the binary rather than by reading the enum:

- `class` — a `Class` value is a `.type_descriptor`
  (`src/lang/primitive/core.zig:43`); `(class (class 5))` → `Class`.
- `matcher` — `Matcher` is an ADR-0106 `host_instance` container
  (`src/runtime/java/util/regex/Matcher.zig:3`);
  `(type (re-matcher #"a" "a"))` → `java.util.regex.Matcher`.

### Getting to that census took three tries, and that is the finding

The first classification, and the draft ADR built on it, were wrong three
separate ways — all of them counting errors of the same family as the audit's:

1. **A computed-tag encode site was missed.** The test was the *syntactic*
   `grep 'encodeHeapPtr(\.'`. `src/runtime/collection/map.zig:695` reads
   `Value.encodeHeapPtr(@enumFromInt(n.header.tag), n)`, and its consumers
   decode the tag straight back out (`map.zig:893, 909, 945, 1126`). So
   `hamt_map_node` and `hash_collision_map_node` are live boxed Values, not
   heap-only.
2. **A test-only encode was counted as production.** `wasm_funcref` /
   `wasm_externref` are encoded exactly once each, at `value.zig:556-557`,
   inside a unit test. They are as unallocated as the other seven.
3. **The census summed to 63, not 64.** `@"volatile"` uses Zig's `@"…"`
   escape and the regex did not match it. *A three-way partition of a
   64-entry enum that silently drops an entry is the same defect as the
   audit's, one layer down.*

The lesson is not "grep more carefully". It is that **a claim about which tags
are used is an execution fact, and it must be produced by execution**, the same
conclusion ADR-0178 reached about placement one commit earlier.

## Decision

### 1. Nothing is deleted or renamed

The nine unallocated names stay. Two reasons, both from the project's own
record rather than from caution:

- **F-004 fixes the day-1 type set, not just the layout.** F-004's body carries
  a "Types day-1 in the 64-slot plan" section that names `reader_conditional`
  ("`#?(:clj …)` for `.cljc`") and the Wasm family (`funcref` / `externref`,
  justified by F-001). D-043's discharge note states the reading verbatim:
  *"NOT an F-004 amendment (F-004 fixes 64 slots + the day-1 type set, not
  intra-group ORDER)"*. Removing or repurposing a named day-1 type is
  therefore user territory, and the loop does not take it.
- **`wasm_fn` / `wasm_funcref` / `wasm_externref` carry an open deferred
  decision.** D-259's barrier says Phase 16 decides how they become
  first-class cljw Values. Deleting the reservations would pre-empt an
  unbuilt structural decision with a named owner — F-003.

CLAUDE.md's Reservation-as-bias smell cuts the other way here, and it is worth
being exact about why. The smell is *obeying a reservation because it is
reserved*. This ADR does not obey the reservations — it **measures** them,
publishes that nine are unallocated, and hands the allocation question to the
owner who holds it. Refusing to spend a slot the loop does not own is not bias;
inventing a blocker out of a name count was.

### 2. Boxability becomes a compile-time property

`Value.encodeHeapPtr` takes `comptime ht: HeapTag` and comptime-rejects a tag
marked heap-only. 182 of its 184 call sites already pass an enum literal, so
they are unchanged; the one computed-tag site (`map.zig:695`) routes through an
explicit `encodeHeapPtrRuntime` that asserts the same property at runtime. A
future attempt to box `tval` is a **compile error at the call site**, not a
convention.

### 3. The census closure is asserted at comptime

`{boxable} ∪ {heap-only} ∪ {unallocated}` must partition `HeapTag`: pairwise
disjoint, union exhaustive, cardinality equal to the field count. This is the
check that would have caught both the audit's error and all three of mine — a
partition that does not close fails the build with the arithmetic in the
message.

### 4. The record is corrected where it is read

`heap_tag.zig`'s header states the measured census and that 11 addresses are
free, so the next reader counting names has the correct number in front of
them.

### What is left for the user, stated precisely

The audit said a user decision was needed to get **any** headroom. The accurate
statement is narrower: **11 addresses are free; 2 are loop-recoverable; using
any of the 9 named reservations for a different type is an F-004 question.**
When `core.async` needs a channel tag, the question to ask is not "may we amend
the 64-slot layout" (no amendment is needed) but "may `box` become `chan`" —
a much smaller question with a much cheaper answer.

## Alternatives considered

*(Devil's-advocate fork, fresh context, 2026-08-04. Reproduced as returned.
Every factual claim in its leading entry was re-verified against the tree
before this ADR was written; all held.)*

### LEADING ENTRY — the draft's own premise fails the same test it was written to fix, in two places, and one deletion class is F-004-amendment territory

**(i) `hamt_map_node` is NOT heap-only. It is NaN-boxed as a Value.**

The draft's mechanical test — "`Value.encodeHeapPtr(.tag, ptr)` literally
present ⇒ the tag is a Value" — is a *syntactic* test, and it misses
computed-tag encode sites. `src/runtime/collection/map.zig:694`:

```zig
fn nodeValue(n: *HamtMapNode) Value {
    return Value.encodeHeapPtr(@enumFromInt(n.header.tag), n);
}
```

`nodeValue` is called at six sites (`map.zig:750, 804, 865, 950, 1003, 1133`),
each writing the result into a `slots[…]` array whose element type is `Value`;
and the consumers *decode* the tag back out of the Value — `map.zig:893, 909,
945, 1126`: `if (child_slot.tag() == .hash_collision_map_node)`. So
`.hamt_map_node` and `.hash_collision_map_node` are both live NaN-boxed Values
whose sub-type field is load-bearing. The heap-only set is **two** tags
(`tail_node`, `tval`), not three.

`tail_node` and `tval` do check out: `PersistentVector.tail` is a raw
`?*TailNode` field (`vector.zig:65`), never encoded; `tval` is reached only
through `Ref.tvals: *TVal` (`stm/ref.zig:51`), and `stm/tval.zig:29` states the
invariant in its own header.

**(ii) The unused-reservation count is 9, not 7 — `wasm_funcref` and
`wasm_externref` are equally dead.**

Their only `encodeHeapPtr` call sites are `value.zig:556-557`, inside the unit
test *"F-004 day-1 Tag additions encode + decode"*. There is no production
producer, no `HeapHeader.init`, no `tag_ops` registration, and zero references
outside `heap_tag.zig` / `value.zig` (verified: `grep -rn
'wasm_funcref\|wasm_externref' --include='*.zig' src/` returns only enum
declarations, the sync test, and that one test). The draft's classifier counted
a test-only encode as "live", so it under-reported. `wasm_module` alone is real
(`runtime/cljw/wasm/wasm_handle.zig:47-48`).

**(iii) The draft's census does not sum to 64.** 53 + 3 + 7 = **63**. A
three-way classification of a 64-entry enum that drops an entry is precisely
the counting failure mode this ADR exists to correct. The corrected partition
does close:

| Class | Count | Members |
|---|---|---|
| NaN-boxed in production | 53 | (the remainder) |
| Heap-only (`HeapHeader.tag` only) | 2 | `tail_node`, `tval` |
| Zero production references | 9 | `reader_conditional`, `class`, `array_chunk`, `matcher`, `tuple`, `box`, `wasm_fn`, `wasm_funcref`, `wasm_externref` |
| **Total** | **64** | |

Reclaimable headroom is therefore **11**, not "~10" — but see (iv) before
spending it.

**(iv) Deleting the reservations is not obviously F-004-neutral, and the
project has already written down the opposite reading.**

F-004's *layout* clause ("4 group × 16 sub-type = 64 slot, 44-bit shifted
pointer") is untouched by any of this — the draft is right about that. But
F-004 also carries a body section headed **"Types day-1 in the 64-slot plan"**
which names `reader_conditional` with its rationale (`#?(:clj …)` for `.cljc`)
and names the Wasm family `funcref` / `externref` with F-001 as the
justification (`project_facts.md:356-360`). And the loop's own D-043 discharge
note (`.dev/debt.yaml:2869`, written 2026-06-15) reads:

> "NON-BREAKING + NOT an F-004 amendment (**F-004 fixes 64 slots + the day-1
> type set**, not intra-group ORDER…)"

That is this project's written precedent that the day-1 *type set* is F-004-fixed
and only the *order* is loop-owned. Under that precedent, deleting
`reader_conditional`, `wasm_funcref`, `wasm_externref` — and arguably `class` /
`matcher` / `tuple` / `box` / `wasm_fn` / `array_chunk`, which appear in
F-004's "Indicative slot map" — is an F-004 amendment, which the loop may not
make. D-200's status note (`debt.yaml:5237`) reinforces this: it framed reusing
`reader_conditional` for `#inst` as *"stealing `reader_conditional`'s
reservation"* and chose the no-slot `typed_instance` path instead, explicitly
on F-004 grounds.

There is a defensible counter-reading: F-004 labels the map "**Indicative**
slot map … the final placement lands when the Phase 5 ADR draft is reviewed",
which subordinates the map to ADR-0027. I do not think that reading extends to
*removing members*, only to *placing* them. **Recommendation: do not delete
anything.** The entire capacity benefit is available without touching a single
name (Alt B below), so the loop never has to test how far "indicative"
stretches. If the ADR nonetheless deletes, it must say plainly that it is
overriding the D-043 reading of F-004's day-1 type set, and it should still not
delete `wasm_fn` / `wasm_funcref` / `wasm_externref` — see Alt A on D-259.

### Alternative 1 — smallest-diff: allocation status without namespace surgery

Keep `HeapTag` as one 64-entry enum and keep every name. Add (a) a single
derived `pub const unallocated: []const HeapTag` (or an `allocation_status`
comptime table) declaring which of the 64 slots carry no behaviour; (b) the
census-closure gate from §Q5 below; (c) an ADR-0027 amendment recording that an
unallocated slot is **freely renameable in place** by any later cycle — a
rename changes no layout bit, no wire byte, and no dispatch index. When
core.async needs a channel, `box → chan` is a one-line enum edit plus the sites
that add behaviour.

**Better than the draft:** zero deletion, therefore zero F-004 exposure on the
day-1 type set and no need to litigate (iv). Zero renumbering, so
`tag_ops.zig`'s three `[64]` tables, the `native_descriptors[70]` array,
`isGcManaged`, and the 81 `switch (tag)` sites are all untouched. It ships the
*actual* correction the handover needs — "the space is not full, 11 slots are
free" — in the smallest verifiable form, and it makes the reservations' intent
explicit rather than deleting it.

**What it breaks:** it does not raise the ceiling above 64, so the next 12th new
type re-opens the same conversation. It leaves `tail_node` and `tval` burning
two NaN-box addresses they provably cannot use. It leaves the real defect — one
enum serving two namespaces of different widths (`HeapHeader.tag` is `u8`/256,
the NaN-box sub-type is 4 bits within a 2-bit band/64) — unfixed, so the
conflation that produced the "100% full" audit error can produce it again. And
the rename-in-place trick is arguably the same F-004 type-set mutation as
deletion, just less legible; if (iv) is a real constraint, renaming inherits it.

### Alternative 2 — finished-form-clean (RECOMMENDED): two types, one **derived** from the other, nothing deleted

Split the namespace as the draft proposes, but reject the draft's
hand-maintained framing. Concretely:

- **`HeapTag: u8`** stays the heap-object discriminant. It is the superset. It
  indexes `tag_ops.zig`'s three tables (which become
  `[@typeInfo(HeapTag).@"enum".fields.len]`, not `[64]`). It has room for 256
  and will not be full in this project's lifetime. `tail_node` and `tval` live
  here and only here.
- **`ValueTag`** is the NaN-box-encodable subset, and its integer values *are*
  the 0..63 slot indices. `encodeHeapPtr` takes a `ValueTag`; `HeapHeader.init`
  takes a `HeapTag`. Passing a non-boxable tag to `encodeHeapPtr` becomes a
  **compile error**, not a gate.
- **The mapping is generated, not written.** Per ADR-0178's ruling ("generate
  the index; gate the generation; keep judgement out of it") the slot index
  must be *derived* from one declaration, not maintained in a second list. One
  `comptime` table in `heap_tag.zig` declares, per entry, `{ name, group,
  boxable }`; `HeapTag`, `ValueTag`, and `valueTagOf(HeapTag) ?ValueTag` are
  all `@Type`-generated from it. Nothing is kept in sync by hand.
- **`Value.Tag` (the 70-entry mirror in `value.zig:44-124`) is deleted as a
  hand-written enum** and generated as `ValueTag` ∪ the six immediates. Today
  that mirror is guarded by `value.zig:468-478`, a test that spot-checks
  **seven** hand-picked pairs — it would not catch a dropped or shifted entry
  in the middle of a group. Generation removes the failure mode instead of
  testing for it.
- Unallocated slots keep their names and get an explicit `boxable = true,
  allocated = false` marking.

**Better than the draft:** it is the only shape that makes the invariants the
draft wants to *assert at runtime* into things the compiler *cannot express
wrongly*. It kills the two hand-maintained parallel structures
(HeapTag↔Value.Tag, and the draft's proposed new heap-tag↔Value-tag split)
rather than adding a third. It answers the reviewer's question 4 in the
affirmative: yes, the split creates a sync burden — **unless** it is derived,
and ADR-0178 is the in-house precedent that derivation is this project's answer
to exactly that. It gives genuinely unbounded heap-tag headroom (WeakRef, WasmGC
internals, java.time internals, STM/channel internals that never need to be a
Value) while leaving F-004's 64 NaN-box addresses *exactly* as decreed. And it
deletes no name, so (iv) never arises.

**What it breaks:** it is by far the largest diff — 1,666
`HeapTag`/`Value.Tag`/`.tag()` references and 81 `switch (tag)` sites must each
be re-typed to whichever enum they actually mean, and the compiler will surface
every one as an error rather than silently accepting the wrong one (that is the
point, but it is the cost). `native_descriptors: [70]` (`runtime.zig:412`) and
the three `[64]` tables become derived lengths. `isGcManaged`
(`heap_tag.zig:157`) and the `Runtime.init` assert at `runtime.zig:609` need
re-typing. The D-043-era invariant "HeapTag and Value.Tag renumber in lockstep"
is replaced by a derivation and needs its own gate.
`(cljw.internal/__native-type :kw)` (`lang/primitive/protocol.zig:310`, an
`inline for` over every `Value.Tag` field by name) changes which keywords it
accepts — an observable, if obscure, surface change.

Per **F-002** I recommend this one anyway. Diff size is not a project
constraint; only F-NNN is, and this alternative is the *most* F-004-conservative
of the three because it is the only one that adds capacity without renaming or
removing anything F-004 names.

### Alternative 3 — wildcard: one slot as an escape hatch (`extended`)

Allocate exactly one of the 64 sub-types as `HeapTag.extended`. A Value tagged
`.extended` carries a pointer whose `HeapHeader.tag` (already a `u8` on every
GC-managed object) holds the *real* discriminant from a second 256-entry space.
`tag()` gains one branch: if the decoded sub-type is `extended`, load
`header.tag` and map it. Hot tags (string/vector/map/fn/…) stay pure
shift-and-mask; cold, rare, or internal tags (WeakRef, java.time internals,
channel internals, WasmGC refs) live behind the hatch and pay one dependent
load.

**Better than the draft:** it converts "how do we ration 64 addresses forever"
into a closed question — the ceiling becomes ~319 and never binds again — while
the F-004 bit layout is *bit-for-bit unchanged* (still 4 groups × 16 sub-types,
still a 44-bit shifted pointer). It requires no renumbering, no deletion, no
second hand-maintained enum, and it composes with either Alt 1 or Alt 2. It also
gives the honest answer to the question the original audit was really asking
("where does core.async's channel go?") without spending a scarce slot on it.

**What it breaks:** `tag()` stops being branch-uniform, which is a direct cost
to gap area III (VM-perf); the extra branch is predictable but the dependent
load on the extended path is not free, and `tag()` is one of the hottest
functions in the runtime. The escape hatch is only available to tags whose
pointer target has a real `HeapHeader` at offset 0 — `heap_tag.zig:140-164`
documents that `var_ref`, `ns`, and `keyword` do **not** satisfy this, so the
hatch is structurally closed to that class. It also introduces a two-tier tag
space whose tier assignment is a judgement call made per-type forever, which is
a slow-drip version of the ADR-0178 problem.

**The variant we cannot take:** the maximal version of this — delete the 4-bit
sub-type field entirely, widen the pointer payload back to 48 bits, and read
*every* heap tag from `HeapHeader.tag` — is the cleanest possible finished form
and is a **direct F-004 violation**: F-004's confirmed direction is verbatim
"4 group × 16 sub-type = 64 slot, 44-bit shifted pointer". Recording it here per
the brief; not proposing it. It would additionally break the three header-less
heap tags above.

### Answers to the five interrogation points

**Q1 — is the central claim right?** Partly. The *conclusion* ("the space is
not full; ~10 slots are recoverable without amending F-004's layout") survives,
and is if anything understated (11). The *classification* has two errors in
opposite directions, both caused by using a syntactic test where an execution
test was needed: a computed-tag `encodeHeapPtr` was missed (`hamt_map_node`),
and a test-only `encodeHeapPtr` was counted as production (`wasm_funcref`,
`wasm_externref`). The other Value-construction paths I checked are clean:
`initInteger` / `initFloat` / `initChar` / `initBuiltinFn` / `initBoolean` use
the immediate bands and never touch the sub-type field; there is no
`@bitCast`-into-Value or inline bit-pattern construction anywhere in `src/`; the
only `@enumFromInt`-into-a-tag sites are `map.zig:695`/`829` (the computed-tag
path above), `value.zig:159` (`heapTagToTag`, a decode), `runtime.zig:609` (an
assert), `protocol.zig:312` (`__native-type`, name-keyed), and
`serialize.zig:1794` (a different enum). The two independently-verified
subsumptions hold: `class` is subsumed by `.type_descriptor`
(`lang/primitive/core.zig:43`) and `matcher` by ADR-0106 `host_instance`
(`runtime/java/util/regex/Matcher.zig`), and the runtime probes cited confirm
both.

**Q2 — does deleting violate F-004, and is renumbering a wire break?** Deleting
does not change the *layout*; see (iv) for why it may nonetheless be
F-004-amendment territory via the day-1 type set. **Renumbering is not a wire
break.** The AOT envelope uses a decoupled `ValueTag`
(`src/eval/bytecode/serialize.zig:128`), documented as *"Stable enum — the
`docs/spec/formats/<version>.edn` archive records this byte for each constant.
Adding a tag is a version bump; removing one is forbidden"*, with hand-assigned
values `0x00`–`0x11` bearing no relation to `HeapTag`. No
`@intFromEnum(HeapTag)` or `header.tag` byte is ever written to disk; heap
values are serialized structurally through the `ValueTag` arms. D-043
(`debt.yaml:2869`) already renumbered all of Group D in lockstep on 2026-06-15
and verified non-breaking, which is direct precedent. `tag_ops.zig`'s tables are
indexed by `@intFromEnum` and populated by *name* at startup
(`registerTrace(.tail_node, …)`), so they follow renumbering automatically. The
two things that do **not** follow automatically are the hand-written magic
numbers `[64]` (`tag_ops.zig:53, 74, 96`) and `[70]` (`runtime.zig:412`), plus
the boundary assertion `tag_ops.zig:198` — all three should become derived
lengths in whichever alternative lands.

**Q3 — delete, or keep-and-mark?** **Keep and mark.** Three of the nine have
live, documented intent that deletion would silently discard: D-259's barrier
(`debt.yaml:2390-2393`) states verbatim that "F-004 reserves `wasm_module` /
`wasm_fn` / `wasm_funcref` / `wasm_externref` separately; P1 collapses to a
single `wasm_module`-tagged handle… Phase-16 decides… how `wasm_fn` /
`funcref` / `externref` become first-class cljw Values." That is an *open
deferred structural decision* with a named owner — deleting its reservations
pre-empts it, which is an F-003 problem on top of the F-004 one.
`reader_conditional` likewise is unimplemented intent rather than dead intent:
`#?` is handled at read time (`eval/reader.zig:151, 861, 893`) so no Value is
needed *today*, but `read-string` with `:read-cond :preserve` returns a
`clojure.lang.ReaderConditional` object in Clojure, and cljw has no `:preserve`
support yet — the reservation is exactly the slot that feature will want. Only
`class`, `matcher`, `array_chunk`, `tuple`, `box` are genuinely dead intent, and
deleting five names buys nothing that marking them unallocated does not. What is
lost by deleting: the co-location intent (`wasm_fn` beside `wasm_module` in the
D12..D15 tail is a deliberate D-248 grouping), the pointer back to the deferring
debt row, and the ability to answer "why is there a gap here?" in two years.

**Q4 — is the split finished-form, or a second thing to keep in sync?** As
drafted — two hand-written enums plus a runtime assertion — it is a second thing
to keep in sync, and it is the *third* such structure in this file family
(HeapTag, `Value.Tag`, and now the split), guarded by a seven-assertion
spot-check test rather than a proof. That is the same class of defect ADR-0178
just fixed in `placement.yaml`, and the smell sensor should fire on it. It
becomes finished-form only if the mapping is **derived** from one declaration —
Alt 2. The reviewer's instinct here is correct and should be the ADR's decision.

**Q5 — what should the gate actually assert?** Note first that the failure mode
is *counting*, and that grep is not a counting instrument: my own scripted
census produced a false negative on `@"volatile"` (the Zig `@"…"` escape
defeats a `\.volatile\b` pattern; `volatile.zig:36` encodes it) and false
positives on `matcher` (prose and Java method names spell `.matcher`). A
grep-based "no tag is unreferenced" check would reproduce the original error
with new decoration. The gate must be:

1. **Type-level where possible.** In Alt 2, "every tag passed to
   `encodeHeapPtr` is in the Value-tag set" is not an assertion — it is the
   function signature, checked by the compiler at every one of the ~150 call
   sites. Prefer this over any runtime check.
2. **Observed-set, derived from execution — the ADR-0178 shape.** Under
   `builtin.is_test` (or a Debug-only build flag), have `encodeHeapPtr` and
   `HeapHeader.init` each set a bit in a static 64-/256-wide bitset. Run
   `zig build test` ×2 plus the full corpus, dump the two observed sets, and
   diff against a checked-in expectation. This converts "is this tag used" from
   a textual guess into an execution fact, catches computed-tag sites (which is
   exactly what the draft missed on `hamt_map_node`), and distinguishes
   test-only from production coverage if the two runs are kept separate (which
   is what the draft missed on `wasm_funcref`).
3. **Census closure — the check that would have caught both errors.**
   `comptime` assert that {boxed} ∪ {heap-only} ∪ {unallocated} **partitions**
   the enum: pairwise disjoint, union exhaustive, `|union| == fields.len`. The
   2026-08-04 audit failed by counting names and not uses; the draft failed by
   producing three counts summing to 63. A partition assertion fails loudly on
   both.
4. **Full-field sync, not spot-checks.** Replace `value.zig:468-478`'s seven
   hand-picked `expectEqual`s with an `inline for` over *every* field asserting
   name-and-value equality between the two enums plus equal field counts — or
   delete the mirror entirely by generating it (Alt 2).
5. **Cheap exact statics:** `fields.len <= 64` for the boxable set; every
   boxable value `< 64`; table lengths derived from `@typeInfo` rather than
   literal `64`/`70`; and the existing `Runtime.init` invariant ("every tag with
   a registered trace or finaliser is GcManaged", `runtime.zig:609`) extended to
   "…and is in the heap-tag set".
6. **Make the expected set the SSOT and fail in both directions** — an unlisted
   tag that gets exercised fails, and a listed tag that never gets exercised
   fails. One-directional gates are how a stale claim survives, which is the
   D-177 lesson `.claude/rules/clj_diff_sweep.md` already records.

## Resolution

**Alternative 2's principle is adopted — boxability becomes a property the
compiler checks — in the form its own cost analysis shows is actually
required.**

The fork priced Alt 2 at "1,666 references and 81 switch sites must be
re-typed". Measured, that is not what the change costs: **182 of
`encodeHeapPtr`'s 184 call sites pass an enum literal**, and a Zig enum literal
coerces by name to whatever enum the parameter declares, so they need no edit at
all. Exactly one site passes a computed tag (`map.zig:695`). The 1,666 figure
counts every `HeapTag` reference, and the great majority of those legitimately
stay on `HeapTag` — they are heap-header and dispatch uses, which is the whole
point of the distinction. So the enforcement is available at a fraction of the
quoted cost, and the cost was the only argument for preferring Alt 1.

What is adopted:

- **Compile-time enforcement** (Alt 2's prize) via a `comptime` boxable
  predicate on `encodeHeapPtr`, with the single computed site routed through an
  explicit runtime-checked entry point. A non-boxable tag becomes a compile
  error at the call site.
- **The comptime census-closure partition** (fork Q5.3), which is the check that
  fails on both the audit's error and all three of mine.
- **Nothing deleted or renamed** (fork's leading recommendation), for the F-004
  day-1-type-set and F-003 D-259 reasons it sets out.

What is deferred, with reasons:

- **Generating `ValueTag` / `Value.Tag` via `@Type`** (Alt 2's derivation half).
  The fork is right that a second hand-maintained enum would be the ADR-0178
  defect repeated. This ADR therefore does not create one — it adds a comptime
  *predicate over the existing enum*, not a parallel type. Generating the
  existing `Value.Tag` mirror away is a real improvement and a separate unit;
  it is not needed for the capacity correction and would change
  `__native-type`'s observable keyword surface.
- **Alt 3's `extended` escape hatch.** Correctly identified as a direct cost to
  `tag()`, one of the hottest functions in the runtime, and gap area III owns
  that trade. It also is not needed: 11 free addresses is not a ceiling anyone
  is pressed against.
- **Relocating `tail_node` / `tval` above 63** to free their two addresses.
  Loop-owned per D-043 (order, not type set) and non-breaking per the same
  precedent, but it buys 2 of 11 addresses at the cost of touching the group-band
  invariant — worth doing in the cycle that actually needs an address, not
  speculatively.

## Consequences

- The handover no longer carries "the tag space is full and only the user can
  unblock it". It carries a measured census and a precisely-scoped user
  question.
- A future attempt to box a heap-only tag fails at compile time.
- A future census that does not close fails at build time, with the arithmetic
  in the message.
- Cost: `encodeHeapPtr` gains a `comptime` parameter, which forbids a
  runtime-tag call — deliberately, since the one legitimate such call is now
  explicit and named.
- The three counting errors are recorded rather than quietly fixed, because the
  pattern (a syntactic test standing in for an execution fact) is the reusable
  part.

## Affected files

- `src/runtime/value/heap_tag.zig` — census, boxable predicate, partition assert
- `src/runtime/value/value.zig` — `encodeHeapPtr` comptime tag,
  `encodeHeapPtrRuntime`
- `src/runtime/collection/map.zig` — the one computed-tag site
- `.dev/handover.md` — the corrected statement

## Revision history

- 2026-08-04: Status: Proposed → Accepted. Alternative 2's enforcement adopted
  at its measured cost; its derivation half deferred as a separate unit;
  nothing deleted per the fork's leading recommendation.
