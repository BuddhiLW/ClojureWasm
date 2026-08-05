# ADR-0184: Runtime-created Functions are ordinary collectable heap objects

- Status: Accepted
- Date: 2026-08-06
- Refs: D-450 (perf campaign, real-workload gap), ADR-0028 (mark-sweep,
  per-tag trace/finaliser), ADR-0130 (frame rooting), ADR-0183 (trigger
  steering), F-006 (GC strategy), D-556 (conservative scan residual)

## Context

Every fn value — including every closure created at runtime — is allocated
with `rt.gpa.create(Function)` + `rt.trackHeap(...)`, which registers it in
`gc.persistent_marks` (a mark-waypoint list) and `rt.heap_objects` (the
teardown free list). Nothing ever unregisters one, so **every closure a
program creates is immortal**.

Measured on the D-450 headline workload (cw-arcade rush-hour `(g/generate 7
:medium)`, M4 Pro, v1.9.0+O-055):

- 15,502,063 persistent marks at exit, **1.98 GB retained** — the BFS
  creates a closure per iteration and none is ever freed.
- `CLJW_GC_STATS=3` phase timing: gc_ms=3858 of a 16.3 s run, of which
  **prep = 2830 ms** — `clearPersistentMarks` bit-clearing all 15.5M
  waypoints on every one of the 122 collects (the walk grows with every
  closure ever created, so the cost is quadratic-ish over the run). The
  mark-worklist reserve is also inflated by `persistent_marks.len`.
- This is simultaneously the campaign's largest measured lever (~17% of
  wall) and an unbounded-memory defect: any server-shaped cljw process that
  creates closures per request grows without bound.

The `persistent_marks` design is correct for its other occupants (protocol
descriptors, type-descriptor refs — one per definition, genuinely
process-lifetime). Function is the only churn-class occupant (plus reify's
per-evaluation anonymous TypeDescriptor, recorded as a residual below).

Prior art (survey: `private/notes/D450-fn-gc-survey.md`): cw v0 treated
`.fn_val` as an ordinary collectable object; JVM Clojure closures are plain
GC'd instances of a compiled class. "Per-closure instance is light and
collectable; the shared code object is long-lived" is the established
finished form. cw v1's immortal closures are the deviation.

## Decision

(Amended after the DA fork below — the fork refuted the draft's rejection
of the inline cell and found the two preconditions incomplete.)

1. **Function allocation moves to the GC heap as ONE variable-length
   cell.** All four alloc paths (`allocFunctionWithBytecodes`,
   `allocFunctionTemplate`, `allocFunctionFromSerialized`, and the
   compile-time slot_base==0 path through the first) allocate a single
   `gc.alloc`-class `.fn_val` cell whose trailing bytes hold the
   `methods` array and `closure_bindings`; the struct keeps its **slice
   fields**, initialized to point into the cell's own tail, so every
   existing `f.methods` / `f.closure_bindings` access compiles unchanged.
   Nothing resizes those slices post-alloc (`patchLetfnClosures` mutates
   contents, not length), so the aliasing is safe. No finaliser is
   needed — sweep frees one cell; `freeFunction` and the Function entries
   in `rt.heap_objects` / `gc.persistent_marks` disappear. Free-pool
   size-class dispersion is measured in the landing commit.
2. **Chunks stay immortal and unowned by Function.** Verified: chunks are
   compiled once per `fn*` form into the run-lifetime analyzer arena
   (`compiler.zig`), and `op_make_fn` copies chunk *pointers* into each
   closure — 15.5M closures share one chunk. The serialize path's chunks
   are serialize-allocator-owned. No chunk lifetime change.
3. **Precondition A — executing-callee roots, installed BEFORE the
   binder.** A collectable callee must be reachable while it runs:
   - tree_walk: `callMethodImpl` holds raw `*Function` + `*FunctionMethod`
     (a pointer INTO `f.methods`) across the body/recur loop. Its
     per-call EvalFrame gains an explicit `callee: Value` slot — and the
     root must be live **before `bindCallFrame` runs**, because the
     binder's rest-pack `consHeap` can trigger a collect while the callee
     is held only as a raw pointer (DA gap A-1).
   - VM: `flattenPush` sets `ar.op_top = fr.result_slot`, dropping the
     callee below the rooted prefix; the flattened frame's `gc_frame`
     gains the same `callee` slot (belt-and-braces on the VM — after
     flatten nothing re-reads `f`/`m`; the load-bearing pin is
     tree_walk's `m`). The `op_call` slow path is safe only because
     `ar.op_top` is synced in stepOnce's defer and therefore stays
     stale-HIGH across `vt.callFn` — that staleness is now a documented,
     test-locked invariant (DA gap A-2).
4. **Precondition B — ALL THREE descriptor registries become roots, with
   extend-type replace-in-place.** `rt.types`, `rt.native_descriptors`
   (where `(extend-type Long/nil …)` impls actually land), and
   `rt.class_descriptors` gain a root-enumeration cursor over their
   method-table values (reify's anonymous TDs stay instance-mediated).
   Because `extendTypeWithImpls` today APPENDS (`old ++ new`, nothing
   dropped), walking tables as roots would immortalize every superseded
   impl — so extend-type becomes **replace-in-place** (dedupe on
   protocol+method) in the same cycle. This also fixes the pre-existing
   parity defect the DA surfaced: `lookupMethod` scans front-first while
   re-extends append at the end, so a re-extend never won (verify against
   clj and pin).
5. **Compile-time Functions stay effectively immortal** via
   `persisted_analysis_roots` — unchanged. Only runtime-created closures
   become collectable, which is exactly the churn population.
6. **Named finished form to converge on (not obstructed by this shape):
   the template/closure split** (DA Alt 3) — runtime closures borrow the
   immortal template's `methods` and own only their bindings. Dissolves
   the tree_walk `m` pin and removes the per-closure methods copy.
   Recorded as the follow-up lever on D-450 together with the epoch-mark
   idea (DA Alt 1) for the remaining waypoint/allocations clears.

## Alternatives considered

(Devil's-advocate fork output, reflected verbatim per the working
agreement. The fork was briefed with F-002/F-004/F-006/F-011/F-012 and
read the draft + survey + source read-only.)

> ## Leading finding (F-NNN envelope)
>
> No finished-form-clean option requires violating any F-NNN. All three
> alternatives below fit F-004 (pointer identity — no object ever moves),
> F-006 (non-moving mark-sweep, per-tag trace/finaliser), F-011/F-012
> (both backends change together through the shared binder). The draft's
> direction (fns collectable) is correct; the findings below are about
> **where the draft's two preconditions are incomplete** and about one
> rejected alternative whose rejection rationale does not hold up.
>
> **Alt 1 (smallest-diff): epoch-stamped marks — kill the prep walk
> without making fns collectable.** Replace the per-collect O(n)
> bit-clear with a global mark epoch ("marked" ≡ `header.mark_epoch ==
> gc.current_epoch`; collect increments the epoch, O(1) prep). Removes
> the ~2.8 s prep cost with zero new UAF surface, and is a good idea
> independently (the allocations-list clear pays the same cost shape).
> Breaks nothing — but fixes only the perf half; the 1.98 GB unbounded
> retention remains. On F-002 grounds it loses as the whole answer;
> record as a compatible follow-up lever.
>
> **Alt 2 (finished-form-clean): single variable-length `gc.alloc` cell,
> landed NOW — the draft's rejection rationale is partly wrong.** Keep
> `methods` / `closure_bindings` as slice fields initialized to point
> into the cell's trailing bytes: every existing access compiles
> unchanged; only the four alloc paths and the free path change, and the
> finaliser disappears (sweep frees one cell). Nothing resizes those
> slices post-alloc (`patchLetfnClosures` mutates contents, not length).
> Size-class dispersion is the one genuinely unmeasured item, but the
> non-moving heap already handles variable-length cells (String bytes).
> Per F-002, an unmeasured guess plus a refutable access-shape claim must
> not demote the finished form to a follow-up: land the inline layout in
> this cycle, measuring dispersion in the landing commit.
>
> **Alt 3 (wildcard): two-tier template/closure split — per-closure cell
> = header + bindings only; methods borrowed from the immortal
> template.** `op_make_fn` today copies the whole `methods` array per
> closure even though all 15.5M closures share one chunk and
> byte-identical FunctionMethod values. Borrowing the template's methods
> dissolves most of Precondition A (`m` then points into immortal
> storage), and is the survey's own JVM/cw-v0 finished form taken
> literally. Breaks: template backreference + no-template paths must
> decide methods ownership. Substantially larger diff — recommended
> anyway per F-002 as the shape to converge on, with Alt 2's inline cell
> as its natural companion; if not taken this cycle, name it as the
> finished form the current shape must not obstruct (it does not).
>
> ## Precondition A stress-test — call shapes the draft misses
>
> Verified safe (state in the ADR): agent/future actions are already
> pinned (future.zig:15-17,154,229; agent.zig:232-245 — the queue is
> off-heap gpa, so `action.body`/`completion` are pinned); worker
> EvalFrames are collector-visible (root_set.zig:314-327, 413-421), so
> the callee slot works cross-thread; keyword-as-fn involves no
> Function; partial/comp inner fns are reached via the outer callee's
> closure_bindings trace; Var redefinition during execution is covered
> by the callee slot.
>
> The gaps:
> 1. **The binder runs BEFORE the frame is installed — with an
>    allocation inside.** In `callMethodImpl`, `bindCallFrame` (which
>    consHeap-allocates the `& rest` pack, tree_walk.zig:1436-1441)
>    executes before the `gc_frame` push (1466-1472). A rest-arity
>    call's cons alloc can collect while the callee is held only as a
>    raw `*Function` — no root; on a worker thread there is no
>    conservative scan (D-556), and main-thread stack survival is an
>    optimizer accident, not a contract. Fix: install the callee root
>    before `bindCallFrame`. The two drafted torture cases will NOT
>    catch this — add a variadic-callee case that collects inside the
>    rest-pack alloc (CLJW_GC_TORTURE_ALLOC through
>    `(apply (fn [& xs] xs) …)` with the callee the only reference).
> 2. **The VM `op_call` slow path is safe only by a deferred-sync
>    accident.** During `vt.callFn` (vm.zig:711-726) the callee+args sit
>    below a stale-HIGH `ar.op_top` (synced only in stepOnce's defer,
>    vm.zig:484-489) and stay rooted — nothing documents that the
>    staleness is load-bearing. Any refactor that syncs earlier silently
>    unroots the executing callee. Record the invariant next to the
>    O-028 hoist comment and lock it with a test.
> 3. **"The callee root removes the fn-value instance of D-556" is
>    overbroad.** It roots a fn only while its frame is live. Fn values
>    fetched from heap objects and held in native locals across an
>    alloc/safepoint on a worker (lazy_seq.force's `ls.thunk` exposure
>    via the ls intermediate, delay, watch/validator loops, value_sort
>    comparators, reduce/map step-fn drivers) join the D-556 residual
>    class the moment fns become collectable — a UAF surface that
>    immortality currently masks. Narrow the claim to the
>    executing-callee instance and price the rest into the D-556 row.
> 4. **Newborn window**: a fresh gc.alloc'd fn is unrooted until it
>    reaches a stack slot/local. Current paths look clean (follow-on
>    allocs are gpa-side; op_make_fn pushes before any further
>    gc.alloc), but require a per-path audit line; the remedy vocabulary
>    is `gc_self_guard` / fabrication brackets (ADR-0150/D-559).
> 5. **Multimethod/protocol fetch-to-call window**: a method fn fetched
>    from a table (`CallSite.last_method` is a raw `*MethodEntry`, "no
>    GC edge", method_table.zig:37-46) is protected between fetch and
>    frame-install only by the table staying reachable and the entry not
>    being replaced. Mostly closed by Precondition B; combined with gap
>    1 (a variadic protocol method) it is real. One audit line.
>
> ## Precondition B stress-test
>
> 1. Cost is a non-issue: dozens of descriptors × <32 entries vs the
>    15.5M-entry clear being removed.
> 2. **The draft walks the WRONG (incomplete) registry set**:
>    `rt.native_descriptors` ([70]?*TypeDescriptor, runtime.zig:417) is
>    NOT in `rt.types` — and it is where `(extend-type Long/nil …)`
>    impls land; `rt.class_descriptors` can also receive method entries;
>    reify's anonymous TDs are deliberately not in `rt.types` and their
>    instance-mediated trace + callee slot must be verified sufficient.
>    Enumerate all three registries or the fix is porous.
> 3. **Root-vs-waypoint changes replacement semantics — because
>    replacement never removes.** `extendTypeWithImpls` appends
>    (`old ++ new`, runtime/protocol.zig:237-241); walked as a root,
>    every superseded impl closure is immortal and an extend-type in a
>    loop grows without bound — a miniature of the disease this ADR
>    kills. Land replace-in-place (dedupe on protocol+method) in the
>    same cycle.
> 4. **Adjacent latent bug**: `lookupMethod` scans front-first
>    (type_descriptor.zig:291-297) while re-extends append at the END —
>    a re-extend's new impl appears to never win (clj: later extend
>    replaces). If confirmed, a pre-existing parity bug hidden by the
>    append-only growth; the replace-in-place fix discharges both. Also:
>    runtime/protocol.zig:250 frees the old slice while the test comment
>    (392-396) claims never-free — the generation check keeps the code
>    safe; clean the contradiction in passing.
>
> ## Mid-execution death / recur `m` pinning
>
> tree_walk: the callee slot pins `f.methods` from frame-install onward;
> the hole is entirely the pre-install window (gap 1). VM: pinned but
> not needed mid-execution — after flattenPush nothing re-reads `f`/`m`
> (recur is an intra-chunk jump; chunk arena-owned; constants rooted;
> captures memcpy'd into rooted locals). The only load-bearing
> methods-pin in the design is tree_walk's `m` — which is precisely what
> Alt 3 dissolves, strengthening it as the finished form.
>
> ## Recommendation
>
> Keep Decision 1/2/5 core. Amend Precondition A per gaps 1-2, narrow
> the D-556 claim per gap 3, rewrite Precondition B to cover all three
> registries with replace-in-place landed alongside. Adopt Alt 2 this
> cycle. Record Alt 3 as the named finished form (or take it now) and
> Alt 1 as an independent follow-up lever.

## Consequences

- A closure-churning program's fn cells are reclaimed like any other
  value; `persistent_marks` returns to its intended dozens-scale
  population, killing the per-collect prep walk (~2.8 s on the headline
  workload) and the 1.98 GB retention.
- `Runtime.deinit`'s `heap_objects` drain no longer frees Functions; the
  gc-side allocations drain does (one rawFree per cell), keeping the leak
  gate green.
- The registry roots close the pre-existing KNOWN-OPEN strand on
  extend-type captures. The callee slot covers the EXECUTING fn only;
  fn values fetched from heap objects and held in native locals across a
  safepoint on a worker thread join the D-556 residual class once fns are
  collectable — that widening is priced into the D-556 row, not absorbed
  silently (DA gap 3).
- `.dev/gc_rooting.md` §A/§D/§F + site census + migration checklist, the
  `heap_tag.zig` membrane comment, and the `traceFunction` docstring are
  updated in the landing commits.
- Locked by: full diff oracle ×2 backends, corpus, `CLJW_GC_TORTURE` e2e
  suite + two NEW torture cases ("loop-created closures die; live ones
  survive a collect", "self-recursive closure survives a mid-execution
  collect"), DebugAllocator leak gate, and a rush-hour re-measure
  (CLJW_GC_STATS=1: persistent_marks back to O(100), prep ≈ 0).

## Residuals (recorded, not in this cycle)

- reify's anonymous TypeDescriptor is trackHeap'd per **evaluation**
  (protocol.zig) — the same immortality shape in miniature; new debt row.
- Worker-thread tree_walk conservative-scan residual (D-556) remains for
  non-fn intermediates; the callee root removes the fn-value instance of
  it.
