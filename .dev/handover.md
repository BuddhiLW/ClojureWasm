# Session handover
> ≤100 lines. Driving doc; framing per `.claude/rules/handover_framing.md`.

## Resume contract

- **HEAD**: `staging` is the WIP/integration branch (`git log` = SSOT); a
  release is cut by PR `staging`→`main` (the merge push auto-bumps the patch).
  Per-commit = smoke; commit **and** push.
- **FIRST MOVE ON RESUME: spawn a cljw nREPL and work through it**
  (`mcp__hive__code cider spawn repl_type="cljw"`, then `cider eval`). Reap by
  scoped pattern per `orphan_prevention.md` rule 4; never before a wrap.
- **First commit on resume MUST be**: finish `[CLJW-ZWASM-PIN-26]`
  (`20260905012148-6489702d`, status doing). zwasm is unpinned from v2.5.0 to
  **v2.6.0** by user direction; `build.zig.zon` + `src/runtime/cljw/wasm/engine.zig`
  are edited and UNCOMMITTED. Build is clean and all 8 `phase16_wasm_*` e2e pass;
  a full gate was launched 2026-09-05 and its result was not seen. `build.zig.zon`
  is risky-tier, so the commit needs a fresh green gate. The card lists the four
  doc follow-ups (F-001 Revision entry, `zwasm_capabilities.md` de-FROZEN,
  `build.zig.zon` comment, CHANGELOG).
- **Gate state: UNKNOWN on `staging`.** Last recorded green was 2026-08-31 (436
  passed, 907s) on the v2.5.0 pin. Re-establish before any release.
- **Pick the smoke selector by COVERAGE, not topic**: grep the e2e tier for the
  file you changed and name that step. A bare `--smoke` on a `walk.clj` change
  ran zero walk e2e and shipped a stale stub assertion for 11 commits
  (memory `20260831212130-2668f443`). Respect ADR-0107's 5-commit ceiling; it
  bounds how far such a miss travels.
- **Forbidden this session**: `git rebase`/`cherry-pick`/`commit --amend`
  (classifier-blocked in auto-mode — use FORWARD commits); killing co-tenant
  JVMs/`cljw` processes to free memory (7 `bb-mcp.core` co-tenants are normal).
- **CI runs ONE configuration everywhere** — PR, push and dispatch all run the
  same `test/run_all.sh --serial-e2e` as `run_gate.sh`; `check_gate_parity.sh`
  fails if a tier comes back.
- **Forbidden**: bare `zig build test` without `-Dwasm`; bare `zig build` for a
  probe (use ReleaseSafe); a concurrent build during a gate (the FULL gate runs
  `--serial-e2e`, ALONE). `.claude/**` edits + cross-repo publishes may hit the
  auto-mode block — surface to the user. **D-549 user-LOCKED**, **D-560
  trigger-gated**; external publishes need `test -s` + read-back guards.

## Project invariants (stable)

- **zwasm** = tag pin **v2.6.0** (`3831e68b`) at `github.com/zwasm/zwasm`,
  separately maintained. The "v2.5.0 is FINAL" framing is RETIRED by user
  direction 2026-09-05; `.dev/zwasm_capabilities.md` still says FROZEN and needs
  updating. Read-only clone for source questions: `~/PP/referential-projects/zwasm`.
- **This repository is a MAINTAINED FORK.** Upstream `clojurewasm/ClojureWasm`
  (chaploud) stopped at v1.10.1 and invited forks under EPL-2.0. `origin` is
  this fork; `main` tracks it. The archive is the `clojurewasm` remote,
  deliberately hobbled (push URL `no_push`, `tagOpt=--no-tags`) so a fetch can
  never deliver its `v1.10.1` over ours — that ref is what the Homebrew tap
  resolves. Tap = `BuddhiLW/homebrew-tap`.
- **TAG CLASH — `v1.10.1` names two commits.** Ours is `50b85214` (what `brew
  install buddhilw/tap/cljw` gets); upstream's is `8fa46d97`. Do NOT fetch
  upstream tags. Releases continue at v1.10.2+, which collide with nothing.
- **Release path is automated.** Every push to `main` touching `src/**` cuts
  the next patch: `preflight` bumps `build.zig.zon`, stamps `## [Unreleased]`
  into a dated heading, tags, builds both native artifacts, bumps the tap
  (`TAP_DEPLOY_KEY`). An EMPTY `[Unreleased]` body is not stamped — write the
  changelog entry in the same landing as the source.
- **Release hazard**: cutting the GitHub release BY HAND before the tag
  workflow runs breaks artifact upload (zwasm #160).
- **PERF CAMPAIGN (D-450) stays stopped** — findings remain in the row.

## Current state (details = CHANGELOG + git log)

- **Issues, PRs and Discussions are all OPEN here.** CONTRIBUTING exempts
  outside contributors from the loop's conventions. Each `scripts/check_*.sh`
  header is its own SSOT.
- **Shipped through v1.13.2.** Unreleased work on `staging`: see CHANGELOG.
- **Wasm FFI is measured for the first time, and the default engine is wrong on
  Linux.** One `wasm/call` costs 392 ns on `:engine :interp` (2.1x a Clojure fn
  call, so the boundary is cheap) and **18,875 ns on the `.auto` default**. That
  48x is zwasm **D-584**: `computeStackLimit` runs per JIT invocation and on
  Linux/glibc on the INITIAL thread glibc answers by parsing `/proc/self/maps`.
  Confirmed against zwasm's own `zig build bench-latency` on this host, not
  inferred. Cards: `[CLJW-WASM-ENGINE-DEFAULT]`, `[CLJW-WASM-WORKER-THREAD]`
  (worker threads pay 561 ns instead of 26.8 us, so ~47x may be available
  cljw-side), `[CLJW-WASM-BENCH-BLIND]`. Probes + numbers:
  `.dev/bench/ffi_boundary/README.md`.
- **`bench/` is stratified and noise-guarded.** shell measures / YAML is the
  datum / Python renders, with `bench/bench_domain.py` owning the vocabulary.
  Harnesses emit `--yaml`; `gen_cross_table.py` (Markdown) and `gen_charts.py`
  (SVG, no deps) render from it. A Suite now carries its own dispersion and the
  renderers refuse to claim a difference inside the noise floor. `wasm_bench.sh`
  was DEAD (called `wasm/load-wasi` + `wasm/fn`, neither exists) and is repaired.
- **bash e2e → cljw-native suites (Layer 5b), paused mid-arc.**
  `test/clj/run_suites.clj` runs `test/clj/suites/*_test.clj` by DISCOVERY and is
  gated in SMOKE_CORE as `test_clj_suites`. 18 scripts ported, 651 spawns
  removed, e2e 410 → 395. What stays in bash: the CLI surface (exit code,
  stderr, argv) and anything needing the PROCESS (`CLJW_GC_TORTURE=1`).
  Card `[CLJW-E2E-TO-SUITES]` (`20260831204206-0eed020c`) carries the method
  and the three hazards.
- **Test layers 6/7/8 OPEN** (ADR-0186): golden (gated), properties
  (`-Dprop-seed`/`-Dprop-iters`), mutation (on demand, NEVER gated). First task
  **D-577**: rule out equivalence before writing a test for a survivor.
- Deferred with a design memo: **[CLJW-DEF-NS]** (Capture-by-Var, multi-backend
  + AOT — memory `20260825160952-2e68811c`).

## What was left unfinished (`.dev/debt.yaml` is the SSOT)

- **D-565** residuals (7)/(8) unreachable (upstream gitignored `private/`).
- **Perf campaign (§9.2.S) — PAUSED** (D-520/D-386/D-005/006); **D-513** (1)
  `clojure.core.reducers`. **D-548** (b) pmap wall-clock on 3-vCPU.
- Open cards: `[CLJW-JSON-REEXPORT]` (`20260831194114-196afd4a`, hypothesis
  unverified) · `[CLJW-ENTRYPOINT-FLAKE]` (`20260831192937-1e3c4ed0`) ·
  `[CLJW-NATIVE-HARNESS]` (`20260831201012-5386d9f9`).

## North star (ACTIVE, distal) + reading order

cljw's differentiator = **Wasm interop (gap II) × VM-perf fusion→JIT (gap
III)**. zwasm JIT (ADR-0200) is the cljw default; remaining =
components-through-the-JIT (zwasm-side, D-500). Distal — needs a user nod.
ADR-0177: "edge execution" is an AIM owned by D-552, not a capability.
Resume reading: handover → `yq` the live `active:` list → ADR-0166 → ROADMAP
§9.0. Memories: `verify_against_releasesafe_binary` /
`smoke_first_batch_full_gate` / `external-publish-payload-guard`.
