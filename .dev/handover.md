# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT). Per-commit = smoke locally;
  **push-to-main CI now runs the FULL gate** (ADR-0107 rev 2026-07-21 —
  == the local full gate, all e2e), so a red push CI is the immediate
  e2e signal, not a next-day nightly. Commit **and** push (atomic
  Step 6). `build.zig.zon` `.zwasm` = tag pin
  `v2.4.0` (2026-08-03; zwasm's external-consumer release — nothing in
  it reaches cljw, pin hygiene only). Latest release:
  **v1.7.0** (2026-08-04; the component marshaller could kill the host on
  guest data — bare `@intCast` = a ReleaseSafe panic; `result` lifts as
  `[:ok v]`/`[:err e]` per ADR-0135 am2, replacing a throw that DISCARDED the
  err payload; `*file*` lands). v1.6.0 earlier the same day carried four
  hang/abort fixes. CHANGELOG is the release-history SSOT.
- **First task on resume**: **D-567 is unblocked on the zwasm side but the
  merge is USER-GATED.** zwasm PR #157 (`clojurewasm/zwasm`, branch
  `develop/component-export-index-space`) fixes the export index-space
  accounting AND a follow-on it exposed (an export could satisfy its own
  sortidx bound — caught by the official corpus `types_02`, which CI runs and
  local `zig build test` does not). 3-OS CI green, MERGEABLE/CLEAN. The
  auto-mode classifier blocked `gh pr merge`, so it needs a user merge + tag.
  Verified end-to-end against a locally-patched zwasm before the pin was
  restored: `echo.component.wasm` lists all 16 exports and every ADR-0135 row
  round-trips, astral-plane `\u{10437}` included. **After the merge + tag**:
  bump `build.zig.zon`'s `.zwasm` pin, then flip
  `phase16_wasm_component_multiexport.sh` from gap-pin to asserting the exports
  + the marshalling table — that discharges D-404's fixture blocker and D-567.
  D-404's resource phase is DONE (ADR-0159 amendment 1, this session).
- **Unreleased on main**: envelope v9 (op_var_meta — def-meta rides
  the AOT wire), computed def-meta (D-316) — incl. `:tag` uniform-eval
  (`^String`→Class, `^Foo`→name error; the bare-symbol workaround
  retired), deserializer GC-rooting fix, Character getName/codePointOf
  name table (D-561), default-data-readers, deftest file:line,
  **ADR-0175 spawn-to-register GC-safepoint fix** (the 2026-07-28
  x86_64-linux nightly gc_torture SIGABRT root-caused: registration is
  now a safepoint; TooManyThreads run-unregistered fallthrough closed;
  D-566 opened), **ADR-0176 live-worker teardown guard** (D-548(a)
  future/promise glibc-abort root-caused + DISCHARGED: exitBarrier +
  deinit chokepoint guards; AD-056; fpd ncpu gate removed; pre 6/32 →
  post 0/96). Next release owns the CHANGELOG entry.
- **Forbidden this session**: bare `zig build test` WITHOUT `-Dwasm`;
  bare `zig build` for a probe (use ReleaseSafe). **The FULL gate MUST
  run `--serial-e2e`, ALONE** ((a) is DISCHARGED per ADR-0176; (b) pmap
  wall-clock stays load-sensitive — the serial discipline stands).
  **Never run a concurrent build during a gate.** `.claude/**` edits +
  cross-repo publishes may hit the auto-mode block — surface to the
  user. **D-549 distribution cluster (Docker/ghcr/notarization) is
  user-LOCKED**; **D-560 is trigger-gated** — neither self-selects.
  External-publish payloads need `test -s` + read-back guards (memory
  `external-publish-payload-guard`).

## Current state (details = CHANGELOG + git log)

- Release history (v1.3.x → v1.7.0) is in CHANGELOG; do not restate it here.
- Debug tooling: `nrepl_send.py`, `clj_diff_sweep.sh` + corpora,
  `binary_size_report.sh` / `check_capability_claims.sh` (ADR-0177),
  `gen_placement.sh` / `check_placement_status.sh` (ADR-0178),
  `check_core_surface.sh` (AD-057).
- nREPL is single-connection (serial accept, D-117(a)): a second client waits
  while an editor is attached — probe via a fresh server, not the editor's port.
- **Issues and PRs are OPEN** as of 2026-08-04 (`e897cbfc`); three issue
  templates + a rewritten CONTRIBUTING that exempts outside contributors from
  the loop's own conventions.

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
