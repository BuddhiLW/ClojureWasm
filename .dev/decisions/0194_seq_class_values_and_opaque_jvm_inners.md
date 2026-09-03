# 0194 — Native seq class values and opaque JVM inner seq classes

- **Status**: Proposed -> Accepted
- **Date**: 2026-09-01
- **Author**: BuddhiLW
- **Tags**: class-values, instance?, seqs, tools.reader, host-interop, ADR-0109

## Context

`clojure.tools.reader.impl.inspect` installs multimethods for five
`clojure.lang` class values. `LazySeq` and `Cons` are real cljw value classes,
but cljw exposed those names only through `displayClassName`; they could not be
resolved as class values and `instance?` raised `NameError`. The other three
targets (`PersistentVector$ChunkedSeq`, `PersistentArrayMap$Seq`, and
`PersistentHashMap$NodeSeq`) are JVM implementation classes that no cljw value
can have. Their symbols also failed to resolve, preventing the namespace from
loading.

## Decision

Promote `LazySeq` and `Cons` into `class_name.NATIVE_ENTRIES`, the exact
name-to-tag registry. Add their `clojure.lang.*` spellings to `FQCN_MAP` and
remove the now-redundant display-only cases. Thus `(class x)` keeps the same
printed name while the corresponding class symbol becomes a real value and
`instance?` gains JVM-faithful membership.

Make the existing `.cons` heap tag live: `clojure.core/cons` returns a
`PersistentList` when prepending to `nil`, and a `Cons` when prepending to a
non-nil seq, matching Clojure. The two tags share storage and sequence
operations, while metadata, equality, printing, lazy-seq traversal, and GC
tracing preserve or recognize their distinct observable identity.

Register the three `$` implementation classes as opaque under their complete
dotted names. ADR-0109's load-only extension rule applies because no cljw
value can have those exact JVM types.

## Alternatives considered

- Make all five names opaque. Rejected: cljw has genuine `lazy_seq` and `cons`
  values, so this would silently route live values to default multimethod and
  protocol branches.
- Keep `LazySeq` and `Cons` display-only and special-case tools.reader.
  Rejected: it preserves incorrect `instance?` behavior and violates the
  name-to-tag registry's single-source-of-truth rule.
- Model the three JVM inner classes as native cljw types. Rejected: cljw's seq
  representations are different; claiming those exact identities would make
  `instance?` lie.

## Consequences

- **Positive**: tools.reader's inspect multimethods load; `LazySeq` and `Cons`
  class values and `instance?` match Clojure.
- **Negative**: two additional heap tags become public exact class targets.
- **Negative**: sequence consumers must treat `.cons` alongside `.list` where
  they operate on generic cons cells, while `list?` remains `.list`-specific.
- **Neutral**: class display strings do not change. Extensions for the three
  JVM-only classes remain load-only no-ops, as required by ADR-0109.

## Affected files

- `src/runtime/class_name.zig`
- `src/runtime/error/host_class.zig`
- `src/runtime/collection/list.zig`
- `src/runtime/lazy_seq.zig`
- `src/runtime/equal.zig`
- `src/runtime/meta.zig`
- `src/runtime/print.zig`
- `src/lang/primitive/sequence.zig`
- `src/lang/primitive/metadata.zig`
- `test/e2e/phase14_class_names.sh`
- `test/e2e/phase14_opaque_host_class.sh`

## References

- ADR-0059 and D-204: class values and the name↔tag registry.
- ADR-0109: opaque host classes are licensed only when dead by construction.
- ADR-0187: protocol targets must not reuse the opaque-class no-op rule.
- Kanban `20260812153837-5357a1b5` (`CLJW-SEQCLASS`).

## Revision history

- 2026-09-01: Status: Proposed -> Accepted (initial landing).
- 2026-09-03: Follow-up: preserve PersistentList identity in `conj`, and add
  `.cons` to every seq-key hash/equality gate. Distinct class identity must not
  drop pre-existing collection semantics.
