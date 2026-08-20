# ADR-0061 — Java static field resolution: `Class/FIELD` bare symbol → `TypeDescriptor.static_fields`

- **Status**: Accepted
- **Date**: 2026-05-31
- **Phase**: Phase 14 (post-v0.1.0 coverage) / cluster A26 (clj differential sweep)
- **Supersedes**: —
- **Superseded by**: —

## Context

`(Integer/parseInt "42")` (a call, WITH parens) works: `analyzeList`
(`analyzer.zig:498-515`) resolves the qualified head via
`special_forms.resolveJavaSurface(rt, env, ns_head)` + `td.lookupMethod`
→ an `InteropCallNode { .kind = .static_method }`. But a bare qualified
symbol `Integer/MAX_VALUE` (no parens, a static FIELD read) goes through
`analyzeSymbol` (`analyzer.zig:402-450`), whose qualified-symbol arm
resolves the namespace via `aliases.get(ns) orelse env.findNs(ns) orelse
raise(.namespace_unknown)` (L425-428). "Integer" is not a Clojure
namespace (the surface is registered in `rt.types` as
`cljw.java.lang.Integer`, not as an Env namespace), so `findNs` → null →
`namespace_unknown`. There is **no static-field resolution path**.

clj-verified targets (cluster A26): `Integer/MAX_VALUE` 2147483647,
`Integer/MIN_VALUE` -2147483648, `Long/MAX_VALUE` 9223372036854775807,
`Long/MIN_VALUE` -9223372036854775808, `Double/MAX_VALUE`
1.7976931348623157E308, `Double/MIN_VALUE` 4.9E-324.

The static-method path proves the resolution machinery exists; the field
path is the missing symmetric half.

## Decision

A Java surface's `TypeDescriptor` owns **both** its static methods
(`method_table`, consumed by `analyzeList`) and its static fields
(a new `static_fields` slot, consumed by `analyzeSymbol`). A bare
`Class/FIELD` and a `(Class/method …)` resolve the **identical**
`*const TypeDescriptor` via `resolveJavaSurface` and then ask that
descriptor — `lookupStaticField` vs `lookupMethod`. **Symmetry is the
invariant**: future fields follow the method recipe; one resolution
path, one registry, two parallel lookups (F-011 commonisation; mirrors
Java's `Class` owning both tables, without any JVM-internals
assumption per `no_jvm_specific_assumption.md`).

1. **`TypeDescriptor.static_fields: []const StaticField = &.{}`**
   (defaulted, so every existing descriptor literal — Math / System /
   deftype / defrecord / reify — is untouched, exactly as the
   `ref_cache: ?Value = null` precedent shows). `StaticField =
   struct { name, value: StaticFieldValue }`,
   `StaticFieldValue = union(enum) { int: i64, float: f64 }`. Plus
   `lookupStaticField(name) ?*const StaticField` (linear, parallel to
   `lookupMethod`).

2. **`static_fields` is comptime-const, populated in the descriptor
   literal — NOT in `init`.** This is the load-bearing asymmetry vs
   `method_table`: a `MethodEntry` holds `Value.initBuiltinFn(&fn)`,
   whose `@intFromPtr(fn)` is **not** comptime-known on Mac, forcing
   `method_table` to be GPA-built in `init` and freed in `deinit`
   (`_host_api.zig:46-61`). A `StaticField` holds only an `i64`/`f64`
   scalar + a string-literal name — **all comptime-known** — so each
   surface declares a module-scope `const` array and sets
   `.static_fields = &integer_static_fields` directly in the
   descriptor literal. `installAll`'s `td.* = ext.descriptor.*`
   duplicates the slice *pointer* to the process-lifetime comptime
   array; **no `init` alloc, no `deinit` free** (and a future
   "tidy for consistency" pass must NOT move it into `init` or free it
   in `deinit` — a one-line comment on the field records this).

3. **`analyzeSymbol` field arm** (before the `namespace_unknown`
   raise): when a qualified symbol's ns resolves via
   `resolveJavaSurface(env.rt, env, ns)` AND `td.lookupStaticField
   (sym.name)` hits → `makeConstant(arena, val, form)` where
   `val` = `integerLiteralToValue(rt, i)` for `.int` (i48 → Long,
   beyond → BigInt — the EXISTING literal path, `analyzer.zig:277`)
   / `Value.initFloat(f)` for `.float`. Otherwise the existing
   `namespace_unknown` raise stands.

4. **Integer / Long / Double surfaces** declare comptime
   `static_fields` arrays (MAX_VALUE / MIN_VALUE; Double adds the two
   bound constants).

**Dual-backend parity (ADR-0036)**: `Class/FIELD` resolves to a
`.constant` Node at analyze time, exactly as integer/float literals do.
Both backends consume the same Node tree → identical constant Value, no
per-backend code, parity-trivial by construction.

**DIVERGENCE inherited, not introduced (D-165, F-005)**: `Long/MAX_VALUE`
/ `MIN_VALUE` exceed i48 (F-004), so `integerLiteralToValue` lifts them
to a heap BigInt — exact value, but prints `…N` where JVM prints a bare
Long. This is the same i48-NaN-box consequence already recorded as D-165
for `parse-long` / `Long/parseLong`; it is **inherited** from the shared
literal path, not re-introduced here, and stays owned by the
numeric-tower owner (F-003). `Integer/*` (fit i48 → clean Long) and
`Double/*` (floats) match clj exactly.

## Alternatives considered

The following is the Devil's-advocate subagent's verbatim output (fresh
context, briefed with the verified file:line facts + the F-NNN
envelope). Its recommendation (Alt 2) is the shape adopted above.

---

## Devil's-advocate: Alternatives considered

**F-NNN gate result up front:** None of the three alternatives below requires violating an F-NNN. All three resolve `Class/FIELD` and store the field value somewhere reachable from `analyzeSymbol`, all produce a `.constant` Node (so ADR-0036 dual-backend parity is untouched — see the cross-cutting flag), and all three land the Long/MAX_VALUE BigInt the same clean way the draft does (via the existing `integerLiteralToValue`, no init-time heap alloc). The tensions are entirely *within* the envelope: where the field registry lives (a `TypeDescriptor` slot vs a per-surface fn vs a central map vs a `def`-injected magic var), and whether to reuse the existing method-table mechanism or add a parallel one. F-005 + D-165 (Long/MAX_VALUE prints `…N` as a BigInt) is a recorded divergence none of these alternatives can or should "fix" — it is owned by the numeric-tower owner. **No forced "leading entry" F-NNN-block disclosure is needed** — the clean shape is reachable.

One verified-fact correction the alternatives lean on: the draft's claim that StaticField "needs NO `init`-time gpa allocation, NO `rt.deinit` free" because it is a comptime `const` array is **correct as stated for the value payload** (`i64`/`f64` scalars + string-literal names are comptime-known, unlike `Value.initBuiltinFn(&fn)` which calls `@intFromPtr` and is not comptime on Mac — that is precisely why `method_table` *must* be built in `init` and freed in `deinit`, per `_host_api.zig:46-61`). So the draft's StaticField genuinely rides as `.static_fields = &integer_static_fields` in the descriptor literal, and the `installAll` heap-copy (`_host_api.zig:127` `td.* = ext.descriptor.*`) just duplicates the slice *pointer* to the process-lifetime comptime array — no free needed, no `deinit` edit. This asymmetry (fields are comptime-const, methods are not) is real and is the draft's strongest structural argument; the alternatives are judged against it.

---

### Alternative 1 — Smallest-diff: a per-surface `lookupStaticField` fn that returns the *raw scalar*, computed-to-Value at the analyzer call site (no `StaticFieldValue` union, no new struct on the hot path)

Keep the registry in each surface, but instead of the draft's `static_fields: []const StaticField` slice + `StaticFieldValue` union + `lookupStaticField` on `TypeDescriptor`, give each surface module a free function `pub fn staticField(name: []const u8) ?ScalarField` where `ScalarField = union(enum){ int: i64, float: f64 }`, and have `analyzeSymbol` reach it through a tiny dispatch the same way `resolveJavaSurface` reaches the descriptor. The descriptor itself gains **nothing** — `TypeDescriptor` stays exactly as it is today.

**What it does better than the draft:**
- Touches `type_descriptor.zig` (a runtime-core, hot, F-009-carve-out file that every dispatch path includes) **zero times**. The draft adds two new types (`StaticField`, `StaticFieldValue`) + a `static_fields` field + a `lookupStaticField` method to `TypeDescriptor`, permanently widening the struct that `instance?`/`extends?`/`satisfies?`/the CallSite cache all carry around, for a feature (bare static-field read) that only 3 surfaces in `java.lang` will ever use.
- Keeps the field registry physically next to the methods it sits beside in the same surface file, so `rg MAX_VALUE src/runtime/java/lang/Integer.zig` finds it with zero indirection (feature-name-consistency R1 grep-100%).

**What it breaks / risks:**
- It **breaks the `analyzeSymbol`/`analyzeList` symmetry** the draft preserves (question (d)). `analyzeList`'s `(Class/method …)` arm resolves a `*const TypeDescriptor` via `resolveJavaSurface` and then asks the *descriptor* `td.lookupMethod(...)`. Alt 1 would have `analyzeSymbol` resolve the descriptor for the namespace head but then **bypass** it to call a free `staticField` fn keyed by some side-channel (the surface module, not the descriptor) — so field-read and method-call resolve through two different mechanisms for the same `Class/`. That is exactly the kind of "two ways to do one thing" the project's commonization invariant (F-011) forbids.
- The side-channel is the real problem: `resolveJavaSurface` hands back a `*const TypeDescriptor`, not the surface module. To reach a per-module free fn you need a *second* registry mapping fqcn → fn-pointer, which is strictly more machinery than the draft's one slot, defeating the "smaller" claim. The only way to avoid the second registry is to put a `static_field_fn: ?*const fn(...)` pointer on the descriptor — at which point you are back to editing `TypeDescriptor`, but with a non-comptime fn-pointer field (re-introducing the `init`-time-alloc + `deinit`-free burden the draft specifically *avoids* by using comptime scalars).
- So Alt 1's "don't touch `TypeDescriptor`" is a smallest-diff-against-current-bits choice that is *not* smallest-diff-against-finished-form: it optimizes "don't widen the struct" at the cost of a parallel resolution mechanism and a second registry.

**Explicit answers:**
- (a) BigInt for Long/MAX_VALUE: handled identically to the draft — the analyzer call site does `.int => integerLiteralToValue(rt, i)`, so 9.2e18 lifts to a heap BigInt at analyze time. Clean. ✓
- (b) GC/lifetime: the `.constant` Node holds the Value; the Node lives in the analyzer arena (per-program lifetime), the BigInt lives on `rt.gc` and is reachable from the constant Node, so it is GC-rooted exactly like an integer literal. ✓ (Identical to the draft.)
- (c) reflection: only value reads are needed — no path requires `(class Integer/MAX_VALUE)` to *find* the field; `(class Integer/MAX_VALUE)` resolves the field to a `Long`/`Double` Value first, then `class` runs on that Value. So no field-on-descriptor reflection requirement. ✓ (True of all three alts.)
- (d) `analyzeSymbol`/`analyzeList` symmetry: **No** — this is the alternative's central weakness. Field-read and method-call resolve through different mechanisms.

---

### Alternative 2 — Finished-form-clean: the draft's `TypeDescriptor.static_fields` slot, sharpened so field-read and method-read are the *same* descriptor-keyed lookup shape (the draft, made symmetric and the comptime-vs-init asymmetry recorded as the invariant)

This is the draft, kept, with three sharpenings rather than changes:

1. **Symmetry is the invariant, not a coincidence.** The draft already lands `lookupStaticField` on `TypeDescriptor` parallel to `lookupMethod`, and `analyzeSymbol` reaches it via `resolveJavaSurface(env.rt, env, ns)` — the *same* helper `analyzeList` uses for `(Class/method …)`. The finished-form framing makes that explicit: **both a bare `Class/FIELD` and a `(Class/method …)` resolve the identical `*const TypeDescriptor` and then ask that descriptor** (`lookupStaticField` vs `lookupMethod`). One resolution path, one registry, two parallel lookups on the same object. This is the F-011 commonization win Alt 1 forfeits, and it mirrors the Java `Class` model (a class carries both its methods and its static fields) without assuming any JVM internals (`no_jvm_specific_assumption.md` — we are modelling Clojure's `Class/FIELD` surface, not JVM bytecode).

2. **The comptime-scalar-vs-non-comptime-fn asymmetry is recorded as the reason the two slots are populated differently.** `method_table` is GPA-built in `init` and freed in `deinit` *because* `Value.initBuiltinFn(&fn)` is not comptime on Mac (`_host_api.zig:46-61`). `static_fields` is a module-scope comptime `const` array set directly in the descriptor literal *because* `i64`/`f64` scalars + string-literal names **are** comptime-known. A one-line comment on the `static_fields` field records this: "comptime-const (scalars + literal names), so unlike `method_table` it needs no `init`-time alloc and no `deinit` free; `installAll`'s `td.* = ext.descriptor.*` duplicates the slice pointer to the process-lifetime comptime array." Without that note a future maintainer "tidying for consistency" might move `static_fields` into `init` (pointless alloc) or, worse, add a `deinit` free of a comptime array (crash). The asymmetry is finished-form-correct; the comment defends it.

3. **`StaticFieldValue` is scoped to exactly the two scalar shapes the numeric tower can lift cleanly at analyze time** (`int: i64`, `float: f64`) and `analyzeSymbol` converts via the existing `integerLiteralToValue(rt, i)` / `Value.initFloat(f)`. This is the same path the integer/float *literal* reader already uses (analyzer.zig:277, the D-014a discharge), so `Long/MAX_VALUE` becomes a heap BigInt by the *one* existing mechanism, and D-165 (BigInt-print divergence) is inherited from that mechanism rather than re-introduced — there is literally no new numeric code, which is why the divergence stays owned by the numeric-tower owner.

**What it does better than the draft-as-written:**
- The draft says "parallel to lookupMethod" but does not *commit* to symmetry as the invariant; Alt 2 makes "field-read and method-read are the same descriptor-keyed shape" the load-bearing property, so a future `Class/FIELD2` or a future surface adds fields by the same recipe it adds methods — one mental model (the keyword/symbol-interning precedent ADR-0059 set, applied here to "the class carries both tables").
- It records *why* the two slots are populated asymmetrically, closing the maintenance hazard the draft leaves implicit (the "tidy for consistency" trap).

**What it breaks / risks:**
- It widens `TypeDescriptor` by one slice field (`static_fields: []const StaticField = &.{}`). The default `= &.{}` means Math/System/every deftype/defrecord/reify descriptor literal is **untouched** (the draft verified this against the `ref_cache: ?Value = null` precedent at type_descriptor.zig:69 — a defaulted field needs no edit at existing literal sites). The cost is ~16 bytes per descriptor on a process-lifetime struct (~25 of them); negligible. The honest risk is *conceptual*, not byte-count: `TypeDescriptor` now models "a class's static-field table", which is a small scope-creep on a struct whose docstring (type_descriptor.zig:43) frames it as the deftype/defrecord/reify type descriptor. Alt 2's answer: that creep is *correct* — Java's `java.lang.Integer` genuinely is a type that owns static fields, and the surface descriptors are `kind = .native` precisely to model host classes. The field is on the right object.
- Long/MAX_VALUE printing `9223372036854775807N` (BigInt suffix) where JVM prints a bare Long is a **visible divergence** (D-165). Alt 2 does not hide this — it inherits it from `integerLiteralToValue` and lets D-165's owner (numeric-tower) decide whether i48-vs-i64 inline-Long ever changes. Bundling a "fix" here would be the smallest-diff-bias trap of pre-empting an owner's decision (F-003).

**Explicit answers:**
- (a) BigInt for Long/MAX_VALUE: **cleanest of the three** — reuses `integerLiteralToValue` verbatim, zero new numeric code, divergence (D-165) inherited not introduced. ✓
- (b) GC/lifetime: `.constant` Node (arena, per-program) holds the Value; scalar ints/floats are inline NaN-box (no heap); the BigInt for Long/MAX_VALUE is on `rt.gc` reachable from the constant Node → GC-rooted like any literal. The `static_fields` array itself is process-lifetime comptime data (never freed, never traced — it holds raw scalars, not Values). ✓
- (c) reflection: value-read only; no descriptor-side field reflection needed. ✓
- (d) `analyzeSymbol`/`analyzeList` symmetry: **Yes — this is the alternative's defining virtue.** Same `resolveJavaSurface` → same `*const TypeDescriptor` → `lookupStaticField` (symbol path) vs `lookupMethod` (list path). One registry, one resolution, two parallel lookups.

---

### Alternative 3 — Wildcard: a central comptime `StaticStringMap` of fully-qualified `"Class/FIELD"` → pre-computable scalar, resolved in `analyzeSymbol` *before* `resolveJavaSurface`, surfaces carry no field data at all

Drop the per-surface registry entirely. Add one module-scope `std.StaticStringMap(ScalarField)` in the analyzer (or a small `runtime/java/static_fields.zig` leaf) keyed by the cljw-prefixed FQCN-plus-field string (`"cljw.java.lang.Integer/MAX_VALUE"` etc.), `.initComptime(.{ .{"…/MAX_VALUE", .{.int = 2147483647}}, … })`. `analyzeSymbol`, on a qualified symbol, first translates the ns head the way `resolveJavaSurface` does (literal / `cljw.` / `cljw.java.lang.` prefix), concatenates `"/FIELD"`, probes the map, and on a hit emits `makeConstant`. `TypeDescriptor` is **never** touched; the surfaces (Integer/Long/Double.zig) are **never** touched.

**What it does better than the draft:**
- Zero edits to `TypeDescriptor` *and* zero edits to the three surface files — the entire feature lands in one new leaf + one `analyzeSymbol` arm. It is the literally-smallest *blast radius across files*.
- The static-field set for `java.lang.*` is genuinely fixed and tiny (the MAX/MIN trio × 3 classes + a handful like `Double/POSITIVE_INFINITY`), and a `StaticStringMap` is the project's blessed idiom for exactly "a small fixed lookup table" (`zig_tips.md` § `comptime StaticStringMap`, used for keyword/opcode tables). The values are pure constants — there is no per-class behaviour to attach.

**What it breaks / risks:**
- **It severs the field data from the class it belongs to**, which is the same anti-pattern ADR-0059's Alt 3 was rejected for: a separate representation that then has to be re-bridged. `Integer/parseInt` lives on `Integer.zig`'s descriptor, but `Integer/MAX_VALUE` would live in a central map keyed by string — so the answer to "what does `Class/X` do" depends on whether `X` happens to be a method (descriptor) or a field (central map). That **fails grep-locality** (R1): `rg MAX_VALUE src/runtime/java/lang/Integer.zig` returns nothing; the reader must know to look in the central map. F-009's whole point is that a feature's data lives *with* the feature, discoverable by keyword.
- **It breaks `analyzeSymbol`/`analyzeList` symmetry worse than Alt 1** (question (d)): method-call resolves through `resolveJavaSurface` → descriptor → `lookupMethod`; field-read resolves through a string-concat → central map, never touching the descriptor at all. Two completely disjoint mechanisms for `Class/method` vs `Class/FIELD`. This is the strongest F-011 commonization violation of the three.
- **It duplicates `resolveJavaSurface`'s prefix-translation logic** (the literal / `cljw.` / `cljw.java.lang.` three-try cascade at special_forms.zig:54-66) inside the new arm to build the map key, or it has to call `resolveJavaSurface` to get the descriptor's `fqcn` and *then* concat `/FIELD` and probe the map — at which point it has already resolved the descriptor and is choosing *not* to ask it, which is strictly more steps than Alt 2's "ask the descriptor you already have."
- The "values are pure constants, no behaviour to attach" argument is true but proves too little: methods are *also* keyed by name on a per-class basis, and the project already chose to attach them to the descriptor. Fields are the same shape (per-class, name-keyed); the consistent finished form is "attach them the same place," which is Alt 2.

**Explicit answers:**
- (a) BigInt for Long/MAX_VALUE: handled the same as the others (the central map stores `.int = 9223372036854775807` and the arm calls `integerLiteralToValue`). Clean. ✓
- (b) GC/lifetime: identical to Alt 2 — `.constant` Node holds the Value, BigInt on `rt.gc` rooted from it, the `StaticStringMap` holds raw scalars (process-lifetime comptime, not Values). ✓
- (c) reflection: value-read only. ✓
- (d) `analyzeSymbol`/`analyzeList` symmetry: **No — the worst of the three.** Field and method resolution are fully disjoint; the descriptor is bypassed for fields entirely.

---

### Non-binding ranked recommendation

1. **Alt 2 (finished-form-clean: the draft's `TypeDescriptor.static_fields` slot, with symmetry made the invariant + the comptime-vs-init asymmetry recorded + numeric lift reusing `integerLiteralToValue`).** This is the draft's chosen direction, sharpened — not changed. It is the cleanest finished form: a `Class/` resolves to *one* `*const TypeDescriptor` and that descriptor owns *both* its methods (`lookupMethod`, used by `analyzeList`) and its static fields (`lookupStaticField`, used by `analyzeSymbol`), so field-read and method-call share one resolution path and one registry (F-011 commonization). It reuses the existing `integerLiteralToValue` for the Long/MAX_VALUE BigInt with zero new numeric code, so D-165's divergence is inherited (and stays owned by the numeric-tower owner per F-003), not re-introduced. The two things the ADR should *add* to the draft (not change): (i) state symmetry as the invariant — "field-read and method-read are the same descriptor-keyed lookup shape" — so future fields follow the method recipe; (ii) record the comptime-scalar-vs-non-comptime-fn asymmetry in a one-line comment on `static_fields`, so a future "tidy for consistency" pass cannot move it into `init` (pointless alloc) or add a `deinit` free of comptime data (crash).

2. **Alt 1 (per-surface `staticField` free fn, raw scalar computed at the call site).** Keeps the field data grep-local to the surface file (a genuine virtue) and avoids widening `TypeDescriptor`, but it forfeits the `analyzeSymbol`/`analyzeList` symmetry: it needs either a *second* fqcn→fn registry (more machinery than the draft's one slot, defeating "smaller") or a non-comptime fn-pointer field on the descriptor (re-introducing the `init`-alloc/`deinit`-free burden the draft's comptime scalars specifically avoid). Per F-011 the parallel resolution mechanism is the disqualifier; per F-002 its "don't widen the struct" is a bits-today convenience, not a finished-form gain.

3. **Alt 3 (central `StaticStringMap` keyed by `"Class/FIELD"`).** Smallest cross-file blast radius and uses a blessed idiom for a fixed tiny table, but it severs field data from the class it belongs to (fails F-009 grep-locality: `rg MAX_VALUE Integer.zig` finds nothing) and breaks `analyzeSymbol`/`analyzeList` symmetry the hardest (field and method resolution fully disjoint, the descriptor bypassed for fields). It is the same separate-representation-then-re-bridge anti-pattern ADR-0059's Alt 3 was rejected for, in miniature. Reservation-of-a-side-channel where the descriptor you already resolved would answer the question.

**One cross-cutting flag for the ADR regardless of choice (ADR-0036 dual-backend parity):** all three alternatives resolve `Class/FIELD` to a `.constant` Node **at analyze time** (via `makeConstant`), exactly as integer/float literals already do. The TreeWalk and VM backends both consume the same analyzed Node tree, so both see the *identical* constant Value (an inline `Long`/`Double` for the in-range fields, a heap BigInt for `Long/MAX_VALUE`) with no per-backend code. The dual-backend diff oracle (`test/diff/cases.yaml`, Layer 3) therefore needs no special handling — a `Class/FIELD` case is parity-trivial by construction, because the divergence point (if any) is the numeric representation set at analyze time, which is upstream of the backend split. **Confirmed: no alternative touches the ADR-0036 parity contract.**

A second cross-cutting note: the draft (and Alt 2) correctly does **not** "fix" the D-165 Long/MAX_VALUE BigInt-print divergence (`…N` vs JVM's bare Long). That divergence is the F-005 numeric-tower consequence of i48-inline-Long, owned by the numeric-tower owner per F-003 — pre-empting it here (e.g. by widening the inline integer payload) would require an F-004 amendment (user-owned) and is out of scope for a static-field-resolution ADR. The ADR should record D-165 as inherited-not-introduced, exactly as the draft frames it.

---

The main loop adopts **Alt 2** (finished-form-clean, the DA's #1) verbatim,
including the two sharpenings: symmetry as the stated invariant + the
comptime-vs-init asymmetry comment on `static_fields`.

## Consequences

- **Positive**: `Integer/MAX_VALUE` / `MIN_VALUE`, `Long/MAX_VALUE` /
  `MIN_VALUE`, `Double/MAX_VALUE` / `MIN_VALUE` resolve (clj parity for
  the value). A surface adds a static field by the same recipe it adds a
  method — one mental model. No new numeric code; the BigInt path is the
  existing literal mechanism. No `init`/`deinit` machinery (comptime
  const). Dual-backend parity is trivial (constant Node at analyze time).
- **DIVERGENCE (D-165, inherited)**: `Long/MAX_VALUE` / `MIN_VALUE` print
  `…N` (BigInt) vs JVM's bare Long; value exact. Owned by the
  numeric-tower owner (F-003). `Integer/*` + `Double/*` match clj exactly.
- **Scope**: only static FIELD READS (`Class/FIELD` as a value). Static
  field WRITES do not exist in Clojure semantics; method references
  without parens are out of scope (Clojure has no bare static-method
  value form). Boolean/Character have no MAX/MIN constants in scope here.

## Affected files

- `src/runtime/type_descriptor.zig` — `StaticField` / `StaticFieldValue`
  + `static_fields` slot (defaulted) + `lookupStaticField` + the
  comptime-vs-init asymmetry comment.
- `src/eval/analyzer/analyzer.zig` — `analyzeSymbol` field arm before the
  `namespace_unknown` raise; `staticFieldValue` helper.
- `src/runtime/java/lang/{Integer,Long,Double}.zig` — comptime
  `static_fields` arrays + `.static_fields = &…` in the descriptor.
- `test/e2e/phase14_static_fields.sh` — clj-parity cases (incl. the
  D-165 BigInt-N pin for `Long/MAX_VALUE`).
- `.dev/debt.yaml` — D-165 cross-reference (Long/MAX_VALUE field inherits it).

## Revision history

### 2026-05-31 — `StaticFieldValue` gains `.bool` (Boolean/TRUE/FALSE), cluster A26 cycle F

`java.lang.Boolean` needs `Boolean/TRUE` → `true` / `Boolean/FALSE` →
`false` static fields, whose values are booleans — outside the original
`int`/`float`-only `StaticFieldValue`. Amendment: add `.bool: bool` to
`StaticFieldValue`; `analyzeSymbol`'s lift switch gains
`.bool => |b| Value.initBoolean(b)` (the existing `value.zig` helper,
matching the `.float => Value.initFloat(f)` arm). A cljw boolean is an
inline `NB_CONST_TAG` immediate (comptime-const), so the §2 comptime-const
property (no `init`/`deinit`) holds; the descriptor slot, resolution path,
and dual-backend parity are unchanged. **Forward note (do not
over-anticipate)**: `Double/POSITIVE_INFINITY` / `NEGATIVE_INFINITY` /
`NaN` need NO new variant — they are comptime f64 (`std.math.inf` / `-inf`
/ `nan`) carried by the existing `.float`; only a future
`Character/MAX_VALUE` (a char) would add a `.char: u21` variant.

Devil's-advocate (mandatory at depth ≥ 2) ran fresh-context; its verbatim
output (3 alternatives + ranked recommendation) follows. The main loop
adopts its #1 (Alt 1: `.bool` variant + `Value.initBoolean`).

> ## Devil's-advocate: Alternatives considered (StaticFieldValue grows a bool)
>
> **F-NNN gate result up front:** None of the three alternatives below requires violating an F-NNN. A cljw boolean is an inline `NB_CONST_TAG` immediate Value (`value.zig:34-35` `true_val`/`false_val`; F-004) — comptime-const exactly like the existing `int`/`float` scalars, so every alternative preserves the `static_fields` comptime-const property (no `init` alloc, no `deinit` free) that ADR-0061 §2 made load-bearing. All three emit a `.constant` Node at analyze time, so ADR-0036 dual-backend parity is untouched (confirmed per-alternative below). F-011 commonization (one descriptor-keyed lookup shape) is the axis the alternatives are judged on. The clean shape is reachable; no forced F-NNN-block disclosure needed.
>
> One verified-fact sharpening the alternatives lean on: `value.zig:192` already ships `Value.initBoolean(b: bool) Value` = `if (b) true_val else false_val`. The draft's inline `if (b) Value.true_val else Value.false_val` re-spells this helper at the call site; the alternatives prefer the named helper for symmetry with the existing `.float => Value.initFloat(f)` arm.
>
> ### Alternative 1 — Smallest-diff: add `.bool: bool` to `StaticFieldValue`, lift via `Value.initBoolean` (the draft, using the existing helper)
>
> The draft as written, with the one-line tightening: the lift arm is `.bool => |b| Value.initBoolean(b)` (reusing `value.zig:192`) rather than an inline `if`. `StaticFieldValue` becomes `union(enum) { int: i64, float: f64, bool: bool }`; `Boolean.zig` declares `boolean_static_fields = [_]StaticField{ .{ .name="TRUE", .value=.{.bool=true} }, .{ .name="FALSE", .value=.{.bool=false} } }`.
>
> **What it does better:** Minimal, and each variant maps 1:1 to the analyzer arm that lifts it — `int → integerLiteralToValue`, `float → initFloat`, `bool → initBoolean`. The union stays a flat list of the primitive scalar kinds Clojure static fields actually carry, each comptime-const. Grep-local (`rg TRUE src/runtime/java/lang/Boolean.zig` hits). The lift switch stays exhaustive (`zig_tips.md` narrow-enum rule), so a future variant added without a matching arm is a compile error — a real regression guard.
>
> **What it breaks / risks:** Each new scalar shape costs one variant + one arm. Today's question already names the next ones: `Double/POSITIVE_INFINITY`/`NEGATIVE_INFINITY`/`NaN` are **comptime f64 values — already covered by `.float`** (`std.math.inf(f64)` / `-inf` / `nan` are comptime-const, `Value.initFloat` lifts them, no new variant). `Long/SIZE = 64` fits `.int`. The *one* genuinely-new shape on the horizon is `Character/MAX_VALUE` (a char `￿`), which would need a `.char: u21` variant + a `.char => |c| Value.initChar(c)` arm (`value.zig:216`). So the union's realistic end state is 4 variants (`int`/`float`/`bool`/`char`) — small and closed; Clojure host static fields are scalars, never collections. The risk is purely "N small edits over time" — but each is a one-line variant + one-line arm, and the exhaustiveness check makes them safe. This is finished-form-clean, not merely smallest-diff: the union models "the primitive Value kinds a constant field carries", which is exactly what it is.
>
> **Explicit answers:** (a) comptime-const for all future kinds incl. `Double` inf (`.float`, already covered) and `Character/MAX_VALUE` (`.char`, comptime u21): **yes** — every kind is an inline immediate or a comptime scalar. (b) regress the BigInt path? **No** — `.int => integerLiteralToValue` is untouched; `Long/MAX_VALUE` still lifts to a heap BigInt at analyze time exactly as ADR-0061 specifies. (c) dual-backend parity: **unaffected** — `.bool` emits a `.constant` Node like every other arm; both backends see the identical inline `true_val`/`false_val`.
>
> ### Alternative 2 — `.value: Value` single variant holding any comptime-const Value
>
> Collapse the union into one variant `StaticFieldValue = struct { value: Value }` (or drop the union entirely: `StaticField = struct { name, value: Value }`). `Boolean.zig` writes `.value = Value.true_val`; `Math.zig`-style float fields write `.value = Value.initFloat(...)`; the analyzer arm becomes a trivial `makeConstant(arena, sf.value, form)` — **no lift switch at all**.
>
> **What it does better:** One variant covers bool, char, float, and any in-range int with **zero** future edits — `Character/MAX_VALUE` is just `.value = Value.initChar(0xFFFF)` in the surface, no `type_descriptor.zig` touch ever again. The analyzer arm shrinks to one line (no switch).
>
> **What it breaks / risks — this is the disqualifier:** It **regresses the `Long/MAX_VALUE` BigInt path**, which is the whole reason ADR-0061 stored a *raw scalar* rather than a `Value` in the first place (see the field docstring, `type_descriptor.zig:109-113`: *"the value is kept as a raw scalar (not a `Value`) because a heap `Value` (BigInt for `Long/MAX_VALUE`) cannot be comptime-const"*). `9223372036854775807` exceeds i48 (F-004), so its Value is a **heap BigInt** — which is **not comptime-const** (it needs a `rt.gc` allocation). A `static_fields` array of `Value` therefore cannot hold `Long/MAX_VALUE` as a comptime literal: you would either (i) lose `Long/MAX_VALUE` (a shipped ADR-0061 target — regression), or (ii) reintroduce an `init`-time heap-build + `deinit`-free for the array, destroying the comptime-const property ADR-0061 §2 made load-bearing and explicitly forbade. Either branch breaks a confirmed invariant. The raw-scalar union exists *precisely* to defer the i48→BigInt lift to analyze time (where `rt.gc` is available) via `integerLiteralToValue`; `.value: Value` cannot defer it. This is a Reservation-as-convenience trap: it looks like the cleanest "any Value" generalization, but it collides with F-004's i48 NaN-box ceiling.
>
> **Explicit answers:** (a) comptime-const for all future kinds: **no** — fails for any field whose Value is a heap type, and `Long/MAX_VALUE` is one **today**. (b) regress BigInt? **Yes, directly** — this is the central failure. (c) dual-backend parity: would be fine in isolation (constant Node), but moot given (a)/(b).
>
> ### Alternative 3 — Wildcard: store a `comptime`-evaluated thunk `*const fn() Value` per field
>
> Make `StaticFieldValue` hold a function pointer `produce: *const fn(rt: *Runtime) anyerror!Value`, so each field declares how to build its own Value (`Boolean/TRUE` → returns `true_val`; `Long/MAX_VALUE` → returns the BigInt build). The analyzer arm calls `sf.value.produce(env.rt)`.
>
> **What it does better:** Maximally general — any Value, including heap ones, with no union growth and no analyzer switch; the per-field producer encapsulates the lift.
>
> **What it breaks / risks:** It reintroduces the exact non-comptime-fn-pointer hazard ADR-0061 §2 identified as the reason `method_table` (which holds `Value.initBuiltinFn(&fn)`) must be `init`-built and `deinit`-freed: `@intFromPtr(fn)` is **not comptime on Mac**. A `produce: *const fn(...)` field makes `static_fields` non-comptime *in the same way method_table is*, forcing it back into `init`/`deinit` — re-merging the asymmetry ADR-0061 deliberately split (its strongest structural argument). It also over-engineers a constant read into a runtime call for zero benefit: static fields are pure constants with no per-field behaviour to encapsulate. Strictly more machinery, and it forfeits the comptime-const property that is F-004/§2's load-bearing win.
>
> **Explicit answers:** (a) comptime-const: **no** — fn pointers are non-comptime on Mac (the documented `_host_api.zig:46-61` constraint). (b) regress BigInt? It *handles* BigInt, but only by paying the `init`/`deinit` cost the whole design avoids. (c) dual-backend parity: still a constant Node, but the producer runs at analyze time — parity-fine yet irrelevant given (a).
>
> ### Non-binding ranked recommendation
>
> 1. **Alt 1 (`.bool: bool` variant + `.bool => Value.initBoolean(b)` arm).** Finished-form-clean: `StaticFieldValue` stays a flat closed list of the primitive scalar kinds a Clojure host static field carries (`int`/`float`/`bool`, +`char` when `Character/MAX_VALUE` lands), each comptime-const, each with a 1:1 exhaustive lift arm reusing the existing literal path. It preserves the `Long/MAX_VALUE` raw-scalar→analyze-time-BigInt deferral, keeps the §2 comptime-const invariant, and stays grep-local + descriptor-keyed (F-011 symmetry). Tightening over the draft: use `Value.initBoolean(b)` in the arm. Record that `Double` infinities need no variant (existing `.float`); only `Character/MAX_VALUE` later adds `.char`.
> 2. **Alt 2 (`.value: Value`).** Tempting as "the one generalization that never needs another variant", right in a world without the i48 ceiling — but it **regresses `Long/MAX_VALUE`** (non-comptime heap BigInt), and forcing it comptime needs the `init`/`deinit` machinery §2 forbids. F-004 disqualifies it.
> 3. **Alt 3 (per-field `*const fn() Value` producer).** Reintroduces the non-comptime-fn-pointer cost ADR-0061 §2 split away from, over-engineers a constant read into a runtime call. Most machinery, forfeits the comptime-const win.
>
> **Cross-cutting (ADR-0036 parity):** all three resolve `Boolean/TRUE`/`FALSE` to a `.constant` Node at analyze time holding an inline immediate; TreeWalk and VM see the identical constant. Parity-trivial by construction. Confirmed: no alternative touches the parity contract.
