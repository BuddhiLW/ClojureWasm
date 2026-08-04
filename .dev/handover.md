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
- **First task on resume**: **release v1.8.0.** 21 commits since v1.7.0, all
  green, nothing half-landed. The one thing to settle FIRST: `build.zig.zon`
  pins `.zwasm` to a COMMIT (`1ecc7a8a`) rather than a tag, because the two
  fixes cljw needs (component export index space #157, the capture cap #158 +
  #159) are on zwasm `main` and **cutting a zwasm tag is user-only per its
  ADR-0156**. Either cut zwasm v2.4.1 and flip the pin to it (one line), or
  release cljw on the commit pin — it is hash-pinned and reproducible, just
  unusual. Then the four distribution repos.
  After that: **D-570** (the wall-clock axis `wasm/run` still lacks) is the
  cleanest open unit; its only blocker is choosing a default that would not
  break a legitimately long-running guest.
- **Unreleased on main** (21 commits since v1.7.0, 2026-08-04 audit-drain day —
  CHANGELOG entry is owed by the next release):
  **Wasm/component**: multi-export components load at all (zwasm #157); the
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
  **Scaffolding**: `cleanup_orphans.sh` now exists (it was cited as live and did
  not); `run_wasm_gate.sh` had been exiting 0 without running; new gates
  `reference_clones` / `clj_attribution --gate` / `doc_coverage`; NOTICE said
  three files where ten reproduce upstream text. ADR-0180/0181, AD-058/059.
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

- **D-565** — external-contributor reproducibility / doc-staleness sweep
  (Discussion #11). Items (1)-(6) DISCHARGED 2026-08-04. Two of them were not
  doc rot: `scripts/cleanup_orphans.sh` did not exist anywhere (now in-repo +
  wired as a SessionStart hook), and `scripts/run_wasm_gate.sh` guarded on a
  directory renamed long ago, so it had been exiting 0 without running.
  `scripts/check_reference_clones.sh` is the new gate that would have caught
  the dead reference paths. Residual: (7) survey-workflow setup notes, (8)
  handover pointing at gitignored `private/notes/` recipes. Companion: zwasm
  D-526.

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
