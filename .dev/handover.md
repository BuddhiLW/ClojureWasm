# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT). Per-commit = smoke locally;
  **push-to-main CI now runs the FULL gate** (ADR-0107 rev 2026-07-21 —
  == the local full gate, all e2e), so a red push CI is the immediate
  e2e signal, not a next-day nightly. Commit **and** push (atomic
  Step 6). `build.zig.zon` `.zwasm` = COMMIT pin
  `1ecc7a8a` (zwasm main; carries #157 component export index space + #158/#159
  the WASI capture cap — both load-bearing for cljw, unlike the v2.4.0 tag it
  replaced. Tagging zwasm is user-only, its ADR-0156). Latest release:
  **v1.9.0** (2026-08-05; the eval budget bounds blocking calls and follows
  spawned work, data errors are catchable, regex gains named groups /
  lookbehind / `\A\z\Z` / class algebra, multidim aget/aset, and the GC
  stops taxing long-running programs 2-4x — D-571/573/446/447 discharged).
  CHANGELOG is the release-history SSOT.
- **First task on resume**: the wind-down is DONE except the announcement —
  post it in Discussions (Announcements, pinned) when the user decides to.
  **v1.10.0 is released and is the final release** (2026-08-12): zwasm pin
  v2.5.0, full gate 435/435, 3-OS CI green, artifacts verified by download +
  checksum + running the macOS binary, homebrew tap bumped, cw-playground
  and cw-serverless-demo redeployed on it (both live), cw-arcade re-verified
  (32 tests / 153 assertions green; it pins nothing by design). The PERF
  CAMPAIGN (D-450) is **stopped, not paused** — findings stay in the row as
  a record.
- **Unreleased on main**: nothing. CHANGELOG `[1.10.0]` is the SSOT.
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
