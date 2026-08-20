# 0053 — General 3-way `compare` (clojure.lang.Util.compare)

**Status**: Accepted (Devil's-advocate fork landed 2026-05-29)
**Date**: 2026-05-29
**Author**: Shota Kudo (drafted with Claude autonomous loop)
**Tags**: correctness-bug, compare, ordering, F-005, F-009, D-137, sibling-of-ADR-0052

## Context

`compare` in cw v1 is numeric-only (`math.zig` arity-2 + `ensureNumeric`
+ f64/i64 compare), so `(compare :a :b)` / `(compare "a" "b")` /
`(compare [1] [2])` raise type_error; only numbers compare. JVM
`clojure.lang.Util.compare` is a general 3-way comparator. This is the
direct sibling of D-136/ADR-0052 (universal `=`); it blocks
`sort`/`sort-by` (deferred behind it) + future sorted-map/sorted-set.

Survey: `private/notes/phase14-D137-compare-survey.md`. Mirrors ADR-0052
/ `runtime/equal.zig` structurally, with three crux differences:
3-way (`std.math.Order`); numeric **crosses the tower with NO category
gate** (`(compare 1 1.0)`→0 — opposite of `=`'s F-005 gate); mismatched
types **RAISE** (compare is not under the never-raise contract `=` has).

## Decision

### D1: `valueCompare` in a new neutral `runtime/compare.zig`

`pub fn valueCompare(rt, a, b, loc) anyerror!std.math.Order`. A **new
sibling file** to `equal.zig` (NOT folded in): the two numeric arms are
structurally opposite (F-005 category gate vs no-gate), and a shared
file where "the numeric arm" means two contradictory things is a
maintainer hazard. ROADMAP A2 ("new features via new files") + F-009.
The `compare` primitive becomes a thin wrapper returning a -1/0/1
integer Value. Takes `loc` because it raises on uncomparable pairs.

### D2: dispatch (JVM Util.compare order)

1. identity (`@intFromEnum` eq) → `.eq`.
2. **nil lowest**: nil vs nil → eq; nil vs x → lt; x vs nil → gt.
3. **numeric arm — HYBRID** (both numeric): same-category exact via the
   existing Order fns (`int` i48 `std.math.order`; big_int↔big_int
   `big_int.compareManaged`; ratio↔ratio `ratio.compareValue`;
   decimal↔decimal `big_decimal.compareValue`); genuinely mixed-tower
   (any float, or cross big-category) → `promote.toF64` collapse
   (matches cw's existing `<`/`>`). **No category gate** (crosses
   tower per F-005). Exact cross-category compare → **deferred** to the
   numeric combine ladder (D-014a family — same dependency that gates
   cross-category `==` in ADR-0052 D3; it also carries the NaN-ordering
   subtlety: JVM `(compare ##NaN 1)`→1 while `(< ##NaN 1)`→false).
4. string → `std.mem.order` (lexicographic) → lt/eq/gt.
5. char → `asChar` u21 `std.math.order`.
6. bool → false < true.
7. keyword / symbol → ns-then-name: nil-ns sorts before non-nil-ns,
   then `std.mem.order(ns)`, tiebreak `std.mem.order(name)`. Accessors
   confirmed: `keyword.asKeyword(v).ns/.name`, `symbol.asSymbol(v).ns/.name`.
8. vector → **length-first** then element-wise recursion
   (`APersistentVector.compareTo`: shorter < longer; equal length →
   first differing element).
9. else (mismatched / uncomparable, incl. **lists** — not Comparable in
   JVM) → raise `type_error` (same observable as JVM's CCE).

### D3: sort/sort-by follow-up — stable-sort MANDATE (separate cycle)

This unblocks `sort`/`sort-by` (D-134, deferred behind D-137). The sort
**algorithm** is a separate cycle (it needs eager materialisation + a
comparator closure). **The follow-up MUST use a stable sort** — Clojure
`sort` is stable; `std.sort.pdq` / `std.sort.block` are NOT guaranteed
stable. A hand-rolled stable mergesort over a materialised vector with
`valueCompare` as comparator is the target. Stability is a **contract,
not an optimisation**: the next cycle's smell sensor must treat "just
use `std.sort.pdq`" as a correctness regression. Recorded now so the
sort cycle cannot silently ship an unstable sort.

## Alternatives considered

Devil's-advocate fork (general-purpose, fresh context, 2026-05-29,
F-005/F-009/F-002 envelope) output verbatim:

**Envelope reminder.** F-005 fixes the numeric *direction*: `compare` crosses the tower with **no category gate** (`(compare 1 1.0)`→0) — the opposite of `=`'s gate, and NOT open. F-009 fixes the *location*: neutral `runtime/` impl, thin `math.zig` `compare` wrapper — NOT open. F-002: cycle/diff/LOC is not a constraint; only a real dependency justifies deferral. The genuinely open axes are: (1) mixed-tower numeric **precision**, (2) **file placement** (new `compare.zig` vs fold into `equal.zig`), (3) **kw/sym** scope, (4) **list** compare, (5) **stable-sort mandate** for the sort follow-up. **No alternative below requires an F-NNN amendment** — the accessors for kw/sym ns·name exist (`keyword.asKeyword`/`symbol.asSymbol`, confirmed), the same-category Order fns exist (`big_int.compareManaged`/`ratio.compareValue`/`big_decimal.compareValue`), and `promote.toF64` exists. The only thing that does NOT exist is a unified cross-category numeric `Order` ladder (`comparePromoting`) — that is the one real dependency in play, and it is the SAME ladder D-136/ADR-0052 deferred cross-category `==` behind (D-014a family).

### Alt 1 — Smallest-diff

(a) **All in one file**: extend `equal.zig` (do NOT add `compare.zig`). Add `valueCompare(rt, a, b, loc) anyerror!std.math.Order` beside `valueEqual`, reusing the in-file `numCat`/`isSequential`/`Cursor` directly (no import, no duplication). **Numeric arm = pure f64-collapse** for everything via `promote.toF64(a)` vs `toF64(b)` — exactly mirrors the current `compare` body + `pairwise` + `<`/`>`. nil-lowest + identity fast-path + string (`std.mem.order`) + bool + kw/sym (ns-then-name) + vector (length-first). **List → raise** (uncomparable, mirrors JVM). **kw/sym INCLUDED** (accessors exist, trivial). Rewire `math.zig` compare to call it, drop `ensureNumeric`. Sort follow-up: **no stability mandate** — use `std.sort.pdq` (fast, unstable) and document the divergence.

(b) Better: smallest surface — one file touched in `runtime/`, helpers shared with zero duplication, the numeric arm is ~4 lines (one `toF64` pair + `std.math.order`). Numeric behaviour is byte-identical to the existing `<`/`>`/`compare` surface, so there is zero new numeric-precision *inconsistency* introduced — `(compare big big)` is exactly as imprecise as `(< big big)` already is. Lands the whole D-137 fix + unblocks D-134 sort in minimal diff.

(c) Breaks / risks: **(i) the shared-file numeric-semantics trap.** `equal.zig`'s numeric arm is **category-GATED** (F-005, `if (ca != cb) return false`); `compare`'s is **un-gated** (crosses tower). Two functions in one file where "numeric arm" means structurally-opposite things is exactly the confusion the survey §5 flagged — a future reader patching one gate risks touching the other. **(ii) f64-collapse for same-category big values is a needless precision regression** vs free precision: `(compare 1N (inc (bit-shift-left 1 60)))` collapses two distinct big_ints to equal f64 and returns `0` (wrong) even though `big_int.compareManaged` is sitting right there returning the exact Order for free — `valueEqual` already calls it. Using f64 where an exact same-category Order fn exists and is already imported is a *silent wrong answer* with no dependency excuse (worse than the `<`/`>` case, which has no such fn wired). **(iii) unstable sort** makes `(sort-by f coll)` reorder f-equal elements — observably non-Clojure; `sort` stability is part of the contract, not an optimisation.

### Alt 2 — Finished-form-clean (recommended)

(a) **New `src/runtime/compare.zig`** (Zone 0, sibling of `equal.zig`, F-009 + ROADMAP A2 "new features via new files"). It duplicates the *tiny* helper shapes it needs (`numCat`, length-first vector walk) rather than importing `equal.zig`, because the two files' numeric arms are deliberately opposite (gate vs no-gate) and must not share a "numeric arm" abstraction. Signature `valueCompare(rt, a, b, loc) anyerror!std.math.Order` (`loc` needed because compare RAISES on uncomparable, unlike `valueEqual`). Dispatch: identity→`.eq`; nil-lowest; **numeric HYBRID** (see below); string `std.mem.order`; bool false<true; kw/sym ns-then-name (nil-ns sorts first, then `std.mem.order(ns)`, tiebreak `std.mem.order(name)`); vector **length-first** then element-wise recursion; **char** (`asChar` u21 → `std.math.order`, ~3 LOC, observable under F-005); else → `type_error`. **List → raise** via the else-arm (JVM throws; cw raises clean `type_error` — same observable). **Numeric hybrid**: int/int → i48 direct `std.math.order`; both same big-category → the existing `compareValue`/`compareManaged` (exact, free, already returns Order); **any float involved OR genuinely-mixed big-categories (e.g. ratio↔decimal, big_int↔ratio) → `toF64`-collapse** (matches `<`/`>` precision behaviour). Cross-category-EXACT numeric compare → **DEFER** to the numeric-combine ladder (D-014a family, the same row that gates cross-category `==`). Sort follow-up: **mandate stable sort** in the ADR (the follow-up cycle uses a stable mergesort over a materialised vector with `valueCompare` as comparator), but the sort *algorithm* is a **separate cycle** — this ADR only records the *mandate*, not the impl.

(b) Better: (i) same-category big/ratio/decimal compares are **exact for free** by routing to the Order fns that already exist and that `valueEqual` already calls — no silent `(compare 1N hugeN)`→0 lie. (ii) Separate file keeps the gate/no-gate semantics from colliding — a reader of `compare.zig` sees "numeric crosses tower" without the F-005 gate noise, and a reader of `equal.zig` sees the gate without the crossing noise. (iii) kw/sym/char/vector/bool all land now (every accessor exists; no dependency forces a defer — deferring any of them would be a pure Cycle-budget defer smell). (iv) The single deferral (exact cross-category) is anchored to a **real** missing primitive (`comparePromoting`), identical in kind to ADR-0052's cross-category `==` defer — provable as dependency-driven, not budget-driven. (v) Recording the stable-sort mandate now prevents the sort cycle from silently shipping `std.sort.pdq` (unstable) and diverging from Clojure's stable `sort`.

(c) Breaks / risks: (i) a few helper shapes (`numCat`, length-first walk) are duplicated between `equal.zig` and `compare.zig` — mild DRY cost, justified by the opposite-semantics argument; if it grates later, a third `numeric_category.zig` could host `numCat` for both (out of scope now). (ii) the hybrid's "mixed big-category → f64" branch is a documented precision limit, not exact JVM parity — but it matches cw's own `<`/`>` and the exact path is a genuine dependency, so this is a DIVERGENCE-with-rationale, not a lie (and same-category, the common constructible case, stays exact). (iii) larger cycle than Alt 1 (the hybrid ladder + char arm + a real ADR) — but F-002 explicitly removes cycle size as a constraint.

### Alt 3 — Wildcard

(a) **Build the cross-category numeric `Order` ladder NOW** (`promote.comparePromoting(rt, a, b) !std.math.Order`) and make BOTH `compare`'s numeric arm AND the deferred cross-category `==` ride it — i.e. fold the D-014a-family numeric-combine dependency into this cycle. `comparePromoting` would mirror `addPromoting`'s contagion ladder (decimal > ratio > float > integer) but compute an Order instead of a Value: promote both operands to the widest category via `coerceToManaged`/ratio cross-multiply/big_decimal scale-align, then call the existing same-category Order fn. With it, `compare`'s numeric arm becomes a single `comparePromoting` call (exact across the whole tower, no f64 anywhere), `==`'s cross-category gap (ADR-0052 D3) closes for free, and `valueCompare` over numbers is fully JVM-exact. `compare.zig` as in Alt 2 for the non-numeric arms; stable-sort mandate as Alt 2.

(b) Better: the **complete** Clojure numeric-comparison story in one shot — `(compare 1N (inc (bit-shift-left 1 60)))`, `(compare 1/3 0.333M)`, `(== 1N 1.0)` all exact; eliminates the D-014a-family follow-up for both `compare` and `==`; no f64 precision footnote anywhere; the numeric surface (`<`/`>`/`<=`/`>=` could later route through the same Order ladder too) becomes uniformly exact.

(c) Breaks / risks: this is a **genuine dependency-bearing scope jump that belongs to its own cycle**, distinct from a cycle-budget defer. `comparePromoting` is the D-014a-family combine ladder — building it correctly means: float↔ratio comparison (a float is not exactly a ratio; needs a defined rounding/exactness rule matching `Numbers.java`'s `ratioToBigInteger`/`toBigDecimal` paths), big_decimal↔ratio scale-alignment, NaN ordering (JVM `Numbers.compare` has specific NaN behaviour: `Double.compare` sorts NaN as greatest, which `<` does NOT — so the ladder is NOT just "reuse `<`"), and a re-audit of how `<`/`>`/`==` should *also* migrate onto it for consistency. That is its own correctness surface with its own test matrix (the NaN-ordering subtlety alone is a trap: `(compare ##NaN 1)` returns `1` in JVM but `(< ##NaN 1)` is `false`). Folding it into the `compare`-3-way cycle couples two independently-testable fixes and enlarges blast radius across the entire numeric-comparison family. **This is the ADR-0052-Alt-3 shape exactly**: a real dependency boundary (there, hash/eq-consistency → D-092; here, the exact cross-tower combine ladder + NaN-order semantics → D-014a family), so deferring it is NOT a Cycle-budget defer smell — it is respecting a legitimate correctness boundary.

### Recommendation (non-binding) — Alt 2

Answering the five axes: (1) numeric **HYBRID** (same-category exact via existing Order fns; mixed-tower f64-collapse matching `<`/`>`; cross-category-exact deferred to the D-014a combine ladder — pure-f64 Alt 1 ships the `(compare 1N hugeN)`→0 lie and is the Cycle-budget defer smell). (2) **New `compare.zig`** (opposite numeric semantics from `equal.zig` — shared file is a hazard; A2 + F-009). (3) kw/sym **INCLUDE now** (accessors confirmed; deferring = pure cycle-budget smell). (4) list **RAISE** via else-arm (mirrors JVM CCE; not a divergence). (5) stable-sort **MANDATE in ADR, IMPLEMENT in a separate cycle** (stability is a contract; the sort algorithm needs materialisation + comparator closure = own cycle). Alt 2 over Alt 1: Alt 1's wins (one file, pure-f64) are anti-finished-form, held back only by diff size. Alt 2 over Alt 3: Alt 3 crosses the real D-014a combine-ladder boundary (NaN-ordering + float↔ratio exactness) without a correctness gain to the 3-way story that same-category-exact + mixed-f64 doesn't already deliver for every Phase-14-constructible value.

## Selection rationale

Alt 2. Same-category numeric compares are exact for free (the Order fns
`valueEqual` already uses); mixed-tower f64 matches cw's own `<`/`>`;
the one deferral (exact cross-category) is the real D-014a combine-ladder
dependency (with its NaN-ordering trap), not a budget punt. New
`compare.zig` keeps the gate/no-gate numeric semantics from colliding
with `equal.zig`. kw/sym/char/vector/bool all land (accessors confirmed).
List-raises mirrors JVM. Stable-sort mandated for the follow-up cycle.

## Consequences

- New `src/runtime/compare.zig` (`valueCompare`); `math.zig` `compare`
  rewired to it (drops `ensureNumeric`; returns -1/0/1). Tier A by
  clojure.core aggregate.
- The `math.zig` "non-numeric compare → type_error" test narrows to a
  genuinely-uncomparable pair (e.g. `(compare 1 "a")`), since most
  former type_errors now succeed.
- **Unblocks D-134 sort/sort-by** — separate cycle, MUST use a stable
  sort (D3).
- Deferred: exact cross-category numeric compare + NaN-ordering →
  D-014a-family combine ladder (same dep as cross-category `==`);
  sorted-map / sorted-set ordering.
- DIVERGENCE: mixed-tower big-category compare uses f64-collapse (matches
  cw `<`/`>`), not exact — documented limit, not a silent lie
  (same-category stays exact).

## Affected files

- `src/runtime/compare.zig` (new) · `src/lang/primitive/math.zig`
  (compare rewire) · `test/e2e/phase14_compare.sh` (new) ·
  `.dev/debt.yaml` (D-137 discharge).

## Revision history

- 2026-05-29 issued + accepted with Devil's-advocate fork
  (general-purpose, fresh context, F-005/F-009/F-002 envelope, 3
  alternatives verbatim, Alt 2 selected). Sibling of ADR-0052; fixes the
  numeric-only `compare` bug (D-137). Numeric crosses the tower (no
  category gate, per F-005 — opposite of `=`); mismatched types raise.
