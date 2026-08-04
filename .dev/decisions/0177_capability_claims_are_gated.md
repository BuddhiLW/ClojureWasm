# ADR-0177 — Capability claims carry a status marker, and the marker is gated

- **Status**: Proposed → **Accepted** (2026-08-04)
- **Supersedes**: nothing. Amends ROADMAP §1.1, §1.2, §1.3, §8.1, §8.3, §10.3
  per ROADMAP §17.
- **Related**: ADR-0172 (binary-size budget + `size_claims`), ADR-0135
  (component-as-namespace), D-552 (cljw-self-as-Wasm, research-first),
  F-002, F-003, F-010, F-015, zwasm lesson
  `2026-08-03-ungated-negative-doc-claim-rotted-into-a-lie`.

## Context

The 2026-08-04 cross-project audit measured the shipped artifact and compared
it against what the project says about itself. Two classes of claim had rotted,
and the boundary between rotted and correct was exact: **every document a gate
read was true, and every document no gate read was false.**

The numeric half was fixed in `77f690a3` (the `size_claims` gate now reads
`README.md`, `docs/landscape.md`, and `bench/RELEASE_METRICS.md`, and each
`<N> MB` figure either matches the built binary within 10 % or carries an
explicit `<!--size:other-->` exemption). This ADR is the capability half.

What was measured, at HEAD `e897cbfc`:

- `build.zig` contains no `wasm32`, `wasi`, or `freestanding` target. The
  `-Dwasm` flag *embeds zwasm* — it is about consuming Wasm, and is easy to
  misread as producing it.
- `cljw build` (`src/app/builder.zig`) emits a native binary with an embedded
  bytecode payload (Deno-style trailer), not a `.wasm`.
- Against that, the ROADMAP asserted, in the present tense:
  - §1.1 — "**Edge execution**: runs on Cloudflare Workers / Fastly / Fermyon
    Spin and other Wasm Component Model hosts".
  - §1.2 axis 1 — "v2 makes Wasm Component a first-class output".
  - §1.3 — users "who want to call a Clojure runtime as a component".
  - §8.1 — "**Two artifacts from one source tree**", artifact 2 being
    `cljw.wasm`.
  - §8.3 — a Phase-14 row reading "Component build begins".
  - §10.3 — a "Wasm cold start < 50 ms" performance target for that artifact.
- Two further stale figures: "measured 9.5 MB at v1.3.1" appeared **twice**
  (§1.1 and §10.3) while the enforced ceiling is 8,800,000 bytes and the built
  binary is 7,368,808; and §1.1's "shrink code volume to 30–40 % of v1 (89K
  LOC)" against a measured 124,712 LOC of Zig (~119 % of v1 even after
  excluding the 18,534 generated Unicode lines).

The failure is not that someone wrote something false. It is that the ROADMAP
is the project's **single source of truth** (CLAUDE.md § References) and no
mechanism connected any sentence in it to the code.

## Decision

**Retire the claim; keep the goal.** Three parts.

### 1. A status marker on capability claims

Two inline markers, mirroring `SIZE_EXEMPT_MARKER` exactly so the convention is
one idea rather than two:

- `<!--claim:shipped-->` — this exists and is exercised by a test.
- `<!--claim:planned:D-NNN-->` — this does not exist; `D-NNN` owns it.

### 2. `scripts/check_capability_claims.sh`, wired into the full gate

Two fail-closed invariants:

1. Every `claim:planned:D-NNN` names a debt row that **exists and is still
   open**. A planned claim whose owner has been discharged is a claim with
   nobody left to build it — which is precisely how "planned" becomes
   "abandoned, still advertised".
2. A curated list of phrases that were found asserting unbuilt capabilities
   may not appear **unmarked** in a claim-bearing document.

It is deliberately **not** a general prose checker. A heuristic
"is this sentence a capability claim?" scanner over a 1,600-line ROADMAP would
false-positive constantly and be disabled, which is worse than no gate. The
curated list grows when an audit finds a new rotted phrase — the list is a
record of actual failures, not a guess at future ones.

### 3. The ROADMAP amendments

§1.1, §1.2 axis 1, §1.3, §8.1, §8.3 and §10.3 now state the shipped capability
(load a Wasm core module or component in-process and call it like a namespace)
and mark cljw-as-a-Wasm-guest as an **aim with an owner** (D-552), not a
capability. §10.3's "Wasm cold start" row is removed — it targeted an artifact
that does not exist, and returns with D-552. The LOC target is retired in
favour of the property it proxied (§1.2 axis 3, readable end-to-end); the
binary-size row is marked superseded by ADR-0172's live ledger. `.dev/ROADMAP.md`
joins `SIZE_CLAIM_FILES`, so its numeric figures are gated like README's.

**This ADR changes no scope.** F-010 (2026-05-29, user-directed) already
de-prioritised widening the Wasm FFI surface, and D-552 (2026-07-02,
user-directed) already made cljw-self-as-Wasm research-first with
implementation user-nod-gated. The sequencing was the user's; this is
documentation catching up to it.

## Alternatives considered

*(Devil's-advocate fork, fresh context, 2026-08-04. Reproduced as returned.)*

### Leading finding — no F-NNN blocks this amendment, but one framing does

No alternative below violates an F-NNN, and neither does the draft. F-001
(embed zwasm) and F-016 (component model always on as a *consumer*) both
concern cljw **consuming** Wasm; neither asserts anything about cljw **being**
Wasm. F-010 explicitly de-prioritises wasm-FFI breadth. So the edge claim is
not F-protected.

The one framing that *would* trip a constraint is **deciding** the question.
F-003 reserves structural decisions for the owning unit, and D-552 names
exactly the structural content at issue ("efficient memory management under
Wasm, the GC/allocator story in linear memory, sandbox-first assumptions"). An
amendment that reads as *"cljw will not run as a Wasm guest / that is
ClojureWit's job"* is decision-seizure on an unbuilt structural plan and
brushes F-003; an amendment that retires the false **present-tense claim**
while preserving the **aim** does not. The distinction is load-bearing and
should appear in the Decision text, not just be implied: **retire the claim,
keep the goal.** Corollary: the §1.1 opening sentence ("with first-class edge
and Wasm support") is the project's identity statement and is user-owned
territory — leave it (the Wasm half is true in the interop sense that ships).

Two evidence corrections to the draft's Context before it is stamped:

- **The Cloudflare size argument is weak and should be dropped or softened.**
  3 MB gzipped vs "the shipped native binary is 7,368,808 bytes" compares two
  different artifacts. A hypothetical `wasm32-wasi` cljw would not carry the
  native-codegen paths or (necessarily) the embedded JIT engine, and would be
  gzipped. Citing it as justification over-claims and hands a future reader a
  refuted premise.
- **The LOC figure needs its denominator stated.** 124,712 total Zig; minus
  the 18,534 generated Unicode lines that is ~106K = ~119 % of v1's 89K. The
  target fails on either denominator, so the conclusion holds — but restating a
  *new* number in an ungated doc simply re-arms the same rot. Prefer retiring
  the numeric LOC target in favour of the property it proxies (readable
  end-to-end, §1.2 axis 3), or gating it.

### The four interrogated questions, answered

**Is retiring right, or is "keep the goal, mark it planned" the honest fix?**
Both, in different registers. F-003 protects deferral of *decisions*; it says
nothing in favour of keeping a false *assertion of fact* in the present tense.
"Runs on Cloudflare Workers / Fastly / Fermyon Spin" is not a plan, it is a
claim, and `build.zig` has no `wasm32` target (`b.standardTargetOptions` + a
`-Dwasm` flag that *embeds zwasm*, line 79 — the flag is about consuming Wasm,
and is easy to misread as producing it). But F-015 equally rules out the lazy
repair: parking it as "PLANNED, Phase N" with no owner is precisely the
blind-Phase-deferral posture F-015 retires. The correct shape is *aim + named
owner*: unbuilt, tracked as D-552, user-nod-gated.

**Does F-010 make this documentation catch-up rather than a scope change?**
Yes, and the ADR should say so in one sentence. F-010 § What this changes for
the loop ¶1: "wasm FFI breadth is de-prioritised, NOT cancelled… the loop must
not widen wasm FFI surface… before M + a quality-loop pass, unless the user
re-directs." D-552 (2026-07-02, user-directed) then made cljw-self-as-Wasm
research-first and implementation user-nod-gated. The sequencing was therefore
decided by the user in 2026-05-29 and 2026-07-02; this ADR changes no scope and
should disclaim doing so. Framing it as a scope decision would overstate the
loop's authority over a user-owned mission line — the F-003 hazard above.

**Is the north star being destroyed?** No — and the draft's scope proves it by
accident. §1.2 names **axis 2** (component-as-namespace) as "the north star",
and §9.18 records it **BUILT** (`cljw.wasm/*` over
`src/runtime/cljw/wasm/{engine,component,marshal,surface}.zig`, four real e2e
steps). The unbuilt thing is **axis 1**, and axis 1's cell still reads "v2
makes Wasm Component a first-class output" — the *same false claim* as §8.1, in
the differentiation table, untouched by the draft. That is the single strongest
objection to the draft as scoped: it would land §8.1 marked NOT IMPLEMENTED
while §1.2 row 1 continues to assert the artifact exists.

**Convention over three sentences?** Yes, with one-commit-old precedent.
`77f690a3`'s own message: *"Fixing the three claims without widening the gate
would have re-created the condition, so the gate moved with them."* The draft
as scoped does the thing that commit refused to do. Concretely:
`.dev/ROADMAP.md` is **not** in `SIZE_CLAIM_FILES` (`README.md
docs/landscape.md bench/RELEASE_METRICS.md`), and the stale "9.5 MB at v1.3.1"
appears **twice** — line 74 and line 1586. Hand-fixing §1.1 leaves 1586
rotting, re-creating the failure inside one document.

### Alternative A — smallest-diff: status-token the claims in place, change nothing else

Keep §1.1's bullet and §8.1's artifact 2 verbatim, prefixed with `PLANNED
(unbuilt — D-552)`; correct the three figures; touch nothing else.

*Better than the draft*: zero movement on mission scope, so the F-003 surface
is nil; smallest re-activation cost if the user later nods D-552; no new
machinery to maintain.
*Breaks*: nothing checks the token, so this is the ungated-claim pattern again;
a "PLANNED" with no owner is the F-015-retired posture unless D-552 is named;
and it leaves the identical claim standing in §1.2 axis 1, §1.3 bullet 2
("Wasm-ecosystem users who want to call a Clojure runtime as a component"),
§8.3 rows *WASI 0.2 → "Component build begins"* and *WasmGC*, §9 tracker line
1014, and §10.3's "Wasm cold start < 50 ms" target for a nonexistent artifact.

### Alternative B — finished-form-clean (recommended, F-002): one sweep plus a claim gate

(i) Sweep **every** site carrying the claim, not three: §1.1 bullet 2, §1.2
axis 1 cell, §1.3 bullet 2, §3's in-scope "Wasm Component pod loading", §8.1
artifact 2, §8.3's Phase-14 "Component build begins" row, §9 tracker line 1014,
§10.3's "Wasm cold start" row. (ii) Add `.dev/ROADMAP.md` to
`SIZE_CLAIM_FILES` so lines 74 and 1586 are gated like README's, with
`<!--size:other-->` on the deliberate historical rows. (iii) Introduce an
inline `<!--claim:shipped-->` / `<!--claim:planned:D-NNN-->` marker plus
`scripts/check_capability_claims.sh`, wired as a `run_all.sh` step — mirroring
`SIZE_EXEMPT_MARKER` exactly, so the exemption is greppable and never silent.

*Better*: closes the class rather than the instance (F-002); makes the ROADMAP
agree with `docs/landscape.md`, which received precisely this treatment 24
hours earlier and currently **contradicts** the ROADMAP; satisfies F-015 by
giving every unbuilt item a debt owner instead of a phase number; and the
numeric rot cannot recur.
*Breaks*: substantially larger diff (new script, new gate step, marker sweep,
likely README/docs follow-on) — recommended anyway per F-002, cycle budget is
not a project constraint. The present-tense-capability grep is heuristic and
will need scoping (restrict to §1/§8/§9-tracker/§10 lines carrying a bolded
capability name) or it will false-positive across a 1600-line document. Every
future capability line then needs a marker — a real maintenance tax, and the
honest counter-argument to (iii).

### Alternative C — wildcard: the ROADMAP stops carrying capability status at all

Generate a `docs/CAPABILITIES.md` from sources that already exist and are
already gated — `data/compat_tiers.yaml`, `data/feature_deps.yaml`,
`.dev/debt.yaml`, the `test/e2e/phase16_wasm_*.sh` step list, and `build.zig`'s
flags. §1/§8 retain only aims and rationale (which cannot rot, being
non-factual) and link out for status.

*Better*: rot becomes structurally impossible rather than merely gated — the
doc cannot disagree with the code because it is derived from it; permanently
kills the "N documents disagreeing with the binary" class that the 2026-08-04
audit found; and it feeds the already-planned `cljw --list-vars` capability
introspection from one source.
*Breaks*: it must first define "shipped", and §9.18 shows that is genuinely
subtle — `-Dwasm` is "gated `-Dwasm` opt-in **by design** (lazy dep), NOT
unimplemented", which no mechanical rule infers. A generator is itself code
that can lie. Restructuring the ROADMAP's authority over §1/§8 is a structural
plan whose owner is not this cycle (F-003). And it risks over-rotation: a
ROADMAP is a *plan*, and plans legitimately state intentions; mechanising
status pressures the document toward only-what-exists, which is how a north
star quietly disappears.

**Recommendation (non-binding): Alternative B**, with the leading finding's
"retire the claim, keep the goal" wording, the two evidence corrections, and an
explicit "no scope change — F-010 and D-552 already sequenced this" sentence in
the Decision.

## Resolution

**Alternative B is adopted**, with all three of the fork's qualifications:

- The wording is "retire the claim, keep the goal". §1.1's opening identity
  sentence is left alone as user-owned territory.
- The Cloudflare size argument is **dropped** from the reasoning. It compared
  two different artifacts and would have handed a future reader a refuted
  premise.
- The LOC target is **retired** rather than restated with a corrected number,
  because a corrected number in an ungated sentence re-arms the same rot. The
  measured figure is quoted once, here, where it is dated and attributed.

The fork's own counter-argument to (iii) — that every future capability line
now needs a marker — is accepted as a real cost and answered by scope: the gate
checks a *curated* phrase list plus marker integrity, not every sentence. A
line only needs a marker if it uses a phrase an audit has already caught being
false.

## Consequences

- The ROADMAP now distinguishes, mechanically, what cljw does from what it
  intends. A reader can trust §1 and §8 again.
- A discharged debt row can no longer silently orphan a "planned" claim.
- Cost: two gate steps instead of one, and a curated list that must grow when a
  new class of false claim is found. That growth is a record of real failures.
- `docs/landscape.md` and the ROADMAP now agree with each other and with the
  binary. Before this ADR they disagreed with both.
- The v0.1.0-era `10.3` targets table is now partly historical; a future perf
  campaign should re-cut it against measured v1.x figures rather than patch it.

## Affected files

- `.dev/ROADMAP.md` — §1.1, §1.2 axis 1, §1.3, §8.1, §8.3, §10.3
- `scripts/check_capability_claims.sh` — new
- `scripts/binary_size_report.sh` — `.dev/ROADMAP.md` added to `SIZE_CLAIM_FILES`
- `test/run_all.sh` — `capability_claims` step
- `docs/landscape.md`, `bench/RELEASE_METRICS.md`, `README.md` — landed in `77f690a3`

## Revision history

- 2026-08-04: Status: Proposed → Accepted. Alternative B adopted with the
  Devil's-advocate fork's three qualifications (retire-the-claim-keep-the-goal
  wording, Cloudflare size argument dropped, LOC target retired rather than
  restated).
