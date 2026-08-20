# 0055 — `binding` special form + cw v1's first dynamic var (`cljw.error/*error-context*`) + error-context capture

**Status**: Accepted (Devil's-advocate fork landed 2026-05-29)
**Date**: 2026-05-29
**Author**: Shota Kudo (drafted with Claude autonomous loop)
**Tags**: dynamic-var, binding, special-form, error-context, with-context, F-002, F-004, F-009, D-075, D-141-sibling, row-14.13

## Context

Row 14.13 deliverable (3) is `cljw.error/with-context`: `(with-context
{:request-id … :trace-id …} body)` stacks a context map on a dynamic
var; when an error event is emitted (EDN render in
`src/app/error_render.zig::formatErrorEdn`) the merged map's keys become
top-level event fields.

A Step-0.6 re-lay (survey `private/notes/phase14-14.13-binding-survey.md`
§9) found the handover's "narrow prerequisite = just the `binding`
special form" **wrong on a load-bearing point**:

- cw v1 has **ZERO production dynamic vars**. The dynamic-binding runtime
  machinery is fully built (`env.zig`: `BindingFrame`, threadlocal
  `current_frame`, `pushFrame`/`popFrame`/`findBinding`, `Var.deref`
  consulting the chain when `Var.flags.dynamic`), and both backends honor
  `DefNode.is_dynamic → Var.flags.dynamic` — but `analyzeDef` NEVER sets
  `is_dynamic` from surface syntax, and `^:dynamic` reader metadata is
  unimplemented (`(def ^:dynamic *x* 1)` → "def expects 1 or 2 args, got
  3"). Surface `^:keyword` metadata = **D-075** (a ~500-LOC Phase-7+
  feature) and is **F-004-entangled** (per-value metadata NaN-box slot is
  "未確定, decided at Phase 5 entry").
- So `with-context` needs cw v1's **first dynamic var**, and the natural
  `(def ^:dynamic *error-context* {})` will not parse.
- `binding` is also unimplemented (absent from the analyzer special-form
  set; `pushFrame`/`popFrame` have zero production call sites).
- Read-side constraint: the `binding` frame is popped (Zig `defer
  popFrame`) as an error unwinds, so by render time the frame is GONE —
  the context must be snapshotted **at raise time** while the frame is
  live. And `catalog.zig::raise(comptime code, location, args)` has **no
  `rt`/`env` access** (verified) — it only populates the threadlocal
  `Info`. So an Env-scoped slot reachable from raise is infeasible
  without rippling raise's signature across ~100 call sites.

## Decision

### D1: `binding` is a real special form (`BindingNode`), not a macro-transform

Diverges from JVM (a `defmacro` over `push-thread-bindings`/try/finally)
AND cw v0 (`transformBinding` macro). cw v1's analyzer special-form set +
dual-backend Node contract make a dedicated `binding_node` the
finished-form-clean shape: no dependency on a `var`/`hash-map`/`try`
macro chain, no per-call hash-map Value allocation, dynamic-var
resolution at analysis time. (ROADMAP A2 "features via the analyzer
surface" + F-002.)

- **Analyzer** (`bindings.zig::analyzeBinding`): even-position symbols
  resolve to their existing `*Var` (same qualified/alias/current-ns path
  as `analyzeSymbol`), NOT a lexical slot; odd-position init-exprs analyze
  in the OUTER scope (JVM parallel-eval); body analyzes in the same scope.
- **TreeWalk** (`evalBinding`): stack `BindingFrame`, eval inits in outer
  `locals`, validate each target `flags.dynamic` (else raise the new
  catalog Code), `pushFrame` + `defer popFrame()` (Zig defer = JVM
  finally), eval body.
- **VM** (real arm, no VM-DEFER — per F-002 + the handover's explicit
  "analyzer + tree_walk + vm" scope): two opcodes
  `op_push_binding_frame` / `op_pop_binding_frame`, compiled in the
  `try { push; body } finally { pop }` shape (the binding's own cleanup
  handler always pops the frame before an exception escapes its extent,
  reusing the existing `op_push_handler`/`op_pop_handler` unwind — so no
  threadlocal dangle on uncaught throw, and no new unwind path). The VM
  shares `env.zig`'s threadlocal `current_frame` (single-threaded per
  session), keeping `Var.deref` backend-agnostic.
- **Validation**: new catalog Code `binding_target_not_dynamic` ("Can't
  dynamically bind non-dynamic var: ns/name", JVM-faithful text per
  `error_catalog_only.md`), raised at eval/push time (JVM-faithful site).

### D2: cw v1's first dynamic var = Zig-registered `cljw.error/*error-context*`

`*error-context*` is interned at bootstrap into the `cljw.error` ns with
`flags.dynamic = true` set directly (no `MetadataMap` change, no reader
metadata, no F-004 value-metadata touch), root `{}`. System dynamic vars
being Zig-registered is the finished form (JVM's `*out*`/`*ns*` are
bootstrap-created clojure.core vars); this is NOT a stopgap. **User-facing
`^:dynamic`** (so users mark their OWN dynamic vars) stays deferred to
D-075 — with-context does not need it, and when D-075 lands NOTHING about
with-context changes (it was already `binding` over a real dynamic var).

### D3: read-side = global `*Var` slot + raise-time snapshot into `Info.context` + render via `printValue`

- A `?*const Var` slot in `runtime/error/` (next to the other error
  threadlocals), set when `*error-context*` is registered.
- `setErrorFmt`/`raise` snapshots `slot.?.deref()` into a new
  `Info.context: ?Value` field (default null) **at raise time** (frame
  live). Non-map / empty-map → leave null.
- `formatErrorEdn` (Layer 3) iterates `info.context`'s map entries and
  emits each `key value` pair as a top-level EDN field, rendering via the
  **canonical `runtime/print.zig::printValue`** (exists; Layer 0) — NOT a
  second hand-rolled printer.
- The slot is a **process-global**, not Env-scoped: raise has no env
  access (an Env-scoped slot would ripple raise's signature across ~100
  sites). For the single-Env CLI path (the only path that renders EDN
  error events — nREPL returns errors to the client, bypassing
  `renderError`) this is correct. The multi-Env-nREPL-EDN-error case is
  recorded as **D-142**.
- Field is **specific `Info.context`**, not a generic `Info.data`
  ex-info payload: ex-info `Info`-integration is not scoped here and a
  generic field would over-fit a not-yet-landed shape (Reservation-as-bias
  per F-002). It can generalize when ex-info `Info`-payload lands.

### D4: `with-context` = thin `.clj` macro over `binding`

New ns `cljw.error` at `src/lang/clj/cljw/error.clj` (new
`src/lang/clj/cljw/` dir) + an `@embedFile` row in `bootstrap.zig` FILES
after `core.clj` (needs `merge`/`defmacro`/`binding`). The `*error-context*`
Var is Zig-registered into the same ns before/at load.

```clojure
(in-ns 'cljw.error)
(defmacro with-context [ctx-map & body]
  `(binding [*error-context* (merge *error-context* ~ctx-map)] ~@body))
```

`merge` against the current `*error-context*` gives the stacking
(nested with-context accumulate). Reached as `(require [cljw.error :refer
[with-context]])` (F-009: `cljw.*` is the cljw-original ns family).

## Alternatives considered

(Devil's-advocate subagent, fresh context, F-NNN envelope — output
verbatim. The DA assumed raise could reach `rt.env`; the main loop
verified it CANNOT, which is why D3 takes the process-global slot rather
than the DA-recommended Env-scoped slot.)

> **F-NNN clearance for all three:** none violates an F-NNN. All avoid
> touching NaN-box layout / per-value metadata / `with-meta`/IObj
> (F-004), keep impl namespace-neutral with `cljw.error` as a thin
> Clojure-ns surface (F-009), and ship a working read-side (no forbidden
> no-op). The `binding` special form lands in all three. The decision is
> purely the var-creation + snapshot wiring.
>
> **Alt 1 — Smallest-diff: Zig-registered var, raise snapshots into
> `Info.context: ?Value`.** Error subsystem stores the `*Var` in a
> global/threadlocal slot; `raise` reads `if (ctx_var) |v| info.context
> = v.deref()`. `info.zig` already imports `Value` (layering clean).
> `formatErrorEdn` walks the map → top-level EDN keys. *Better:* smallest
> moving surface; the Var-pointer-in-error-subsystem slot dissolves the
> Layer-3↔Var coupling. *Breaks:* (1) a global `*Var` slot is
> process-wide mutable state — a second Env (nREPL) races on it; should
> be threadlocal/Env-scoped. (2) a `deref()`+field-set on EVERY raise
> (incl. ~100 internal raises with no context) is an always-on cost. (3)
> the EDN map-walk still needs a Value→EDN printer; `error_render.zig`
> has none — real work the proposal hand-waves.
>
> **Alt 2 — Finished-form-clean: generic `Info.data: ?Value` +
> Env-scoped dynamic-var registry; render via the canonical Value EDN
> printer.** Same Zig-registered var, but (a) an `Env.system_vars`
> registry (home for every future Zig-owned dynamic var `*out*`/`*ns*`/
> `*print-length*`) reached via `rt.env` so multi-session is correct by
> construction; (b) `Info.data` as a generic ex-info-style payload, not a
> context-specific field; render through the canonical Value→EDN printer
> cw needs anyway. *Better:* this is where the finished form lives — Alt
> 1's error-only slot gets unwound the moment `*out*` arrives
> (Reservation-as-bias); `Info.data` matches cw's ex_info direction;
> forcing the canonical printer kills the duplicate-printer smell;
> multi-session correctness falls out. *Breaks:* substantially larger;
> the system-var registry is a structural-plan touch that F-003 says to
> imagine-and-defer to the owning Phase (10/15 owns `*out*`); routing
> through the canonical printer may pull its scheduling forward;
> `Info.data` risks over-fitting a guessed ex-info shape (premature
> reservation) — UNLESS the registry is scoped to just `error_context`
> today (one field), barely larger than Alt 1 but multi-session-correct.
>
> **Alt 3 — Wildcard: no `Info` field — render-time deref through an
> error-subsystem callback.** Keep `Info` a pure scalar; install a
> `?*const fn() ?Value` provider; to beat frame-already-popped, capture
> the live frame pointer at raise and deref lazily at render. *Better:*
> most decoupled; `Info` stays Value-free; generalizes to "any subsystem
> contributes EDN fields". *Breaks:* capturing the stack-allocated
> frame pointer for later deref is a use-after-return; to be safe you
> must snapshot the VALUE at raise anyway — at which point the callback
> buys nothing over a field and adds a hop + the same global-slot race.
> Highest complexity, lowest payoff.
>
> **Recommendation (non-binding):** Alt 2 scoped down to one field —
> Zig-register `*error-context*`, reach it from raise via an Env-scoped
> slot (NOT process-global), snapshot `deref()` at raise into a generic
> `Info.data: ?Value`, render via the canonical Value→EDN printer. Do NOT
> build the full system-var registry now (F-003 defer — one
> `Env.system_vars.error_context: ?*Var` field is enough; debt-row the
> generalization). The two clean wins independent of the field's name:
> Env-scoped slot (kills the multi-session race) + canonical printer
> (kills the duplicate printer).

## Selection rationale

Took Alt 1's **var-creation mechanism** (Zig-registered system var) + the
DA's **canonical-printer** clean win (`printValue` exists — feasible),
and **rejected** the DA's Env-scoped-slot recommendation on a fact the DA
could not see: `catalog.zig::raise` has **no `rt`/`env` parameter**, so an
Env-scoped slot is unreachable from the snapshot site without a
~100-site signature ripple — disproportionate, and the EDN-error path is
single-Env (CLI) in practice (nREPL bypasses `renderError`). The
multi-Env race the DA flagged is therefore latent, not manifest; recorded
as **D-142** for the nREPL-EDN-error owner.

Rejected the DA's generic `Info.data` for a **specific `Info.context`**:
ex-info `Info`-payload is not scoped here, and a generic field would be a
Reservation-as-bias bet on a not-yet-landed shape (F-002). Rejected the
full `Env.system_vars` registry per the DA's own F-003 caveat — but since
the slot can't be Env-scoped anyway (raise has no env), the registry
question is moot for this cycle.

This shape is finished-form-clean for the with-context FEATURE: when
D-075 lands user `^:dynamic`, with-context is unchanged (it was already
`binding` over a real dynamic var; `*error-context*` stays Zig-registered
like `*out*`). A primitive push/pop with-context (no dynamic var) would
be unwound by that finished form = smallest-diff bias, so it was rejected.

## Consequences

- cw v1 gains its first dynamic var + the general `binding` special form;
  `binding` is dogfooded by with-context.
- The VM gains a real `binding` arm (not VM-DEFER) — the first
  control-construct beyond `try` to share the handler-unwind machinery.
- `Info` gains an optional `context` Value field; `formatErrorEdn` gains
  a context-merge loop (only the `edn` format carries structured fields;
  `text` is unaffected).
- Process-global `*error-context*` `*Var` slot: correct for CLI, latent
  multi-Env race recorded as D-142.
- User-defined `^:dynamic` stays deferred to D-075; `binding` only works
  on system (Zig-registered) dynamic vars until then.

## Affected files

- `src/eval/node.zig` (+`BindingNode`, union arm)
- `src/eval/analyzer/analyzer.zig` (special-form set + dispatch)
- `src/eval/analyzer/bindings.zig` (`analyzeBinding`)
- `src/eval/backend/tree_walk.zig` (`evalBinding` + node switch)
- `src/eval/backend/vm/opcode.zig` (+2 opcodes)
- `src/eval/backend/vm/compiler.zig` (`compileBinding`)
- `src/eval/backend/vm.zig` (dispatch arms + binding-frame stack)
- `src/runtime/error/catalog.zig` (+`binding_target_not_dynamic`)
- `src/runtime/error/info.zig` (+`Info.context` + `context_provider` hook + raise-time snapshot)
- `src/runtime/error/context.zig` (new — the `*Var` slot + `current`/`clear` + `register`)
- `src/runtime/env.zig` (+`on_deinit_hook` so the slot can't dangle past its Env)
- `src/app/error_render.zig` (`formatErrorEdn` context merge via `printValue`)
- `src/lang/clj/cljw/error.clj` (new — `with-context`)
- `src/lang/bootstrap.zig` (embed row + `error_context.register` in setupCore)
- `src/lang/diff_test.zig` (+`binding` case)
- `test/e2e/phase14_binding.sh` + `test/e2e/phase14_with_context.sh` (new)
- `.dev/debt.yaml` (D-142 multi-Env nREPL slot; D-144 user-throw EDN context)

## Revision history

- 2026-05-29 created: row 14.13 (3) re-lay after the Step-0.6
  prerequisite-gap finding (no production dynamic var; `^:dynamic`
  reader metadata = D-075, F-004-gated). Devil's-advocate fork landed.
- 2026-05-29 amendment 1 (implementation): D3 originally claimed "Zig
  unit tests ... never set the slot." **False** — `src/app/builder.zig`
  test blocks call `setupCore` → `register`, so a test Env that
  registered left the process-global slot pointing at a freed Var,
  UAF-ing the next `setErrorFmt` (caught by the `info.zig` setErrorFmt
  unit test). Fix: `register` arms `Env.on_deinit_hook = clear`
  (env.zig) — every `Env.deinit` drops the slot before freeing its
  Vars. The slot + provider live in a new `runtime/error/context.zig`
  (not `info.zig`) so `info.zig` stays free of an `env.zig` import (the
  provider is a plain fn-pointer hook). Read-side verified for the
  catalog-error path (`(/ 1 0)` carries `:request-id`); user
  `(throw ex-info)` does NOT (it bypasses `setErrorFmt`) — recorded as
  D-144.
- 2026-05-29 amendment 2 (D-144 discharge): user-throw structured EDN
  rendering. See § Amendment 2 below.

## Amendment 2 (2026-05-29) — user-throw structured EDN rendering (D-144)

### Context

D3 left a read-side gap: a user `(throw v)` raises `error.ThrownValue`
(payload in `dispatch.last_thrown_exception`), NOT a catalog `raise`, so
`setErrorFmt` never runs and the threadlocal `Info` stays null. The
renderer's null-Info fallback emitted a degraded event
(`{:cljw/error true :file … :kind :unknown :message "ThrownValue"}`) with
**no `*error-context*` fields** — so `(with-context {…} (throw (ex-info …)))`
dropped its context while `(with-context {…} (/ 1 0))` (a catalog error)
carried it. D3 explicitly foresaw this: *"Field is specific `Info.context`,
not a generic `Info.data` ex-info payload … It can generalize when ex-info
`Info`-payload lands."* This amendment is that landing.

### D5: model user-throw as `Info.origin == .thrown`, not a new `Kind`

- **`Info.origin: Origin = .catalog`** (`enum { catalog, thrown }`) +
  **`Info.data: ?Value = null`** (the thrown ex-info's ex-data, distinct
  from the ambient `context`). A new `Info.kindLabel()` is the single
  category-label source both renderers consult: `@tagName(kind)` for
  `.catalog`, `"exception"` for `.thrown`.
- **Why not a `Kind.exception` variant** (the original draft): `info.zig`
  documents a 1:1 `Kind` ⇄ `ClojureWasmError` mapping, but a user throw
  raises `error.ThrownValue` (not a `ClojureWasmError`). A new `Kind`
  would have no honest error tag — forcing a vestigial
  `ClojureWasmError.Exception` or an `unreachable`/lie arm in the
  exhaustive `kindToError`. Modelling user-throw as a distinct *origin*
  keeps `Kind` the honest catalog-category enum it was designed as, and
  matches reality: a user can `(throw 42)` — there is no catalog `Kind`
  for "the integer 42".
- **Throw-time context snapshot**: `dispatch.last_thrown_context: ?Value`,
  set in `evalThrow` (TreeWalk) + `op_throw` (VM) via
  `info.snapshotContext()` while the `binding` frame is live, cleared with
  `last_thrown_exception` on catch. Same constraint the catalog path
  solves inside `setErrorFmt` (the frame is popped by `defer popFrame`
  during unwind, before render).
- **Render-time synthesis**: `error_render.zig::buildThrownInfo` builds a
  `{ origin = .thrown, message = ex-message | printValue, data = ex-data |
  null, context = last_thrown_context }` Info from
  `dispatch.last_thrown_exception`; both text + EDN route through it (one
  printer, per D3). `formatErrorEdn` emits `:kind :exception`, a
  `:data <ex-data>` field (when present), and the merged context.
- **Exit code unchanged**: `renderAndExit` reads `peekLastError()` (null
  for throws) → exit 1, the existing user-error code. The synthetic Info
  is render-only and never round-trips through `kindToError`.
- **`class_name` deferred**: a per-exception class label
  (`"ExceptionInfo"`) was considered and deferred — cw v1 has no class
  hierarchy yet (ex_info.zig comment), so a class field would be a
  Reservation-as-bias bet on a not-yet-landed multi-class-catch future
  (F-002). When multi-class catch lands (Phase 5+), that cycle adds it.

### Alternatives considered (amendment 2)

(Devil's-advocate subagent, fresh context, F-NNN envelope — output
verbatim. The DA's leading finding — the `Kind` ⇄ `ClojureWasmError` 1:1
break — drove the selection of the `origin` discriminator over the
draft's `Kind.exception`.)

> **F-NNN clearance summary (all three):** None requires violating an
> F-NNN. All keep the snapshot-at-throw-time discipline (forced by the
> `defer popFrame()` constraint — `evalBinding` pops during unwind,
> `formatErrorEdn` runs at the CLI boundary after the frame is gone, so
> render-time deref is structurally impossible). All keep the impl
> namespace-neutral (the snapshot helper and the printer live in
> `runtime/`, never in a `java/`/`cljw/` surface — F-009 + R4 hold).
> None touches NaN-box layout or per-value metadata (F-004). The
> decision space is purely: how user-throw exceptions get represented in
> the `Info`/`Kind` model, where the throw-time context snapshot is
> owned, and whether `Info.data` generalizes now.
>
> **Leading finding — the `Kind` ⇄ `ClojureWasmError` 1:1 invariant is
> the real load-bearing decision, and the draft's `Kind.exception` breaks
> it.** `info.zig` documents a strict 1:1 mapping between every `Kind`
> and a `ClojureWasmError` tag; `kindToError` is exhaustive returning a
> non-optional `ClojureWasmError`. A user throw raises `error.ThrownValue`
> (not a `ClojureWasmError`). So a new `Kind.exception` has no honest
> counterpart — forcing a vestigial `ClojureWasmError.Exception` or an
> `unreachable`/lie arm. Both are smells the project would unwind. Not an
> F-NNN violation (F-NNN is silent on the `Kind` model) but the single
> most important thing to get right; resolvable internally, no halt.
>
> **Alt 1 — Smallest-diff: reuse an existing `Kind`, synthesize `Info` at
> render time, no new enum variant.** Add only `last_thrown_context`;
> build a synthetic Info reusing `Kind.value_error` ("a thrown Value is
> evaluation producing a raised value"); special-case `:data` off
> `thrown.tag() == .ex_info` directly in `formatErrorEdn`. *Better:* zero
> change to the `Kind` enum / `ClojureWasmError` / `kindToError` — the
> 1:1 invariant stays pristine; no premature `Info.data`. Smallest
> surface that fixes the observable bug; text path gets message + context
> free. *Breaks:* `:kind :value_error` for a user throw is a category lie
> to a log consumer (conflates user exceptions with analyzer value
> errors); the `:data` special-case scatters ex-info knowledge into the
> printer; `(throw 42)` gets arbitrary `:value_error`. *F-NNN:* clean;
> the `value_error` reuse is an F-002 cleanliness compromise, not a
> block.
>
> **Alt 2 — Finished-form-clean: model user-throw OUTSIDE the
> `Kind`⇄`ClojureWasmError` coupling via an `Info` origin discriminator.**
> Add `Origin = enum { catalog, thrown }` + `origin` field (+ optional
> `class_name` string + `data`); `Kind`/`ClojureWasmError` untouched. EDN
> `:kind` becomes a function of `origin`: `@tagName(kind)` for `.catalog`,
> the ex-info class / `:exception` for `.thrown`. Throw-time snapshot +
> Info-build via a neutral helper shared by both backends. *Better:* the
> finished form — `Kind` stays the honest catalog-category type; no
> vestigial error, no `unreachable`; `class_name` is truthful and
> forward-compatible with multi-class catch; the text path renders via an
> `originLabel` helper fixing text + EDN in one place (D3's "one
> printer", extended). *Breaks:* larger — touches `formatErrorWithContext`
> (hard-codes `@tagName(info.kind)`), `formatError`, `kindToExitCode`;
> `Info` grows fields. Unlike `Kind.exception`, none of it lies. *F-NNN:*
> clean; neutral helper honors F-009; zone-clean.
>
> **Alt 3 — Wildcard: populate a full `Info` AT THROW TIME inside
> `evalThrow`/`op_throw`, not at render time.** Have the throw site call a
> `setErrorFmt`-equivalent (message, data, context-while-live,
> `origin = .thrown`) into `last_error`, then return `error.ThrownValue`;
> the render path's null-Info fallback then rarely fires. *Better:*
> eliminates render-time reconstruction; `error_render.zig` stays a pure
> Info reader; snapshot-at-throw-time satisfied by construction; unifies
> the two error families at the Info layer. *Breaks:* the dangerous one —
> a `(try (throw …) (catch …))` that recovers leaves a populated
> `last_error` that MUST be cleared at every catch site (two backends,
> easy to miss → silent-wrong-output), and it makes throw-time a second
> writer of `last_error` (the `error_catalog_only.md` rule reserves that
> for the catalog — needs a carve-out). Re-raise/nested-try interaction
> is fiddly; always-on formatting cost on caught-in-loop throws. *F-NNN:*
> clean on F-004/F-009/zones, but collides with the `error_catalog_only`
> rule (a project rule, not F-NNN); stale-Info-after-catch is the real
> reason it is the wildcard.
>
> **Recommendation (non-binding): Alt 2**, with the throw-time context
> snapshot owned by `dispatch.last_thrown_context` and the Info-synthesis
> at render time (avoiding Alt 3's stale-Info hazard by keeping
> `last_error` catalog-owned). It is the only alternative that does not
> lie about the `Kind`⇄`ClojureWasmError` 1:1 invariant; the draft and
> Alt 1 are smallest-diff biases against this, and preferring them on
> "the amendment is only ~150-250 lines" grounds is the Cycle-budget
> defer smell. `Info.data` should land, but as the scoped ex-data sibling
> of `context` (the concrete field this feature needs), not a speculative
> generic payload. Snapshot lives in `dispatch` (sibling to
> `last_thrown_exception`); the label indirection (`kindLabel`) fixes text
> + EDN together. *Where it could be wrong:* if Phase 5+ folds user
> exceptions and catalog errors into one unified taxonomy, Alt 3's
> "everything is an Info by the boundary" might be truer — judged
> unlikely (`ClojureWasmError` is host-failure-bound, structurally
> distinct from user-thrown arbitrary Values).

### Selection rationale (amendment 2)

Took **Alt 2**, the DA's recommendation, per F-002 (finished-form wins —
the larger diff is correct because the draft's `Kind.exception` is the
shape a finished-form owner would unwind). Declined `class_name` for this
cycle (Reservation-as-bias on multi-class catch — deferred to the Phase
5+ owner), keeping the amendment to the `origin` + `data` + `kindLabel`
core. Kept the synthesis render-side (not Alt 3's throw-time `last_error`
write) to preserve the `error_catalog_only` invariant and dodge the
stale-Info-after-catch hazard. Snapshot owned by
`dispatch.last_thrown_context` (sibling to `last_thrown_exception`); set +
cleared together so it is valid iff a thrown exception is pending.

### Affected files (amendment 2)

- `src/runtime/error/info.zig` (+`Origin`, +`Info.origin`/`Info.data`,
  +`Info.kindLabel`, +`snapshotContext`; `formatError` uses `kindLabel`)
- `src/runtime/dispatch.zig` (+`last_thrown_context` threadlocal)
- `src/eval/backend/tree_walk.zig` (`evalThrow` snapshots context;
  `evalTry` clears it on catch)
- `src/eval/backend/vm.zig` (`op_throw` snapshots; handler clears)
- `src/runtime/error/print.zig` (`formatErrorWithContext` uses `kindLabel`)
- `src/app/error_render.zig` (`buildThrownInfo` + thrown branch in
  `renderError`; `formatErrorEdn` uses `kindLabel` + emits `:data`)
- `docs/spec/error_format.md` (`:exception` kind + `:data` key)
- `test/e2e/phase14_user_throw.sh` (new) + `test/run_all.sh` (register)
- `.dev/debt.yaml` (D-144 discharged)

### Consequences (amendment 2)

- The EDN error schema gains `:kind :exception` (user throws) + an
  optional `:data` key (ex-data). `:data` was already listed as an
  anticipated forward-compatible key; `:exception` is a new `:kind`
  value. v0.1.0 is HELD/un-tagged, so no released contract is broken;
  the spec doc is amended to list both.
- `(with-context {…} (throw (ex-info …)))` now carries context into the
  EDN event — the with-context read-side is complete for both catalog
  errors and user throws.
- D-142 (multi-Env nREPL slot race) is unchanged — the throw path reuses
  the same process-global provider; the latent race is the same.
