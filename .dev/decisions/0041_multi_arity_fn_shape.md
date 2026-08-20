# 0041 — Multi-arity `fn*` shape: uniform `methods` slice on FnNode + Function

- **Status**: Accepted (Devil's-advocate fork landed 2026-05-27)
- **Date**: 2026-05-27
- **Author**: Shota Kudo (drafted with Claude autonomous loop)
- **Tags**: fn, analyzer, dispatch, multi-arity, recur, F-001, F-002,
  F-009, D-070, ADR-0036

## Context

Phase 7 row 7.8 (D-070) opens multi-arity `fn*` / `defn`:

```clojure
(defn greet
  ([] (greet "world"))
  ([name] (str "hello, " name)))
```

JVM Clojure compiles each arity body to its own `invoke(N args)`
method on the generated class; the JIT dispatches by JVM method
overload resolution. cw v1 today accepts only single-arity
`(fn* [params] body)` (`src/eval/analyzer/bindings.zig:23-86`)
and emits a flat `FnNode { arity, has_rest, params, body }`
(`src/eval/node.zig:160-175`). `tree_walk.Function`
(`src/eval/backend/tree_walk.zig:100-124`) mirrors the flat shape.

Several Phase 6 `.clj` defns are blocked on multi-arity:
transducer 1-arg arities (`(map f)`), multi-arg `comp` / `juxt` /
`partial` / `complement` / `every?`, the 3-arity
`clojure.set/join`. All carry `PROVISIONAL` markers pointing at
`feature_deps.yaml#special_form/fn_multi_arity` which discharges
at row 7.8 close.

Row 7.8's Step 0 survey lives at
`private/notes/phase7-7.8-survey.md` (850 lines; reads JVM
`Compiler.java::FnExpr.parse` + `AFn.invoke`, cw v1 current shape,
cw v0 `extra_arities` prior art, dual-backend parity check per
ADR-0036). Survey §6 enumerates 3 options (A macro-desugar, B
uniform `methods` slice, C bytecode jump-table). Step 0.6
amendments at survey §11 lock in REPLACE-not-additive for FnNode +
Function fields and MERGE per-method recur scope creation into
cycle 1 (eliminates the R1 silent-default-shift gap entirely).

## Decision

Adopt **Option B-extracted** — uniform `methods: []const FnMethod`
slice on both `FnNode` and `tree_walk.Function`, with `variadic:
?FnMethod` as a separate slot; single-arity ships as
`methods.len == 1`, `variadic == null`. Per-method recur scope
creation merges into cycle 1 (so the multi-arity surface opens
with correct `recur` semantics from day one — no window where
`recur` re-enters the wrong body).

### `FnNode` shape (`src/eval/node.zig`)

```zig
pub const FnMethod = struct {
    arity: u16,
    has_rest: bool,
    params: []const []const u8,
    body: *const Node,
    bytecode: ?*const BytecodeChunk = null,
};

pub const FnNode = struct {
    /// Fixed-arity methods, sorted by `arity` ascending. Single-arity
    /// is a 1-element slice. JVM rule 2 (no two same-arity fixed)
    /// enforced at analyzer-time.
    methods: []const FnMethod,
    /// At most one variadic per JVM rule 1.
    variadic: ?FnMethod = null,
    slot_base: u16 = 0,
    loc: SourceLocation = .{},
};
```

### `tree_walk.Function` shape

Same `methods` + `variadic` shape on the heap struct. The
existing flat fields (`arity` / `has_rest` / `params` / `body` /
`bytecode`) are dropped — single-arity reads `methods[0]`.

### Analyzer dispatch (`analyzeFnStar`)

JVM `FnExpr.parse` always normalises into multi-arity form before
parsing. cw v1's analyzer wraps single-arity (`(fn* [x] body)`)
into the multi-arity shape (`(fn* ([x] body))`) before walking the
body list; each `(params body...)` sublist becomes one FnMethod.

JVM rules enforced at analyzer-time with three new error catalog
codes (per `.claude/rules/error_catalog_only.md` naming convention):

- `fn_star_arity_duplicate` — two fixed methods share the same
  required-arg count.
- `fn_star_variadic_duplicate` — more than one `[& rest]` body.
- `fn_star_fixed_exceeds_variadic` — a fixed method has more
  params than the variadic's required count.

Per-method scope: each FnMethod runs body analysis inside its
own `child_scope` with its own `recur_target`. `recur` inside
arity-N body re-enters arity-N body (JVM parity).

### Runtime dispatch (`callFunction`)

```zig
for (f.methods) |m| {
    if (args.len == m.arity) { ... bind params + run body ... }
}
if (f.variadic) |v| {
    if (args.len >= v.arity) { ... bind v.params + build rest list ... }
}
return error_catalog.raise(.arity_not_expected_multi, loc, .{
    .fn_name = ..., .got = args.len, .arities = ... });
```

JVM rule "fixed-arity wins on exact match" naturally falls out:
the fixed loop scans first.

New error code `arity_not_expected_multi` carries a `{arities}`
slot for the message "Wrong number of args (N) passed to: foo —
expected one of: 1, 2, or [3 & rest]".

### VM compile dispatch

Each FnMethod's body compiles to its own `BytecodeChunk`. The
`op_make_fn` payload extends to carry N chunks; the runtime
`Function.methods[i].bytecode` carries the per-method pointer.

### Cycle plan (4 cycles, down from survey's 5)

- **Cycle 1**: FnNode + Function uniform `methods` slice + analyzer
  parse + per-method recur scopes + TreeWalk dispatch + VM compile
  arm + VM call dispatch + 3 new error codes + ≥ 1 diff_test case
  (this ADR is the cycle 1 ADR commit).
- **Cycle 2**: variadic-and-fixed coexistence dispatch + JVM rule 3
  analyzer-time enforcement + diff_test cases.
- **Cycle 3**: `defn` macro extension (multi-arity body desugar
  surface); 2 e2e tests; docstring + meta-map deferred per survey
  §11 Q6 to a new D-NNN follow-up row.
- **Cycle 4** (= survey's cycle 5): PROVISIONAL discharge for the
  5+ blocked `.clj` defns; flip
  `feature_deps.yaml#special_form/fn_multi_arity` from `planned`
  to `landed`; flip row 7.8 [x].

Survey's cycle 4 (optional perf fast-path inlined `arity0` slot)
is deferred to a debt row to be filed only if `bench/quick`
regresses on single-arity calls after cycle 1.

## Devil's-advocate fork (depth-2, fresh context) — verbatim embedding

The DA subagent ran with fresh context and the F-NNN envelope from
`.dev/project_facts.md`. Survey §6 already enumerates Options A
(macro-desugar), B (uniform slice), C (bytecode jump-table); the
DA produced **3 new alternatives** the main loop may be
attention-suppressed against (named D / E / F to follow the
survey's A/B/C):

> **Alternative D — Analyzer-only multi-arity (Function stays
> single-arity; one Function value per arity; closure storage
> shared)**.
> Shape. Analyzer emits N FnNodes wrapped in a thin
> `MultiFnNode { arities, variadic, closure_bindings_shape }`. A
> new HeapTag `multi_arity_fn` (Group B reserved slot per F-004)
> wraps N per-arity Functions; closure-captured Values intern
> once behind a `*const ClosureCells` shared across arities. The
> existing single-arity Function and `callFunction` are
> **unchanged** — only a `callMultiArityFn` arm is added.
> Better than B-extracted. Zero churn in `Function` struct →
> zero risk of regressing the single-arity hot path (survey R4
> evaporates). VM `op_make_fn` / `op_call` / `evalChunk` need no
> field-layout work; only the new tag arm. `(arglists f)` works
> identically.
> Cost. Burns a Group B reservation. Identity / meta semantics
> double the wrap layer. Most importantly: **two callable shapes**
> (`fn_val` vs `multi_arity_fn`) for what JVM calls "one fn" —
> every dispatch site (dispatch.zig, partial, apply, comp) has to
> learn both. Exactly the asymmetry F-002 finished-form penalises.
> F-NNN. F-001 ✓; F-002 ⚠ (asymmetric callable shapes contradict
> "symmetric methods slice with `len == 1` for single-arity"
> finished form). F-004 ✓. F-006 ✓. F-009 ✓. **Verdict: F-002
> weak; smallest-diff bias smell against B-extracted.**
>
> **Alternative E — Reuse the existing `multi_fn` Tag as the
> dispatch backbone (row 7.2 multimethod infrastructure subsumes
> arity dispatch)**.
> Shape. The analyzer compiles `(fn* ([x] body1) ([x y] body2))`
> into a synthetic MultiFn (the existing `.multi_fn` Tag at
> `value.zig:63`) whose dispatch-fn is the built-in
> `arity-of-args`, and whose method table maps `1 → body1-as-
> Function`, `2 → body2-as-Function`, `:default-variadic →
> variadic-Function`. `callFunction` stays untouched.
> Better than B-extracted. One dispatch mechanism for "callable
> that branches on a property of its args" — multimethods AND
> arity dispatch share it. Row 7.2's hash-keyed table is O(1)
> dispatch.
> Cost. **`recur` semantics break catastrophically.** A MultiFn's
> per-method body is a separate Function value with its own
> scope frame; routing through `callMultiFn` adds a hash lookup
> + dispatch-fn evaluation + method-table read for every fn
> call (hot-path regression). The dispatch-fn must live outside
> lexical scope — opposite to JVM's "arity is the first thing
> decided, params bind second." `(arglists f)` on a MultiFn-
> shaped fn would have to special-case "is this really a fn?"
> F-NNN. F-001 ✓. F-002 **violation candidate** — subsumption
> produces a finished form where `(fn ...)` returns a
> *multimethod*; the Clojure surface says "fn returns a fn." F-005
> ✓. F-006 ✓. F-009 ✓. **Verdict: rejected** — semantic-identity
> violation; the cleanness is on the wrong axis.
>
> **Alternative F — Discriminated-union FnNode + tagged Function
> (`Single` fast path inlined, `Multi` is the slice path)**.
> Shape. `FnNode` becomes a `union(enum) { single: SingleArityFn,
> multi: MultiArityFn }`. `SingleArityFn` keeps today's flat
> fields verbatim; `MultiArityFn` carries the `methods` slice +
> variadic. `Function` mirrors. `callFunction` does
> `switch (f.body) { .single => |s| ...today's fast path...,
> .multi => |m| ...linear scan + variadic... }`.
> Better than B-extracted. Single-arity Function never pays for
> the `methods` slice indirection (survey R4 evaporates without
> needing the deferred "inline arity0 fast slot" fix). The two
> shapes are explicit in the type — readers grep `.multi` to find
> all multi-arity code paths. **Minimum-risk** shape for cycle 1.
> Cost. Two code paths per Function operation forever —
> `(arglists f)`, GC root-set walk, bytecode chunk install at
> `op_make_fn`, etc. — each has a switch arm. Each future arity-
> touching feature must remember both arms. This is exactly the
> "primary + extras" asymmetry survey §3 rejected as v0 folklore.
> The `methods.len == 1` uniformity that B-extracted ships *is*
> the F-002 finished form precisely because it kills the "is this
> single or multi?" branch.
> F-NNN. F-001 ✓. F-002 ⚠ — duplicate code paths is the textbook
> smallest-diff bias shape (small per-cycle diff, larger finished
> form). F-006 ✓. F-009 ✓. **Verdict: B-extracted is the F-002-
> cleaner shape; F is the *risk-minimal* shape if cycle 1 cannot
> afford the unified-slice surgery, but the main loop's authority
> to take big surgery (F-002 says so explicitly) makes F a
> smallest-diff-bias trap.**
>
> **No hard F-NNN violation** across D / F (both flagged as F-002
> weak, not breaches). Alt E is rejected for breaking JVM
> `(arglists f)` + recur ergonomics.
>
> **Recommendation**: B-extracted (the main agent's choice) is
> the strongest finished-form fit. F is held as the documented
> mitigation in `.dev/debt.yaml` if `bench/quick` later motivates
> it; D and E recorded as "considered and rejected" so future
> readers see why the symmetric-slice shape is load-bearing
> rather than a default.

**Selected**: Option B-extracted (uniform `methods` slice). The
DA's recommendation aligns with the main agent's lean. Alt D
rejected because callable-shape asymmetry fan-outs across
dispatch / partial / apply / comp / meta — a permanent debt the
loop would carry. Alt E rejected per DA's "semantic-identity
violation" finding (a fn that is actually a multimethod). Alt F
preserved as a follow-up fallback debt row to be filed only if
cycle 1's bench shows the linear-scan-over-1-element-slice as a
real regression.

## Affected files

Cycle 1 source commit touches:

- `src/eval/node.zig` — `FnNode` field rewrite (drop `arity` /
  `has_rest` / `params` / `body`; add `methods` + `variadic`); new
  `FnMethod` struct co-located with FnNode.
- `src/eval/analyzer/bindings.zig` — `analyzeFnStar` extension: detect
  single-vs-multi body shape, parse each `(params body...)` into one
  FnMethod, enforce JVM rules 1-2 (rule 3 deferred to cycle 2 along
  with variadic-fixed coexistence). Per-method `child_scope` with own
  `recur_target`.
- `src/eval/backend/tree_walk.zig` — `Function` field rewrite to mirror
  FnNode shape; `callFunction` linear-scan dispatch.
- `src/eval/backend/vm/compiler.zig` — `op_make_fn` payload extension
  to carry N chunks; emit one chunk per FnMethod.
- `src/eval/backend/vm.zig` — `op_call` arm consumes the FnMethod with
  the matching arity from `Function.methods`.
- `src/runtime/error/catalog.zig` — three new Codes
  (`fn_star_arity_duplicate`, `fn_star_variadic_duplicate`,
  `arity_not_expected_multi`); `fn_star_fixed_exceeds_variadic`
  deferred to cycle 2 with rule 3.
- `src/lang/diff_test.zig` — ≥ 1 diff_test case exercising 1-method
  + N-method dispatch.

Cycle 2 / 3 / 4 add `variadic` body parsing, `defn` macro extension,
and the PROVISIONAL discharge sweep.

## Consequences

**Required**:
- ADR-0036 dual-backend parity: cycle 1 lands TreeWalk + VM in the
  same commit (`Function.methods` + `callFunction` + `op_make_fn`
  payload extension all share the same `methods` slice shape).
- Step 6 cycle protocol: this ADR commit lands first; the source
  commit lands separately.

**Optional follow-ups**:
- If `bench/quick` shows single-arity regression after cycle 1, file
  a `D-NNN` debt row promoting Alternative F (discriminated-union
  Function) as the mitigation. Survey R4 predicts the regression is
  negligible (single-element slice walk ≈ direct field read).
- `defn` docstring + meta-map support deferred per survey §11 Q6 to
  a separate `D-NNN` follow-up row, filed at cycle 3 close.
- `feature_deps.yaml#special_form/fn_multi_arity` flips from
  `planned` to `landed` at cycle 4 close.

## Revision history

- 2026-05-27 (Accepted): initial draft + DA fork + main-agent
  selection of Option B-extracted.
