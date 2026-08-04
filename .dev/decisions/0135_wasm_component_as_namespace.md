# ADR-0135 — Wasm Component Model as a first-class Clojure namespace (`require` a component, call its exports with Clojure data)

- **Status**: Proposed → Accepted (2026-06-13, user-directed)
- **Driven by**: the project's north-star differentiator (ROADMAP §1.2 axis 2;
  ADR-0099 / the Clojure-conj CFP "WebAssembly as an FFI — calling a `.wasm`
  *like a namespace*, the one thing no other Clojure runtime demonstrates").
  This ADR fixes the **finished form** that ADR-0099's minimal
  `(wasm/load)`+`(wasm/call handle "export")` core-module spike points toward.
- **Relates to**: ADR-0099 (minimal core-module FFI spike — the v0.1 layer
  below this), F-001 (zwasm v2 unavoidable, lazy + `-Dwasm`-flag-guarded),
  F-009 (impl/surface split), ROADMAP §8 (Wasm/edge strategy), §6 (tier
  system). External dependency: **zwasm's Component Model + WASI-P2 campaign
  (zwasm ADR-0170, `-Dcomponent`)** — functional, embedding API **not yet
  frozen**; this ADR is designed to land **paced by that API freeze**.

## Context

The four Clojure dialects each bind one host: clj↔Java (`:import`),
cljs↔JavaScript, cljd↔Dart. Each is **host-specific**. ClojureWasm's
analogue — clojure↔**WebAssembly Component** — is structurally *better*
because the Wasm Component Model contract is **language-neutral,
spec-defined, and self-describing**:

- A WIT (`WebAssembly Interface Types`) interface describes a component's
  exports with a rich, typed value language (records, variants, lists,
  options, results, resources) that maps **almost 1:1 onto Clojure data**.
- A **component binary embeds its own interface types** (Component-Model
  binary format) — so the export list + their WIT types are recoverable by
  *decoding the `.wasm` alone*. **No `.wit` sidecar file is required.** (The
  contract is the public spec: `CanonicalABI.md` / `WIT.md` / `Binary.md`.)
- cljw is Zig-native, so the lift/lower marshalling is a **hand-written fast
  path**, not a reflection layer — and the optimisation ceiling is the metal
  (see ROADMAP §1.2 the Zig-level thesis).

Current state (2026-06-13): cw v1 ships only the minimal core-module FFI
(`wasm/load` + `wasm/call handle "export"` — string-keyed, i32/i64/f-only,
manual marshalling; ADR-0099). cw v0 had the *seed* of the higher form
(`:cljw/wasm-deps` named modules in `deps.edn` + a WIT signature parser).
zwasm is building the Component-Model runtime (WIT type system + Canonical
ABI lift/lower + component instantiate/invoke) to wasmtime-equivalent
conformance, behind `-Dcomponent`.

## Decision

**A WebAssembly *component* is loadable as a first-class Clojure namespace.**
`require`-ing it introspects the component's embedded WIT exports and interns
one Clojure Var per exported function; arguments and results are negotiated
by the Canonical ABI so the caller passes/receives **Clojure data**, never
raw `i32`s.

### Surface (two shapes; deps+require is the finished form, load is the REPL hatch)

```clojure
;; deps.edn — a component declared like any dependency (cw v0 :cljw/wasm-deps,
;; evolved from :path module to :component).
{:cljw/wasm-deps {markdown {:component "libs/markdown.wasm"}}}

;; finished form — same hand-feel as importing Java
(ns my.app (:require [markdown :as md]))
(md/render "# hi")        ;; md/render generated from the component's WIT export;
                          ;; args/return are Clojure data, docstring/arglists from WIT

;; REPL / dynamic escape hatch
(def md (cljw.wasm/load-component "markdown.wasm"))   ;; introspect → ns-like handle
;; or a def-ing macro:
(cljw.wasm/import-component "markdown.wasm" :as md)
```

The component's WIT exports are the **SSOT** for the generated surface — no
hand-written wrapper, no `.wit` sidecar.

### The contract — WIT ↔ Clojure value mapping (Canonical ABI; spec-derived, stable)

This table is the finished-form artifact. It is derivable from the public
Canonical ABI spec and changes only when the spec does.

| WIT type            | Clojure value                             | Notes                                                             |
|---------------------|-------------------------------------------|-------------------------------------------------------------------|
| `bool`              | boolean                                   |                                                                   |
| `s8…s64`/`u8…u64` | long                                      | `u64`/`s64` may promote to BigInt at the f64 edge (F-005)         |
| `f32`/`f64`         | double                                    |                                                                   |
| `char`              | char                                      | Unicode scalar                                                    |
| `string`            | string                                    | UTF-8 ↔ cljw string                                              |
| `list<T>`           | vector                                    | element-wise lift/lower                                           |
| `tuple<A,B,…>`     | vector `[a b …]`                         | fixed arity                                                       |
| `record{a,b,…}`    | map `{:a … :b …}`                       | field names → keyword keys (kebab preserved)                     |
| `option<T>`         | `nil` \| T                                | `none`→nil, `some(x)`→x                                         |
| `result<T,E>`       | `[:ok v]` / `[:err e]`                    | payload slot omitted when the arm carries none (amendment 2)      |
| `variant`           | `[:case-name payload]`                    | same tagged-vector shape as `result` (amendment 2)                |
| `enum`              | keyword                                   |                                                                   |
| `flags`             | set of keywords                           |                                                                   |
| `resource`          | opaque handle, deterministically released | ADR-0159: NO GC finaliser; `own` drop on scope exit (amendment 2) |

Exports that are interfaces/worlds nest as sub-namespaces or qualified
names (TBD with zwasm's introspection shape). Imports the component *needs*
(e.g. WASI) are satisfied by cljw-provided host functions (the inverse
direction — exposing cljw fns as WIT exports — is ROADMAP §1.2 axis 2's
second half, a later ADR).

### Dependency & sequencing (paced by zwasm)

1. **Now (v0.1)**: keep ADR-0099's `wasm/load`+`wasm/call` core-module FFI.
   This ADR does *not* deprecate it — core modules without a component
   wrapper still need it.
2. **When zwasm's CM embedding API freezes** (zwasm ADR-0170): it must expose
   (a) decode a component → list exports + their WIT types; (b) invoke an
   export with Canonical-ABI lift/lower of host values. cljw then builds the
   `require`/`import-component` introspection + the mapping table above.
3. **`deps.edn` `:cljw/wasm-deps`** is the resolution layer (cw v0's seed).
4. cljw-as-component-output (exporting cljw itself / Clojure fns as WIT) and
   WasmGC are later (ROADMAP §8.3).

## Alternatives considered

- **Core-module-only, string-keyed call (status quo, ADR-0099)** — keeps
  marshalling manual (no records/strings/lists ergonomically). Correct as the
  low layer; insufficient as the finished form. *Kept as the layer below.*
- **Require a hand-written `.wit` sidecar** — rejected: the component binary
  is self-describing, so a sidecar is redundant and drifts from the binary.
  (`.wit` may still be *accepted* as an override/doc, but is not required.)
- **Static codegen (wit-bindgen-style) at build time** — heavier; loses the
  dynamic `(require …)`/REPL story that is the differentiator's heart. The
  introspect-at-require approach is more Clojure-native. (A build-time AOT
  path can be added later for size/speed without changing this contract.)
- **A `variant` as a bare 2-vector `[case value]`** — considered vs the
  tagged-map shape; deferred to the implementing cycle (pick the shape that
  round-trips cleanly through `case`/`match` ergonomics).

## Consequences

- **Differentiator becomes concrete + provable**: "ClojureWasm `require`s a
  Wasm component and calls it with Clojure data, types negotiated by the
  Canonical ABI — no other Clojure runtime does this, and the marshalling is
  Zig-native." This is the CFP heart in finished form.
- **The mapping table is a stable, spec-anchored contract** — a future AI / the
  user can implement against it without re-deriving the design.
- **Two-repo coordination is clean**: zwasm owns the CM runtime + embedding
  API; cljw owns the ns surface + the value mapping. The freeze of zwasm's CM
  embedding API is the one gating event.
- **No core-VM risk**: like ADR-0099, all of this is `-Dwasm`/`-Dcomponent`
  flag-guarded; the default gate never resolves zwasm (F-001).

## Affected files (when implemented)

- `runtime/cljw/wasm/` (surface + a new `component.zig` introspection/marshal
  layer over zwasm's CM API), `lang/require_resolver.zig` (the `:cljw/wasm-deps`
  + component-require path), `deps/parse.zig` (`:cljw/wasm-deps` schema).
- Tracked by debt rows D-404 (impl, blocked-by zwasm CM API freeze) and the
  conformance/proof rows.

---

## Amendment 1 (2026-06-21, user-directed) — the finished-form surface is settled; blocker dissolved; implementation begins

**Status of the blocker**: zwasm's Component-Model embedding API is now **functional
and default-ON** (`-Dwasi=p2`, wasmtime-equivalent: real `wasm32-wasip2` components run
e2e, typed embedder introspection + `invokeTyped`, official corpus 158/0/0). cljw already
ships the lower layers: `wasm/load-component` / `wasm/component-exports` (surfaces the
typed WIT signature) / `wasm/component-call`, plus a `require-component` macro, and
`component.zig` already lifts/lowers record/tuple/variant/enum/option/result/flags/string/
list per the §"contract" table. **D-404's "blocked-by zwasm CM API freeze" is DISSOLVED.**
This amendment fixes the remaining finished-form decisions and starts the build-out.

### A1. `:require` is overloaded with a STRING libspec (CLJS/CLJD lineage)

The finished `ns` surface follows the **modern Clojure-family convention**, NOT JVM
`:import`. JVM Clojure binds Java *classes* via `:import` (a flat, sub-functionless
namespace); **ClojureScript** (`["react" :as React]`) and **ClojureDart**
(`["package:flutter/material.dart" :as m]`) bind host *modules* via **`:require` with a
STRING lib name**. A Wasm component is a module (a namespace of typed functions +
resources), so it takes `:require`, not `:import`:

```clojure
(ns my.app
  (:require [clojure.string :as str]            ; Clojure ns (unchanged)
            ["greet.wasm" :as greeter]          ; Wasm component → aliased ns
            ["img.wasm" :refer [resize crop]])) ; refer specific exports
(greeter/greet "world")
(resize photo 800 600)
```

A **string-headed libspec is unambiguously a Wasm component** in cljw (cljw has no
JavaScript, so the CLJS "string = JS module" meaning cannot collide). `:as` aliases the
component's exports under a namespace; `:refer` interns named exports into the current ns
— identical mechanics to the existing `require-component` macro, which becomes the
**dynamic/REPL escape hatch** (the `:require` directive is the static form; same
`require` fn vs `:require` directive duality as Clojure). **`:import` stays Java-only**
(running existing JVM-Clojure assets); `:require`-string is the *new-code worldview*.

### A2. Resolution order (CLI-handy first; deps.edn; registry later)

cljw is lightweight + CLI-handy, so a component must resolve **without** a `deps.edn`.
The resolution kinds are distinguished by the **shape of the string** so precedence is
explicit, not an implicit shadowing chain (the DA-fork's risk #1 — a bare `greet.wasm`
next to the source must NOT silently shadow a classpath one):

1. **Explicit relative** — a string starting `./` or `../` (`["./greet.wasm"]`) resolves
   relative to the **executing source file** (the `.clj` doing the `:require`). Opt-in
   only; a bare name never resolves source-relative.
2. **Absolute path** — a string starting `/` (`["/opt/libs/greet.wasm"]`).
3. **A bare logical name / classpath** (`["greet.wasm"]` or `["greet"]`) — resolves on
   the existing `rt.load_paths` classpath + a `:cljw/wasm-deps` `deps.edn` alias
   (`{:cljw/wasm-deps {greet {:component "libs/greet.wasm"}}}`, cw v0's seed). A bare name
   is classpath-first (NOT source-relative-first) — this is the safe default that avoids
   dependency-confusion.
4. **Registry coordinate (deferred — debt row)** — a WIT package coordinate
   (`["wasi:http/proxy@0.2.0"]`, `namespace:package@version`) resolves through a registry:
   **OCI artifacts** (`application/vnd.wasm.config.v0+json`) + the **`wkg` / wasm-pkg-tools**
   resolver (`registry.json` at `/.well-known/wasm-pkg/registry.json`; Warg is being
   superseded by OCI). **Scoped IN but deferred**: land explicit-relative + absolute +
   classpath first, registry as a follow-on.

The reuse target: `lang/require_resolver.zig` (already maps ns→.clj on `load_paths`) +
`app/deps/{parse,resolve}.zig` (already parse deps.edn + git deps). The component path is
a sibling resolution arm, not a new subsystem.

### A3. Always-latest Wasm/WASI — a consumer-side invariant (→ F-016)

zwasm serves Wasm-1.0-only runtime users (`-Dwasi=p1` / lean opt-outs). **ClojureWasm,
as a zwasm *consumer*, forces the full modern surface**: it always embeds zwasm with the
**Component Model + WASI ≥ p2 (the latest zwasm ships; p3/async as it lands)** — there is
no cljw build axis that downgrades to Wasm-1.0-only or drops the component model. Rationale:
cljw is a *language for new code*; its users want the modern, self-describing component
world, and removing the version-negotiation axis is a pit-of-success default ("reach for
cljw's wasm interop → you get Wasm 3.0 + WASI latest, period"). Recorded as **F-016**
(`project_facts.md`) — a user-declared invariant.

### A4. Type information is RETAINED and LEVERAGED

A component binary is self-describing, and `component-exports` already decodes the typed
WIT signature (`{:name :params [[name type]…] :result type}`). The finished form attaches
that to each interned Var and uses it:

- **`:arglists` + `:doc` metadata** on each generated Var, derived from the WIT signature
  (param names + types, result type) — so `(doc greeter/greet)` and editor arglist hints
  work, identical hand-feel to a normal Clojure fn.
- **Compile-time arity checking — gated to statically-resolved components only** (the
  DA-fork's risk #2). When the `.wasm` resolves at analysis time (explicit-relative /
  absolute / classpath / embedded), the analyzer decodes its exports and can reject a
  wrong-arity call before runtime — richer than Java reflection. But a genuinely-dynamic
  `(wasm/load runtime-path)` has **no** signature at analysis time, so the check would
  silently degrade to none — two reliability tiers under one syntax. So: the compile-time
  check fires ONLY for the static `:require` form (where the component is present + will
  be embedded); the dynamic `wasm/load` path is runtime-checked, and that tiering is
  **documented + explicit**, never a silent "sometimes-checked". Build-time note: a static
  check means the `.wasm` must be present + byte-identical at every analysis (CI included);
  the build embeds it (ADR-0158), so "present at build" and "present at analysis" coincide.
- The WIT↔Clojure mapping table (§"contract") is the lift/lower SSOT; types are never
  erased to "just call it".

### A5. Resource ergonomics (prior-art-informed)

WIT `resource` (a stateful, owned/borrowed handle) maps to an opaque GC-finalised handle
(finaliser calls `resource.drop`; own/borrow tracked). The *call ergonomics* follow the
CLJD precedent for host objects (`obj.method` → `(.method obj)` / `alias/Method`): a
component exporting `resource counter { constructor; increment: func; }` surfaces as
`counter/new` (constructor) + `(counter/increment c)` (method on the handle). Final
method-access shape (a `counter/increment` Var taking the handle as arg 1, vs a
`.increment` interop form) is settled in the implementing cycle; the handle + GC-drop
contract is fixed here.

### A6. Single-binary embedding → ADR-0158

`cljw build` (the bytecode-envelope single-binary builder) must produce a **self-contained**
binary for a module that `:require`s a component: the component's `.wasm` bytes are embedded
into the envelope (cljw already `@embedFile`s the bundled `.clj` core), and the embedded-run
startup resolves component `:require`s from the embedded bytes, not the filesystem. The
mechanism is its own decision — see **ADR-0158**.

### Alternatives considered (Amendment 1 — Devil's-advocate fork, 2026-06-21)

A fresh-context DA fork challenged the design within the F-NNN envelope; its output:

- **Alt A (smallest-diff) — keep `wasm/require-component` as the ONLY surface, no `ns`
  integration.** Better: zero risk to the load-bearing `:require` analyzer path; never
  mints a new string-libspec special case. Breaks: components aren't declared in `ns`, so
  the single-binary static resolver (ADR-0158) must walk top-level forms — a *worse*
  static-resolution story. **Rejected (F-002)**: a smaller-diff convenience; the finished
  form wants deps in `ns`.
- **Alt B (finished-form-clean) — a dedicated `(:components ["greet.wasm" :as g])`
  directive, NOT an overloaded `:require`.** Better: zero string-libspec ambiguity; one
  meaning per directive; the DA's sharpest point — *CLJS overloaded strings because it had
  JS modules; cljw has no JS, so inheriting the overload is cargo-culting the lineage, not
  its rationale*; one well-known key for the static resolver. Breaks: diverges from
  CLJS/CLJD muscle memory; a Clojure dev won't reach for `:components` reflexively. No
  F-NNN violation. **The DA recommended this.**
- **Alt C (wildcard) — WIT-coordinate / logical-name only (`[greet :as g]` via
  `:cljw/wasm-deps`), no path strings in committed `ns`.** Better: kills source-relative
  resolution for committed code (relocatable sources); registry future drops in with no
  surface change. Breaks: defeats the "CLI-handy WITHOUT deps.edn" goal (a logical name
  needs a resolution map). No F-NNN violation but fights the stated goal.

**Decision: keep the `:require`-string overload (Alt B *not* adopted).** This is the one
point the user decided explicitly ("`:require` 上書きでいいです"). The DA's Alt-B argument
is genuinely strong and recorded here, but the choice is a close, defensible-both-ways
call (purity vs. CLJS/CLJD family-consistency + single-directive cognitive load + genuine
zero-ambiguity in a no-JS runtime), which the user resolved by explicit preference; the
permission-flip covers *open* points + *clearly-better* finished-form choices, not the
override of a deliberate explicit decision on a toss-up. **The DA's three cross-cutting
risk fixes ARE adopted** (they are not about Alt-B): resolution-order safety (A2 reordered
— relative is `./`-opt-in, bare names are classpath-first), compile-time-check tiering (A4
— static-only, explicit degraded tier), and F-016 kept as a *capability* invariant, not a
consumer-side *rejection* policy (an older component the embedded runtime can satisfy still
loads).

### Implementation phasing (debt-tracked)

A (ns `:require`-string wiring) → B (resolution order) → C (type leverage) → D (single-
binary embed, ADR-0158) → E (resource ergonomics + registry). D-404 reframed from
"blocked-by zwasm" to "the impl epic"; sub-rows per phase.

### Sources (research, 2026-06-21)

- Component distribution via OCI + `wkg`/wasm-pkg-tools; Warg → OCI transition:
  [bytecodealliance/wasm-pkg-tools](https://github.com/bytecodealliance/wasm-pkg-tools),
  [component-model: distributing](https://component-model.bytecodealliance.org/composing-and-distributing/distributing.html),
  [MS OSS blog: components over OCI](https://opensource.microsoft.com/blog/2024/09/25/distributing-webassembly-components-using-oci-registries/).
- Single-binary embedding precedent (precompile + link): Wasmtime pre-compiling
  (`.cwasm`), Wasmer `create-exe` (wasm→object→link).

## Amendment 2 (2026-08-04) — `result` and `variant` become tagged vectors; the table is corrected against the code

The 2026-08-04 cross-project audit compared this table against ClojureWit's
`doc/design/0012-wit-clojure-type-mapping.md` (the sibling repo's mapping,
implemented and falsified against a real `echo` component). Three rows differed.
A Devil's-advocate fork then read `src/runtime/cljw/wasm/component.zig` and found
that **this table also disagreed with cljw's own implementation on three rows** —
so the inter-repo divergence was the smaller problem.

### What was wrong here

- **`result` discarded the error value.** The table promised
  `throw (ex-info … {:wit/err e})`. The code raised `.wasm_trap` with no
  payload, whose template reads "WebAssembly module trapped (e.g.
  divide-by-zero, out-of-bounds, or an unreachable instruction)". A component
  returning `err("not found")` reached the user as a *trap* — a different kind
  of event — with the error value gone. Under `provisional_marker.md`'s table
  that is the forbidden row: the user sees a plausible outcome while the
  intended semantics are silently dropped.
- **`result`-as-throw has no meaning off the return position.** `lift` is
  recursive, so a `result` nested inside a `list` or `record` aborted the whole
  lift and discarded the successfully-lifted prefix. `list<result<u32, string>>`
  had no representation at all. `Explainer.md` is normative that `result` is the
  *recovery* channel — a value, not a control transfer.
- **`resource` said "GC-finalised; finaliser calls `resource.drop`".** ADR-0159
  deliberately did the opposite: release is **deterministic**, and there is no
  `host_finalise`. Both this project and ClojureWit independently landed on
  explicit close, so this row recorded agreement as if it were a design.

### The decision

`result` lifts as **`[:ok v]` / `[:err e]`**, and `variant` as
**`[:case-name payload]`**, with the payload slot omitted when the arm carries
none. One tagged-vector idiom now covers every WIT sum type, and it destructures
directly: `(let [[tag v] (c/f …)] …)`.

The reasoning is cljw's own, not deference to the sibling. The nested-position
hole and the discarded payload are defects in this implementation, and the
Canonical ABI settles the direction. That ClojureWit reached the same shape from
the same spec is corroboration — and where the spec constrains the *value* and
not the *representation*, the two runtimes are expected to differ. `char` is
exactly that case and is recorded below as a binding difference, not a bug.

### `char` — a binding difference, not a divergence

|        | cljw           | ClojureWit (JVM)     |
|--------|----------------|----------------------|
| `char` | Clojure `char` | `Integer` code point |

ClojureWit rejected `Character` because a JVM `Character` is 16-bit and
truncates the astral planes. That reason is host-specific and does not transfer:
cljw's char is a 21-bit code point. Verified 2026-08-04 —
`(char 0x10437)` returns `𐐷` on cljw and throws "Value out of range for char" on
JVM Clojure. Both bind the same semantic row (*a Unicode scalar value*); the
representation differs because the host char types differ. Shared Clojure glue
moving between the two must convert (`(int c)` / `(char n)`).

The surrogate-range hazard is shared: a value in `[0xD800, 0xDFFF]` is
representable on both hosts and must trap on lowering.

### Also corrected in the same cycle

The integer rows were a *panic* rather than a mapping: lowering used a bare
`@intCast` (a ReleaseSafe safety panic on out-of-range caller data) and lifting
`u64` did the same on **guest-controlled** data. Fixed in `3662d5a9` by sharing
`wasm/call`'s existing range check; `u64` above `i64` max and `s64` outside
`i48` now lift exactly via BigInt, which this table already promised.

### Not decided here

`own` / `borrow` are one table row over a two-tier behaviour — `own` wraps only
on the cached `component-call` path and lifts as a bare integer (no drop) on the
one-shot `component-invoke` path. That is a real gap and belongs to D-404's
resource phase, not to a mapping amendment.

The shared falsifier — one typed `echo` component driven by both repos — is the
mechanism that would keep the two tables from drifting again, and it discharges
D-404's stated blocker ("the full marshalling-table verification is BLOCKED on a
typed component FIXTURE") as a side effect. Recorded as the next step rather
than done here, because it is a cross-repo artifact with its own pinning
question.

## Amendment 3 (2026-08-04) — `result` / `variant` lowering existed only on paper

Amendment 2 opened by stating that "`component.zig` already lifts/lowers
record/tuple/variant/enum/option/result/flags/string/list per the §contract
table". The lift half was true. The lower half was not: `component.zig` raised
`feature_not_supported` for `result` **and** `variant` on the parameter side,
with the justification "rare on the input side".

Two things follow from that, and neither was visible while the claim stood:

- **A component taking a `result` or `variant` parameter could not be called at
  all** — not degraded, not approximate; the invoke aborted. `variant` is the
  Component Model's ordinary sum type, so this was not a corner.
- **The amendment's own round-trip was untestable.** The tagged-vector shapes
  `[:ok v]` / `[:err e]` / `[:case-name payload]` were decided *because* one
  destructuring idiom should cover every WIT sum type — but a shape the lift
  emits and the lower side rejects is not a round-trip, and nothing could have
  caught the disagreement.

The `echo` fixture this ADR names as the shared falsifier carries
`echo-result: func(v: result<u32, string>) -> result<u32, string>` and
`echo-shape: func(v: shape) -> shape` precisely to exercise the parameter
direction. Those two rows had never run.

**Decision**: both lower. `result` accepts `[:ok v]` / `[:err e]`; `variant`
accepts `[:case-name payload]`, with the payload slot present exactly when the
case's type says it is. The two share one shape-check helper, mirroring the way
the lift side shares one emitter — so the shapes cannot drift apart again
without the helper being edited.

A tag that names no case is an error rather than case 0, and a payload arity
disagreeing with the case type is an error in both directions. Silently picking
a case, or silently dropping a supplied payload, sends the guest a value the
caller did not write; for a sum type that is a wrong-branch bug in the guest,
not a lost detail.

Verified against the `echo` fixture (all five rows round-trip, including the
payload-less `[:point]`) and pinned by unit tests at the `lower()` boundary, so
the coverage does not depend on a component fixture the pin cannot yet open.

**Generalisation.** This is the fifth instance this cycle of *documented intent
vs implementation mismatch* — a doc naming a capability the code does not have.
The other four were caught by turning the claim into a gate. That is why the
coverage here is a unit test rather than a note: a claim nothing executes is
indistinguishable from a claim that is false.
