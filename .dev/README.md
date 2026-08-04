# .dev/

Project-level design and operational metadata. Tracked in git. English.

## Always present (load-bearing)

- [`ROADMAP.md`](./ROADMAP.md) — **the** authoritative mission, principles,
  architecture, phase plan, success criteria, and quality-gate timeline.
  Single source of truth. If anything elsewhere disagrees with this file,
  this file wins.
- [`handover.md`](./handover.md) — short, mutable, current session state.
  Read at session start, updated at session end. **Framing discipline
  enforced** via [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md)
  (≤ 100 lines, no log accumulation, no forecast tables, no stop-
  rationalisation phrases).
- [`cw_v0_parity_and_gap_plan.md`](./cw_v0_parity_and_gap_plan.md) — the
  2026-05-29 cw-v0-vs-cw-v1 parity snapshot + the plan for incorporating
  v0's gaps into cw v1 (redesigned, not copied; per-gap ordering +
  ROADMAP-amendment hooks). CLOSED 2026-07-02 (banner in the file; the
  phase model is retired, ADR-0142). Historical reference only.
- [`orbstack_setup.md`](./orbstack_setup.md) — **retired** OrbStack x86_64
  gate setup (ADR-0049; kept for history). The live Linux gate is
  [`ubuntunote_setup.md`](./ubuntunote_setup.md) + `scripts/run_remote_ubuntu.sh`.
- [`decisions/`](./decisions/) — Architectural Decision Records.
  - `README.md` — convention.
  - `0000_template.md` — copy this when adding a new ADR.
  - `NNNN_<slug>.md` — accumulated decisions.

## Created on demand (do NOT pre-create as empty stubs)

Empty files rot. Create them when they have real content, using the
templates in **ROADMAP §15.2**:

- `debt.yaml` — row-level debt ledger (ADR-0072; replaced the planned
  `known_issues.md`). The live SSOT for technical debt.
- `data/compat_tiers.yaml` — per-namespace/class Clojure tier table.
- `data/placement.yaml` — GENERATED per-var placement index (ADR-0178; supersedes
  the planned `status/vars.yaml` tracking, which was never built). Regenerate with
  `scripts/gen_placement.sh`; the `placement_drift` gate keeps it honest.
