# 0196 — Engine truth at the wasm surface; the default stays `.auto`

- Status: Accepted (2026-09-06)
- Card: `[CLJW-WASM-ENGINE-DEFAULT]` (`20260905005755-11afa056`)
- Resolves: ADR-0195 Decision 3 (the engine default was kept out of that ADR)
- Devil's-advocate report: `private/notes/adr-0196-da.md` (fresh-context fork,
  reflected below)

## Context

1. `(wasm/load path)` defaults to `:engine :auto` (D-488, 2026-06-22): zwasm's
   JIT-first engine with a transparent downgrade to the interpreter ONLY when
   the JIT cannot BUILD the module. The flip's evidence was compute: the JIT
   runs a 100M-iteration i32 loop 15.5x faster than the interpreter
   (`bench/wasm_jit_vs_interp.sh`).
2. cljw **D-585** (2026-08-22, still holds on the v2.6.0 pin, gap-locked by the
   unit test "dual-engine: a zero-result export traps on the JIT beyond a
   narrow window" in `src/runtime/cljw/wasm/engine.zig`): the JIT miscompiles
   zero-result exports outside a narrow window. Measured over empty-body
   exports, arities 1 to 5, every i32/f64 mix (40 shapes): a void export runs
   on the JIT only when its arity is <= 1, or its arity is 2 or 3 with no
   floating-point parameter. Every other void shape traps at invoke, including
   all-GPR `(i32,i32,i32,i32) -> ()`. Non-void was clean at every arity and mix
   tested. The module BUILDS, so `.auto` never downgrades: `.auto` protects
   against build failure, not miscompilation. The trapping shape is what an
   in-place numeric kernel is (`residual-add!` `(i32,i32,i32,i32)->()`).
3. The trap set is larger than that window on cljw's own ledger: D-488's
   barrier records zwasm's deferred JIT gaps as "wide arity (SysV > 5 / Win64
   > 3 params), > 2 results, v128 at the boundary; use `.interp` for these".
   Whether those fail at build (so `.auto` downgrades) or at invoke is
   unmeasured; the D-585 mechanism (a signature-keyed dispatch table with no
   entry) is the same mechanism, so the pessimistic reading is the likely one.
   The 40 measured shapes were empty bodies with i32/f64 parameters only; they
   prove nothing about i64, f32 or v128 parameters, arity above 5, or bodies
   that spill registers.
4. The interpreter is not trap-free either: a v128 (SIMD) body is JIT-only in
   zwasm, and `test/e2e/phase16_wasm_engine_select.sh` step 3 asserts exactly
   that ("lane0-interp: TRAPPED"). cljw ships a SIMD bench tier that is the
   shape an `.interp` default would break.
5. Per-call cost after ADR-0195 (cljw runs on a spawned runtime thread, so
   zwasm/D-584's initial-thread penalty is gone): on Linux a trivial
   `wasm/call` costs ~1.15 us on the JIT and ~0.4 us on the interpreter (2.8x).
   The residual is zwasm/D-584's non-initial-thread cost (~570 ns) +
   zwasm/D-585 (export re-resolved by name per call, upstream #208) + cljw's
   own double resolve in `wasmCallFn` (`[CLJW-WASM-EXPORTSIG-CACHE]`). Once
   both upstream costs are memoised the JIT's crossing equals the
   interpreter's and the JIT strictly dominates (same crossing, 15.5x body).
6. Engines cannot be switched per call: an instance's linear memory belongs
   to one engine; a module is instantiated once under one engine.
7. zwasm's embedding API exposes export SIGNATURES only on an instance
   (`Instance.exportFuncSig`); `Module.exports` yields name + kind. Any
   pre-instantiation routing by signature therefore needs either a second
   instantiation per module or a second wasm decoder inside cljw. Under
   `.auto`, cljw knows the engine it REQUESTED, not the arm zwasm chose; the
   facade has no engine-in-effect accessor.
8. `.dev/zwasm_capabilities.md` records the standing posture: cljw does not
   build cljw-side shims around zwasm gaps; it requests each upstream and
   pins the fix, and where a gap must be accommodated it is gap-locked by a
   unit test that FAILS the day zwasm fixes it, forcing removal.
9. "ADR-0200" as cited in `engine.zig`, `surface.zig`, `handover.md`,
   `debt.yaml` and the engine-select e2e is a **zwasm** ADR number. cljw's own
   sequence is at 0196 and will mint its own 0200 within a few cycles.

## Decision

1. **The default stays `.auto`.** No fixed engine default is trap-free today
   (facts 2 to 4), and the finished form is `.auto` with no cljw-side routing
   at all: both gaps are zwasm's, both have upstream fixes, and after them the
   JIT strictly dominates (fact 5). A cljw-resident model of zwasm's dispatch
   table (the shape-guarded `.auto` the first draft proposed) is a shim the
   finished-form owner would unwind, is not implementable without a second
   decoder or double instantiation (fact 7), and misses gaps already in the
   ledger (fact 3). An `.interp` default trades "in-place kernels trap" for
   "SIMD kernels trap" and leaves a second flip to land later. F-002 picks the
   shape with nothing to unflip.
2. **Engine truth at the surface: `(wasm/engine handle)`.** A new var on the
   `wasm` namespace returns `:auto`, `:jit` or `:interp`, the selection the
   handle was loaded with, read from a new `engine` field on `Loaded`. Under
   `:auto` this is the request, not the arm zwasm chose; the docstring says so.
   Resolving the arm is upstream ask (iii) below. Without this var any
   engine-dependent behaviour is the Silent default-shift smell: the user
   cannot find out which engine their handle rides.
3. **The trap diagnostic names the engine, the export and its signature, and
   the remedy when one is known.** `wasmCallFn` already holds the signature
   before it invokes, so on `.wasm_trap` the message carries
   `<export> <sig> on <engine>` at no new cost. One table,
   `src/runtime/cljw/wasm/gaps.zig`, holds the known engine gaps as rows
   (engine, signature predicate, user-facing remedy, evidence). Rows at
   landing: (a) JIT, zero results, outside the arity <= 1 / arity 2-3-no-FP
   window (measured; gap-lock test); (b) JIT, more than 5 parameters
   (zwasm-listed, D-488 barrier); (c) JIT, more than 2 results (zwasm-listed);
   (d) JIT, v128 in the signature (zwasm-listed); (e) interp, v128 in the
   signature (measured by e2e step 3). Remedies are user-facing text
   (`{:engine :interp}`, "give the export a result", `{:engine :jit}`), never
   ledger ids (error catalog hygiene). A row whose evidence is "zwasm-listed"
   words its remedy as a suggestion; a measured row states the fact. The
   table is the one place the gap set lives (F-011 clause 1, F-013 clause 2);
   the D-585 gap-lock test names row (a), and a row dies in the pin bump whose
   gap-lock flips.
4. **The crossing cost is documented, not hidden.** The `wasm/load` docstring
   and the docs/works wasm page state the measured per-call cost per engine
   and the break-even (a call whose interpreter body runs longer than ~0.8 us
   wins on the JIT; shorter loses). `[CLJW-WASM-BENCH-BLIND]` owes the
   crossing-dominated bench row (instantiate once, call many, time only the
   calls, median with min and max) beside `bench/wasm_bench.sh`, every
   workload of which loops inside the module.
5. **Three upstream asks, filed once the user nods** (`[ZWASM-PERCALL-TRACK]`
   carries them): (i) the zero-result miscompile, with the two discriminator
   pairs from the D-585 row; (ii) `.auto` should fall back on DISPATCH
   refusal, not only on build failure, which is where a correct-by-default
   `.auto` actually lives (only zwasm can tell "no dispatch entry for this
   signature" from "the guest trapped"); (iii) an engine-in-effect accessor on
   `Instance`, so `wasm/engine` can report the arm under `:auto`.
6. **zwasm ADR numbers are written `zwasm ADR-NNNN`** in cljw text, the same
   convention as `zwasm/D-NNN` for ledger ids. The bare "ADR-0200" cites in
   `.dev/`, `bench/`, `docs/`, `src/` and `test/` are rewritten in the commits
   that land this ADR (`.dev/wt-golden/` is an untracked snapshot and is left
   alone).
7. **Not taken, recorded for the next reader.** Deferred instantiation with a
   first-call downgrade (Alt C below) is the only shape inside the F-NNN
   envelope that makes the raster kernel work on a no-opts load today. It is
   trap-set-agnostic, but it protects the first call only, it cannot tell a
   dispatch refusal from a legitimate first-call guest trap without ask (ii),
   and it re-instantiates zwasm state from cljw. It is a bet on the upstream
   answer, taken WITH Decision 2 to 5, never instead; revisit only if zwasm
   declines ask (ii).

## Alternatives considered (Devil's-advocate fork, condensed from the report)

**Alt A (smallest-diff).** Keep `.auto` unguarded; land only the documented
crossing cost, the bench and the upstream report, plus a trap message that
names the engine and the signature. Better than the draft: no promise the code
cannot keep, no missing zwasm API, no scar. Breaks: it ships the trap; a raster
`residual-add!` still fails on a no-opts load.

**Alt B (finished-form-clean, taken).** Engine truth at the surface, one gap
table (not a void-only predicate), the trap diagnostic generated from it,
`wasm/engine`, and the upstream ask that moves `.auto`'s fallback from build
time to dispatch time. Better than the draft: implementable with today's API;
complete against the gap set cljw has already written down; symmetric (it
covers the interpreter's v128 gap the draft's own D1 condemned but its D2
ignored); no cljw-side model of zwasm internals; the fix goes where it
belongs. Breaks: the default still traps for a raster kernel on the first run;
Alt B's answer to that user is a precise message and a one-line remedy, not a
success, and it says out loud that no fixed engine default is trap-free.

**Alt C (wildcard).** Deferred instantiation with a first-call downgrade:
`wasm/load` compiles only; the handle instantiates at the first `wasm/call`; if
that call fails before any guest code ran, cljw discards the instance,
re-instantiates on `.interp`, retries once and pins the handle. Sound because
cljw's load path passes no linker, so a loadable module is import-free and a
fresh re-instantiation is unobservable outside its own new linear memory.
Better than everything else: trap-set-agnostic, and the only shape that makes
the raster kernel work on a no-opts load. Breaks: a cljw-side shim in the
strong sense; first-call only; cannot distinguish a dispatch refusal from a
legitimate divide-by-zero; moves a load-time failure class to call time. C is
B plus a bet on the upstream answer, not an alternative to B.

**The first draft (shape-guarded `.auto`), rejected.** Not implementable with
today's zwasm embedding API (fact 7); incomplete against the ledger (fact 3);
a cljw-resident model of zwasm's dispatch table, which is the shim
`.dev/zwasm_capabilities.md` records cljw does not build. A gap-lock guarantees
REMOVAL, not correctness while the thing stands. Load-time refusal and a
load-time warning die on the same missing API. Redefining `:auto` to mean
"cljw decides by shape" would give one keyword two contracts across the two
repos; if cljw ever needs its own policy it mints a new keyword, never
overloads zwasm's.

**`.interp` default, rejected.** Not correct by construction (fact 4);
inverts step 4 of `phase16_wasm_engine_select.sh`, the only mechanical
evidence the project holds about which engine the default uses; leaves a
second flip, its own e2e rewrite and CHANGELOG entry for later.

**DA recommendation (verbatim, closing paragraph).** "I am not recommending
Alt B because it is smaller. It is not smaller. It adds a gap table, a new var,
an accessor, an enriched error path, two upstream reports, a new bench tier
and a docs pass, against the draft's single predicate. I would recommend the
draft's guard over all of this if it were implementable and complete. It is
neither." And: "D2 without B3 is the Silent default-shift smell in pure form.
If the loop keeps the guard, `wasm/engine-of` is not optional."

## Consequences

- Positive: a user whose kernel traps under the default reads which engine
  ran it, the export's signature and the one-line remedy, instead of
  "WebAssembly module trapped". `(wasm/engine h)` makes engine-dependent
  behaviour discoverable.
- Positive: the gap set lives in one table with its evidence rung per row;
  the D-585 gap-lock test names its row, so the row cannot outlive the gap.
- Positive: nothing to unflip when zwasm lands asks (i) and (ii); the default
  is already the finished form.
- Negative: the default still traps a void arity-4 kernel on its first run
  until zwasm answers ask (ii). This ADR chooses a truthful failure over a
  guessed success.
- Negative: `wasm/engine` reports the request under `:auto` until ask (iii)
  lands; the docstring states the limit.
- Neutral: D-488 stands; ADR-0195 Decision 3 is resolved by this ADR.

## Affected files

- `src/runtime/cljw/wasm/engine.zig`: `Loaded.engine` recorded at `load`.
- `src/runtime/cljw/wasm/gaps.zig` (new): the engine-gap table + unit tests
  over the measured window and the zwasm-listed shapes.
- `src/runtime/cljw/wasm/surface.zig`: `wasm/engine`; `wasmCallFn`'s trap
  raise carries export, signature, engine and remedy; the `wasm/load`
  docstring states the crossing cost.
- `src/runtime/error/catalog.zig`: `.wasm_trap` template gains the fields.
- `test/e2e/phase16_wasm_engine_select.sh` + fixture: `wasm/engine` round
  trip; a void arity-4 export trapping on the default with the diagnostic.
- `data/placement.yaml` (regenerated), `docs/examples/wasm/README.md` (the
  engine section states the crossing cost), CHANGELOG.
- `.dev/debt.yaml`: D-585 re-narrowed (diagnostic lands; barrier unchanged);
  `[ZWASM-PERCALL-TRACK]` carries the three asks.
- The `zwasm ADR-NNNN` citation sweep across `.dev/`, `bench/`, `docs/`,
  `src/`, `test/`.

## References

- ADR-0195 (runtime thread; Decision 3), ADR-0192 (the memory surface that
  surfaced D-585), zwasm ADR-0200 (`.auto` / `:engine`), zwasm ADR-0209
  (per-call latency bench).
- D-488 (the flip), D-585 (the miscompile), D-586 (zwasm/D-584 tracking),
  zwasm/D-584, zwasm/D-585 (upstream #208).
- `.dev/wasm_percall_findings.md`, `.dev/bench/ffi_boundary/README.md`.
- Cards: `[CLJW-WASM-ENGINE-DEFAULT]`, `[CLJW-WASM-EXPORTSIG-CACHE]`,
  `[CLJW-WASM-BENCH-BLIND]`, `[ZWASM-PERCALL-TRACK]`.
- `private/notes/adr-0196-da.md` (full Devil's-advocate report).
