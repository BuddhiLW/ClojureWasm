# 0187 — Extend a protocol to another protocol via a dispatch-miss fallback

- **Status**: Proposed
- **Date**: 2026-08-12
- **Author**: BuddhiLW
- **Tags**: protocols, dispatch, host-compat

## Context

`defprotocol` on the JVM generates an interface, so a library can name that
interface as an `extend` target and mean "every type that implements it":

```clojure
;; clojure.tools.reader.reader-types:208
(extend-protocol ReaderCoercer
  Object                                    (to-rdr [r] ...)
  clojure.tools.reader.reader_types.Reader  (to-rdr [r] r)
  String                                    (to-rdr [s] (string-reader s))
  java.io.Reader                            (to-rdr [r] (PushbackReader. r)))
```

cljw has no interfaces. Protocols are dispatch tables keyed by
`TypeDescriptor`, and `__extend-type!` requires a `.type_descriptor` target,
so the second clause raises `expected type_descriptor, got protocol`.

The clause became *reachable* only once commit 67128e9f taught
`resolveClassValue` to resolve a protocol by its generated interface name.
Before that the symbol did not resolve at all, so the failure appeared one
layer earlier. The two changes are entangled: a bisect would blame the
resolution fix rather than the missing capability.

This blocks `clojure.tools.reader`, and through it `encore`, `timbre`, and
every hive component that logs. hive-contracts is otherwise green on cljw:
9 of its 10 namespaces load, and the tenth fails only through a single
`taoensso.timbre` require behind one `log/warn` call.

The enabling observation is that protocol membership is a property of the
TYPE, not the value: `td.protocol_impls` is the declared-interface SSOT
(D-190 / ADR-0068) and `protocol.satisfies` already answers "does this
descriptor satisfy P" from the descriptor alone. So the fallback needs no
access to the receiver value and no reverse index of implementors.

## Decision

`__extend-type!` accepts a `.protocol` target. The impls are not written to
any descriptor — there is no descriptor to write them to. They are recorded
on the Runtime in a side table keyed by the PROVIDING protocol's fqcn:

    protocol_target_exts : fqcn(A) -> [{ target_proto: fqcn(B), impls }]

`dispatch.dispatch` consults that table after a per-type miss and BEFORE the
`Object` universal default: for each recorded entry whose `target_proto` the
receiver's descriptor satisfies, the matching `(protocol, method)` impl is
called. Ordering is deliberate — on the JVM an interface impl is a real
per-type impl and beats an `Object` default, so checking it first is the
faithful order.

The table is stored on `Runtime` rather than in `ProtocolDescriptor` because
the latter is an `extern struct` with a fixed ABI; a side table keeps the
wire format untouched.

No memoization. The scan runs only on the already-failing miss path, the
per-protocol entry list is 0–2 long in practice, and copying impls onto the
descriptor mid-dispatch would mutate a live table and bump
`protocol_generation` — invalidating every CallSite cache in the process —
during a call that may be re-entrant.

This is the same value ADR-0114 Decision C argued for in the neighbouring case
(`clojure.lang` interfaces as extend targets): membership must be DERIVED, never
hand-maintained, because "a hardcoded list is a denylist-by-omission" and the
omission is silent. Deriving membership from `satisfies?` at dispatch time cannot
drift and cannot silently omit an implementor — including one extended to B after
this extension was recorded. The mechanism differs from C's synthetic-supertype
endgame because a protocol's implementor set is OPEN and grows at runtime, so
there is no fixed chain to write into once.

## Alternatives considered

### Alternative A — registration-time propagation

- **Sketch**: when A is extended to B, copy A's impls onto every type already
  extended to B, and re-copy whenever a new type is later extended to B.
- **Why rejected**: needs protocols to track their implementors, which they do
  not today, and correctness depends on catching BOTH orderings
  (A-extends-B before/after T-extends-B). Zero hot-path cost is not worth a
  new reverse index and a second write path that can silently miss a case.

### Alternative B — load-only no-op

- **Sketch**: treat a protocol target the way AD-023 treats a `host_inert`
  `java.util.Map` target (ADR-0103 / ADR-0109) — load the section, never
  dispatch it, record an accepted divergence.
- **Why rejected**: every existing load-only-no-op target shares one licence —
  no cljw value can ever have that type, so the impl is dead by construction.
  A cljw map genuinely is not a `java.util.Map`; a cljw value genuinely CAN
  satisfy protocol B. Reusing the inert contract here would be the first case
  where "inert" hides a live divergence rather than describing a dead branch,
  which would also corrode what AD-023 means. It happens to be invisible in
  tools.reader — both coercer protocols guard their `Object` branch with
  `(satisfies? Reader rdr)` and return exactly what the protocol clause
  returns — but that is one library's luck, not a general guarantee.

## Consequences

- **Positive**: `clojure.tools.reader` loads, unblocking encore, timbre, and
  hive-contracts. A common clj idiom stops being a hard error.
- **Negative**: the miss path grows a scan. It runs only where cljw would
  previously have raised, so no currently-succeeding dispatch slows down.
- **Neutral / follow-ups**: `satisfies?` still answers from the descriptor and
  will report false for a type that only gets its impls through this fallback.
  Whether `(satisfies? ReaderCoercer x)` should follow the same rule is a
  separate question, tracked rather than decided here.

## Affected files

- `src/lang/primitive/protocol.zig` — accept a `.protocol` target; record it.
- `src/runtime/runtime.zig` — the `protocol_target_exts` side table + deinit.
- `src/runtime/dispatch.zig` — the miss-path consult, before the Object default.
- `src/runtime/protocol.zig` — a by-name `satisfiesName` beside `satisfies`.
- `test/e2e/` — a protocol-to-protocol extend case, both orderings.
