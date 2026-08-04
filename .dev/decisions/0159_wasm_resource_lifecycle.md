# ADR-0159 — Wasm Component `resource` lifecycle: `own`-handle ownership + drop (D-404 Impl E)

- **Status**: Proposed → Accepted (2026-06-21, user-directed; D-404 Impl E resource ergonomics; DA-fork incorporated)
- **Driven by**: ADR-0135 Amendment 1's promise that a `:require`d Wasm Component's
  exports feel native — including WIT `resource`s. Today an `own`/`borrow` handle lifts to
  a bare integer; methods work (the `resource_counter` demo returns 6) but nothing ever
  runs the guest `resource.drop` destructor for an `own` handle → a **resource leak** for
  the lifetime of the component.
- **Relates to**: ADR-0135 (component-as-namespace), ADR-0158 (single-binary embed),
  F-001 (zwasm embedding), F-006 (mark-sweep GC; cljw heap ⟂ Wasm linear memory — separate
  spaces), F-016 (always-latest). External: zwasm `Opened.dropResource` (REQ-5).

## Context

A WIT `resource` (e.g. `resource counter { constructor(start:u32); increment:func()->u32;
get:func()->u32 }`) exports a constructor returning `own<T>` + methods taking `borrow<T>`.
cljw's `invokeTyped` lift currently maps `.own`/`.borrow` → `Value.initInteger(handle)`, so
a handle is an opaque integer the Clojure code threads back into method calls. This works
but:

- **Leaks**: nothing calls `resource.drop`, so the guest destructor never runs until the
  whole component is torn down (the `ComponentLoaded` box's GC finaliser runs
  `Opened.deinit()`, which frees the entire resource table — so there is no leak *across*
  components, only *within* a long-lived component holding many short-lived resources).
- **Untyped**: a bare integer carries no own/borrow distinction and no tie to its owning
  component — a handle from component A could be passed to component B's method.

zwasm already exposes the mechanism: **`Opened.dropResource(handle: u32)` (REQ-5)** runs the
declared destructor for an `own` handle (graph path only; a single-module component has no
resource table → `NoResourceTable`). Verified zwasm semantics (`resource_table.zig`):

- **Double-drop traps** (stale handle) — drop is NOT idempotent; the cljw wrapper must guard.
- **Handle indices are reused** (free-list) — a handle is opaque, single-use across drop,
  scoped to one `Opened`; cljw must never cache/compare a handle past its drop.
- **`own` vs `borrow`**: dropping an `own` runs the destructor; dropping a `borrow`
  decrements the lender's `num_lends`; an `own` can't be dropped while lent
  (`HandleStillBorrowed`). cljw reads own-vs-borrow straight from the WIT result type
  (`resolveFuncSig` → `.own`/`.borrow`).

(A mailbox note `from_cljw_05` asks zwasm to confirm these four points; all are read from
zwasm source, so the design proceeds on them — confirmation is a safety check, not a gate.)

## The crux — finaliser ordering hazard (cljw-side, NOT a zwasm concern)

cljw's GC is **mark-sweep, non-moving** (F-006), with NO guaranteed finaliser ordering
between two host objects collected in the same cycle. An `own`-handle wrapper whose GC
finaliser calls `componentBox.opened.dropResource(handle)` risks a **use-after-free**: if
the wrapper AND the `ComponentLoaded` box are both unreachable in one GC cycle and
`componentFinalise` (which `Opened.deinit()`s) runs first, the resource finaliser touches a
freed `Opened`. Rooting the component from the wrapper (hold the component handle Value in
`host_trace`-marked state) keeps the component alive while a resource is *reachable*, but
does not order the two finalisers when both are simultaneously garbage. The Decision below
picks the rooting + ordering mechanism.

## Decision

**Deterministic release is the contract; the resource wrapper's finaliser NEVER touches
zwasm state.** An `own` result becomes a typed wrapper; release is via a deterministic
`(wasm/resource-drop h)` / a `with-resource` scope (the Clojure-idiomatic `with-open`
pattern), and `componentFinalise`'s existing `Opened.deinit()` drains the whole resource
table at component teardown as the backstop. The wrapper roots its owning component (so a
held resource cannot outlive its `Opened`), but carries **no finaliser that calls
`dropResource`**.

Concretely:

1. **Wrapper**: an `own` result → a `.host_instance` (`resource_descriptor`) with
   `state = { component-handle Value (state[0]), raw handle u32 (state[1]), dropped-flag
   (state[2]) }`. `descriptor.host_trace` marks state[0] (the `ComponentLoaded` box Value),
   rooting the component while any resource is reachable — the java.util.Iterator
   cursor-rooting precedent (mark-only, non-moving GC; `gc_rooting.md §H`). **No
   `host_finalise`** on the resource wrapper.
2. **lower**: a wrapper passed to a `borrow`/`own` param yields state[1] (the raw handle);
   a wrapper whose dropped-flag is set raises a use-after-drop error before the call.
3. **release** (`(wasm/resource-drop h)` / `with-resource` exit): if not already dropped,
   reach the component via state[0] → `ComponentLoaded.opened.dropResource(state[1])` + set
   the one-shot dropped-flag (double-drop guarded cljw-side; `dropResource` would otherwise
   trap on the stale handle). Safe because the caller holds the wrapper, which roots the
   component → `Opened` is live at the call.
4. **backstop**: `componentFinalise` already runs `Opened.deinit()`, freeing the entire
   resource table — every un-dropped resource is released at component teardown.

### Divergence from the Devil's-advocate recommendation (the safety correction)

The DA recommended **C+** = `with-resource` + a **B′ registry where the resource wrapper's
finaliser deregisters-and-drops** ("valid because the rooting edge proves `Opened` is alive
at that instant"). **This per-resource-finaliser drop is NOT safe in cljw's GC** and is
therefore rejected: rooting via `host_trace` keeps the box alive only while the resource is
**reachable**; once the resource is garbage it no longer marks the box, so when a resource
and its component become garbage in the **same mark-sweep cycle**, both are swept together
with no ordering guarantee (the DA's own fact 4). At the resource finaliser's instant the
box may already be freed — so *any* box/`Opened` touch from the resource finaliser (drop OR
even "deregister", which dereferences the box's intrusive set) is a potential
use-after-free. The structurally safe form removes the resource finaliser entirely: the
wrapper holds the component Value by `host_trace` (a passive mark, no finaliser), release is
deterministic (held wrapper ⇒ live component), and the only GC-time drop is
`componentFinalise` draining its OWN table — exactly one finaliser, touching only state it
owns. The DA's deterministic-`with-resource`-is-the-finished-form thesis is adopted; only
its unsafe per-resource-finaliser path is dropped (this is a correctness divergence, not a
cycle/LOC downgrade — F-002 is upheld: the chosen form is *more* correct, not smaller).

### Scope / known limitation (documented, not a leak)

An individual resource that is GC'd **without** an explicit `resource-drop` / `with-resource`
is released at **component** teardown, not at its own death. For a long-lived component
minting many short-lived resources, use `with-resource` for timely release. This is the safe
trade vs. an unsafe finaliser; "GC drop" is honoured as *component*-GC drops all its
resources. The one-shot `(wasm/component-invoke …)` path (no cached component) keeps the
bare-integer lift for `own` results — there is no persistent component to own them; the
typed wrapper applies to the `require-component` / `component-call` cached-handle path.

## Alternatives considered

*(Devil's-advocate fork, fresh context, verbatim — the per-resource-finaliser-drop in its
B′/C+ is corrected in the Decision's "Divergence" note above.)*

> **Leading finding — no F-NNN is violated by any candidate.** A GC-finalizer drop touches
> only zwasm's `Opened` (zwasm's separate space, F-006), reached through a cljw-side pointer
> the resource wrapper already holds; it never traces Wasm linear memory into cljw's heap,
> never unifies the two spaces. F-001/F-006/F-016/F-002 are all satisfiable by every shape
> below. The real axis is **finalizer-ordering safety + idiomatic determinism**, not law.
>
> **(1) Smallest-diff — A, explicit-drop-only.** `own` becomes a thin wrapper host_instance
> holding `{component-handle Value, handle:u32, dropped-flag}`; `host_trace` marks the
> component Value; `(wasm/resource-drop h)` calls `opened.dropResource`, flips the one-shot
> flag; double-drop guarded cljw-side; NO finalizer drop. Leak bounded by `componentFinalise`'s
> full-table teardown. *Better*: zero finalizer-ordering surface — the hazard cannot arise.
> *Breaks*: contradicts ADR-0135's "GC drop"; a resource never explicitly dropped lives until
> *component* teardown — a long-lived component minting many short-lived resources accumulates
> dead handles.
>
> **(2) Finished-form-clean — B′, finalizer-via-registry (the box drops, not the resource).**
> GC-finalizer auto-drop, but the resource finalizer never calls `dropResource` directly;
> the `ComponentLoaded` box owns an intrusive set of live handles; the wrapper roots the box;
> the wrapper's finalizer only deregisters; `componentFinalise` drains the set before
> `opened.deinit()`. *Better*: true GC-lifecycle drop with the ordering hazard structurally
> dissolved — exactly one site touches `Opened`. *Breaks*: the per-resource immediate-drop-on-
> deregister path must prove the box is alive at that instant; double-drop guard still needed;
> the intrusive set must be freed; `HandleStillBorrowed` means a still-lent `own` can't drop.
>
> **(3) Wildcard — C+, `with-open`/`with-resource` deterministic scope + B′ backstop.**
> Primary path is `(with-resource [c (counter/new 5)] …)` dropping at scope exit
> (idiomatic, `with-open`-shaped); the GC-finalizer (B′) is best-effort for escapees.
> *Better*: deterministic release is the Clojure-idiomatic answer AND has a real backstop.
> *Breaks*: largest surface; scope-exit drop and the backstop must share the one-shot flag
> or double-drop; the macro needs a `try/finally` lowering.
>
> **Recommendation: adopt C+ layered on B′** (deterministic `with-resource` as the contract,
> registry-backed finalizer where the box drops). Per F-002 do NOT downgrade to A on
> diff/LOC grounds — A leaves "drop-when-the-value-dies" unsolved.
>
> **What the implementer must verify first:** that the fixture's only drop-observable signal —
> a method on a dropped handle *traps* — is reachable through cljw's catch surface as a
> deterministic assertable error, AND that the rooting edge keeps the box alive across a
> forced GC while a resource is reachable.

## Consequences

- Resources are released **deterministically** (`with-resource` / `resource-drop`) or at
  **component teardown** (the `Opened.deinit()` backstop) — no leak across components, and
  **no use-after-free** (no resource-finaliser → `Opened` path).
- An `own` handle is a **typed wrapper tied to its component** (can't be passed to another
  component's method); double-drop is guarded; use-after-drop raises a catchable error.
- **Limitation** (documented above): an un-scoped individual resource releases at component
  teardown, not at its own GC — `with-resource` is the timely path. One-shot
  `component-invoke` keeps the bare-int `own` lift.
- Implementation is incremental: **cycle 1** = the wrapper + `host_trace` rooting + lift/lower
  + `(wasm/resource-drop)` + the use-after-drop guard + the "method-on-dropped-handle traps"
  e2e; **cycle 2** = the `with-resource` macro sugar. Both deliver the same finished form;
  each is independently green.

## Affected files (when implemented)

- `runtime/cljw/wasm/component.zig` — the `own`-handle wrapper (`.host_instance` +
  `resource_descriptor` with `host_finalise`/`host_trace`); `lift`/`lower` changes to wrap
  an `own` result + extract the raw handle from a wrapper passed to a `borrow`/`own` param.
- `lang/clj/cljw/wasm.clj` — the surface (`require-component*` interns method Vars; a drop
  form / `with-open` per the Decision).
- e2e `phase16_wasm_require_component.sh` + a fixture — drop observed via "method on a
  dropped handle traps" (the `resource_counter` fixture has no drop-observable export).

## Amendment 1 (2026-08-04) — the one-shot's `own` was a dangling number, and the "tied to its component" Consequence was never enforced

This ADR's Scope section reads: "The one-shot `(wasm/component-invoke …)` path
(no cached component) keeps the bare-integer lift for `own` results — there is
no persistent component to own them." That framed the one-shot lift as
*untyped*. It is worse than untyped: `componentInvokeFn`'s `defer opened.deinit()`
destroys the instance and its resource table **before the Value reaches the
caller**, so the integer is already invalid when it is returned.

Measured on `resource_counter`: the one-shot constructor returned `1`, and
passing that `1` to a method gave an opaque "WebAssembly module trapped". It
trapped only because the fresh instance's table happened to be empty. zwasm's
`resource_table.zig` is a dense per-instance array with index 0 reserved, so
**the first resource any instance mints is handle `1`** — one `resource.new`
away, that same call silently succeeds against a *different* object.

Reviewing the fix surfaced two more holes on the path this ADR recommends as
the cure, both of which contradict its own Consequences:

- `rawResourceHandle` accepted a bare integer via `@intCast(v.asInteger())`.
  `asInteger` does not check the tag, so any Value became a table index, and a
  negative integer was a **ReleaseSafe `@intCast` panic on caller data** — the
  exact host-crash class the numeric marshalling rows in the same file had
  already closed.
- Nothing checked that a resource wrapper belonged to the component being
  called. This ADR's Consequences claim an `own` handle "can't be passed to
  another component's method"; that was never implemented. Two live components
  each holding a resource at index 1 meant `(wasm/component-call c method a)`
  operated on `c`'s resource while reading as `a`'s.

### Decision

**The component's lifetime is its reachability whenever the result names
something inside it.** `componentInvokeFn` heap-allocates the same
`ComponentLoaded` triple `wasm/load-component` builds, and decides from the
resolved signature — before invoking — which lifetime applies:

- result holds no resource → the triple is freed at return, exactly as before;
  the common case is unchanged and still deterministic.
- result holds a resource at any depth → the triple goes into the GC-owned box,
  the `own` lifts through the existing `makeResourceHandle`, and `resourceTrace`
  roots the component for as long as the resource is reachable.

`own` therefore has ONE meaning on both entry points, which discharges the gap
ADR-0135 amendment 2 recorded as "a real gap … `own`/`borrow` are one table row
over a two-tier behaviour". `component-invoke` becomes `component-call` where
the component is anonymous — a difference in naming, not in what values mean.

Two consequences of that principle, landed in the same cycle:

- **A resource handle names its own component**, so `wasm/component-call`
  accepts one as its first argument. Without this a resource returned by a
  one-shot invoke would be live but unusable: its component has no other name,
  and the caller could only drop it, never call a method.
- **`rawResourceHandle` takes only a wrapper, and only one whose owner is the
  component being called.** There is no legitimate source of a raw handle
  number — every one a caller can hold came out of a component call already
  wrapped. Two new Codes (`wasm_resource_expected`, `wasm_resource_foreign`)
  rather than reusing `wasm_opts_invalid`, whose template hard-codes
  `wasm/load:` and would mislabel the raise site.

`witTypeHoldsResource` recurses through list / option / tuple / record /
variant / result: a top-level-only check would send
`record { text: string, handle: own<T> }` down the teardown branch and
reproduce the defect one level down.

`openComponentBoxed` / `freeComponentBox` now hold every partial-failure unwind
for the triple, and both entry points use them. That is not tidying: the
one-shot decides ownership *after* opening, so caller-side `errdefer`s for the
same resources fire alongside its own teardown. The first version of this fix
did exactly that and segfaulted on `0xaa…` — freed memory — on the error path.

### Verification

`test/e2e/fixtures/wasm_component_probe.clj` gains two cases, both of which fail
against the pre-fix binary (checked by rebuilding without the source change):
the one-shot resource surviving a forced `System/gc` and a full
construct → method → drop → use-after-drop chain, and the cross-component
rejection in both directions plus the raw-integer and negative-integer cases.
`witTypeHoldsResource`'s recursion is unit-tested at every arm, including
`list<record { handle: own<T> }>`, because no fixture in the tree has an
aggregate carrying a resource.

### What this does not change

The GC-drop limitation stands: an un-scoped resource still releases at component
teardown rather than at its own death, and `with-resource` remains the timely
path. That is now uniform across both entry points instead of applying only to
one.

### Alternatives considered (amendment 1)

*(Devil's-advocate fork, fresh context, verbatim. Its "facts verified in code"
preamble is preserved because the three code findings in it — the pre-call
placement, the dense-table handle numbering, and the two unenforced holes on the
cached path — are what changed the shape of this amendment.)*

> **Leading finding — no F-NNN blocks any candidate below.** Every shape keeps the `Opened` in zwasm's separate space (F-006) and reaches it only through a cljw-side pointer the wrapper already holds; none traces Wasm linear memory into cljw's heap; none needs a zwasm API that the v2.4.0 pin lacks (F-001). The axis is **where the owner identity lives**, not law. Per F-002 the recommendation below is the largest-diff shape.
>
> **Facts verified in code, not assumed.**
>
> 1. *The result type is known before the call.* `invokeOnOpened` resolves `sig` and does not call `invokeTyped` until later. `sig.result` and every `sig.params[i].ty` are in hand, fully expanded (zwasm's `resolveFuncSig` chases named/nested provenance and preserves `own`/`borrow` at every depth). **Any rejection must be pre-call.** The draft as stated ("lift the result, notice it contains `own`, raise") runs the guest constructor first: the resource is minted, the guest allocates, any WASI side effect the export performs has happened, and only then does the caller get an error. Pre-call refusal is both cheaper and semantically different — it is the only form where "this call is not expressible" is true rather than "this call already happened and I am discarding it".
> 2. *The integer has no cross-instance meaning — provably, not probably.* zwasm's `resource_table.zig` is a per-`WasiP2Ctx` dense `slots` array plus a `free` list, with index 0 reserved as the `None` sentinel and freed slots tombstoned and **reused**. `add` returns `slots.items.len` on an empty table, i.e. **the first resource any fresh instance mints is handle `1`**. The measured trap is therefore the benign corner of the defect; the malign corner ("index 1 names a different object and the call silently succeeds") is exactly one `resource.new` away. There is no cross-instance semantics to preserve, so no alternative needs to keep the integer for compatibility. The only surviving "legitimate" use is a handle the caller intends to *ignore* — which matters for the compound-result case below.
> 3. *The same defect is live on the parameter side, and it is worse.* `rawResourceHandle` falls through to `@intCast(v.asInteger())` for any non-wrapper. `Value.asInteger` is an unchecked `@truncate` + `@bitCast` — it does not verify the tag. So `(wasm/component-call c method "oops")` indexes a table with garbage, and a negative integer (`-1`) is a **ReleaseSafe `@intCast` panic on caller data** — precisely the host-crash class this file's own comments congratulate themselves on having closed for the numeric rows. Furthermore `lower` never receives the callee's component identity, so a wrapper minted by component A is accepted verbatim by component B's method. **ADR-0159's Consequences claim "an `own` handle is a typed wrapper tied to its component (can't be passed to another component's method)" is not enforced anywhere in the code.** A change that fixes only the one-shot lift ratifies a same-shaped bug on the path it recommends as the cure.
> 4. *A one-shot invoke whose PARAMS contain `own`/`borrow` is unusable for the identical reason.* The instance is opened inside `componentInvokeFn` with an empty table; no handle the caller could possess names anything in it. The draft does not cover this.
> 5. *`component-invoke` has no user-facing contract to break.* It is interned with `null` meta (no docstring); `docs/` never mentions it; its only description is a Zig doc comment calling it "the experiment's roundtrip probe". ADR-0135 Amendment 2 already records this exact split as "**a real gap**". Latitude to redefine it is total.
> 6. *Precedent.* wasmtime does not answer this with "use the other API". `ResourceAny` carries its store's identity and a cross-store use is a **detected error at the use site**; the `&mut Store` borrow makes it structurally impossible for a handle to outlive the store as a usable thing. The industry answer is *make the handle carry its owner and validate at use*, not *refuse the call*. JVM Clojure's nearest idiom is `with-open`: it does not forbid a function from returning the stream it closed; the failure is `IOException: Stream closed` at use.
>
> **(1) Smallest-diff — pre-call refusal (the draft, corrected).** In `invokeOnOpened`, immediately after `sig` resolves and **before** `invokeTyped`, when `component_handle == null`, walk `sig.result` and every `sig.params[i].ty` with a small recursive `containsResource(WitType) bool` and raise. Add a dedicated Code rather than reusing `.wasm_opts_invalid`, whose template is hard-coded `"wasm/load: {detail}"` and would mislabel the raise site.
> *Better than the others*: nothing invalid is ever constructed, and no guest code runs before the refusal — the diagnosis is deterministic instead of depending on whether the fresh instance's table happens to be empty. Smallest surface, no lifetime change, no GC interaction.
> *Breaks*: it rejects the **whole call** when the resource is an ignorable leaf — `record { text: string, handle: own<T> }` now returns nothing, and the perfectly-liftable `text` is lost. It makes `component-invoke` non-total over the export surface `component-exports` advertises, so any code generator driven by that listing acquires holes. And it leaves fact 3 untouched: the bare-integer acceptance and the missing owner check on the *cached* path are the same bug wearing a different hat, and this alternative sends users toward them.
>
> **(2) Finished-form-clean — delete the one-shot's private lifetime; the component is owned by whoever can still reach it.** `componentInvokeFn` stops being a second implementation of instantiation. It allocates the `Engine`/`WasiHost`/`ComponentLoaded` triple on the heap exactly as `loadComponentFn` does (today they are **stack locals** — that is the whole mechanism of the bug), wraps it in the `component_descriptor` host_instance, and passes that Value into `invokeOnOpened` as `component_handle`. An `own` result then lifts through the *existing* `makeResourceHandle`, whose `resourceTrace` already roots the component; `wasm/resource-drop` and `with-resource` work identically on both paths; `componentFinalise`'s `Opened.deinit()` remains the backstop. Deterministic teardown is preserved for the overwhelmingly common case by deciding pre-call from `sig.result`: **no resource in the result ⇒ tear down at return exactly as today; resource in the result ⇒ the component's lifetime is its reachability.** One sentence describes it: *the component lives as long as anything can still name a thing inside it.*
> The same cycle closes fact 3, which this shape exposes rather than creates: `rawResourceHandle` stops accepting bare integers (a resource param must be a wrapper — a raw index is not a value a user can legitimately construct), and `lower` gains the callee's component identity so a wrapper whose `state[0]` is a different component is rejected with a named error instead of indexing a foreign table. That check also subsumes alternative (1)'s parameter case for free: the only wrapper you could pass to a one-shot invoke belongs to some other component, so the identity check produces the right diagnostic without a separate rule.
> *Better than the others*: it deletes the defect class instead of diagnosing it. `own` acquires **one** meaning across every entry point, which discharges the gap ADR-0135 Amendment 2 explicitly deferred, and reduces `component-invoke` to "`component-call` where the component is anonymous" — a difference in *naming*, not in *what values mean*. The compound-result case returns everything, usable. It is the shape wasmtime arrived at (owner-carrying handle, validated at use).
> *Breaks*: the largest diff — `componentInvokeFn` inherits `loadComponentFn`'s `errdefer` LIFO discipline, and the conditional-teardown branch is a second lifetime rule inside one function, which must be documented at the function, not only in the ADR. The real residual cost is F-006-adjacent: Wasm linear memory is invisible to cljw's GC pressure heuristics, so a loop of one-shot invokes each returning a resource can hold many instances alive until a cljw-heap-triggered collection. That exposure already exists for `load-component`; this makes it reachable from a function whose name reads "one-shot". The honest mitigation is documentation plus `with-resource`, not a smaller design.
>
> **(3) Wildcard — the born-dropped tombstone.** Lift `own`/`borrow` on a component that is about to be torn down into the same `resource_descriptor` host_instance, but constructed **already dropped**: `state[2] = 1`, `state[0]` empty. The call succeeds, the enclosing record/tuple/list lifts intact, `wasm/resource-drop` is a no-op (it is already idempotent), and passing it anywhere raises the **existing** `.wasm_resource_dropped` — "wasm component resource handle used after it was dropped", which is *literally true*: the one-shot teardown dropped it. No new error Code, no lifetime change, ADR-0159's guard reused verbatim.
> *Better than the others*: it preserves partial results and does not punish a call made for its side effects; the failure lands at the point of misuse rather than at a call the user may have had every right to make; and it is honest about the mechanism (the instance died at return) instead of asserting the operation is unsupported.
> *Breaks*: it manufactures a value whose only purpose is to fail later — a subtler contract than an error, and a caller who ignores the result learns nothing, which is how the current bug got shipped. `resourceTrace` unconditionally does `@enumFromInt(state[0])` and marks it, so an empty `state[0]` needs an explicit guard — the tombstone is not free in the GC surface. It perpetuates the two-tier `own` mapping ADR-0135 already flagged. And it leaves the deferred-error debugging distance essentially where the bug is today; only the message improves. There is also no `wasm/resource-dropped?` predicate today, so the tombstone is not even inspectable without adding one.
>
> **Recommendation: (2), explicitly citing F-002.** (1) is the smaller diff and (3) is the cleverer one, but both accept as permanent the thing that produced this bug: **one WIT type having two meanings depending on which cljw function you entered through.** (2) removes the second meaning. Do not downgrade to (1) on diff size — the diff is larger precisely because it also closes the unenforced ADR-0159 Consequence (bare-int acceptance, missing owner check, `asInteger` panic on caller data), which is the same defect on the path the draft would recommend as the cure. If (2) is rejected, then (1) must still be taken **with** the parameter arm, the pre-call placement, and a separate follow-up row for the cached-path holes — the draft as written covers none of the three.
>
> **What the implementer must verify first.** (a) That a one-shot `own` result actually reaches the wrapper path — `Opened.dropResource` is `NoResourceTable` for the `.single` variant, so a resource-bearing single-module component would surface as the catch-all `.wasm_trap` ("WebAssembly module trapped"), a misleading message that deserves its own Code under **any** of the three shapes. (b) That the rooting edge survives a forced GC between the invoke's return and the resource's first use. (c) `test/e2e/fixtures/wasm_component_probe.clj` currently has **no** one-shot resource case at all; the winning shape needs a probe there driving `resource_counter`'s constructor through `component-invoke`, plus its expectation line in `test/e2e/phase16_wasm_component.sh`, or the same false-positive-discharge class that `clj_diff_sweep.md` Discipline 1 was written against reappears.

**Adopted: (2)**, per F-002 and the DA's own reasoning. Its three
implementer-verification items were all discharged in this cycle: (b) the forced
`System/gc` assertion and (c) both e2e probes are in
`wasm_component_probe.clj`. (a) remains open as a message-quality gap — a
`.single`-variant component carrying a resource surfaces `NoResourceTable` as
the catch-all `wasm_trap`; tracked as **D-568**, not fixed here because no
fixture in the tree reaches it.

## Revision history

- 2026-08-04: Amendment 1 — one-shot `own` lifetime + the two unenforced
  cached-path holes (`wasm_resource_expected`, `wasm_resource_foreign`).
