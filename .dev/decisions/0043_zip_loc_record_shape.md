# 0043 — `clojure.zip` zipper representation: defrecord ZipLoc (Option B)

- **Status**: Accepted (Devil's-advocate fork landed 2026-05-27)
- **Date**: 2026-05-27
- **Author**: Shota Kudo (drafted with Claude autonomous loop)
- **Tags**: clojure-zip, defrecord, pattern-a, F-002, F-003, F-009,
  D-080, D-075

## Context

Phase 7 row 7.13 (D-080) opens `clojure.zip` Pattern A landing — 31
vars (28 JVM-public + 3 cw v1-only predicates; DA fork amendment
expands to a 4-predicate set, see Decision below). A functional
zipper carries a "loc" pair of (current-node, navigation-context).
The navigation context records path / lefts / rights / end? so
`(up loc)` / `(left loc)` / `(right loc)` reconstruct ancestors and
siblings without re-walking the whole tree.

JVM Clojure `clojure.zip` represents the loc as a **vector with
metadata**: `[node {:zip/path ... :zip/lefts ... :zip/rights ...}]`.
cw v0 (`~/Documents/MyProducts/ClojureWasm/src/lang/lib/clojure_zip.zig`,
608 lines) ports the JVM shape verbatim. The JVM-faithful shape
requires `with-meta` / `meta` / IObj / IMeta protocols + reader
`^{...}` form + per-Value metadata slot — all of which cw v1 tracks
as a Phase 7+ scope item (D-075, ≈500 LOC of its own; HeapHeader
layout review per F-004).

The row 7.13 Step 0 survey
(`private/notes/phase7-7.13-survey.md`, 463 lines) enumerates the
representation choice and recommends Option B (defrecord ZipLoc).
The Devil's-advocate fork
(`private/notes/phase7-7.13-da-fork.md`, 492 lines, fresh context)
considers 3 alternatives within the F-NNN envelope and confirms
Option B with two amendments. This ADR records the decision.

Substrate available at HEAD (rows 7.4 / 7.5 / 7.6 / 7.12 close):

- ADR-0040 — `op_deftype` / `op_ctor_call` / `op_field_access` /
  `op_method_call` opcodes (row 7.6 cycle 4).
- ADR-0041 — multi-arity `fn*` (row 7.8) + ADR-0042's apply
  variadic peel-and-pass (row 7.9) unblock `(edit loc f & args)`
  variadic.
- `defrecord` macro (row 7.4 cycle 1) + factory `(->Name ...)`
  (cycle 4) + per-field accessors via `(.field instance)`
  (row 7.6 cycle 1 + cycle 4 VM landing).
- `instance?` macro + `runtime/class_name.zig` registry that
  includes user TypeDescriptor parent walk for typed_instance
  (row 7.12 cycle 1) — `(instance? ZipLoc loc)` is the dispatch
  predicate the public zipper API uses to validate inputs.
- `host_class.zig` Throwable hierarchy (row 7.11) — `(throw
  (ex-info ...))` in `:else` arms is catchable as `ExceptionInfo`.

D-085 (keyword-as-fn callable) is **not yet landed** (verified
2026-05-27: `(:a {:a 1})` raises "Cannot call value of type
'keyword'"). The xml-zip arm's `:content` lookup uses `(get node
:content)` workaround in cycle 1 — no PROVISIONAL marker needed
(`(get)` is fully working).

## Decision

Adopt **Option B — `(defrecord ZipLoc [node path lefts rights end?])`**
with the two Devil's-advocate amendments:

1. **Forward-commitment statement**: the defrecord shape is the
   **permanent finished form** of cw v1's zipper representation,
   not a transient stopgap. Even after D-075 lands `with-meta` /
   `meta` / IObj / IMeta, this ADR does NOT migrate to the
   JVM-faithful vector-with-metadata shape. The migration would
   churn every user-side `(instance? ZipLoc loc)` call + every
   zipper-aware library + the public field-access surface
   `(.node loc)` for marginal JVM-faithfulness gain. cw v1's
   finished form keeps the defrecord shape; D-075 lands for
   non-zipper consumers.
2. **Predicate-set rename + expansion**: the cycle 1 predicate
   set becomes 4 instead of the survey's 3:
   - `zip-loc?` (was the survey's `node-loc?` — renamed for
     clarity: the predicate is "is this a ZipLoc?", not "is
     this a loc-node?").
   - `seq-zip?` / `vector-zip?` (unchanged from survey).
   - `xml-zip?` (new — symmetric with the other 3 source-shape
     predicates).

### `ZipLoc` shape (`src/lang/clj/clojure/zip.clj`)

```clojure
(defrecord ZipLoc [node path lefts rights end?])
```

- `node` — current node value (the user-visible "where" of the
  zipper).
- `path` — parent `ZipLoc` or nil at root. Forms an upward
  reverse-linked chain; `(up loc)` returns the parent loc with
  the current node spliced back into the parent's child sequence
  at position `(count (.lefts loc))`.
- `lefts` — vector of sibling nodes to the left of `node` in the
  parent's child sequence. Empty vector at the leftmost sibling.
- `rights` — vector of sibling nodes to the right of `node`.
  Empty vector at the rightmost sibling.
- `end?` — boolean marker. `(next loc)` sets this true when the
  depth-first walk has exhausted; `(end? loc)` reads it. Allows
  `(loop [loc z] (when-not (end? loc) ...))` idioms without an
  out-of-band sentinel.

The zipper-fn closures (`branch?`, `children`, `make-node`) are
NOT stored on the ZipLoc — instead `(zipper branch? children
make-node root)` returns a closure-bearing `ZipLoc` constructor
function, and the public API stores the 3 fns once per zipper-
type (e.g. `vector-zip` stores `(fn [x] (vector? x))` for
`branch?` etc.) in the cycle 1 `vector-zip` / `seq-zip` /
`xml-zip` constructor bodies. This avoids carrying 3 fn slots on
every ZipLoc instance — the slot cost would be wasted on the
vast majority of locs that share the same constructor's fns.

### Public API surface (31 vars in 4 cycles)

- **Cycle 1 (representation + ctors + leaves, ≈16 vars)**:
  `zipper` / `vector-zip` / `seq-zip` / `xml-zip` / `node` /
  `branch?` / `children` / `make-node` / `zip-loc?` /
  `seq-zip?` / `vector-zip?` / `xml-zip?` / plus the underlying
  defrecord + factory.
- **Cycle 2 (navigation, ≈7 vars)**: `down` / `up` / `right` /
  `left` / `root` / `lefts` / `rights` / `path` / `leftmost` /
  `rightmost`.
- **Cycle 3 (traversal, ≈3 vars)**: `next` / `prev` / `end?`.
- **Cycle 4 (mutation, ≈7 vars)**: `replace` / `edit` /
  `insert-child` / `append-child` / `insert-right` /
  `insert-left` / `remove`.
- **Cycle 5 (close)**: compat_tiers entries (31), placement.yaml
  status flip, ROADMAP `[x]`, handover.

## Alternatives considered

(Devil's-advocate subagent output condensed from
`private/notes/phase7-7.13-da-fork.md`; the subagent's
recommendation is Alt 2 with the two amendments above, adopted
verbatim by the main loop.)

### Alt 1 — Smallest-diff: vector + minimal-IObj shim

JVM-faithful representation: `[node {:zip/path … :zip/lefts …
:zip/rights …}]`. cw v1 lacks `with-meta` / `meta`, so the path
forward is either to land the full D-075 system (~500 LOC,
out-of-scope for row 7.13) or to ship a minimal IObj-equivalent
JUST for zipper (e.g. per-vector tail-meta slot with only the
keys clojure.zip uses).

- **Surface**: ~600 LOC (full minimal-IObj impl + zipper defns).
- **Better**: JVM-faithful — line-for-line port of `zip.clj`;
  upstream zipper-aware libraries port without modification;
  future Clojure conformance tests on zipper land without
  shimming.
- **Worse**: F-003 violation — the minimal-IObj shim **seizes the
  D-075 / F-004 owner's structural decision** (HeapHeader layout
  review for the meta pointer). Survey + DA both flag this as
  the headline reason to reject Alt 1; the per-nav `~3×`
  hashmap-probe cost (Group A array_map / hash_map lookup vs
  ZipLoc field access) and the "skeleton enlarges the future
  rewrite" smell are secondary.
- **F-NNN: violates F-003** (premature structural decision in a
  D-075 / F-004 owner's territory). Neutral on F-001 / F-002 /
  F-006 / F-009.

### Alt 2 — Finished-form-clean: defrecord ZipLoc (ADOPTED)

(Decision section above.) The survey's Option B.

### Alt 3 — Wildcard: dedicated `HeapTag.zip_loc` slot

Promote ZipLoc to a first-class Tag rather than routing through
`.typed_instance`. Maximum cache density (no descriptor pointer
chase per field access; `node` reads a fixed offset).

- **Surface**: ~250 LOC (zip_loc HeapTag + trace fn + finaliser
  + per-field accessor + 31 defns). One F-004 NaN-box slot
  consumed.
- **Better**: fastest per-op access; "zip is core enough to
  warrant a slot" finished form for zipper-heavy workloads.
- **Worse**: **violates F-003 + F-004**. F-004 budget is finite
  (12 slots remaining per the second-generation layout); spending
  one on a single library function set sets a precedent that
  exhausts the budget by Phase 8+. Also weakens F-009 — impl
  moves into Zig (`runtime/collection/zip_loc.zig`) when the
  whole point of Pattern A is .clj-side migration.
- **F-NNN: violates F-003 + F-004**.

### Pre-finding (out-of-envelope, recorded leading per CLAUDE.md DA mandate)

**`atom`-keyed sidecar (DA wildcard, sub-variant)**: a global
`atom`-keyed-by-node-identity hashmap could carry path state
hidden from user code entirely, giving a clean public API
without per-loc state. Survey's DA flagged: cw v1's `atom`
Layer-2 primitive is **NOT wired** (HeapTag slot 32 reserved but
no `atomFn` registration in `src/lang/primitive/`). Substrate
gap excludes this even as a wildcard. Recorded so the main loop
sees it but does not halt.

### F-NNN comparison summary

| Option          | F-001 | F-002 | F-003 | F-004 | F-006 | F-009 |
|-----------------|-------|-------|-------|-------|-------|-------|
| Alt 1           | 0     | =     | **-** | 0     | 0     | 0     |
| Alt 2 (ADOPTED) | 0     | +     | +     | 0     | 0     | +     |
| Alt 3           | 0     | =     | **-** | **-** | 0     | -     |

Alt 1 vs Alt 2 is a genuine F-002 ambiguity (JVM-faithful for
library compatibility vs defrecord for v1 internal consistency).
F-003 breaks the tie cleanly in Alt 2's favour.

## Consequences

### Positive

- D-075 (with-meta / IObj / meta runtime) stays a separate Phase
  7+ entry decision; row 7.13 does not seize that owner's choice.
- defrecord substrate (rows 7.4 / 7.6) gets a meaningful Pattern A
  consumer beyond the diff_test cases, proving the dispatch +
  field-access path end-to-end on a real Clojure surface.
- `(instance? ZipLoc loc)` works out of the box via row 7.12
  cycle 1's class_name registry (user TypeDescriptor parent
  walk).
- The 4-predicate set (`zip-loc?` / `seq-zip?` / `vector-zip?` /
  `xml-zip?`) gives users symmetric query surface — JVM has
  only the underlying instance check; cw v1's richer set is a
  cw-original ergonomic improvement.
- `cycle 4`'s `(edit loc f & args)` variadic rides ADR-0041
  (multi-arity `fn*`) + ADR-0042 (apply variadic peel-and-pass)
  — no follow-up debt.

### Negative

- Non-JVM-faithful representation: users porting zipper-aware
  libraries from JVM Clojure must rewrite any code that calls
  `(meta loc)` to inspect internal zipper state. Mitigation: the
  public clojure.zip API (`up` / `down` / `node` / `path` etc.)
  is identical to JVM — only internal-state inspection diverges.
  Most user code uses the public API only.
- The forward-commitment statement above means future re-reads
  of this ADR cannot re-open the JVM-faithful migration question
  without a new ADR amendment chain. This is deliberate per the
  DA's amendment (A): every future re-read re-opens the question
  otherwise.

### Deferred

- D-075 `with-meta` / `meta` runtime is independent of this ADR.
  Its landing does NOT trigger any ZipLoc migration.
- `xml-zip`'s `:content` keyword-as-fn lookup → use `(get node
  :content)` workaround in cycle 1 (no PROVISIONAL marker
  needed — `(get)` works fully). D-085 keyword-as-fn closure is
  opportunistic; once landed, the cycle 1 `(get node :content)`
  call can opportunistically flip to `(:content node)` for
  ergonomic uniformity.

## Cross-references

- ROADMAP §9.9 row 7.13 (this row's task table entry).
- D-080 (`.dev/debt.yaml`) — `clojure.zip` 28 vars Pattern A
  landing. ADR-0043 carries the representation decision +
  expands the var count to 31 (4-predicate set per DA
  amendment B).
- D-075 — `with-meta` / IObj / IMeta runtime. Permanently
  unrelated to this ADR per the forward-commitment statement.
- D-085 — keyword-as-fn callable. Opportunistic discharge
  trigger for the `(get node :content)` → `(:content node)`
  ergonomic upgrade in `xml-zip`.
- ADR-0040 — `op_method_call` (the field-access path cycle 4's
  `(edit loc f ...)` uses for `(.node ...)` reads).
- ADR-0041 — multi-arity `fn*` (cycle 4 `edit`'s variadic
  substrate).
- ADR-0042 — apply variadic peel-and-pass (cycle 4 `(edit loc f
  & args)` calls `(apply f node args)` under the hood).
- F-002 (`.dev/project_facts.md`) — finished-form cleanliness;
  the rejection of Alt 1's smallest-diff JVM-faithful path
  rides on this.
- F-003 — decision-deferral on structural plans; the headline
  reason for Alt 1's rejection (would seize D-075 / F-004
  owner's territory).
- F-004 — NaN-box 64-slot layout; the headline reason for Alt 3's
  rejection (would consume a precious slot for a single
  library).
- F-009 — feature-implementation neutrality; Alt 2 keeps impl in
  `.clj`, aligning with the F-009 surface-layering aesthetic.
- `private/notes/phase7-7.13-survey.md` — Step 0 survey.
- `private/notes/phase7-7.13-da-fork.md` — Devil's-advocate
  enumeration; this ADR's "Alternatives considered" section is
  the DA output condensed.
- `~/Documents/OSS/clojure/src/clj/clojure/zip.clj` — JVM
  Clojure semantics anchor (=Alt 1 baseline).
- `~/Documents/MyProducts/ClojureWasm/src/lang/lib/clojure_zip.zig`
  (608 LOC) — cw v0 implementation. NOT a clean template for
  v1 because v0 had the with-meta system landed; ADR-0043
  explicitly diverges from v0's representation.
