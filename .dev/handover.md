# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT). Per-commit = smoke locally;
  **CI runs ONE configuration everywhere** — PR, push and dispatch all run the
  identical `test/run_all.sh --serial-e2e` that `scripts/run_gate.sh` runs, so
  "green" means the same run wherever it is said. The nightly schedule and its
  tree_walk sweep are RETIRED (2026-08-12); `check_gate_parity.sh` fails if a
  tier comes back. Commit **and** push (atomic
  Step 6). `build.zig.zon` `.zwasm` = tag pin **v2.5.0**
  (`278587f6`, 2026-08-12, FINAL — full WASI 0.3 + the `libzwasm.a` C-API
  export fix; neither reaches cljw's Zig embedding surface. Tagging zwasm is
  user-only, its ADR-0156). Latest release:
  **v1.10.0** (2026-08-12) — upstream's final release, and this fork's
  starting point. CHANGELOG is the release-history SSOT.
- **This repository is a MAINTAINED FORK.** Upstream
  `clojurewasm/ClojureWasm` (chaploud) stopped at v1.10.0 and invited forks
  under EPL-2.0; `BuddhiLW/ClojureWasm` continues from that tree.
  `origin` = upstream (read-only, archived-in-practice), `buddhilw` = the
  maintained remote. What changed with the handover: Issues and PRs are OPEN
  here (upstream disabled both — the "branches to cherry-pick" workflow in
  CONTRIBUTING no longer applies), the homebrew tap is
  `BuddhiLW/homebrew-tap` (`brew install buddhilw/tap/cljw`), and the `1.x`
  line continues from v1.10.0. The PERF CAMPAIGN (D-450) stays **stopped**
  — findings remain in the row as a record.
- **First task on resume**: cut **v1.10.1** — a no-feature release whose only
  job is to prove the fork's release path end to end (tag → `release.yml`
  artifacts on this repo → tap formula bump → `brew install buddhilw/tap/cljw`).
- **Unreleased on main**: the fork-handover docs. CHANGELOG `[Unreleased]`
  is the SSOT.
- **Release-process hazards** (both live in `.github/workflows/release.yml`):
  cutting the GitHub release BY HAND before the tag workflow runs breaks the
  artifact upload (zwasm #160), and the workflow's `gh release view || gh
  release create` is TOCTOU across the two matrix legs — if they reach it
  within the same instant, the loser fails on "already exists" under
  `set -e`. v1.10.0 missed it by 47 s. Never hit, never fixed.
- **Forbidden**: bare `zig build test` without `-Dwasm`; bare `zig build` for a
  probe (use ReleaseSafe). The FULL gate runs `--serial-e2e`, ALONE; never a
  concurrent build during a gate. `.claude/**` edits + cross-repo publishes may
  hit the auto-mode block — surface to the user. **D-549 (Docker/ghcr/
  notarization) is user-LOCKED**, **D-560 trigger-gated** — neither
  self-selects. External-publish payloads need `test -s` + read-back guards.

## Current state (details = CHANGELOG + git log)

- **Issues and PRs are DISABLED and always were** (deliberate — the
  maintainer cannot service them); **Discussions is the one channel**, and
  outside contributors send branches to cherry-pick. CONTRIBUTING exempts
  them from the loop's own conventions, so a contributed commit is taken
  as-is with authorship preserved and any missing `Smell-audited:` line
  amended in. Debug tooling: `scripts/check_*.sh` headers are each their
  own SSOT — read the script, not a list here.
- **2026-08-12: the README declares ClojureWasm no longer maintained**
  (`1c8a9cbf`); the Sponsors badge, README footer line, and `.github/FUNDING.yml`
  are gone with it. Issues/PRs were always disabled — Discussions is the one
  channel. Wind-down context + the surveyed wording/transfer research:
  memory `clojurewasm-wind-down-plan`, `private/notes/2026-08-11-{sunset-wording,
  transfer-risk}-survey.md`.
- 2026-08-11/12: Discussions #12/#13/#14 (BuddhiLW) answered in code — three
  fix branches cherry-picked with authorship preserved, each one's CLASS then
  swept and fenced. #12 repr-misread → 3 more live bugs (multimethod isa? at 9
  defmethods, http client/server 9-entry headers, error_render context) +
  `check_repr_decode.sh`; #13/#14 entry-point divergence → `cljw repl`'s
  `[-cp][-A]` surface, `cljw build`'s missing top-level-`do` unroll,
  `check_entrypoint_surface.sh` + `test/e2e/entrypoint_eval_parity.sh` (a
  6-entry-point differential oracle). D-374's discharge was a listed-not-probed
  claim; corrected in place. Endgame row = D-576.

## Standing units (tracked in .dev/debt.yaml)

- **D-565** — external-contributor reproducibility sweep (Discussion #11).
  Items (1)-(6) DISCHARGED 2026-08-04; the ledger row carries what each was.
  Residual: (7) survey-workflow setup notes, (8) handover pointing at
  gitignored `private/notes/` recipes. Companion: zwasm D-526.

- **Perf campaign (§9.2.S) — PAUSED** (D-520 / D-386 / D-005/006). **D-513**
  item (1) `clojure.core.reducers` is the only remaining piece (repl + var :doc
  landed); it is IN PROGRESS — its "take up on a real consumer" deferral is the
  pattern the 2026-06-25 drain-order decision forbids.
- **D-548** — (a) DISCHARGED (ADR-0176); residual = (b) pmap wall-clock on the
  3-vCPU runner (timing envelope, still gated).

## North star (ACTIVE, distal)

cljw's differentiator = **Wasm interop (gap II) × VM-perf fusion→JIT (gap
III)**. zwasm JIT (ADR-0200) is the cljw default; remaining =
components-through-the-JIT (zwasm-side, D-500). Distal — needs a user nod.
NOTE ADR-0177: "edge execution" is an AIM owned by D-552, not a capability.

## Reading order (resume)

handover → `yq` the live `active:` list → ADR-0166 → ROADMAP §9.0. Memories:
`verify_against_releasesafe_binary` / `smoke_first_batch_full_gate` /
`external-publish-payload-guard`.
