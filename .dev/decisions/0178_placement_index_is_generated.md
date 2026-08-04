# ADR-0178 — The placement index is generated from the runtime, not maintained by hand

- **Status**: Proposed → **Accepted** (2026-08-04)
- **Amends**: ADR-0033 (Clojure-ns placement / naming / polymorphism) — the
  *migration schedule* is recorded complete; the *placement rule* (D2-D5) stands
  unchanged. ROADMAP §5 layout line + §15.x `status/vars.yaml` note per §17.
- **Related**: ADR-0174 D9 (`check_compat_members.sh`, the same fix applied to
  compat_tiers member lists), ADR-0163 (lazy namespace loading), ADR-0177
  (capability claims), D-062 (discharged 2026-05-27), D-094 (`clojure.string/escape`),
  F-002, F-003, F-009, F-013.

## Context

`data/placement.yaml` was introduced by ADR-0033 as the per-var record of the
Pattern A / B1 / B2 / C-thin placement decision for Clojure-namespace vars, and
`.claude/CLAUDE.md` listed it as an authoritative data source. Measured
2026-08-04 at HEAD `c601aa75`:

- It covered **49 vars**. `cljw` exposes ~683 publics in `clojure.core` alone,
  and 1,326 across all bundled namespaces. Coverage ~4 %.
- Its header cited three helper scripts. **Two never existed**
  (`check_placement_schema.sh`, `analyze_clojure_upstream.bb`,
  `gen_placement_yaml.bb` — only `check_placement_status.sh` was real).
- **No gate read it.** `test/run_all.sh` had no `run_step` for it.
- Two `leaf_loc` paths pointed at files that do not exist
  (`src/lang/primitive/core/core.zig`, `.../core/sequence.zig`).
- It was written in Japanese, against the CLAUDE.md language policy for
  configuration.
- Its content had not changed substantively since the 2026-05-25 scaffold.

And most importantly: **42 rows read `status: transient_zig` — "Zig for now,
`.clj` migration pending" — for vars whose migration had already shipped.**
D-062, the cluster row tracking that migration, was **discharged 2026-05-27**
with `clojure.string/escape` named as the sole residual (now D-094). The code
agrees with the discharge: `clojure/set.clj` carries 12 `(def …)` bodies,
`string.clj` 21, `walk.clj` 11. The plan executed; the ledger did not follow.

## Decision

**Generate the index; gate the generation; keep judgement out of it.**

1. **`(cljw.internal/__dump-placement)`** (new, `src/lang/primitive/core.zig`,
   alongside `__dump-host-classes`) emits one line per Var in every registered
   namespace's own `mappings`, deriving the implementation home from the root
   value's tag: `builtin_fn` → `zig`, `fn_val` / `multi_fn` → `clj`, otherwise
   `value`, and `unbound` for a rootless declare. Flags (`private`, `macro`,
   `dynamic`, `zig-leaf`, `unsupported`) ride along.

2. **`scripts/gen_placement.sh`** requires every bundled namespace first —
   namespaces load lazily (ADR-0163), so a bare dump sees only the eager set —
   then renders `data/placement.yaml`: a sorted, English, generated file with a
   do-not-hand-edit banner. Measured output: **1,326 vars across 31 namespaces
   — 394 `zig`, 725 `clj`, 201 `value`, 6 `unbound`.**

3. **`scripts/check_placement_status.sh` becomes the `placement_drift` gate**
   (wired into `test/run_all.sh`): regenerate, diff, fail on any difference. Its
   previous body — an audit that proposed `status:` flips for the ADR-0033
   migration schedule — is retired with the schedule.

4. **Intent stays out of the generated file.** "This var's current placement is
   not its intended one" is a judgement with a barrier, so it belongs in
   `.dev/debt.yaml`. Today that is exactly one row: D-094
   (`clojure.string/escape`). ADR-0033 D2-D5 remains the placement rule the
   index reports against.

### What is deliberately NOT decided here

**No forward policy about where future `clojure.core` vars should live.** The
draft that opened this cycle wanted to declare "Zig implementation is the
finished form for `clojure.core` hot paths". That is a structural decision over
an unbuilt residual, which F-003 reserves for the owning unit — and it is
redundant anyway: ADR-0033 D5 already says fast-path = Tag switch, slow-path =
`extend-protocol`.

## Alternatives considered

*(Devil's-advocate fork, fresh context, 2026-08-04. Reproduced as returned.)*

### Leading finding — the draft's crux premise is factually wrong (and no F-NNN blocks the clean option)

No finished-form-clean alternative here requires violating any F-NNN. But before
the alternatives: **two of the draft's load-bearing claims do not survive contact
with the files.**

**(a) The `ready_for_migration` shortlist is not a plan to move hot primitives
into `.clj`.** All six rows (`count`/`seq`/`first`/`rest`/`cons`/`empty`,
`data/placement.yaml:435-482`) carry `pattern: B1`, and **none has a
`target_loc`**. ADR-0033 D3 defines B1 as "Layer 2 `.zig` 直 intern (`.clj`
不在)" — i.e. **B1's finished form *is* Zig, with no `.clj` file at all**. The
`status: ready_for_migration` on those rows is a *status-vocabulary misuse*: the
inline comment on `count` reads `# = Phase 6.16.a-1 cycle で着地予定 (新規)` —
"scheduled to *land* in cycle 6.16.a-1", i.e. not-yet-implemented, not "awaiting
`.clj` migration". Per the schema's own enum those rows should read `stable`
("最終形 (Pattern B1 等で Zig が最終形)"). ADR-0033 D5 already states the
hot-path rule the draft thinks it is introducing: "fast-path = Tag switch 維持,
slow-path = extend-protocol". **So "retire the plan before it moves `count` into
`.clj` and costs perf" attacks a straw man, and "declare Zig implementation the
finished form for `clojure.core` hot paths" is a restatement of an
already-Accepted ADR clause, not a new decision.**

**(b) The plan is not unexecuted — it is executed with an un-updated ledger.**
`debt.yaml:3160` D-062 is **Discharged 2026-05-27**, and the discharge text
enumerates set 12 + walk 10 + string 12 B2 shims + GREEN trio + YELLOW pair +
`replace`/`replace-first` Pattern A, with **`clojure.string/escape` as the sole
residual** (tracked as D-094). Code confirms: `src/lang/clj/clojure/set.clj` has
12 `(def …)` bodies, `string.clj` 21, `walk.clj` 11 — real Pattern A composition
and real B2 one-line shims over private `-name` leaves. Yet all 12
`clojure.set` rows and 42 rows overall still read `status: transient_zig`. The
file is therefore **a stale mirror of a completed migration**, not a live plan
with 42 unexecuted items. That reframes the whole decision: what rotted is the
*maintenance mechanism*, not the *plan*.

Two further defects the draft did not catch, which strengthen the "it is broken"
case but point at repair rather than deletion:

- **Dangling `leaf_loc` pointers**: of four distinct `leaf_loc` paths,
  `src/lang/primitive/core/core.zig` and `src/lang/primitive/core/sequence.zig`
  **do not exist** (the tree has `src/lang/primitive/core.zig`). All three
  `target_loc` paths do exist.
- **The named future consumer is already stale**:
  `.dev/cw_v0_parity_and_gap_plan.md:143` (G11) says `cljw --list-vars` will read
  `compat_tiers.yaml` + `placement.yaml`. There is **no `--list-vars` in
  `src/app/`**; `src/runtime/introspect.zig` is the building block and it **walks
  `Env`/`Namespace`/`Var`**, not a yaml. So the consumer argument for keeping the
  file as-is is weaker than it reads — but it is also an argument that the
  *right* placement index is derived from `Env`, not hand-written.

And one fact that argues against plain deletion: **ROADMAP §15.x records
`.dev/status/vars.yaml` + `generate_vars_yaml.clj` as SUPERSEDED *by*
`placement.yaml`** ("Per-var tracking is covered by `placement.yaml` … The
originally-planned `status/vars.yaml` + generator were not built",
`.dev/ROADMAP.md:2049-2052`). Deleting `placement.yaml` without a successor
leaves per-var placement tracking with **no owner at all** — a hole the roadmap
explicitly closed once already.

### Alternative 1 — smallest-diff: truthify in place, gate it, and stop calling it an SSOT

Keep the file and ADR-0033 intact. In one cycle: (i) delete the three phantom
script citations from the header (`check_placement_schema.sh`,
`analyze_clojure_upstream.bb`, `gen_placement_yaml.bb` — replace with a note that
D9's generator route was never built); (ii) flip statuses to code truth (42
`transient_zig` → `migrated`/`stable` per D-062's discharge text; the six B1 rows
→ `stable`; keep `clojure.string/escape` as the one honest open row pointing at
D-094); (iii) fix the two dangling `leaf_loc` paths; (iv) wire
`scripts/check_placement_status.sh --check` as a `run_step` in
`test/run_all.sh` (it already has a `--check` mode, unused); (v) translate the
header to English per the language policy; (vi) rewrite the
`.claude/CLAUDE.md:591` and `.dev/README.md:37` wording from "SSOT /
authoritative" to "index of the ADR-0033 6.16-arc migration (49 vars), not a
complete `clojure.core` index"; (vii) fix the stale G11 sentence in
`cw_v0_parity_and_gap_plan.md`. **Sub-variant 1b**: since D-062 is discharged,
move the file to `.dev/archive/` as a *closed migration record* and drop the SSOT
claim entirely, keeping only D-094 live.

- **Better than the draft**: makes zero structural decision — no policy is
  declared about where future `clojure.core` vars live, so no F-003 exposure on
  the unbuilt residual. Preserves the Pattern A/B1/B2 vocabulary that ADR-0171
  (`:131` "placement.yaml Pattern B2 already interns private leaves directly into
  clojure.core"), ADR-0043 (`:128`), ADR-0102 (`:122`, which cites the
  compat_tiers/placement role split as *precedent* for its own design) and source
  comments (`src/lang/primitive/string.zig:269, 617`) all depend on. Fixes every
  defect the audit actually measured. Leaves `--list-vars`'s future free.
- **Breaks**: it re-instates a **hand-maintained parallel index**, which is
  precisely the mechanism that produced the rot — nothing derives status from
  code, so it will drift again the first cycle nobody remembers to update it (the
  exact failure the 2026-05-31 audit found for debt rows). And it does not answer
  F-013: an index that covers 49 of 683 publics is not 網羅 from the definition;
  it is the set of vars that happened to be in scope in the 6.16 arc. Wiring
  `--check` gates *schema validity only* (its `check_mode` merely validates the
  status enum) — it cannot catch a `transient_zig` row whose var is already
  `.clj`, which is the actual lie class here.
- **F-NNN**: no violation. Weak on F-013 (partial coverage retained as "index"),
  neutral on F-009 (ledger survives, still hand-fed).

### Alternative 2 — finished-form-clean (RECOMMENDED): stop maintaining placement, start *deriving* it, over all 683 publics

Replace the hand-written 49-row file with a **generated, total placement index
plus a drift gate**, and shrink the hand-written residue to only the
non-derivable field.

The observation that makes this clean: **placement is a property of the code, and
the code already knows it.** For every var in every `clojure.*` / `cljw.*` ns,
`Env` + the loaded `.clj` sources determine the pattern mechanically — B1 =
interned from Zig with no `.clj` `def`; B2 = a `.clj` `def` whose body is a
single call to a same-ns `^:private`/`-name` leaf; A = a `.clj` `def` composed of
other Clojure vars; C-thin = a `.clj` body with 1-2 branches over a leaf. That is
exactly the classification ADR-0033 D2's B-Q1→B-Q4 flowchart asks a human to
make, and it is decidable from the AST plus the leaf metadata `env.intern`
already carries (ADR-0033 D8: `zig_leaf`, `private`).

Concretely: extend `src/runtime/introspect.zig` (already documented as the
`--list-vars` building block) with a placement classifier; land `cljw
--list-vars --placement` as the CLI that `cw_v0_parity_and_gap_plan.md` G11 has
been promising; check in the emitted snapshot as `data/placement.yaml`
(regenerated, **all** publics, English, machine-owned with a "generated — do not
hand-edit" banner); add a `run_step` to `test/run_all.sh` that regenerates and
diffs, failing on drift. Keep a small hand-written companion section (or, better,
leave it entirely in `.dev/debt.yaml`) for the only genuinely non-derivable fact:
**"current placement is not the intended finished form"** — today exactly one
var, `clojure.string/escape` (D-094).

- **Better than the draft**: (1) It answers **F-013** as written —
  "definition-derived comprehensive coverage in canonical form, never an ad-hoc
  *just make this one pass*": 683/683 instead of 49/683, derived from the
  definition (the pattern rules) rather than from what one arc touched. The
  draft's own strongest datum (7.2% coverage) is an argument for *completing* the
  index, not for deleting it; deleting it is the "ad-hoc" move F-013 forbids in
  its own domain. (2) It preserves **F-009**'s only live ledger. F-009 is the
  invariant "impl bodies namespace-neutral, Clojure/Java/cljw surfaces thin
  above", and it explicitly anticipates this cycle: *"At Phase 12+ the AI loop is
  statistically very likely to propose 'inline impl into the surface for fewer
  files.' F-009 lets the Devil's-advocate subagent automatically reject these
  envelope-violating alternatives."* The placement index is the per-var evidence
  that the Clojure surface is thin; killing it removes the observability for a
  *confirmed, live* invariant while the invariant stands. (3) It kills the rot
  **mechanism** rather than the artifact — no human can make it lie again, which
  is the only durable fix (Discipline 1 of `clj_diff_sweep.md`: leave the probe
  behind, mechanically re-checkable). (4) It delivers G11 and closes the ROADMAP
  §15.x `status/vars.yaml` hole in the same move. (5) It matches the project's own
  established shape: ADR-0102 chose "dedicated SSOT + generated/checked Zig table
  + gate" over hand-extension, citing the compat_tiers/placement role split as the
  precedent — this alternative is that same design applied back to placement
  itself.
- **Breaks**: the classifier must handle real shapes — `(def x (fn* …))` rather
  than `defn` (which is what `set.clj`/`string.clj` actually use — note `grep
  '^(defn'` returns **zero** in all three files), multi-arity `fn*`, macros, the
  `rt` → `cljw.internal` rename from ADR-0171, and `def`-with-computed-value.
  Misclassification is possible and a wrong generated row is a *new* lie class
  (though a gated, diffable one). It costs 1-2 cycles plus a `run_all.sh` step.
  Most importantly it **changes what the artifact is**: a generated mirror can
  record *what is*, never *what should be* — so the aspirational half of ADR-0033
  (D7's cycle plan, `recall_trigger`) must be explicitly retired into debt rows,
  and ADR-0033 needs a Revision-history amendment saying so. That amendment is the
  honest version of the draft's "retire the plan": the *migration schedule* is
  done (D-062 discharged), the *placement rule* (D2-D5) stays law.
- **F-NNN**: violates none. Strengthens F-013 (網羅 from the definition), F-009
  (ledger complete and machine-true), F-011 (one mechanism, behavioural claim
  mechanically re-checkable), F-002 (finished form over the smaller repair).
  Larger diff than Alt 1 — **per F-002 that is explicitly not a reason to prefer
  Alt 1**.

### Alternative 3 — wildcard: delete the ledger by making the invariant executable

Delete `data/placement.yaml` *and* the tracking concept, and re-express the only
load-bearing thing it guarded — F-009's "surfaces are thin, cross-surface calls
forbidden" — as an **executable check for the Clojure-ns surface**, extending the
existing G1-G4 guardrail family (`zone_check.sh`, `check_surface_marker.sh`,
`check_feature_keyword.sh`, `check_host_interface.sh`). The check asserts: every
public Clojure-ns var either (a) resolves to a Zig leaf whose impl lives in a
namespace-neutral `runtime/` home, or (b) is composed solely of other Clojure
vars — and never reaches a `runtime/java/**` or `runtime/cljw/**` surface.
Pattern A/B1/B2 stop being *recorded* because they become
*unrepresentable-if-wrong*. Human-readable output moves to a generated
contribution map in `docs/` (the `--list-vars` surface), aimed at the
Issue-template audience opened in `e897cbfc`.

- **Better than the draft**: the draft deletes the ledger and leaves the invariant
  unobserved; this deletes the ledger *and* raises the invariant's enforcement
  from documentary to mechanical, which is strictly stronger than what exists
  today. Highest information-per-artifact of the three; nothing can rot because
  nothing is hand-written. Directly serves the contribution-surface concern with a
  generated artifact contributors can read.
- **Breaks**: (1) the "no cross-surface call" property is far harder to decide for
  Clojure-ns vars than for Zig imports — a `.clj` body calling another `.clj` var
  is legal and the graph is dynamic, so the check is not the simple import-graph
  test G1 runs; realistically it degenerates into the same AST classifier Alt 2
  needs, minus the artifact, i.e. the same cost with less output. (2) It
  **discards a shared vocabulary that four ADRs and live source comments depend
  on** (ADR-0171:131, ADR-0043:128, ADR-0102:122, `string.zig:269/617`,
  `data/feature_deps.yaml:17` "placement.yaml — Pattern A vs Pattern B
  classification per…"), forcing edits across all of them or leaving dangling
  terms — the audit's own complaint about dead references, reproduced. (3) It has
  nowhere to put per-var *intent* (`escape` is Zig-for-now-`.clj`-later) except
  debt rows, which is acceptable at n=1 today but re-opens the §15.x hole the
  moment n>5.
- **F-NNN**: no violation. Strengthens F-009's enforcement, weakens F-013's
  coverage-visibility (the index disappears), neutral on F-003 (declares no future
  policy).

### Direct answers to the five interrogations

**1. Is "kill it" decision-seizure?** *Split verdict.* F-015 narrowed F-003
explicitly: "F-003 … still holds for genuinely-unbuilt layout/representation
decisions, but it is NOT a licence to park built-but-unhardened behaviour behind
a Phase number" (`project_facts.md:1141-1143, 1168`). The
`clojure.set`/`string`/`walk` split is **built** (D-062 discharged), so F-003
does *not* shield the ledger from repair — F-015 says fix it now. But the draft's
second clause — *"declare Zig implementation the finished form for
`clojure.core` hot paths"* — is a forward policy over the **unbuilt residual**
(where do the next N `clojure.core` vars live?), and that is precisely a
responsibility/dependency-graph decision F-003 reserves for its owning unit,
which is not this audit-remediation cycle. Correct move: **repair or replace the
artifact (permitted); do not stamp the policy (seizure)**. Note also that for the
hot primitives the policy is redundant — ADR-0033 D5 already says fast-path = Tag
switch — so dropping the clause costs nothing.

**2. Is the shortlist wrong?** No — and the draft has the pattern backwards.
Those six rows are **B1**, whose ADR-0033 D3 finished form is Zig-with-no-`.clj`.
Nothing in the plan proposes moving `count`/`seq`/`first` into `.clj`.
Separately, on the general question: B2 is **not** free at runtime — a shim is a
real extra Var deref + fn invoke per call (`(def upper-case (fn* [s] (-upper-case
s)))`, `string.clj:41`) — which is exactly why ADR-0033 routes hot/multi-arity
vars to B1/C-zig ("multi-arity 複雑 / hot path") and reserves B2 for "Tier A
surface, JVM diff 維持". The classification rule already encodes the perf concern
the draft thinks it is defending. The rows are **mislabelled, not misplaced**;
the fix is a status flip to `stable`, not a retirement.

**3. What does F-009 say?** F-009 is `confirmed` and live, and placement.yaml is
its only per-var observability for the Clojure-ns row of F-009's own surface
table. F-009's rationale section pre-registers this exact cycle as a predicted
envelope violation ("At Phase 12+ the AI loop is statistically very likely to
propose 'inline impl into the surface'"). Killing the ledger does not violate
F-009 by itself — the invariant lives in the ADRs and guardrails — but it removes
the artifact that makes F-009 auditable per-var while offering no successor. Alt
2 and Alt 3 both supply a successor; the draft does not.

**4. What is the contribution-surface argument worth?** Less than the draft
implies, and it **cuts the other way**. The 1:14 ratio is not comparable to
upstream: the 124.7K Zig includes the VM, GC, JIT, wasm engine, and Java/cljw
host surfaces, which in the JVM implementation are Java (~tens of KLOC), not
`core.clj`; the honest comparison is cljw's `lang/` layer against `src/clj/`, not
the whole tree. More importantly, if outside contribution by Clojure programmers
is the goal, the response is *more* `.clj` surface and *better* visibility into
which vars are `.clj`-able — i.e. Alt 2's total index or Alt 3's generated
contribution map. Deleting the `.clj`-ability ledger three commits after opening
Issue templates (`e897cbfc`) is backwards. It should not drive this decision
regardless: contribution surface is a product/community question whose owner is
the release unit, and F-003's residual applies to it.

**5. Is there a third state?** Yes, three, and the draft considered none: **(a)
generated mirror** (Alt 2) — machine-owned, total, gated; **(b) demoted index**
(Alt 1) — keep it, strip "SSOT/authoritative" from `.claude/CLAUDE.md:591` and
`.dev/README.md:37`, state the 49-var scope honestly, gate it; **(c)
archive-as-closed-record** (Alt 1b) — D-062 is discharged, so move it to
`.dev/archive/` as the migration's historical record with the one live residual
(`escape`/D-094) promoted to debt. Any of the three is strictly better than
deletion, because deletion also silently re-opens the ROADMAP §15.x
per-var-tracking hole that `status/vars.yaml` was superseded *into*.

### Recommendation

**Adopt Alternative 2.** The measured facts justify *repairing the mechanism*,
not retiring the plan: the plan largely executed, the ledger did not follow, and
the fix that cannot rot is derivation plus a drift gate. It is the only option
that satisfies F-013 (683/683 from the definition rather than 49/683 from one
arc), keeps F-009 observable, closes G11 and the §15.x hole, and follows the
project's own ADR-0102 precedent of "dedicated SSOT + generated table + gate". It
is the largest diff of the three, and per **F-002** that is not a reason to prefer
Alternative 1.

If the loop nonetheless lands Alternative 1 for sequencing reasons, the two
clauses that must **not** ship in any variant are (i) the phrase "SSOT /
authoritative" over a 49-var file, and (ii) the forward policy "Zig is the
finished form for `clojure.core` hot paths" — the first is the measured lie, the
second is F-003 seizure of an unbuilt-residual decision and is already covered by
ADR-0033 D5 anyway.

## Resolution

**Alternative 2 is adopted**, and both forbidden clauses are excluded: the
"SSOT / authoritative" wording is gone from `.claude/CLAUDE.md` and
`.dev/README.md`, and no forward placement policy is stamped.

Every factual claim in the fork's leading finding was re-verified against the
tree before acting on it: the six rows are `pattern: B1` with no `target_loc`;
D-062 is discharged with `escape` as the residual; `set.clj`/`string.clj`/
`walk.clj` carry 12/21/11 `(def …)` bodies and zero `(defn`; both flagged
`leaf_loc` paths are absent.

**One deliberate narrowing of the fork's proposal.** It asked for the full
A / B1 / B2 / C-thin classification, decided by an AST classifier over the `.clj`
bodies. What shipped derives the **`zig` / `clj` / `value` / `unbound`** axis
from the Var's root tag instead. The reason is the fork's own "Breaks" note: an
AST classifier must handle `(def x (fn* …))`, multi-arity `fn*`, macros, and
`def`-with-computed-value, and a misclassified generated row is a new lie class.
The root-tag axis is decided by the runtime rather than inferred, so it cannot be
wrong — and it already answers the question the rotted rows were lying about
("is this var Zig or `.clj` today?"). The finer split is available on top
whenever a consumer needs it: `zig-leaf` already separates B1 from a B2 leaf, and
the flags ride in the same index. A classifier that guesses is worse than an
index that reports.

## Consequences

- The index went from 49 hand-written rows to **1,326 generated ones across 31
  namespaces**, and can no longer disagree with the code.
- **Measured, previously invisible**: 394 vars are Zig-implemented and **725 are
  Clojure-implemented**. The audit that opened this cycle had argued from the
  124.7K:8.8K *LOC* ratio that the Clojure surface was structurally thin. At the
  var level it is the majority. LOC was the wrong denominator, and nothing in the
  tree could have corrected it before this index existed.
- `clojure.spec.alpha` shows up with 123 `clj` vars + 17 values — it is bundled
  and working, which the same audit had wrongly recorded as unimplemented because
  `docs/works/ladder.md` and `COVERAGE.md` carry no row for it. **A working
  feature absent from the ledgers misleads exactly like a broken one.**
- ADR-0033's migration *schedule* is recorded complete; its placement *rule*
  (D2-D5) is untouched and still governs new vars.
- Cost: one more full-gate step, and the index must be regenerated in the same
  commit as any var that moves between Zig and `.clj`. The gate says so on
  failure.

## Affected files

- `src/lang/primitive/core.zig` — `__dump-placement`
- `scripts/gen_placement.sh` — new
- `scripts/check_placement_status.sh` — rewritten as the drift gate
- `test/run_all.sh` — `placement_drift` step
- `data/placement.yaml` — regenerated (was hand-written)
- `.claude/CLAUDE.md`, `.dev/README.md`, `.dev/ROADMAP.md` (§5 layout, §15.x),
  `.dev/cw_v0_parity_and_gap_plan.md` (G11)

## Revision history

- 2026-08-04: Status: Proposed → Accepted. Alternative 2 adopted, narrowed to
  the root-tag-derived axis per the fork's own misclassification warning.
