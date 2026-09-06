# clj differential sweep (F-011 quality mode)

Auto-loaded when editing `src/lang/clj/**` or the sweep harness. Codifies
how the post-M quality loop checks `cljw` against the `clj` oracle, and the
two disciplines that keep that work honest.

## The harness — don't hand-roll the loop

`scripts/clj_diff_sweep.clj` is the SSOT for "run these exprs through both
runtimes and show me the diffs". Do NOT write ad-hoc
`for e in …; cljw vs clj` loops — they are unreviewable, throw away
the result, and repeatedly re-derive the same methodology.

```sh
bb scripts/clj_diff_sweep.clj exprs.txt              # one bare value-expr per line
printf '%s\n' '(map inc [1])' | bb scripts/clj_diff_sweep.clj -
bb scripts/clj_diff_sweep.clj exprs.txt --corpus seqfns   # append OKs to a corpus
```

Methodology baked into the Clojure harness: persistent clj and cljw nREPL
servers receive one bounded request per expression; process ownership and
cleanup stay in one babashka boundary. Bound every seq producer with
`(take N …)`.

## Discipline 1 — corpus-backed discharge (anti D-177)

A debt row whose discharge text **lists functions/behaviours as "landed"**
MUST add those exact expressions to a corpus under
`test/diff/clj_corpus/<area>.txt` (via `--corpus`), so the claim is
mechanically re-checkable. The 2026-06-02 audit found **D-177 discharged
with `take-while`/`take-nth`/`partition-by` listed as done when they were
not** — a false-positive-discharge lie. The fix for that lie class is:
*never list coverage you did not probe*, and leave the probe behind as a
corpus line. `scripts/corpus_regression.clj` re-runs every corpus and
fails on any DIFF, so a regression (or an over-claim) surfaces.

## Discipline 2 — big-bang, don't drip-feed

Coverage sweeps are done **exhaustively-then-closed**, not one function per
cycle forever (the Micro-coverage-grind smell). The drip-feed mode quietly
displaces the project's real differentiator (Phase 15-20 Wasm/edge-native)
and never converges. When opening a sweep area, enumerate the *whole*
surface (e.g. all of `clojure.string`, all transducer arities, all the
numeric tower), drive it to zero DIFFs in one focused push, write the
corpus, and close the area. A half-swept area is worse than an unswept one
because the debt ledger reads "covered".

## When a DIFF is NOT a bug

> **SSOT for accepted divergences = [`.dev/accepted_divergences.yaml`](../../.dev/accepted_divergences.yaml)**
> (AD-001…AD-007), with the full classification discipline in
> [`accepted_divergences.md`](accepted_divergences.md). A DIFF is classified
> bug→fix OR accepted→AD-NNN (never left floating). The quick reminders:

- **Set / non-sorted-map print order** differs from clj's hash order — not
  a bug (AD-001; don't "fix" `#{2 3}` vs `#{3 2}`).
- **`()` vs `nil` for an empty realized seq** is the tracked **D-164** —
  this is a **bug scheduled for fix** in the clj-parity campaign (ROADMAP
  §9.2.P), NOT an accepted divergence. A single big-bang fix, uniform across
  every seq fn.
- **F-NNN-intentional divergences** (`+`/`*` overflow auto-promote per
  F-005; `(class …)` simple name per ADR-0059 = AD-003; error Kind = AD-007)
  — check `project_facts.md` + the AD ledger before treating a DIFF as a gap.

## Related

- memory `clj_diff_sweep_methodology` — the original hand-method notes.
- `.claude/rules/orphan_prevention.md` — the `timeout` / bounded-seq rules
  the harness obeys.
- `.dev/debt.yaml` D-164 (empty-seq `()` vs nil overhaul) — the standing
  big-bang target this rule's Discipline 2 points at. (D-047 setString was
  discharged 2026-06-02 via the `big_int.parseBase10` consolidated fix.)
