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
  **v1.7.0** (2026-08-04; the component marshaller could kill the host on
  guest data — bare `@intCast` = a ReleaseSafe panic; `result` lifts as
  `[:ok v]`/`[:err e]` per ADR-0135 am2, replacing a throw that DISCARDED the
  err payload; `*file*` lands). v1.6.0 earlier the same day carried four
  hang/abort fixes. CHANGELOG is the release-history SSOT.
- **First task on resume**: **release v1.8.0** + the four distribution repos.
  Nothing blocks it: zwasm v2.4.1 is cut (user-granted) and `.zwasm` is pinned
  to that tag. 26 commits since v1.7.0, all green, nothing half-landed.
  NOTE on history hygiene: commit `673b082b`'s message describes only the
  gate-parity fix, but its diff ALSO carries the zwasm tag re-pin, `wasm/run`'s
  `:timeout-ms` axis and D-570's discharge — they were in the tree when the
  gate went green and rode along. Not amended (already pushed); recorded here
  so the CHANGELOG for v1.8.0 is written from the diff, not from that message.
- **Unreleased on main** (21 commits since v1.7.0, 2026-08-04 audit-drain day —
  CHANGELOG entry is owed by the next release):
  **Gate**: the local full gate now runs `--serial-e2e`, the configuration CI
  runs — it did not, and a serial-only EPIPE death in an e2e was therefore
  invisible locally while failing every push (`gate_parity` + `epipe_head`
  assert both halves).
  **Wasm/component**: `wasm/run` gains `:timeout-ms` (D-570 — fuel is a ~760x
  proxy for time, so the 1e9 default permitted ~18 h); multi-export components
  load at all (zwasm #157); the
  ADR-0135 marshalling table asserted in both directions over a 16-export
  fixture; `result`/`variant` LOWER (they raised `feature_not_supported`);
  one-shot `component-invoke`'s `own` result no longer names a destroyed table
  (ADR-0159 am1) and a resource handle is bound to its component; `wasm/run`
  output is capped (D-349 — ~64 GB was reachable).
  **clj surface**: `clojure.core.reducers` bundled (31/32 oracle-identical);
  `core_meta.clj` 291→628 rows, so `reduce`/`assoc`/`conj`/`first` are
  documented and `find-doc` covers 84% of core not 36% (ADR-0181);
  `clojure.set` → multi-arity `defn`, `(intersection)` now throws where it
  answered nil; 49 pprint + 5 data internals privatised; 44 authored
  `clojure.math` docstrings.
  **Scaffolding**: `cleanup_orphans.sh` now exists (cited as live, did not);
  `run_wasm_gate.sh` had been exiting 0 without running; new gates
  `reference_clones` / `clj_attribution --gate` / `doc_coverage` /
  `epipe_head` / `gate_parity`; NOTICE said three files where ten reproduce
  upstream text. ADR-0180/0181, AD-058/059.
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
