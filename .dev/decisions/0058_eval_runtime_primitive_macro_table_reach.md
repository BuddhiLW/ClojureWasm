# ADR-0058 — `eval` runtime primitive reaches the macro table via a typed Layer-1 driver verb

- **Status**: Accepted
- **Date**: 2026-05-31
- **Phase**: Phase 14 (post-v0.1.0 coverage) / cluster A26
- **Supersedes**: —
- **Superseded by**: —

## Context

`clojure.core/eval` was absent (debt D-162). The wire-up is otherwise
ready — `analyzer.valueToForm` (Value→Form), `analyzer.analyze`
(Form→Node, needs a `*const macro_dispatch.Table`), and
`driver.evalForm` (Node→Value) — BUT `analyze` needs the
macro-expansion table, which until now was threaded only at
setup/bootstrap/analysis time (stack-owned per app entry point,
passed by pointer) and is **not reachable from a runtime primitive**.
A primitive runs at eval-time with `rt` + `env` in scope but no
`macro_table`.

This is structural-defect class #3 in
`.dev/lessons/structural_defect_hunting.md` — "a runtime primitive
needs a resource that only exists at setup/analysis time" — and it
**will recur** (`load-string`, `eval` inside a macro, a future
`load`/`read+eval` REPL surface all need the same reach). So the fix
must set a clean, reusable precedent, not a one-off.

Two confirmed facts shape the design:

1. **The macro table is a process constant** — always exactly
   `lang/macro_transforms.registerInto`'s output, no per-session
   state. User `defmacro` macros do **not** live in it; they live on
   the Var (`flags.macro_` + deref'd root, `macro_dispatch.zig:103/114`)
   and are reachable via `env` alone. So a runtime `eval` re-entering
   analysis needs the table **only** to expand built-in Zig macros
   (`and`/`or`/`when`/`->`/…); user macros come free via `env`.
2. **The `eval` primitive is Layer 2** (`src/lang/primitive/`), which
   imports `eval/` (Layer 1) freely. So it can call
   `valueToForm`/`analyze`/`evalForm` directly — **no Layer-0 vtable
   indirection is needed**. The single missing piece is the table.

Zone constraint (`.claude/rules/zone_deps.md`): Layer 0 (`runtime/`)
must NOT import Layer 1 (`eval/`), so a typed
`macro_table: *const macro_dispatch.Table` field on `Runtime` is a
zone violation — it must be stored type-erased (`?*const anyopaque`),
the same concession `dispatch.VTable.evalChunk` already makes for a
Layer-1 `BytecodeChunk` pointer (`dispatch.zig:84-89`).

Zig constraint: top-level fn pointers cannot close over locals, so
"install an `evalForm` fn on the vtable that closes over the table"
is impossible — any such fn would still have to read the table from
`rt` (anyopaque) or a module-level `var` (forbidden globals per
ROADMAP §13). The vtable option therefore does **not** escape the
anyopaque; it only relocates where it is read.

## Decision

Adopt **Alt 2 (finished-form-clean)** from the Devil's-advocate fork:

1. **`Runtime.macro_table: ?*const anyopaque = null`** (Layer 0,
   type-erased). Documented as a **borrow** of the Layer-1
   `macro_dispatch.Table`, set once in the universal funnel
   `bootstrap.setupCorePrefix`, valid for the entry point's
   setup-frame lifetime. (Adding a field is explicitly not an
   ADR-level change per `runtime.zig` doc; the ADR is for the
   structural-precedent choice.)

2. **`driver.evalValue(rt, env, locals, arena, value, loc)`** — a new
   **typed** Layer-1 verb that packages the whole runtime-eval
   pipeline: cast `rt.macro_table` back to `*const macro_dispatch.Table`
   once (raise an internal error if null = eval before bootstrap),
   then `valueToForm → analyze(…, table) → evalForm`. The
   `@ptrCast`/`@alignCast` lives at exactly **one** site, behind a
   typed function.

3. **`eval` primitive** (Layer 2, `lang/primitive/core.zig`): allocate
   a per-call arena off `rt.gpa` (the analysed Node/Form live there;
   the result Value is GC-allocated so it survives `arena.deinit()`),
   a fresh `[MAX_LOCALS]Value` locals buffer, and call
   `driver.evalValue` with **zero casts**. Registered as `eval` in
   `clojure.core`.

The reusable precedent for class #3 is therefore: *"a runtime
primitive that needs a setup-time analysis resource calls a typed
Layer-1 driver verb; the resource is threaded Layer-0→Layer-1 once,
type-erased only at the single Runtime field and cast back behind the
typed verb."* The next such primitive reuses `driver.evalValue` (or a
sibling verb) and never re-derives the cast.

**Rejected**: Alt 1 (raw `?*const anyopaque` field cast in *each*
primitive) — it is the smallest diff but compounds: every recurrence
of class #3 adds another untyped field + bespoke cast (Smallest-diff
bias smell, and the diff-size advantage over Alt 2 is the
Cycle-budget-defer trap). **Rejected**: Alt 3 (process-singleton
table, anyopaque-free) — the only fully-anyopaque-free shape, but it
requires a forbidden module-level `var` (ROADMAP §13) + a new
process-global allocator lifetime, colliding with the deliberate
per-Runtime isolation `keywords`/`symbols`/`vtable` all enshrine.

**Known fidelity limit (carried as follow-up):** `valueToForm`
(`analyzer.zig:797-820`) handles
{nil,bool,int,float,symbol,keyword,string,list,vector,array_map,hash_set}
and raises `macro_return_not_data` for everything else. So
`(eval \a)` / `(eval 1N)` / `(eval 1/2)` / `(eval 1.5M)` /
`(eval <large-hash_map>)` raise rather than self-evaluate. The D-162
motivating case `(eval (read-string "(+ 1 2)"))` is all-handled-tags
and works. Extending `valueToForm` to cover char/bignum/hash_map is a
separate unit (it also governs macro returns) — recorded as a
follow-up, not blocking D-162.

## Alternatives considered

The following is the Devil's-advocate subagent's verbatim output
(fresh context, briefed with the F-NNN envelope + zone + Zig
constraints):

> # Devil's-advocate review — Debt D-162: how `clojure.core/eval` reaches the macro-expansion table
>
> ## Verification of the brief's claims (cited)
>
> - **`evalChunk` anyopaque precedent**: confirmed (`dispatch.zig:84-89`). `chunk: *const anyopaque`, cast back at the VM end. This is the project's *one* existing Layer-0-carries-Layer-1-pointer concession, and its doc comment explicitly frames it as a zone-barrier workaround.
> - **`Runtime` "adding a field is OK"**: confirmed (`runtime.zig:50`). `require_resolver: RequireResolverFn` (runtime.zig:43) is the precedent for *a Layer-1 fn pointer typed in Layer 0, installed by bootstrap* — but note it is **typed** (`*const fn(*Runtime, []const u8) ...!?[]const u8`), NOT anyopaque, because its signature names only Layer-0 types. The macro_table cannot do this (its type lives in Layer 1).
> - **macro_table is a process constant**: confirmed (`macro_dispatch.zig:61-86`) — always `macro_transforms.registerInto`'s output; user `defmacro` lives on the Var (macro_dispatch.zig:103/114), reachable via `env`.
> - **eval primitive is Layer 2**: confirmed — it will live in `src/lang/primitive/`, which already imports `eval/` freely (bootstrap.zig itself, a Layer-2 file, imports analyzer + driver). So `valueToForm`/`analyzeForm`/`evalForm` need **no** vtable. The *only* gap is the table.
> - **The universal funnel exists**: confirmed and stronger than the brief stated. **Every** entry point (builder:107, repl:70, runner:66, nrepl:102, cache_gen:43) reaches the table through `setupCorePrefix` (bootstrap.zig:204) → `macro_transforms.registerInto`. There is exactly one install site to instrument.
> - **Lifetime caveat (important, the brief understated it)**: the table is `var macro_table = ...Table.init(gpa); defer macro_table.deinit();` *on the entry-point stack frame* (builder:105-106, repl:68-69, etc.). It outlives every eval in `setupCore`/the REPL loop because those run inside the same frame. **Any `?*const anyopaque` stored on `rt` is a borrow** — correct only while that stack frame is live. For the REPL/runner this is the whole session, so it is fine; but it is a borrowed pointer, not owned, and that constraint must be documented at the field.
>
> ---
>
> ## Alternative 1 — Smallest-diff: `Runtime.macro_table: ?*const anyopaque` (≈ the main loop's Option-2)
>
> Store the table pointer on `Runtime`, set once inside `setupCorePrefix` (the single funnel), cast back in the Layer-2 eval primitive.
>
> **Better than nothing / what it does well**: one field + one assignment line in the one funnel + one cast site. No new file, no vtable slot, no signature churn. Per-Runtime (not a global), so parallel tests are isolated. Mirrors `evalChunk`'s sanctioned concession exactly.
>
> - **(a) Avoids anyopaque?** No — it *is* the anyopaque. One new cast site (`@ptrCast`/`@alignCast` back to `*const macro_dispatch.Table` in the Layer-2 primitive).
> - **(b) Multi-Runtime safe?** Yes. Field on `Runtime`, not a `pub var`. Each test's Runtime carries its own pointer.
> - **(c) Lifetime correct?** Yes *but borrowed*. The field aliases the entry-point's stack-owned table. Correct as long as no code path stores a Runtime past its setup frame's lifetime. Today nothing does. The risk is future: if anyone ever returns a `Runtime` by value or heap-promotes it, the borrow dangles silently (anyopaque erases the type, so the compiler will not catch a stale pointer).
> - **(d) Reusable precedent for structural-class #3 ("primitive needs a setup-time resource")?** **This is its weakness.** It establishes "when a primitive needs resource X, bolt `?*const anyopaque` onto Runtime and cast in the primitive." That is a precedent that *scales badly* — class #3 WILL recur (the debt row itself flags it), and each recurrence adds another untyped anyopaque field + another bespoke cast site. Five recurrences = five anyopaque fields on Runtime with five separate "cast back, trust me" sites. That is the **Smallest-diff bias smell** compounding: each instance is cheap, the aggregate is a Runtime struct full of type-erased borrows.
>
> ---
>
> ## Alternative 2 — Finished-form-clean: a typed Layer-1 "analysis context" handle, vtable-thin, owned by the Runtime
>
> Promote the macro_table from a stack-local to a **Runtime-owned, Layer-1-typed resource reached through one narrow accessor**, so the anyopaque never appears. Concretely: introduce a small Layer-1 struct (call it `eval/analysis_env.zig`'s `AnalysisEnv`, or reuse the existing `Table` directly) that the Runtime *owns by value or owns the pointer to*, and expose it to Layer 2 via a **typed function on the Layer-1 driver** — `driver.evalValue(rt, env, locals, arena, value)` — that internally does `valueToForm → analyzeForm(…, rt's table) → evalForm`. The eval primitive (Layer 2) calls one typed Layer-1 entry point and never touches the table at all.
>
> The table reaches the driver because the driver is Layer 1 and *can* name `macro_dispatch.Table`. The Runtime stores the table as `?*const anyopaque` **only internally** OR — cleaner — the driver reads it from a Layer-1-side store. The decisive move: **the public contract Layer 2 sees is `driver.evalValue(...)`, fully typed, zero casts.** The anyopaque (if any remains) is confined to a single Layer-0↔Layer-1 plumbing line inside `runtime/` + its cast inside `driver`, both authored once, never copied by future primitives.
>
> **Better than Option-2**:
> - Layer 2 (where new primitives keep getting added) gets a **typed, reusable verb**: `driver.evalValue`. The next primitive that needs eval-at-runtime (`load-string`, `eval` inside a macro, `clojure.core/load`, `read+eval` REPL) calls the same typed function. No copy-paste cast.
> - The anyopaque, if it survives at all, lives at **one** Layer-0↔1 boundary with a typed cast immediately behind it (same shape as `evalChunk`, but consumed through a typed wrapper rather than re-cast at every call site).
> - Sets structural-class #3's precedent **correctly**: "a primitive that needs a setup-time analysis resource calls a typed Layer-1 driver verb; the resource is threaded Layer-0→Layer-1 once." That precedent *shrinks* future diffs instead of growing the anyopaque field count.
>
> - **(a) Avoids anyopaque?** Partially-to-fully. It does NOT eliminate the Layer-0↔1 type-erasure if the table is stored on `Runtime` (zone rule forces `?*const anyopaque` there). But it **relocates and confines** it: the cast happens once inside `driver`, and Layer 2 never sees it. Compared to Alt 1, the anyopaque stops being a per-primitive concern. If the table is instead held in a Layer-1 module-side store keyed by Runtime, the Runtime field disappears entirely — but a Layer-1 keyed store risks a `pub var` (forbidden) unless keyed off something the Runtime already carries, so the clean version still stores `?*const anyopaque` on Runtime and casts in driver. **Honest verdict: it relocates the anyopaque to one confined typed-wrapper site; it does not delete it.**
> - **(b) Multi-Runtime safe?** Yes — still a per-Runtime field/handle, no global.
> - **(c) Lifetime correct?** Same borrow caveat as Alt 1, but the typed wrapper is the natural place to document "borrowed for the Runtime's setup-frame lifetime," and a future heap-promotion of Runtime would force a decision at the single typed boundary rather than silently dangling N anyopaque fields.
> - **(d) Reusable precedent?** **Best of the three.** This is the finished-form answer to class #3: typed Layer-1 verbs, anyopaque confined behind them. F-002 (finished-form wins) points here.
>
> **What it breaks/risks**: larger diff (new typed `driver.evalValue` entry + threading the table into the driver's reach). If the table ends up stored on `Runtime` anyway, a critic could say "you added a typed wrapper around the same anyopaque field — Alt 1 with extra steps." The rebuttal: the wrapper is the reusable surface; the field's erasure is an implementation detail Layer 2 never re-derives. Also: `evalForm` already exists at driver.zig:54 and takes a `*const Node` (post-analysis) — `evalValue` must additionally hold the analyzer entry, so it couples driver to analyzer (already true — analyzer is Layer 1, driver is Layer 1, and bootstrap.zig:157 already calls `analyzeForm` then `evalForm` back-to-back; `evalValue` just packages that pair).
>
> ---
>
> ## Alternative 3 — Wildcard: make the macro_table a Layer-1 *process constant* reached by a pure comptime/once-init function, eliminating the field entirely
>
> The brief's own confirmed fact is the lever: **the macro_table is a process constant** — always exactly `macro_transforms.registerInto`'s output, no per-session state, no per-Runtime variation. If that is *truly* invariant, the table does not need to live on the Runtime at all. Instead: expose a Layer-1 (or Layer-2) function `macro_dispatch.canonicalTable()` that lazily builds the one canonical table **once per process** behind a `std.once`-style guard, returns `*const Table`, and is called by both bootstrap's `setupCorePrefix` AND the eval primitive. No field on Runtime, no anyopaque, no borrow, typed end-to-end.
>
> **Better than Option-2**:
> - **(a) Avoids anyopaque?** **Yes, completely.** The table is named with its real Layer-1 type at every site. eval (Layer 2) calls `macro_dispatch.canonicalTable()` and gets `*const Table`. Bootstrap does the same. Zero casts, zero erasure. The zone rule is satisfied because Layer 2 may import Layer 1, and Layer 0 (`runtime/`) is never involved — the table leaves the Runtime entirely.
> - **(c) Lifetime correct?** **Best possible** — process-lifetime constant, outlives every Runtime by construction. The borrow problem vanishes.
> - **(d) Reusable precedent?** Strong *for genuinely process-constant resources*: "a setup-time resource that is a true process constant is a lazily-initialized Layer-1 singleton, not a Runtime field." That is a clean, named category.
>
> **What it breaks/risks — and this is fatal-ish**:
> - **(b) Multi-Runtime safe? Only conditionally.** A `std.once`/lazy-singleton needs *somewhere* to store the built table + the once-guard. In Zig 0.16 that storage is a **module-level `var`** — i.e. a `pub var` (or file-private `var`) — which **ROADMAP §13 forbids** and which the brief explicitly rules out. A file-private (non-`pub`) `var` is a softer violation but is still the exact shape (mutable global state) §13 targets, and it breaks the project's "per-Runtime, no shared mutable global" invariant that `keywords`/`symbols`/`vtable` were all deliberately designed around (runtime.zig:73-88 comments repeatedly justify per-Runtime-ness "so parallel tests don't collide"). Even though the *table content* is constant, the *once-guard* and *storage slot* are process-global mutable state, and the table's `alloc` field (macro_dispatch.zig:63) binds it to one allocator — which allocator? A process singleton cannot belong to a per-Runtime `gpa`. It would need the page allocator or a process arena, a new lifetime category.
> - **Leading finding (per brief instruction)**: *The only fully-anyopaque-free option (Alt 3) requires either a forbidden module-level `var` (§13) or a new process-global allocator lifetime.* It does **not** require an F-NNN amendment — F-004/F-006 don't speak to this — but it **does** require either a §13 carve-out (an ADR amendment, loop-ownable) or accepting a file-private mutable singleton. Because §13 is a hard ROADMAP rule and the per-Runtime isolation is load-bearing for parallel tests, I flag this as the reason Alt 3 cannot be taken as-is despite being the only anyopaque-free shape. **Do not halt** — record and move on.
> - A weaker non-singleton variant (build the table fresh each `eval` call via `registerInto` into an arena) avoids the global but pays a full table rebuild per eval call — correctness-fine, performance-poor, and it duplicates the "table is built once" assumption the codebase relies on. Acceptable as a *stopgap* but not finished-form.
>
> ---
>
> ## Recommendation (advisory, not binding)
>
> Rank: **Alt 2 (finished-form-clean) > Alt 1 (smallest-diff) > Alt 3 (wildcard)**. Alt 3 is the only shape that fully deletes the anyopaque, and the brief's "macro_table is a process constant" fact makes it tempting — but it collides with ROADMAP §13 (no module-level `var`) and the deliberate per-Runtime isolation that `keywords`/`symbols`/`vtable` all enshrine, so it cannot be taken without a §13 carve-out and a new process-global allocator lifetime; that cost is not justified for one debt row. Between Alt 1 and Alt 2, the deciding question per the project's own Cycle-budget-defer smell is *not* diff size: Alt 1 is the Smallest-diff-bias trap because structural-class #3 ("a primitive needs a setup-time resource") **will recur** (the debt row says so), and Alt 1's precedent makes each recurrence add another untyped anyopaque field + bespoke cast, whereas Alt 2 gives Layer 2 a typed, reusable `driver.evalValue(...)` verb and confines the unavoidable Layer-0↔1 erasure to one wrapper authored once. Per F-002 (finished-form cleanliness wins, cycle size is not a constraint), take Alt 2: a typed Layer-1 `driver.evalValue` (`value → valueToForm → analyzeForm(rt's table) → evalForm`) consumed by the eval primitive with zero casts, with the table reaching the driver via a single documented `?*const anyopaque` Runtime field set in the `setupCorePrefix` funnel (mirroring `evalChunk`'s sanctioned concession, but consumed through a typed verb rather than re-cast per primitive). Document the field as a borrow of the entry-point-owned table with the setup-frame lifetime caveat, so a future Runtime heap-promotion surfaces at one typed boundary rather than dangling silently.

The main loop adopts the DA's recommendation (Alt 2) unchanged.

## Consequences

- **Positive**: `eval` works for data forms. A typed, reusable
  Layer-1 verb (`driver.evalValue`) now exists for every future
  runtime-eval primitive (`load-string`, REPL `read+eval`, …); the
  Layer-0↔1 type erasure is confined to one Runtime field + one cast
  behind the typed verb. User macros expand via `env` for free;
  built-in macros via the borrowed canonical table. Sets the clean
  precedent for structural-defect class #3.
- **Negative / watch**: `Runtime.macro_table` is a **borrow** of the
  entry-point's stack-owned table — valid only while that frame is
  live (the whole session for repl/runner/builder). A future
  heap-promotion of `Runtime` would dangle it; the type erasure means
  the compiler will not catch that. Mitigated by documenting the
  borrow at the field + confining the cast to `driver.evalValue`.
- **Fidelity limit**: eval of `char`/`BigInt`/`Ratio`/`BigDecimal`/
  large `hash_map` literals raises `macro_return_not_data` until
  `valueToForm` is extended (separate unit; governs macro returns
  too).

## Affected files

- `src/runtime/runtime.zig` — add `macro_table: ?*const anyopaque`
  field (borrow doc).
- `src/lang/bootstrap.zig` — `setupCorePrefix` sets `rt.macro_table`
  after `registerInto`.
- `src/eval/driver.zig` — new typed `evalValue` verb.
- `src/lang/primitive/core.zig` — `eval` primitive + registration.
- `test/e2e/` — `(eval …)` surface tests.
- `.dev/debt.yaml` — D-162 discharged.
