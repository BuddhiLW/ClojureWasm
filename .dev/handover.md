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
  **v1.8.0** (2026-08-04; multi-export components load, `wasm/run` gains
  output + wall-clock bounds, `clojure.core.reducers` lands, and `(doc reduce)`
  finally prints something). CHANGELOG is the release-history SSOT.
- **First task on resume**: the remaining distribution repos —
  `cw-playground`, `cw-serverless-demo`, `cw-arcade`. The homebrew tap is DONE
  (cljw 1.8.0 + zwasm 2.4.1, `brew audit` clean after dropping the redundant
  explicit `version` — Homebrew scans it from the release URL).
  Release-process note worth keeping: **cutting the GitHub release by hand
  before the tag workflow runs breaks the artifact upload**. zwasm's workflow
  did an unconditional `gh release create`, which failed on "already exists"
  and took the upload down with it, so v2.4.1 had notes and no binaries until
  the release was deleted and the workflow re-run. Fixed to `view || create`
  then `upload --clobber` (zwasm #160), matching what cljw's has always done.
  NOTE on history hygiene: commit `673b082b`'s message describes only the
  gate-parity fix, but its diff ALSO carries the zwasm tag re-pin, `wasm/run`'s
  `:timeout-ms` axis and D-570's discharge — they were in the tree when the
  gate went green and rode along. Not amended (already pushed); the v1.8.0
  CHANGELOG was written from the diff rather than that message.
- **Unreleased on main**: nothing. v1.8.0 (2026-08-04) carried the whole
  audit-drain day; CHANGELOG is the SSOT for what it contained.
- **Forbidden**: bare `zig build test` without `-Dwasm`; bare `zig build` for a
  probe (use ReleaseSafe). The FULL gate runs `--serial-e2e`, ALONE; never a
  concurrent build during a gate. `.claude/**` edits + cross-repo publishes may
  hit the auto-mode block — surface to the user. **D-549 (Docker/ghcr/
  notarization) is user-LOCKED**, **D-560 trigger-gated** — neither
  self-selects. External-publish payloads need `test -s` + read-back guards.

## Current state (details = CHANGELOG + git log)

- **Issues and PRs are OPEN**; CONTRIBUTING exempts outside contributors from
  the loop's own conventions. Debug tooling: `scripts/check_*.sh` headers are
  each their own SSOT — read the script, not a list here.

## Stopped — user requested (2026-08-04, end of the audit-drain day)

The loop ran to a clean boundary and stopped on an explicit instruction: full
gate green, nothing half-landed, cron removed. Per-task note with the
alt-hypothesis / next-experiment / blocker triad:
`private/notes/2026-08-04-audit-drain.md`.

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
