# 0197 — The Seqable/ISeq boundary lives at Layer 0; a lazy body realizes through it

- Status: Accepted (2026-09-07)
- Card: `[CLJW-LAZY-SEQABLE]` (`20260906180421-14443fe9`), child of
  `[CLJW-COMPLIANCE]` (`20260818224554-330d9c16`)
- Amends: ADR-0143 (the realise window now also runs the seq coercion; a
  raised coercion resets the flag like a thrown thunk), ADR-0054 (lazy
  producers; the `-concat2` boundary is unchanged)
- Review: local implementation, JVM oracle and GC/concurrency probes; the
  alternatives below are this change's design record, not a panel transcript.

## Context

1. `lazy_seq.zig` (Layer 0) realizes a thunk and stores the raw result after
   `coerceRealized`, a hand-copied SUBSET of the tag table that
   `src/lang/primitive/sequence.zig::seqFn` (Layer 2) owns: vectors are
   copied into an eager list, map entries, sets, maps, sorted collections and
   queues are seq'd, everything else passes through unchanged. `first`/`rest`/
   `next` in the same file answer nil / nil / nil for any tag outside
   {list, cons, chunked_cons, range, array_seq, string_seq}. The two tables
   drifted (Single-Source Lever violation) and the lazy path is the one that
   lost:

   | expression                                             | cljw (a30d4467) | clj 1.12.4 |
   |--------------------------------------------------------|-----------------|------------|
   | `(first (lazy-seq "hi"))`                              | `nil`           | `\h`       |
   | `(rest (lazy-seq "hi"))`                               | `()`            | `(\i)`     |
   | `(seq (lazy-seq "hi"))`                                | `"hi"`          | `(\h \i)`  |
   | `(count (lazy-seq "hi"))`                              | `1`             | `2`        |
   | `(seq (lazy-seq 1))`                                   | `1`             | throws     |
   | `(first (lazy-seq (to-array [1 2])))`                  | `nil`           | `1`        |
   | `(first (lazy-seq (java.util.ArrayList. [7 8])))`      | `nil`           | `7`        |
   | `(first (lazy-seq (reify Seqable (seq [_] '(1 2)))))`  | `nil`           | `1`        |
   | `(first (lazy-seq <deftype implementing ISeq>))`       | `nil`           | `:f`       |

   Non-lazy `(vec "hi")` / `(seq 1)` are right, because they reach `seqFn`.
   The measured set is `private/notes/lazy-seqable-red-2026-09-07.log`; the
   original `test/clj/suites/lazy_seqable_test.clj` baseline had 57 assertions:
   31 passed, 25 failed and one errored before this change.

2. JVM 1.12.4 `LazySeq` (decompiled from the installed jar; no sources jar):
   `realize()` = `force()` (invoke `fn`, clear it) → unwrap nested `LazySeq`
   values ITERATIVELY → `s = RT.seq(ls)` → clear the lock. `seq`/`first`/
   `next`/`count` all pass through `realize()`. So a lazy body is subject to
   the SAME `RT.seq` coercion as every other value, and the terminal seq is
   cached in the outer object. cljw's `seq()` re-walks the nested chain on
   every access: `(let [l (filter #(= % 100000) (iterate inc 0))] (first l)
   (time (first l)))` costs 7.85 ms on cljw and 0.02 ms on the JVM.

3. Two JVM artifacts were measured and are NOT adopted. (a) A body that
   returns a non-seqable throws on the first touch, but `force()` has already
   consumed `fn` and `realize()` dropped `sv` before `RT.seq` threw, so the
   second touch sees an EMPTY seq (`[(realized? l) (count l) (seq l)]` →
   `[false 0 nil]`). (b) The `lazy-seq` macro's `^{:once true}` fn clears its
   closed-overs after the first call, so a retried thrown body that touches a
   local NPEs instead of re-running. cljw keeps ADR-0143's rule: a thrown
   realisation (thunk OR coercion) is not cached; the retry re-invokes the
   thunk and raises again. Both runtimes reject the first touch.

4. Layer rules: `src/runtime/` imports nothing above it; a non-surface
   runtime file must not import `runtime/java/**`. Protocol dispatch
   (`dispatch.dispatchOrNull`) and the error catalog are Layer 0, and Layer 0
   already dispatches `Seqable/-seq` from `equal.zig` and `print.zig`, so the
   complete boundary CAN live below the primitives. GC allocation CAN collect
   before the new object exists, through torture, threshold collection or a
   peer's safepoint. A Value held in a Zig local across allocation or reentrant
   eval must be published as a root (`.dev/gc_rooting.md` §A/§C).

5. Gaps found while probing, tracked separately: `(seq (StringBuilder.))`
   raises where clj seqs any CharSequence (`[CLJW-CHARSEQ-SEQABLE]`); `(seq?
   x)` is false for a deftype implementing `clojure.lang.ISeq`
   (`[CLJW-SEQ-PRED-ISEQ]`).

## Decision

`runtime/seqable.zig` owns `seq`, `first`, `rest` and `next`. Native collection
representations use their existing operations; open user and host types use
Layer-0 protocol dispatch. Layer-2 primitives perform arity validation and
delegate. Equality, printing, iterators and the affected analyzer/collection
consumers use the same boundary. No runtime-to-language or neutral-to-Java
import is introduced. `-concat2` remains unchanged.

The domain contract is nil or ISeq from `seq`; `rest` represents an exhausted
tail as `()`, and `next` collapses it to nil. Dispatched `Seqable.-seq` results
are checked using `class_name.isInstance`, the existing membership oracle.
A vector, string, scalar or map returned directly by a custom Seqable method
raises ClassCastException, matching the JVM method's ISeq return cast. This
is separate from an ordinary non-seqable argument's IllegalArgumentException.
Open receivers retain D-089's direct ISeq-method precedence, including
`extend-type` on native tags. Native collection fast paths retain their prior
dispatch behavior; an integer extended only with ISeq need not also be Seqable.

Realization claims the existing three-state word, invokes the thunk, drains
nested lazy bodies iteratively and coerces the terminal through this boundary.
The entry node caches the terminal; inner nodes publish immutable links. This
avoids recursive depth and makes repeated access to the entry constant-time
without rewriting links another reader relies on for reachability. Successful
publication clears the thunk; a failed thunk or coercion resets the state and
retains the callable for retry. The raw result stays in a manual EvalFrame
through subsequent allocation and user callbacks. Accessor intermediates
returned by custom coercions are also rooted until their next accessor ends.
Host iterators root a fresh cursor until their allocation publishes it and
retain a freshly allocated head while advancing calls custom ISeq methods.
The latter was reproduced in native nREPL: collecting in `next` changed the
already returned `"item-2"` head into `"item-1"` before Iterator could return it.
CSV retains the outer row cursor, inner cell cursor and current cell through
callbacks: the native unrooted path lost the second row when the first lazy
row called `System/gc`. Custom Sorted bounds retain the returned comparator,
fresh cursor and entry across coercion and comparator callbacks; the bounded
walk roots each fresh entry until the accumulated result owns it.
Equality's cursor also retains a fresh head through its own advance callback;
the outer comparison frame can only root the head after that advance returns.

Metadata and fusion copies snapshot flag and payload together: claim pending
sources briefly, wait for an active realization with safepoint polling, and
read published payloads under acquire. No user code runs under a copy claim.
This prevents a pending copy from receiving the nil thunk of a concurrent
successful realization. Pending copies otherwise retain their prior shallow
semantics; this change does not redesign metadata forcing.

Java arrays join vectors/subvectors as backing values of the existing ArraySeq
view. Array mutations remain visible through both eager and realized lazy
sequences, as on the JVM; no new value tag or host import is needed.

AD-067 records the three measured consequences of preserving ADR-0143's one
publication state: coercion failures retry instead of becoming empty, retries
retain closed-over locals, and invoked inner nodes report realized. First-touch
values and exception classes retain JVM parity.

## Alternatives considered

1. Extend `coerceRealized`'s private tag switch. Rejected: it retains two owners
   for one contract, leaves custom ISeq accessors incomplete and repeats the
   string/array drift on the next type.
2. Call the Layer-2 primitive from LazySeq, directly or through a new vtable
   entry. Rejected: the direct import violates stratification; another callback
   duplicates a boundary that existing Layer-0 dispatch can already express.
3. Compress every realized inner link. Rejected: concurrent readers and GC
   reachability would need additional coordination for mutable published
   payloads. Caching the entry's terminal gives the required repeated-access
   behavior while inner links remain immutable.
4. Copy the JVM's separate thunk/raw/seq state and destructive retry behavior.
   Rejected under ADR-0143's existing retry invariant. AD-067 makes the limited
   observable differences explicit and pins them, rather than silently calling
   the whole state machine JVM-identical.

## Consequences

- One owner defines sequence coercion and access. Native fast paths remain;
  adding an open Seqable needs no new switch arm in LazySeq or its consumers.
- Allocation is an effect boundary. CLI allocation torture is required in
  addition to nREPL GC callbacks: registered nREPL workers bypass the current
  allocation-torture trigger.
- Deep nesting, concurrent realization and metadata copying have native tests.
  GC callback assertions live in `suites.lazy-seqable-gc-test`; the smaller
  `test/clj/torture/lazy_seqable.clj` program runs six checks with collection at
  every allocation. Loading the broad test namespace at that cadence panics
  on both the WIP and retained v1.14.2 binary; directory discovery also returns
  empty on both. Those existing loader/harness gaps remain separate. Bash only
  launches the native programs and supplies process-level settings.
  The shared native runner rejects unknown namespace selectors and empty selections.
  CLI selectors use `cljw -cp test/clj -M test/clj/run_suites.clj <namespace>`;
  `-M` selects the existing script-argument grammar and binds the arguments.
- Seeded hive-test metamorphic laws cover string observations; test.check covers
  nested custom Seqables. Two production-Var mutation witnesses guard against
  raw-body/nil-head regressions. A hive-test EDN golden pins values and exception
  classes alongside the existing process-output golden.
- Golden output is reviewed against the installed JVM oracle; only AD-067's
  named retry/state lines differ. Test expectations are not captured blindly.
- D-089 and D-530 shell value assertions move to native Clojure programs/suites.
  The D-530 arity fixture now returns ISeqs from its Seqable/Sorted methods,
  preserving the overload check while satisfying their JVM return contracts.
- The separate CharSequence and `seq?` gaps in Context remain separate cards.

## Affected files

- `src/runtime/seqable.zig`, `src/runtime/lazy_seq.zig`,
  `src/runtime/collection/array_seq.zig`, `src/runtime/gc/gc_heap.zig`.
- `src/lang/primitive/sequence.zig`, `src/lang/primitive/sorted.zig`,
  `src/lang/primitive/csv.zig`, `src/eval/analyzer/analyzer.zig`.
- `src/runtime/equal.zig`, `src/runtime/print.zig`,
  `src/runtime/java/util/Iterator.zig`, `src/main.zig`.
- `test/clj/suites/lazy_seqable_test.clj`,
  `test/clj/suites/lazy_seqable_gc_test.clj`, `test/clj/harness/suites.clj`,
  `test/clj/run_suites.clj`,
  `test/clj/suites/deftype_overload_arity_test.clj`,
  `test/clj/process/seq_protocol_extensions.clj`,
  `test/clj/process/priority_map_bounds.clj`, `test/clj/torture/lazy_seqable.clj`,
  `test/e2e/phase16_gc_torture.sh`, `test/e2e/phase8_d089_seq_extend.sh`,
  `test/e2e/phase14_deftype_overload_arity.sh`,
  `test/conformance/verified_projects/hive-test/laws.clj`,
  `test/conformance/verified_projects/hive-test/lazy-seqable.edn`,
  `test/golden/cases/lazy_seqable_bodies.clj` and its `.expected` file.
- This ADR, ADR-0143, `.dev/gc_rooting.md`,
  `.dev/accepted_divergences.yaml`, `.dev/handover.md`, `CHANGELOG.md`.

## References

- ADR-0143 (thread-safe force), ADR-0054 (lazy producers), ADR-0116
  (interface membership), ADR-0102 (host-interface SSOT), AD-066 (the seq
  view class name), D-164 (empty seq → nil).
- `test/clj/suites/lazy_seqable_test.clj`, `test/golden/cases/lazy_seqable_bodies.clj`.
- `private/notes/lazy-seqable-survey.md`, `private/notes/lazy-seqable-red-2026-09-07.log`.
