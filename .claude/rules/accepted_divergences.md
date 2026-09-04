---
paths:
  - "src/**/*.zig"
  - "src/lang/clj/**"
  - "scripts/clj_diff_sweep.clj"
  - "scripts/corpus_regression.clj"
  - "scripts/check_accepted_divergences.sh"
  - ".dev/accepted_divergences.yaml"
  - "test/diff/clj_corpus/**"
---

# Accepted divergences (the "NOT a bug" discipline)

Auto-loaded when editing runtime source, the clj-diff harness, or the
divergence ledger. Codifies how a behavioural difference between cljw and
JVM Clojure is **classified** — so the small mismatches a user can hit are
either fixed or recorded-as-intentional, never silently left to erode
trust.

## The two-way classification (every clj DIFF is one or the other)

When a `clj_diff_sweep` / `check_corpus_regression` run shows cljw differing
from `clj`, the difference is exactly one of:

1. **A bug** → fix it (F-011 behavioural equivalence). Land the fix + a
   corpus/e2e case asserting the clj-matching behaviour. This is the
   default disposition.
2. **An accepted divergence** → record it in
   [`.dev/accepted_divergences.yaml`](../../.dev/accepted_divergences.yaml)
   as a new `AD-NNN` with a **`derives_from`** invariant (F-NNN / ADR) and a
   **`pin`** test that locks cljw's divergent behaviour. Then it is no longer
   a DIFF to chase.

**A DIFF is never left unclassified.** "I'll look at it later" on a clj
divergence is the Defer-to-amnesia smell (`.dev/principle.md`): either it is
a bug (open a debt row + fix) or it is accepted (add the AD-NNN). Leaving it
as floating sweep noise is what erodes trust — the same divergence resurfaces
every sweep and no one knows if it is intended.

## When a DIFF is an accepted divergence

The bar for "accepted" is a **project invariant**, not convenience:

- **F-NNN-mandated** — e.g. ADR-0059 no-JVM (`(class 5)`→`Long`, error Kind
  vs JVM exception class), F-005 numeric tower (single f64, no f32).
- **Semantically irrelevant** — set / non-sorted-map print ORDER (the values
  are `=`; order is not part of unordered-collection semantics).
- **Non-reproducible on the clj side** — opaque-ref `#object[… 0xADDR …]`
  embeds an identity hash cljw cannot and should not mirror.
- **Rare-edge grammar** explicitly out of scope (e.g. hex-float in
  `Double/parseDouble`) — flagged for promotion-to-bug if real code hits it.

If you cannot name the invariant, it is **not** accepted — it is a bug (or a
debt row pending a decision). `scripts/check_accepted_divergences.sh`
enforces the `derives_from` field for exactly this reason.

## Auto-defense (what the gate guarantees)

`scripts/check_accepted_divergences.sh --gate` (in `test/run_all.sh`)
guarantees the ledger stays a trust contract:

1. The SSOT is well-formed and non-empty.
2. Every `AD-NNN` cites a non-empty `derives_from` — no lazy accept.
3. Every `pin` test path exists — the divergent cljw behaviour is **locked**.
   If a future change accidentally makes cljw match clj (or diverge
   differently), the pin test fails → a conscious decision is forced, not a
   silent flip.
4. `COVERAGE.md`'s "Acceptable divergences" section points at the SSOT, so
   the human-facing doc cannot drift from the machine-readable ledger.

## Promotion / demotion is explicit (both directions)

- **Accept a divergence** (bug → AD): add the `AD-NNN` with `derives_from` +
  `pin`. Remove any debt row that tracked it as a gap.
- **Un-accept** (AD → bug): the project decides the divergence should after
  all match clj. Remove the `AD-NNN`, open a debt row, add a corpus/e2e case
  asserting the clj-matching behaviour. The pin flips from "lock the
  divergence" to "assert parity".

Neither direction is silent. The SSOT diff + the commit message record the
decision.

## Relationship to the user-facing capability ledger

`docs/works/` (F-010) is where the user-readable "this is how cljw behaves"
narrative lives. Accepted divergences worth surfacing to users (notably the
high-frequency AD-001 set print order and AD-003 simple class name) should
get a line there too, so the divergence reads as "designed" rather than
"broken" when someone first hits it.

## Cross-references

- [`.dev/accepted_divergences.yaml`](../../.dev/accepted_divergences.yaml) —
  the SSOT.
- [`scripts/check_accepted_divergences.sh`](../../scripts/check_accepted_divergences.sh)
  — the gate.
- [`clj_diff_sweep.md`](clj_diff_sweep.md) § "When a DIFF is NOT a bug" — the
  in-harness reminder; this rule is the full discipline it points to.
- [`.dev/principle.md`](../../.dev/principle.md) — Defer-to-amnesia smell
  (an unclassified DIFF) + Silent-default-shift smell (an un-recorded flip).
- F-011 (behavioural equivalence) / ADR-0059 (no-JVM) — the invariants most
  accepted divergences derive from.
