# Session handover
> ≤100 lines. Driving doc; framing per `.claude/rules/handover_framing.md`.

## Resume contract

- **HEAD**: `staging` = WIP branch (`git log` = SSOT); release = PR `staging`→`main`.
  Per-commit = smoke; commit **and** push. **First move on resume: spawn a cljw
  nREPL** (`mcp__hive__code cider spawn repl_type="cljw"`); reap by scoped pattern
  (`orphan_prevention.md` rule 4), never before a wrap.
- **First commit on resume MUST be**: `[CLJW-WASM-ENGINE-DEFAULT]`
  (`20260905005755-11afa056`) as an ADR with a DA fork. Deciding fact: cljw
  **D-585** (the zwasm JIT traps void exports beyond arity <=1 or <=3-without-
  FP; `.auto` cannot downgrade at invoke; engine.zig's gap-lock holds on v2.6.0)
  outranks the 2.8x crossing residual; the 15.5x compute win is opt-in territory.
  Then `[CLJW-WASM-EXPORTSIG-CACHE]` (safe: zwasm `FuncType` is slices into the
  instance's compiled sigs), `[CLJW-WASM-BENCH-BLIND]`, `[CLJW-CORE-ASYNC]`
  (`20260905225236-594e3f6a`, user direction 2026-09-06: go-like CSP + multicore).
- **v1.14.0 SHIPPED 2026-09-06** (PR #16, merge a68aa417; tag, artifacts, tap).
  The verbatim path put NO bump commit on `main`; the CHANGELOG stamp was hand
  commit 10f0b612. **ADR-0195 landed** (`runtime_thread.zig` owns the geometry,
  `main.zig` hops; JIT `wasm/call` 16.5 us -> 1.15 us): v1.14.1's content, cut by
  the next `staging`->`main` merge (preflight bumps + stamps a NON-EMPTY
  `[Unreleased]`). Memory `20260905220820-09e3d821`.
- **Gate state**: `.dev/.gate_pass` = `scripts/gate_state_hash.sh` of the v2.6.0
  pin tree (full gate, 425 pass); ADR-0195 rode a smoke. The cadence hook diffs
  the WORKING TREE, so a dirty risky diff blocks every commit.
- **Pick the smoke selector by COVERAGE, not topic** (grep the e2e tier for the
  changed file; memory `20260831212130-2668f443`). ADR-0107's 5-commit ceiling.
- **Forbidden this session**: `git rebase`/`cherry-pick`/`commit --amend`
  (classifier-blocked; FORWARD commits only); killing co-tenant JVMs/`cljw`
  processes to free memory (`bb-mcp.core` co-tenants are normal).
- **CI = ONE configuration** (`test/run_all.sh --serial-e2e`, same as `run_gate.sh`).
  No push trigger on staging: "green" = the last dispatch/PR run's sha.
- **Forbidden**: bare `zig build test` without `-Dwasm`; a Debug probe (use
  ReleaseSafe); any build during the FULL gate (`--serial-e2e`, ALONE). `.claude/**`
  edits + cross-repo publishes may hit the auto-mode block. **D-549 user-LOCKED**,
  **D-560 trigger-gated**; external publishes need `test -s` + read-back guards.

## Project invariants (stable)

- **zwasm** = tag pin **v2.6.0** (`3831e68b`) at `github.com/zwasm/zwasm`,
  separately maintained. The pin MOVES on user direction (F-001 Revision
  2026-09-05); `.dev/zwasm_capabilities.md` is a pin record (§ Pin + § History
  per bump), not a watch list. `zig fetch` needs the PEELED commit
  (`git rev-parse 'vX.Y.Z^{}'`). Read-only clone: `~/PP/referential-projects/zwasm`.
- **MAINTAINED FORK.** Upstream `clojurewasm/ClojureWasm` (chaploud) stopped at
  v1.10.1 and invited forks (EPL-2.0). `origin` = this fork. The `clojurewasm`
  remote is hobbled (`no_push`, `--no-tags`) because **`v1.10.1` names two
  commits** (ours `50b85214` = what the tap `BuddhiLW/homebrew-tap` installs;
  upstream's `8fa46d97`). Never fetch upstream tags.
- **Release path**: a push to `main` whose `.version` HAS shipped cuts the next
  patch (preflight bumps `build.zig.zon`, stamps `[Unreleased]`, tags, builds both
  artifacts, bumps the tap). A `.version` that has NOT shipped (hand minor/major)
  is released VERBATIM and NOT stamped: stamp CHANGELOG yourself in the
  `chore(release): target vX.Y.0` commit. An EMPTY `[Unreleased]` is never stamped.
  Never cut the GitHub release BY HAND before the tag workflow (zwasm #160).
- **PERF CAMPAIGN (D-450) stays stopped** — findings remain in the row.

## Current state (details = CHANGELOG + git log)

- **Issues, PRs and Discussions are OPEN here**; CONTRIBUTING exempts outside
  contributors from the loop's conventions. **Shipped through v1.14.0**
  (CHANGELOG has no `[1.13.4]` heading: verbatim path).
- **Wasm FFI is measured; the initial-thread penalty is gone (ADR-0195).** One
  `wasm/call` costs ~400 ns on `:engine :interp` (2.1x a Clojure fn call) and
  ~1.15 us on the `.auto` JIT default, on the runtime thread and on workers
  alike. The old 48x was **zwasm/D-584** (`computeStackLimit` per JIT call; on
  the process's INITIAL thread glibc parses `/proc/self/maps`), NOT fixed by
  v2.6.0; cljw no longer runs there (D-586 tracks it). The 2.8x residual is
  zwasm/D-585 (upstream #208) + cljw's per-call `exportSig` re-resolve. Issues
  #13/#14/#15. Write-up `.dev/wasm_percall_findings.md`; probes
  `.dev/bench/ffi_boundary/` (`engine_thread_matrix.clj` = the 2x2). zwasm
  ledger ids are written `zwasm/D-NNN` (bare `D-NNN` is a cljw row).
- **`bench/` is stratified and noise-guarded** (shell measures / YAML datum /
  Python renders via `bench/bench_domain.py`; a Suite carries its own
  dispersion). Every wasm workload loops INSIDE the module, so per-call cost is
  invisible to it: `[CLJW-WASM-BENCH-BLIND]` adds the crossing-dominated axis.
- **bash e2e → cljw-native suites (Layer 5b), paused mid-arc.**
  `test/clj/run_suites.clj` discovers `test/clj/suites/*_test.clj`, gated in
  SMOKE_CORE as `test_clj_suites`. Bash keeps the CLI surface and anything
  needing the PROCESS. Card `[CLJW-E2E-TO-SUITES]` (`20260831204206-0eed020c`).
- **Test layers 6/7/8 OPEN** (ADR-0186): golden (gated), properties, mutation
  (never gated). **D-577** first. Deferred with a memo: **[CLJW-DEF-NS]**
  (memory `20260825160952-2e68811c`).

## What was left unfinished (`.dev/debt.yaml` is the SSOT)

- **D-565** residuals (7)/(8) unreachable. **Perf campaign (§9.2.S) PAUSED**
  (D-520/D-386/D-005/006); **D-513** (1); **D-548** (b). Open cards:
  `[CLJW-JSON-REEXPORT]` (`20260831194114-196afd4a`), `[CLJW-ENTRYPOINT-FLAKE]`
  (`20260831192937-1e3c4ed0`), `[CLJW-NATIVE-HARNESS]` (`20260831201012-5386d9f9`).

## North star (ACTIVE, distal) + reading order

cljw's differentiator = **Wasm interop (gap II) × VM-perf fusion→JIT (gap
III)**. zwasm JIT (ADR-0200) is the default; remaining = components-through-
the-JIT (zwasm-side, D-500), distal, needs a user nod. ADR-0177: "edge
execution" is an AIM owned by D-552. Resume reading: handover → `yq` the live
`active:` list → ADR-0166 → ROADMAP §9.0. Memories: `verify_against_releasesafe_binary` /
`smoke_first_batch_full_gate` / `external-publish-payload-guard`.
