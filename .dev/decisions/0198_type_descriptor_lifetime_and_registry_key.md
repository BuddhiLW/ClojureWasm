# ADR-0198 - A displaced TypeDescriptor is retired, never freed; the registry key is the qualified class name

- **Status**: Accepted (2026-09-09)
- **Debt row**: D-587
- **Card**: `[CLJW-TD-UAF]` `20260909211032-6471bc49`
- **Supersedes**: the free-on-re-registration behaviour introduced for row 7.7
  cycle 5 (the in-code comment cited "D-190 / ADR-0068"; ADR-0068 is
  `sequential_marker_print_form` and has nothing to do with descriptor
  ownership, so that citation was wrong and is not carried forward).

## Context

`registerType` (`src/runtime/type_descriptor.zig`) kept `rt.types` keyed by
the type's SIMPLE name and, whenever a name was registered again, removed the
old entry and FREED the descriptor: every `field_layout` entry name, the
layout slice, `fqcn`, `defining_ns`, each `method_table` entry's
`method_name`, the `method_table` slice, the `protocol_impls` slice, and
finally `gpa.destroy` of the `TypeDescriptor` itself.

Nothing that holds a descriptor was told. Three distinct holders outlive the
free:

1. **Instances.** `TypedInstance` / `ReifiedInstance` hold `descriptor` as a
   raw `*const TypeDescriptor`. `print.zig printTypedInstance` reads
   `inst.descriptor.field_layout` and indexes the instance's field array by
   `fe.index`.
2. **Boxed class values.** `makeTypeDescriptorRef` allocates a ref on
   `rt.gc.infra`, `trackHeap`s it as a persistent mark waypoint and caches it
   in `td.ref_cache`. Those refs are never revoked, and
   `traceTypeDescriptorRef` reaches `markDescriptorValues`, which walks
   `method_table` and the `parent` chain.
3. **The dispatch cache.** `CallSite.last_type` is a raw
   `*const TypeDescriptor` living in analyzer storage the GC cannot see, and
   `lookupWithCache` hits on `last_type == td` plus a generation match.

So the free produced a use-after-free with three faces. The reported symptom
was a print-time crash whose form varied with whatever the freed memory
happened to contain (`thread panic: integer overflow` on some shapes,
`error: WriteFailed` on others), which is the signature of a use-after-free
rather than a logic error. The two unreported faces are worse: the GC MARK
phase can walk a freed `method_table` when a captured `(class x)` value is
still live, and, because `registerType` bumped no generation and a freed
address is promptly reused for the next descriptor of the same size class, a
stale call site could ABA-match and dispatch through a freed method table,
which is a silent wrong answer rather than a crash.

Repro matrix, measured on a ReleaseSafe v1.14.3 binary:

| case | before |
|---|---|
| two namespaces, different record names | fine |
| two namespaces, same record name | crash printing the FIRST instance |
| one namespace, same name redefined | crash |
| same name, different field count | crash |
| `deftype` rather than `defrecord` | `WriteFailed` |

The third row is the ordinary REPL re-eval and `require :reload` path, which
`dev/user.clj`'s hot-reload loop is built on. ADR-0019 forbids a panic on a
user-reachable path.

**The code had drifted from its own documentation in two separate places**, and
that is what settles the decision rather than any new preference:

- `TypeDescriptor`'s doc comment: "Descriptor for one type. Process-lifetime,
  allocated on `rt.gpa`." The free contradicted it.
- The `Runtime.types` field comment: "Maps the fully-qualified class name
  (e.g. `user.Point`) to a process-lifetime TypeDescriptor." The code keyed by
  the simple name.

This was found while migrating `test/e2e/phase7_defrecord.sh` to a native
suite: `test/clj/suites/` shares ONE cljw image, so a second suite defining a
record named `Point` (`class_type_test.clj` already had one) hit the
same-simple-name path and took the whole suite run down.

## Decision

Two changes, both restoring a documented contract.

**1. A displaced descriptor is RETIRED, not freed.** `registerType` moves the
old descriptor to `rt.retired_types` and frees only the map key. `Runtime.deinit`
drains that list with the same free body it already applies to `rt.types`,
minus the key. Teardown is the one moment at which no instance, ref or call
site can still reach a descriptor.

`registerType` additionally bumps `rt.protocol_generation`. Retiring already
guarantees a cached pointer stays valid; the bump is what makes a stale
CallSite slot MISS and refill against the new descriptor instead of continuing
to serve the retired one.

**2. The `rt.types` key becomes the fully-qualified class name.** For a host
surface the fqcn already is qualified (`java.util.UUID`); for a user type the
key becomes `<defining_ns>.<Name>`. A null `defining_ns` (bare unit-test
registration, `ensureRegistered`, and reify, which is not registered at all)
keeps the bare name as its own qualified form, so the rule is total with no
null branch. `td.fqcn` stays the SIMPLE name: key and printed class name are
deliberately decoupled, so `(class x)` and the `#ns.Name{...}` print form are
unchanged and ADR-0059 / AD-003 are untouched.

The two halves reinforce each other. Under simple-name keys, re-registration
is routine (any two namespaces, any reload), which is the pressure that
motivated the free in the first place. Under qualified keys a replacement only
happens on a genuine same-`(ns, name)` re-evaluation, so retirement is rare
and the retention it implies is small.

### On the retained memory

Nothing is freed at retirement: the descriptor struct, the `fqcn` and
`defining_ns` dupes, the layout slice plus one dupe per field name, the method
table plus one dupe per entry, the `protocol_impls` slice. Order 300 B to 2 KB
per retired type, **bounded by re-evaluation count, not by data size**. A batch
`cljw -e` run retires nothing. A reload loop retires one per re-eval.

This is not a regression against the oracle, it IS the oracle: JVM Clojure
mints a new Class on each `defrecord` re-evaluation and keeps the old one alive
for as long as anything references it. So F-011 asks for retention here, and
`.dev/accepted_divergences.yaml` needs no row for matching clj.

### Landing order

Two commits in one cycle, for bisectability rather than deferral: the retire
and generation bump first (which makes the crash impossible), the key rule
second (which makes the collision impossible). The key change moves roughly
seven resolution sites plus the AOT wire format, where a mistake resolves a
baked class-value constant to the wrong descriptor SILENTLY. Splitting keeps
that blast radius identifiable. Both land before the loop moves on; shipping
only the first would be the Smallest-diff-bias smell, and the Devil's-advocate
fork named that risk explicitly.

## Consequences

- `Runtime` gains `retired_types: std.ArrayList(*const TypeDescriptor)`.
- `registerType` no longer frees, and now bumps `protocol_generation`.
- `Runtime.deinit` drains the retired list.
- The AOT `.type_descriptor` constant (`serialize.zig`) writes what its comment
  calls "its `rt.types` key". With qualified keys that must be the qualified
  key, and `serialize.VERSION` is bumped in the same commit so any stale cache
  is rejected with `UnsupportedVersion` rather than silently mis-resolved.
- Resolution sites that assumed "user type implies simple-name key" gain a
  current-namespace qualification step. `markRegistryRoots` needs NO retired-list
  walk: a retired descriptor with no live instance and no live boxed ref has no
  dispatchable path, and one with either is already reached through
  `traceTypedInstance` / `traceReifiedInstance` / `traceTypeDescriptorRef`.
- Host-surface descriptors are unaffected by the lifetime half: `ensureRegistered`
  and `_host_api.registerExtension` never took the freeing path.
- The one-type-name-per-image cap on `test/clj/suites/` is lifted by the key
  half. Until it landed, `defrecord_test.clj` worked around it by naming its
  record `DPoint`; that rename is reverted when the key change lands.

## Alternatives considered

A `general-purpose` Devil's-advocate subagent was forked with fresh context and
the F-NNN envelope pasted in, per CLAUDE.md's mandatory depth-2 procedure. Its
output is reproduced verbatim below. It verified its claims against the tree
and surfaced two hazards the main loop had not found (the GC mark-phase face
and the ABA dispatch face), which changed the shape of the decision: the
generation bump is in the Decision above because of finding 2.

Its recommendation (Alternative 2) was adopted.

> ## Leading item: no F-NNN blocks the finished-form-clean shape
>
> I could not construct a case where the clean fix requires violating an
> F-NNN. F-006's layering permits a process-lifetime gpa descriptor (that is
> what layer 1 is *for*), F-011 actively *wants* the clj behaviour (old
> instances keep the old class), and ADR-0059/AD-003 constrains the *printed*
> class name, not the *registry key*. So the honest report is: the envelope is
> not the constraint here; the diff size is, and per F-002 that is not a
> project constraint.
>
> ## Four findings that change the framing (verified, not in the debt row)
>
> **1. The print panic is not the worst symptom, the GC mark phase is.**
> `makeTypeDescriptorRef` (`src/runtime/type_descriptor.zig:544-556`) allocates
> the boxed ref on `rt.gc.infra`, `trackHeap`s it as a persistent mark-waypoint,
> and caches it in `td.ref_cache`. Those refs are **process-lifetime and never
> revoked**. `traceTypeDescriptorRef` (`:693-697`) then does
> `markDescriptorValues(gc, ref.td_ptr)`, which walks `d.method_table` and the
> `d.parent` chain (`:659-667`). So `(def c (class a))`, redefine `Point`, then
> any collect while `c` is reachable = a use-after-free **inside the GC mark
> walk**, reading a freed slice pointer and a freed length. Persistent marks are
> waypoints (traced when reached, `gc_heap.zig:333-347`), so this fires only when
> a stale `.type_descriptor` Value is still live, which is an ordinary user path.
>
> **2. `registerType` does not bump `rt.protocol_generation`, and the CallSite
> cache compares descriptors by raw pointer.** `CallSite.last_type: ?*const
> TypeDescriptor` (`src/runtime/dispatch/method_table.zig:38`) hits when
> `last_type == td and cached_generation == current_generation` (`:66`). The
> only two bump sites are `src/runtime/protocol.zig:290` and
> `src/lang/primitive/protocol.zig:285`; `registerType` bumps nothing. CallSite
> slots live in analyzer nodes, outside the GC and outside every registry. So
> after a free, if gpa hands the same address back for a later `TypeDescriptor`
> (same size class, extremely likely in a reload loop), a stale call site **hits
> on an ABA-matched address** and dispatches through `last_method`, a pointer
> into the *freed* method_table. That is a silent wrong answer, strictly worse
> than the panic. **Any alternative that keeps freeing must also bump the
> generation; the retire-based alternatives remove the hazard by construction
> because the address is never reused.**
>
> **3. The free is the outlier, not the contract.** Two independent doc comments
> assert the opposite of what the free does: `:64-65` ("Descriptor for one type.
> Process-lifetime, allocated on `rt.gpa`") and `:393-394` ("Back-pointer to the
> (process-lifetime) descriptor. **Stable for the CallSite cache**"). Retiring
> restores a documented invariant; it does not invent one.
>
> **4. Retire-not-free does NOT reopen ADR-0184's C8 strand class.** I checked
> this because it is the obvious objection. A retired descriptor still reachable
> from a live instance is marked via `traceTypedInstance:901` and
> `traceReifiedInstance:707`; via a live boxed ref through
> `traceTypeDescriptorRef:696`. `markRegistryRoots` (`:680-688`) exists precisely
> for *registered* descriptors with no live holder, and a retired descriptor with
> no live instance and no live ref has no dispatchable path at all. **So no
> retired-list walk needs to be added to `markRegistryRoots`.** Only
> `Runtime.deinit` needs to learn about the retired list.
>
> **5. Only the user path frees.** `ensureRegistered` (`:510-535`) and
> `_host_api.registerExtension` (`src/runtime/java/_host_api.zig:181-208`) both
> `put`/`getOrPut` with no free branch; the latter's re-registration arm merges
> comptime-const fields in place. So **host-surface descriptors (`defining_ns ==
> null`) never take the freeing path today** and are untouched by defect (2)
> under every alternative below. They are affected only by a key-rule change, and
> their key is already the FQCN.
>
> ## Alternative 1 - smallest-diff: retire instead of free, keep the simple-name key
>
> `registerType` (`:804-824`) keeps `fetchRemove(name)`, keeps
> `rt.gpa.free(old.key)` (the key is separately duped at `:825`, so freeing it at
> retirement is still correct), and **stops freeing the descriptor and its
> sub-allocations**. Instead it appends `old.value` to a new
> `rt.retired_types: std.ArrayList(*const TypeDescriptor)`. `Runtime.deinit`
> grows a second loop with the same free body as `runtime.zig:786-812` minus the
> key free. Add the `protocol_generation` bump for good measure (finding 2),
> though retiring alone already makes the cache merely stale-but-valid rather
> than dangling.
>
> - **Better than the others**: it is the only shape that is provably
>   behaviour-preserving for everything except the crash. Zero resolution sites
>   change, zero wire-format change, zero new naming rule to explain.
>   `git diff --stat` is roughly three files.
> - **What it breaks / costs**: it fixes defect (2) and leaves defect (1) fully
>   open. `aaa/Point` and `bbb/Point` still collide with no redefinition at all,
>   so `(instance? aaa/Point b)` still answers wrongly, the `#ns.Name{...}`
>   record-literal reader (`analyzer.zig:1489-1497`) still resolves by simple name
>   and then *checks* `defining_ns`, so it will now silently reject a legitimate
>   `#aaa.Point{...}` after `bbb` loads. It also leaves the native-suite cap in
>   place (`test/clj/suites/` shares one image; 45 type definitions across 103
>   suites, today worked around by renaming to `DPoint`). That cap is a standing
>   tax on every future suite migration.
> - **Call sites forced to change**: `src/runtime/type_descriptor.zig:804-824`
>   (the free block), `src/runtime/runtime.zig:668-813` (new retired-list drain,
>   placed with the existing `rt.types` loop at `:786`), `src/runtime/runtime.zig:~419`
>   (new field). Nothing else.
> - **`defining_ns == null` host descriptors**: unchanged, they never reach this
>   code (finding 5). The one exception is a `registerType` call with a dotted
>   name, which exists in a test (`serialize.zig:2016` registers
>   `"java.lang.Integer"`); retiring is safe there too because the free path
>   already skips the comptime-const `static_fields` / `host_supertypes` (`:100`,
>   `:110`).
> - **Memory**: nothing is freed at retirement. Per retired type: the
>   `TypeDescriptor` struct (~200 B given ~25 fields), `fqcn` + `defining_ns`
>   dupes, the `field_layout` slice plus one dupe per field name, the
>   `method_table` slice plus one `method_name` dupe per entry, the
>   `protocol_impls` slice. Order 300 B to 2 KB. **Bounded by redefinition count,
>   not by data size**: a batch `cljw -e` run retires nothing (each form evaluated
>   once); a REPL or `require :reload` loop retires one per re-eval; a
>   file-watcher reload loop grows linearly at ~1 KB per type per reload. Only a
>   pathological `(dotimes [_ 1e6] (eval '(defrecord P [x])))` is unbounded.
>   **This is exactly JVM Clojure's own behaviour**: each `defrecord` re-eval
>   mints a new Class that survives as long as anything references it, and long
>   REPL sessions accumulate them. So the leak is F-011-faithful, not a regression
>   against the oracle.
>
> ## Alternative 2 - finished-form-clean: the registry key becomes the fully-qualified class name, plus retire-not-free
>
> One uniform rule replaces today's two-rule mess: **the `rt.types` key is the
> fully-qualified class name**. For a host surface that is already true
> (`java.util.UUID`). For a user type it becomes `<defining_ns>.<Name>`, i.e.
> `aaa.Point`. `defining_ns == null` (bare unit-test registration,
> `ensureRegistered`, reify, which is not registered at all, `:496-499`) keeps the
> bare name as its own FQCN, so the rule is total with no null branch.
> `TypeDescriptor.fqcn` stays the **simple** name so `(class x)` and the print
> form are unchanged (ADR-0059 / AD-003 preserved); the key and the fqcn are
> deliberately decoupled, which is the substance of the change. Retire-not-free
> from Alt 1 rides along, because re-evaluating `aaa/Point` still replaces
> `aaa.Point`.
>
> - **Better than the others**: it is the only shape that fixes **both** defects,
>   and it fixes them at the level where they originate. It removes the
>   native-suite one-type-name-per-image cap outright (unblocking the migration
>   that surfaced this bug). It makes `#aaa.Point{...}` reader resolution a direct
>   key lookup instead of a simple-name lookup plus a `defining_ns` re-check. It
>   matches clj's model exactly (a class per namespace), which is what F-011 asks
>   for. And it makes the key change *cause* the retirement change to be small:
>   with qualified keys, a cross-namespace same-name definition is no longer a
>   replacement at all, so retirements become rare rather than routine.
> - **What it breaks / costs**: this is the substantially larger diff, and per
>   F-002 I recommend it anyway. Every resolution site that assumes "user type
>   implies simple-name key" must gain a current-ns qualification step *before*
>   the bare probe, and the AOT wire must carry the key rather than the fqcn.
> - **Call sites forced to change** (all verified):
>   - `src/eval/analyzer/analyzer.zig:698-700` `resolveDescriptorByKey`, the
>     shared SSOT for both the analyze-time and the AOT-load path. Needs a
>     qualified probe.
>   - `src/eval/analyzer/analyzer.zig:723-733`, the simple-name fallback for a
>     *qualified* user-deftype reference (`instaparse.gll.Failure`, D-428/D-391).
>     Under Alt 2 the qualified spelling becomes the **primary** key and this
>     fallback inverts: it becomes the bare-name-to-current-ns promotion instead.
>   - `src/eval/analyzer/analyzer.zig:1489-1497`, the `#ns.Name{...}`
>     record-literal reader. Becomes a direct `rt.types.get("ns.Name")`; the
>     `matches_ns` re-check at `:1495-1496` becomes dead and should be deleted, not
>     left.
>   - `src/eval/analyzer/special_forms.zig:247-266`, the `(Point. ...)`
>     constructor path, which rewrites an `(:import ...)` simple name to its FQCN
>     *guarded on `rt.types.get(fqcn) != null`* (`:254`, `:259`). A
>     current-ns-qualified probe goes in ahead of the bare spelling; the comment at
>     `:247-250` ("a USER deftype registers in rt.types under its BARE name")
>     becomes false and must be rewritten.
>   - `src/runtime/host_class_resolve.zig:30-47`, step 1 is `rt.types.get(head)`
>     verbatim. It gains a current-ns qualification for the dot-free case, ahead of
>     the `(:import ...)` / `java.lang.*` / `java.math.*` steps. This file is the
>     declared SSOT for "what does a class symbol mean", so the rule lands here and
>     the analyzer sites inherit it.
>   - `src/eval/bytecode/serialize.zig:463-473`, the AOT `.type_descriptor`
>     constant writes `ref.td_ptr.fqcn` with the comment "its `rt.types` key". That
>     conflation is exactly what breaks: it must write the qualified key (or fqcn +
>     defining_ns) and `readValue` must resolve it import-blind, preserving the
>     ADR-0034 am5 shadow-proofing. **This is the one place where getting it wrong
>     is silent**: a stale AOT cache would resolve a class constant to the wrong
>     descriptor rather than failing. A cache-format version bump belongs in the
>     same commit.
>   - `src/lang/primitive/core.zig:1886`, the `CLASS <fqcn>` dump that the
>     compat_tiers gate consumes iterates `rt.types`; it must keep emitting `fqcn`,
>     not the key, or the gate diffs.
>   - `src/lang/primitive/protocol.zig:1089`, `fix.rt.types.get("Point")` in a
>     unit test; `defining_ns` is null there so it keeps working, which is a useful
>     check that the null branch is genuinely total.
>   - Unaffected, and worth stating in the ADR so a reviewer does not chase them:
>     `file_io.zig:36`, `locale.zig:40`, `host_enum.zig:124`, `math_context.zig:37`
>     all `get` a dotted host FQCN and are correct unchanged.
> - **`defining_ns == null` host descriptors**: their key is already their FQCN,
>   so the new rule is a no-op for them. `registerExtension`
>   (`_host_api.zig:184-207`) and `ensureRegistered` (`:515`, `:531-533`) need no
>   edit. This is the strongest argument for Alt 2 over any scheme that adds a
>   *parallel* qualified table: one table, one key rule, no null-branch.
> - **Memory**: identical to Alt 1 and strictly less of it. Same retirement, same
>   per-descriptor cost, but retirements now occur only on genuine same-`(ns,
>   name)` re-evaluation, not on cross-namespace collision. Bounded by reload
>   count.
> - **Variant 2b, for the record**: put the type table on the `Namespace`
>   (`ns.types`) instead of qualifying keys in the flat `rt.types`, mirroring the
>   `Namespace.imports` map that `special_forms.zig:253` already consults. It fixes
>   the same two defects and is arguably even closer to clj's model. I do not
>   recommend it over 2: it splits one registry into two tiers, forces every one of
>   the sites above to learn a two-tier lookup order rather than a longer key, and
>   breaks the `rt.types` iteration at `core.zig:1886` and `markRegistryRoots:681`.
>   Same benefit, larger and more invasive surface. It belongs in "Alternatives
>   considered", not in the implementation.
>
> ## Alternative 3 - wildcard: make `TypeDescriptor` a GC-managed heap object
>
> Give `TypeDescriptor` its own `HeapHeader` and a tag, allocate it on `rt.gc`,
> register a trace (its `method_val`s, `meta`, `parent`) and a finaliser (the
> gpa-owned field-name and method-name dupes). `rt.types` becomes a root table;
> every holder becomes a marking edge. A descriptor then dies precisely when no
> instance, no boxed ref and no registry entry references it, the exact clj
> semantics, with no leak at all.
>
> - **Better than the others**: it is the only shape with *zero* retained memory,
>   and it is the only one that would survive a future moving GC without a
>   migration. There is real precedent inside the project: ADR-0184 already moved
>   `Function` out of the pinned/`trackHeap` set into ordinary swept cells, and
>   `.type_descriptor` is already a Value tag with a registered trace
>   (`gc_rooting.md` section F: "50 `registerTrace` (+ `.type_descriptor`,
>   2026-07-02)").
> - **Argued against F-006**: F-006's layer 3 is "Values (Fn / collections /
>   strings / lazy_seq)" and layer 1 (GPA/`infra_alloc`) is explicitly "Env /
>   Namespace / Var / **process-lifetime storage**". A `TypeDescriptor` is metadata
>   about a type, in the same family as `Namespace` and `Var`, layer-1 furniture,
>   not a Value. Moving it to layer 3 is not *forbidden* by F-006 (the ADR-0184
>   `Function` precedent shows the boundary is movable), but it argues against the
>   layering's own stated intent, and it buys precise reclamation of a population
>   whose size is **bounded by the source text** rather than by the workload. That
>   is the wrong thing to spend GC complexity on.
> - **What it breaks / costs, the disqualifier**: `CallSite.last_type`
>   (`method_table.zig:38`) is a raw `*const TypeDescriptor` in an analyzer node
>   that the GC cannot see. Under Alt 3 it becomes a **weak reference to a
>   collectable object**: a descriptor with no live instance and no live ref is now
>   swept, and the stale call site is left pointing at freed memory, the same
>   use-after-free this fix exists to kill, relocated from `registerType` into the
>   sweep phase and made *non-deterministic*. Closing it means either rooting every
>   CallSite (they live in arena/analyzer storage; there is no enumeration of them)
>   or making `last_type` a handle with a generation check. That is a real redesign
>   of the dispatch cache, not a side effect.
>   On top of that: `TypedInstance` (`:389-416`) and `ReifiedInstance` (`:584-600`)
>   are `extern struct`s with `comptime` size/offset asserts (`:598` asserts
>   `@sizeOf(ReifiedInstance) == 24`) and the `descriptor` field is read by the VM,
>   the serializer and ~225 `.descriptor` references across 40+ files.
>   `.dev/gc_rooting.md` rows D4, D5, D7 and section F's leaf cross-check all
>   change. `markRegistryRoots` inverts meaning. And `Runtime.deinit`'s ordering
>   constraint at `runtime.zig:716-724` (D-481: finalise the heap *before* freeing
>   descriptors, because `host_instance` finalisers read
>   `inst.descriptor.host_finalise`) becomes circular, the descriptors would now be
>   *in* the heap being finalised.
> - **`defining_ns == null` host descriptors**: worst case here.
>   `_host_api.zig:190-194` heap-copies a comptime-static descriptor and `:203-206`
>   merges comptime-const `static_fields` / `host_supertypes` slices into it. Those
>   slices are **not** heap-owned (`:98-99`, `:107-109` warn explicitly that
>   freeing `host_supertypes` "crashed cache_gen, D-466's reverted first attempt").
>   A GC finaliser on descriptors must special-case them, reintroducing exactly the
>   two-ownership-regime hazard D-466 already paid for once.
> - **Memory**: nothing retained, which is the whole appeal. But note the honest
>   comparison: it eliminates a leak of ~1 KB per reload in exchange for a
>   weak-reference hazard in the dispatch cache and a rewrite of the descriptor
>   ownership model. **Alt 3 does not fix defect (1) either**: a GC-managed
>   descriptor keyed by simple name still has `aaa/Point` and `bbb/Point`
>   colliding. It would have to be combined with Alt 2's key rule regardless.
>
> ## Recommendation: Alternative 2
>
> Take the qualified-key rule **and** retire-not-free, in one commit, and bump
> `protocol_generation` in `registerType` while you are in there.
>
> Reasons, in order:
>
> 1. **It is the only alternative that fixes both defects**, and the debt row is
>    explicit that there are two. Alt 1 ships a fix that leaves a wrong-answer bug
>    (`aaa/Point` equivalent to `bbb/Point`) standing, and leaves the native-suite
>    migration capped, the very work that found this. Fixing half of a two-part
>    defect and closing the row is the Smallest-diff-bias smell in its textbook
>    form.
> 2. **The key rule is the root cause, and the free is a symptom of it.** The free
>    exists because re-registration under a simple name is *routine* (any two
>    namespaces, any reload). Under qualified keys, replacement only happens on a
>    genuine same-`(ns, name)` re-eval, so retirement becomes a rare event, and the
>    "we must free or we leak" pressure that motivated the D-190/ADR-0068 free
>    largely evaporates. The two halves reinforce each other; landing them apart
>    makes each look worse than it is.
> 3. **F-011 says the retained memory is correct, not merely tolerable.** JVM
>    Clojure keeps the old class alive for old instances. A bounded-by-reload-count
>    retention is the oracle's own behaviour, and `.dev/accepted_divergences.yaml`
>    does not need a row for matching the oracle.
> 4. **No F-NNN blocks it**, and its cost is diff size across ~7 resolution sites
>    plus an AOT wire-format bump. Per F-002 that is not a reason to prefer Alt 1.
>    If the loop's instinct after reading the call-site list is "Alt 1 now, Alt 2
>    later", that instinct is the Cycle-budget defer smell, and "later" here means
>    the wrong-answer half of a correctness-floor row rots in `active:`.
>
> Two implementation notes I would put in the ADR's Consequences rather than
> leave to discovery: the AOT `.type_descriptor` constant
> (`serialize.zig:463-473`) is the one silent-failure site and needs a
> cache-format version bump in the same commit; and the `protocol_generation`
> bump in `registerType` should land even though retire-not-free already removes
> the ABA window, because it is the difference between "stale cache misses and
> refills" and "stale cache is merely provably-not-dangling".
>
> Against Alt 3: I would record it as considered and rejected on the
> `CallSite.last_type` weak-reference argument specifically, it converts a
> deterministic use-after-free into a non-deterministic one, not on F-006
> layering grounds, since ADR-0184's `Function` precedent shows that boundary can
> move when there is a reason. Here there is not: the population is bounded by
> source text.

### Deviation from the recommendation

One: the fork recommended a single commit, and this lands as two within the
same cycle (retire first, key second). The reason is bisectability of the AOT
and resolution blast radius, not cycle budget. Both land before the loop moves
on, which is the condition the fork's point 4 actually cares about.

## Affected files

- `src/runtime/type_descriptor.zig` - `registerType`: retire instead of free,
  bump `protocol_generation`, qualified key.
- `src/runtime/runtime.zig` - `retired_types` field, `deinit` drain.
- `src/eval/analyzer/analyzer.zig` - `resolveDescriptorByKey` and the two
  resolution paths above it.
- `src/eval/analyzer/special_forms.zig` - the `(Point. ...)` constructor path.
- `src/runtime/host_class_resolve.zig` - the class-symbol SSOT.
- `src/eval/bytecode/serialize.zig` - the AOT `.type_descriptor` constant plus
  `VERSION`.
- `test/clj/suites/type_redefine_test.clj` - the regression suite (new).
- `test/clj/suites/defrecord_test.clj` - `DPoint` reverts to `Point` once the
  key half lands.
