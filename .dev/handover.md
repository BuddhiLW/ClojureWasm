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
  **v1.6.0** (2026-08-04; four hang/abort fixes — ADR-0175 spawn-to-register
  safepoint, ADR-0176 live-worker teardown, D-347 unmetered `wasm/run`, D-339
  `run-server` head deadline — plus the opened Issues/PR surface).
  CHANGELOG is the release-history SSOT.
- **First task on resume MUST be**: the NaN-box tag-space surgery
  (`private/notes/2026-08-04-nanbox-tag-space-investigation.md` has the
  measured classification + the ADR outline). The audit's "64/64 full, needs a
  user F-004 decision" was WRONG: 53 tags are actually NaN-boxed, 3 are
  heap-only (`tail_node` / `hamt_map_node` / `tval` — GC-traced, never a
  Value), and **7 are pure unused reservations** (`reader_conditional` /
  `class` / `array_chunk` / `matcher` / `tuple` / `box` / `wasm_fn` — zero
  references outside the enum; `Class` is a `.type_descriptor` and `Matcher`
  is a `host_instance`). So ~10 slots are recoverable WITHOUT touching F-004.
  Treating the reservations as binding was the Reservation-as-bias smell
  CLAUDE.md names explicitly. Then **P1-6** (WIT↔Clojure type-mapping shared
  spec with ClojureWit).
  The 2026-08-04 audit-remediation arc otherwise closed: doc-truth +
  `size_claims` widened (`77f690a3`), Issues/PR opened (`e897cbfc`),
  ADR-0177 capability-claim gate (`92d7926d`), D-339 (`c601aa75`), ADR-0178
  generated placement index (`4c52ebcc`), AD-057 + core-surface gate
  (`18e9ea5f`), D-347 (`b4b5ef83`), D-343 + security triage (`6bdeeeb2`).
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

- **v1.5.1** is the released line; v1.5.0 was the ADR-0174 host-class campaign
  + Thread lifecycle. The v1.4.0 binary-size campaign (ADR-0172/0173) and the
  v1.3.x arc are in CHANGELOG.
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
  (Discussion #11). PARTLY drained 2026-08-04: README version + CONTRIBUTING
  opt-out notes landed with the Issues/PR opening (`e897cbfc`). Residual is
  path rot (`zwasm_from_scratch`→`zwasm`, dead `OSS/zig` ref,
  `cleanup_orphans.sh`). Companion: zwasm D-526.

- **Perf campaign (§9.2.S) — PAUSED** (D-520 / D-386 / D-005/006).
- **D-513** — clojure.core.reducers / clojure.repl / var :doc.
- **D-548** — (a) DISCHARGED (ADR-0176); residual = (b) pmap
  wall-clock on the 3-vCPU runner (timing envelope, still gated).
- CIDER upstream banner patch draft (user-side PR):
  `private/notes/cider-clojurewasm-banner-patch.md`.

## North star (ACTIVE, distal)

cljw's differentiator = **Wasm interop (gap II) × VM-perf fusion→JIT (gap
III)**. zwasm JIT (ADR-0200) is the cljw default; remaining =
components-through-the-JIT (zwasm-side, D-500). Distal — needs a user nod.
NOTE ADR-0177: "edge execution" is an AIM owned by D-552, not a capability.

## Reading order (resume)

handover → `yq` the live `active:` list → ADR-0166 → ROADMAP §9.0. Memories:
`verify_against_releasesafe_binary` / `smoke_first_batch_full_gate` /
`external-publish-payload-guard`.
