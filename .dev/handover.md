# Session handover
> ≤100 lines. Driving doc; framing per `.claude/rules/handover_framing.md`.

## Resume contract

- **HEAD**: `staging` = WIP branch (`git log` = SSOT); release = PR `staging`→`main`.
  Per-commit = smoke; commit **and** push. **First move on resume: spawn a cljw
  nREPL** (`mcp__hive__code cider spawn repl_type="cljw"`); reap by scoped pattern
  (`orphan_prevention.md` rule 4), never before a wrap.
- **First commit on resume MUST be**: ADR-0195 + `[CLJW-WASM-WORKER-THREAD]`
  (`20260905012150-05dc6702`, doing): `main.zig` spawns ONE `std.Thread`
  (explicit 16 MiB stack) running `cli.dispatch`; the initial thread joins and
  propagates the error. Helper + unit test `src/app/entry_thread.zig` (callback
  sees another `std.Thread.getCurrentId()`; errors propagate; `single_threaded`
  = direct call). Win: JIT `wasm/call` 16.5 us -> 1.2 us on Linux. DA report:
  `private/notes/adr-0195-da.md`. Then `[CLJW-WASM-ENGINE-DEFAULT]` (keep
  `.auto`), `[CLJW-WASM-EXPORTSIG-CACHE]`, `[CLJW-WASM-BENCH-BLIND]`.
- **Release in flight: PR #16 `staging`->`main` cuts v1.14.0** (`.version` is
  already `1.14.0`, set in 86006eae, so preflight releases it VERBATIM and does
  NOT stamp CHANGELOG: a `chore(release): target v1.14.0` commit running
  `python3 .github/stamp_changelog.py 1.14.0` must land on staging first; v1.13.4
  shipped unstamped). Merge only on green PR CI. Memory `20260905220820-09e3d821`.
- **Gate state**: the v2.6.0 pin commit carries the full gate that proved it;
  `.dev/.gate_pass` = `scripts/gate_state_hash.sh` of that tree. Note the cadence
  hook diffs the WORKING TREE, so a dirty risky diff blocks every commit.
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
  contributors from the loop's conventions. **Shipped through v1.13.4**
  (CHANGELOG has no `[1.13.4]` heading: verbatim path). v1.14.0 = PR #16, above.
- **Wasm FFI is measured; the default engine is wrong on Linux.** One
  `wasm/call` costs 392 ns on `:engine :interp` (2.1x a Clojure fn call) and
  **18,875 ns on the `.auto` default**. The 48x is **zwasm/D-584**
  (`computeStackLimit` per JIT invocation; on the INITIAL thread glibc parses
  `/proc/self/maps`), confirmed with zwasm's own `bench-latency` on this host,
  NOT fixed by v2.6.0. Off the initial thread the JIT pays 1.2 us; the residual
  2.9x over interp is zwasm/D-585 (upstream #208) + cljw's per-call `exportSig`
  re-resolve. Issues #13/#14/#15. Write-up: `.dev/wasm_percall_findings.md`;
  probes `.dev/bench/ffi_boundary/` (`engine_thread_matrix.clj` = the 2x2).
  zwasm ledger ids are written `zwasm/D-NNN` (bare `D-NNN` is a cljw row).
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
  (D-520/D-386/D-005/006); **D-513** (1); **D-548** (b).
- Open cards: `[CLJW-JSON-REEXPORT]` (`20260831194114-196afd4a`) ·
  `[CLJW-ENTRYPOINT-FLAKE]` (`20260831192937-1e3c4ed0`) ·
  `[CLJW-NATIVE-HARNESS]` (`20260831201012-5386d9f9`).

## North star (ACTIVE, distal) + reading order

cljw's differentiator = **Wasm interop (gap II) × VM-perf fusion→JIT (gap
III)**. zwasm JIT (ADR-0200) is the default; remaining = components-through-
the-JIT (zwasm-side, D-500), distal, needs a user nod. ADR-0177: "edge
execution" is an AIM owned by D-552. Resume reading: handover → `yq` the live
`active:` list → ADR-0166 → ROADMAP §9.0. Memories: `verify_against_releasesafe_binary` /
`smoke_first_batch_full_gate` / `external-publish-payload-guard`.
