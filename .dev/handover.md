# Session handover
> ≤100 lines. Driving doc; framing per `.claude/rules/handover_framing.md`.

## Resume contract

- **HEAD**: `staging` = WIP branch (`git log` = SSOT); release = PR `staging`→`main`.
  Per-commit = smoke; commit **and** push. **Reuse warm CIDER sessions per runtime
  and repo**; spawn `cljw` only when absent or the native runtime changed. Include
  `dev` and `test/clj` roots; keep a JVM oracle (memory `20260907085346-4d52f45e`).
  Stop owned sessions after use; all session REPLs were closed for this wrap.
- **Resume `[CLJW-LAZY-VERIFY]` (`20260907101827-0fd15141`)**: finish bounded
  final-source checks and staging PR CI for the lazy boundary WIP
  (`20260906180421-14443fe9`). No new WIP release has been cut.
  Wrap checkpoint: `20260907102158-6cded5f4`; logs: `private/notes/session-2026-09-07-lazy-wrap/`; original tasks: `private/notes/six-tasks-2026-09-06.md`.
  Compliance/core.async remain active; benches/harnesses use cljw (`20260906005754-05c07d35`).
- **Release synchronization**: PR #19 and v1.14.3 CI/release are green;
  main/staging synced at `dcd5639b`. After the next release, merge `origin/main` into
  staging before the next PR; new changelog entries stay under `[Unreleased]`.
- **Gate state**: prior full 366/369; import/D-089/D-530 failures fixed in source.
  Final VM units passed (1085s); smoke stopped during tree-walk compilation for
  resource cleanup. Final smoke/full CI remain pending; no claim of a green gate.
- **CPU/RAM**: minimal warm sessions, bounded heaps, one low-priority heavy job; prefer hosted CI over cold gates (`20260907100844-23a57c0f`). Keep main Hive alive.
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
  contributors from the loop's conventions. **Shipped through v1.14.3**
  (CHANGELOG has no `[1.13.4]` heading: verbatim path).
- **Wasm FFI is measured; the initial-thread penalty is gone (ADR-0195).** One
  `wasm/call` costs ~400 ns on `:engine :interp` (2.1x a Clojure fn call) and
  ~1.15 us on the `.auto` JIT default, on the runtime thread and on workers
  alike. The old 48x was **zwasm/D-584** (glibc parses `/proc/self/maps` for the
  INITIAL thread's stack bounds per JIT call), NOT fixed by v2.6.0; cljw no
  longer runs there (D-586). The 2.8x residual is zwasm/D-585 (upstream #208) +
  cljw's per-call `exportSig` re-resolve. Issues #13/#14/#15; write-up
  `.dev/wasm_percall_findings.md`; probes `.dev/bench/ffi_boundary/`. zwasm
  ids: `zwasm/D-NNN`, `zwasm ADR-NNNN` (bare `D-NNN` / `ADR-NNNN` = cljw).
- **`bench/` is stratified and noise-guarded** (shell measures / YAML datum /
  Python renders via `bench/bench_domain.py`; a Suite carries its own
  dispersion). Every wasm workload loops INSIDE the module, so per-call cost is
  invisible to it: `[CLJW-WASM-BENCH-BLIND]` adds the crossing-dominated axis.
- **bash e2e → cljw-native suites (Layer 5b): 61 groups shipped; 2 more in lazy WIP.**
  `test/clj/run_suites.clj` discovers `test/clj/suites/*_test.clj`, gated in
  SMOKE_CORE as `test_clj_suites`. Bash keeps the CLI surface and anything
  needing the PROCESS. Card `[CLJW-E2E-TO-SUITES]` (`20260831204206-0eed020c`).
- **Test layers 6/7/8** (ADR-0186): golden (gated), properties, mutation
  (on demand). Native hive-test laws: `cljw -M:laws` in its verified project.
  Continue test-ladder card `20260906173600-1ac2d42b` for remaining coverage. `[CLJW-DEF-NS]` fixed by exact analyzed Var
  capture; evidence memory `20260906155724-7af96201` supersedes its old memo.
- **Lazy boundary (ADR-0197)**: GC roots A8–A13, native suites and process probes,
  hive-test 3000 seeded cases / 9 mutation witnesses / 4 reviewed goldens.
  ALLOC=1 loader/discovery failures reproduce on v1.14.2: separate harness card
  `20260907094157-082f659e`. nREPL workers skip allocation torture; use the CLI probe.

## What was left unfinished (`.dev/debt.yaml` is the SSOT)

- **D-565** residuals (7)/(8) unreachable. **Perf campaign (§9.2.S) PAUSED**
  (D-520/D-386/D-005/006); **D-513** (1); **D-548** (b). Open cards:
  `[CLJW-JSON-REEXPORT]` (`20260831194114-196afd4a`), `[CLJW-ENTRYPOINT-FLAKE]`
  (`20260831192937-1e3c4ed0`); native harness base done. Follow-ups: reload `20260907101833-277f7039`, golden root `20260907101837-067780ad`.

## North star (ACTIVE, distal) + reading order

cljw's differentiator = **Wasm interop (gap II) × VM-perf fusion→JIT (gap
III)**. zwasm JIT (zwasm ADR-0200) is the default; remaining = components-through-
the-JIT (zwasm-side, D-500), distal, needs a user nod. ADR-0177: "edge
execution" is an AIM owned by D-552. Resume reading: handover → `yq` the live
`active:` list → ADR-0166 → ROADMAP §9.0. Memories: `verify_against_releasesafe_binary` /
`smoke_first_batch_full_gate` / `external-publish-payload-guard`.
