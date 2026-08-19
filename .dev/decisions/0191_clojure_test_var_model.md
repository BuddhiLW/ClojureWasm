# 0191 — clojure.test adopts clj's `:test`-metadata var model

- **Status**: Proposed
- **Date**: 2026-08-18
- **Author**: BuddhiLW
- **Tags**: clojure.test, compliance, tooling, conformance

## Context

cljw is being measured against the jank-lang `clojure-test-suite` — 248 `.cljc`
namespaces, one per `clojure.core` symbol, run by `cljw` itself (ADR-0188 put
`:cljw` in the reader's feature set for exactly this). A first full run scored
150 green / 96 red / 2 aborted namespaces, and the campaign that follows is a
long drain against that number.

Which makes the harness itself load-bearing. An audit of cljw's `clojure.test`
against clj 1.12's found three defects that are not test failures but
**measurement failures** — the instrument reporting something other than what
ran:

1. `(run-tests *ns*)` — the call clj's own 0-arity makes — printed
   `Testing #object[Namespace "user"]` and reported `Ran 0 tests, 0 failures`.
   A namespace whose tests never ran read as a clean pass.
2. Re-evaluating a `deftest` (any reload, any `require :reload`) appended the
   var to the registry a second time, so one test reported as two.
3. `(are [x y] (= x y) 1 1 2)` silently dropped the trailing partial group and
   passed. The assertion the author wrote simply did not exist.

Underneath all three is a design difference. clj stores a test's body in the
**var's `:test` metadata** and makes the var's value `(fn [] (test-var (var
name)))`; cljw stored the body as the var's value and tracked membership in a
separate `*test-registry*` atom keyed by namespace symbol. Everything clj builds
on `:test` therefore had no cljw analogue — `with-test`, `set-test`,
`test-vars`, `test-all-vars`, `test-ns`, `run-test`, `run-test-var` were all
absent, `(alter-meta! #'f assoc :test …)` was a silent no-op, and every external
runner (`cognitect.test-runner`, `kaocha`, `lein test` selectors) that
enumerates `(vals (ns-interns ns))` filtering on `:test` found zero tests in
cljw.

The registry model was not a JVM-less necessity. Every primitive clj's model
needs — `^{:test fn}` var metadata evaluated at `def` time (D-563(b)),
`alter-meta!`, `vary-meta`, `ns-interns`, `the-ns`, `find-ns`, `ns-resolve` —
already works in cljw.

## Decision

**`clojure.test` adopts clj's var model: `:test` metadata is what makes a var a
test, and the var's value is a thunk that routes through `test-var`.**

`*test-registry*` is retained, demoted to a pure **order index**: `:test`
metadata decides *membership*, the registry only remembers the order tests were
defined in, and registration is idempotent so a reload cannot double-count.
clj's `ns-interns` walk is hash-ordered; a 248-namespace compliance log is much
easier to read in source order, and a var that acquired its test another way
(`set-test`, `alter-meta!`) is still found — name-sorted — behind the ordered
ones.

Landing with it, so the instrument stops lying and the public surface closes:

- `run-tests` / `test-ns` / `test-all-vars` accept a symbol, a string, or a
  namespace object, and **raise on a namespace that is not loaded** — a zero
  that means "absent" must never read as a pass.
- `are` raises when the argument count is not a whole multiple of its argv.
- `use-fixtures` **replaces** the fixtures of its kind rather than appending, so
  reloading a namespace cannot silently run its fixtures twice per test.
- `report :default` prints the event map (clj parity); `:end-test-ns`,
  `:begin-test-var` and `:end-test-var` gain explicit no-op methods, which
  `:default`'s new printing behaviour makes mandatory rather than decorative.
- New: `test-ns`, `test-vars`, `test-all-vars`, `run-test-var`, `run-test`,
  `with-test`, `set-test`, `deftest-`, `successful?`, `*load-tests*`,
  `assert-predicate`, `assert-any`, `get-possibly-unbound-var`, and
  `assert-expr` methods for `instance?` and `:always-fail`.
- `test-var` counts the test it runs (clj bumps `:test` inside `test-var`), so a
  direct `(test-var #'t)` counts exactly like one reached through `run-tests`.

`test-ns` also honours a namespace's `test-ns-hook`, and is the seam
`cljw.test`'s source-path runner calls per namespace to keep one total across a
whole suite.

## Alternatives considered

*Sourced from a Devil's-advocate fork with fresh context, reflected verbatim.
Every claim marked "verified" was measured — against the built `cljw` for cljw
behaviour, and against `clj` for oracle behaviour — not recalled.*

**No F-NNN blocks any option here.** The cleanest shape (Alternative C) touches
`src/runtime/env.zig`, but `runtime/env.zig` is named in F-009's explicit *Out
of scope* list (language-core foundations), so the neutrality invariant does not
bind it. Nothing in this decision needs an F-NNN amendment.

### Alternative A — smallest-diff: keep the registry as the sole source, patch only the false-greens

Leave `deftest` expanding to `(def name (fn [] body…))` + `swap!`. Land only the
audit's corrections: coerce namespace objects and strings in `run-tests` /
`test-ns`, make registration idempotent, throw on `are`'s partial group, print
unhandled `report` events.

**What it does better than the draft.** It has no two-structure problem at all,
because there is genuinely one structure: the registry is both membership and
order, and definition order is free by construction rather than reconstructed.
It never puts a closure into var metadata, so it cannot interact with the
`:test`-fn-in-def-meta path that D-563(b) opened, and it leaves the AOT envelope
(`cache_gen` → `bootstrap_core.cljc`) compiling a strictly simpler `deftest`
expansion. `tests-in-ns` collapses to a `get`, avoiding the per-namespace
`ns-interns` materialization the draft performs on every `test-ns` call — 248
full `mapOfVars` persistent-map builds across a compliance run.

**What it breaks.** It cannot honestly carry five of the vars the draft adds.
`with-test`, `set-test`, `deftest-`'s privacy story, and any
`alter-meta!`-attached test all require a `:test` key to hang a body on; without
it they are either absent or lies. F-014 clause 2 — *"a partial class is a worse
trap than an absent one"* — governs a surface the campaign is actively touching,
so shipping `clojure.test` with those vars missing while claiming
compliance-oracle readiness is the exact trap that clause forbids. It also
leaves the REPL divergence in place: verified against clj, `@#'some-test` is a
thunk and calling `(some-test)` routes through `test-var` and reports; under A a
direct call runs the raw body, reports nothing, and counts nothing. Finally, the
jank `clojure-test-suite` is `.cljc` written against JVM `clojure.test`; any
namespace in it that reads `(:test (meta #'x))` — or any runner that filters
`ns-interns` on `:test` — sees an empty world. This is a *different and worse
finished form*, not a cheaper route to the same one, so F-002 clause 2 rejects
it. Recorded for completeness only.

### Alternative B — the draft, corrected on four counts (recommended by the fork)

Keep the draft's core move: `:test` metadata is the sole answer to "is this var
a test", the var's value is a `test-var` thunk. Correct four places where the
draft either kept a stale cljw adaptation or closed something clj leaves open.

1. **Delete `*fixture-registry*`; use namespace metadata.** Verified on the
   built binary: `(alter-meta! *ns* assoc :clojure.test/once-fixtures [f])`
   works, persists, survives `in-ns` round-trips, is readable through `find-ns`
   and `the-ns` from another namespace, and round-trips namespaced keys; `(ns
   zzz "doc")` even attaches `{:doc "doc"}`. Verified against clj: in a fixtured
   namespace `(keys (meta *ns*))` is exactly `(:clojure.test/once-fixtures)`.
   The comment justifying the atom — *"cljw namespaces carry no user metadata"*
   — is stale, and the atom is now the same divergence class the draft is
   removing on the `deftest` side: a side table keyed by ns symbol standing in
   for host metadata that in fact exists.
2. **`use-fixtures` goes back to a `defmulti`.** Verified: `(class use-fixtures)`
   in clj is `clojure.lang.MultiFn`, dispatching on `fixture-type`, so a user
   can add a fixture kind. The draft replaces it with a `defn` guarded by
   `(contains? #{:each :once} fixture-type)` — closing an open set, which is the
   Cardinality-Decides-the-Construct inversion and, per F-013 clause 3, a
   hand-maintained recognised-name allowlist where the definition supplies an
   open one.
3. **Match clj's `are` predicate exactly, and its error class.** The draft's
   guard has a hole its sibling closes: for non-empty `argv` and *zero* args,
   `(zero? (mod 0 2))` is true, so `(are [x y] (= x y))` passes silently.
   Verified against clj: that form throws `java.lang.IllegalArgumentException` —
   clj's predicate additionally requires `(pos? (count args))`. The draft fixes
   one silent-drop and leaves the adjacent one open. Separately, both this throw
   and the fixture-type throw should be an `IllegalArgumentException` equivalent
   rather than `ex-info`; F-011 clause 3 makes the exception *class* part of the
   equivalence target even though the message format is free.
4. **`run-all-tests` must not read the registry.** clj's is `(apply run-tests
   (all-ns))` with a regex-filtering arity. The draft keeps `(apply run-tests
   (keys (deref *test-registry*)))`, so a namespace whose tests were attached
   only via `set-test` / `with-test` / `alter-meta!` is invisible to a full run
   — an under-report of exactly the class this ADR was chartered to eliminate,
   and it exists *only because the registry was retained*. `all-ns` exists in
   cljw (verified, 99 namespaces at boot).

**What it does better than the draft.** It removes the last two side tables
instead of one, so the ADR's own thesis — *metadata is where a var's test lives*
— is applied consistently rather than half-way. It closes a leak the atom has
and metadata does not: nothing ever removes a `*fixture-registry*` entry, so
every fixture fn of every namespace ever loaded is retained for the process
lifetime, whereas ns-metadata dies with the namespace. And it removes a
genuinely invisible failure: today cljw's fixture state does not appear in
`(meta *ns*)`, so a reporter or library that introspects fixtures, or that
clears them with `(alter-meta! ns dissoc ::once-fixtures)`, silently does
nothing.

**What it breaks.** More surface churn than the draft, and
`use-fixtures`-as-multimethod means the `:each`/`:once` validity check moves
from an explicit message to "no method for dispatch value", which reads worse to
a user who typos a keyword — that is what clj does, and F-011 makes clj the
target. It does not, on its own, answer the ordering question.

### Alternative C — wildcard: make the namespace itself definition-ordered, and delete the index

`Namespace.mappings` is `std.StringHashMapUnmanaged(*Var)` (`src/runtime/env.zig`).
Change it to the ordered map. Interning order then *is* iteration order, so
`ns-interns` returns definition order, `tests-in-ns` becomes one `filter` over
`ns-interns`, and `*test-registry*`, `register-test!`, the name-keyed dedup, and
the two-bucket reconciliation in `tests-in-ns` all delete. The double-count bug
stops being something the code defends against and becomes structurally
impossible.

**What it does better.** It is the only option in which one structure answers
both questions, so the SSOT concern dissolves rather than needing adjudication.
The benefit is not confined to `clojure.test`: cljw's `ns-interns` order today is
arbitrary *and* unstable (verified: five vars defined `a b c d e` came back
`(x a v1 d b c v2 e)`), which is latent nondeterminism in everything that walks
a namespace — `ns-publics` in doc tooling, `cljw --list-vars`, REPL completion,
and the `scripts/gen_placement.sh` → `placement.yaml` generator whose
`placement_drift` gate diffs generated output. Making it source-ordered is a
strict refinement of a contract clj leaves unspecified, and it lands
`placement.yaml` determinism for free. The ordered map also iterates a dense
array, so the GC root-set walk over `mappings` gets marginally faster.

**What it breaks.** 28 references across 7 files (`primitive.zig`,
`primitive/namespace.zig`, `primitive/core.zig`, `eval/loader.zig`,
`runtime/env.zig`, `runtime/introspect.zig`, `runtime/gc/root_set.zig`); no
ordered hash map is used anywhere in the tree today, so this introduces the
idiom. The API is near-identical (`get` / `put` / `iterator` / `deinit`), with
one trap: `remove` must become `orderedRemove`, not `swapRemove`, or order is
silently destroyed at the one call site that removes — cljw has no `ns-unmap`
(verified absent; `ns-unalias` exists), so removal is close to unused, which
makes this cheap *and* makes it easy to get wrong later by reflex. It also
diverges from clj's hash order, which is a divergence in the direction of
determinism and belongs in the AD ledger next to AD-001 rather than being
treated as a defect. Per F-002, the diff size is not an argument against it.

**Devil's-advocate recommendation: B + C together.** C answers the ordering
question at its source; B makes the metadata thesis consistent. Neither is
blocked by an F-NNN, and per F-002 clause 2 the combined shape is the finished
form the two half-measures are each approximating.

### The three risks the fork was asked to resolve

**Ordering — is keeping both structures a SSOT violation?** Yes, in the form the
draft has it, and the rot has already started. The evidence is in the draft's own
`tests-in-ns`: it filters the registry by `:test`, builds a `seen` set of
*names*, then appends the `ns-interns` residue sorted by name. That
reconciliation exists only because the two structures can disagree — and
`register-test!` compares `(:name (meta v))` where var identity would be exact.
Verified: cljw vars are interned and stable across redefinition (`(identical? v1
v2)` → `true` after `(def x 1)` … `(def x 2)`), so the name comparison is a
workaround for a problem that does not exist. It will rot further in three named
ways: a var that gains `:test` via `set-test` falls into the residue bucket and
sorts by name into a position that is not the source order it was written in; a
`deftest` inside a `when` or emitted by a macro registers in *eval* order, which
is not source order either; and nothing ever clears a registry entry, so a stale
var survives every reload and is saved from being run only by the `:test`
filter, i.e. by the other structure. "Metadata decides membership, index decides
order" is a legitimate projection **only when the index is derived from the
membership source** — the Single-Source-Lever shape — and the draft has two
definitions instead. If C is rejected, the honest alternative is to drop the
index, accept clj's hash order for the *run*, and sort the *report* by the
`:line` / `:file` var meta D-563(b) provides.

**`*load-tests*` — does macroexpansion-time evaluation interact badly with AOT?**
Yes, and the draft has not accounted for it. `src/app/builder.zig::buildEnvelope`
macroexpands every top-level form of a `cljw build` script at BUILD time and
serializes the result; `src/cache_gen.zig` does the same over `ACTIVE_FILES`,
which includes `clj/clojure/test.clj`. So a macroexpansion-time flag is baked
into the artifact by construction: a binary built with `*load-tests*` true
carries every test body forever, and one built with it false contains no test at
all and no runtime rebinding can bring one back. This is the same wart JVM
Clojure has (its docstring says "Use this to omit tests when compiling or
loading production code"), so it is not a parity defect. But **there is no `cljw
build` surface to set the flag**, so it is inert in the one mode where it
matters — the single self-contained binary is cljw's shipping story (F-014
clause 4). Either add a `cljw build --no-tests` that binds the var around
`buildEnvelope`'s form loop, or state that `*load-tests*` is load-time-only on
cljw and a documented no-op under `cljw build`, with a debt row carrying the
barrier. Shipping it as clj-parity surface while the primary compile mode
silently ignores it is the option to reject.

**Fixtures — does the var-metadata model imply the namespace-metadata model?**
Yes, and the adaptation is no longer merely suboptimal, it is justified by a
false premise (see B1). Adopting the var-metadata model for `deftest` while
keeping a ns-symbol-keyed atom for fixtures leaves the file arguing both sides of
the same question in adjacent sections. One thing the draft got right and should
keep: `use-fixtures` replacing rather than appending is genuine clj parity
(clj's methods `assoc` into ns meta), and the reload-doubling it fixes is a real
bug, not a divergence.

### Disposition

The fork's B corrections are accepted and land as follow-ups on the staging
branch; C is accepted as a **separate decision** rather than folded in here,
because it changes a runtime data structure and the GC root walk and so earns
its own ADR, its own gate, and its own AD row for the deliberate order
divergence from clj. Until C lands, `*test-registry*` remains the order index
this ADR describes, with the fork's rot analysis above recorded as the reason
that is temporary rather than settled. `*load-tests*`'s AOT inertness is
recorded here rather than papered over; the `cljw build --no-tests` surface is
the open item.

## Consequences

- **Positive**: the three false-greens are gone, and each is pinned by a case in
  `test/e2e/clojure_test_model.sh`. A compliance number measured after this
  change means what it says.
- **Positive**: cljw becomes legible to external Clojure test runners, which
  read `:test` metadata. That is a portability property, not only a compliance
  one.
- **Positive**: `with-test` / `set-test` / `alter-meta!` work, so a test can be
  attached to a var whose definition it does not own.
- **Negative**: two structures now describe one namespace's tests (metadata for
  membership, registry for order). The rot risk is real and is why registration
  is idempotent and membership is filtered through `:test` on every read — the
  registry can only ever *lose* to the metadata, never contradict it.
- **Neutral**: fixtures stay in `*fixture-registry*` keyed by namespace symbol
  rather than moving to namespace metadata, since cljw namespaces carry no user
  metadata. That adaptation predates this decision and is unchanged by it.

## Affected files

- `src/lang/clj/clojure/test.clj` — the model, the API, the three fixes.
- `test/e2e/clojure_test_model.sh` — new; pins the model and each false-green.
- `src/lang/clj/cljw/test.clj` — the source-path runner that calls `test-ns`.

## References

- ADR-0188 — `:cljw` in the reader's platform feature set; the compliance suite
  is the forcing case there too.
- D-227 — the original `clojure.test` implementation this supersedes in part.
- D-563(b) — computed `def` metadata evaluates at def time, the prerequisite
  that makes `^{:test (fn [] …)}` carry a real fn.
- AD-041 — the `(file:line)` suffix reads the deftest var's source meta, not the
  failing assertion's frame.
