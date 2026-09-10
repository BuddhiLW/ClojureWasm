# Session handover
> ≤100 lines. Driving doc; framing per `.claude/rules/handover_framing.md`.

## Resume contract

- **HEAD**: `staging` = WIP branch (`git log` = SSOT); release = PR `staging`→`main`.
  Per-commit = smoke; commit **and** push. Reuse warm CIDER sessions per runtime
  and repo (include `dev` + `test/clj` roots, keep a JVM oracle, memory
  `20260907085346-4d52f45e`); stop owned sessions after use.
- **First task on resume**: read PR #20's CI result on the LAST pushed head, then
  decide the release. `[CLJW-LAZY-VERIFY]` (`20260907101827-0fd15141`) is now in
  review: staging carries far more than the original lazy WIP. Each push to
  staging CANCELS the prior PR run, so only the newest run is authoritative.
- **Release sync**: v1.14.3 shipped; main/staging diverged at `dcd5639b`, staging
  well ahead. After a release, merge `origin/main` into staging before the next
  PR; new changelog entries stay under `[Unreleased]`.
- **Gate state (2026-09-09)**: **FULL gate GREEN, 368 passed / 0 failed / 1042s**
  on the ADR-0198 content, fingerprint matching the committed tree (109 suite
  files). Supersedes the earlier 366/369 note.
- **CPU/RAM**: minimal warm sessions, bounded heaps, ONE low-priority heavy job;
  prefer hosted CI over cold gates (`20260907100844-23a57c0f`).
- **Pick the smoke selector by COVERAGE, not topic** (grep the e2e tier for the
  changed file; memory `20260831212130-2668f443`). ADR-0107's 5-commit ceiling.
- **Prefer FORWARD commits** over `rebase`/`cherry-pick`/`amend`. The push hook
  wants `Smell-audited: <0-4>:` with a BARE digit; `depth 3` fails its regex.
- **Never kill co-tenant JVMs / `cljw`** (`bb-mcp.core` is normal). Under memory
  pressure shrink your OWN footprint: `nice -n 19` + `zig build -j2` survived a
  kill that default parallelism did not.
- **CI = ONE configuration** (`test/run_all.sh --serial-e2e`, same as
  `run_gate.sh`). "green" = the last dispatch/PR run's sha.
- **Forbidden**: bare `zig build test` without `-Dwasm`; a Debug probe (use
  ReleaseSafe); any build during the FULL gate (ALONE). **D-549 user-LOCKED**,
  **D-560 trigger-gated**; external publishes need `test -s` + read-back guards.

## Project invariants (stable)

- **zwasm** = tag pin **v2.6.0** (`3831e68b`), separately maintained; the pin
  MOVES only on user direction (F-001). `.dev/zwasm_capabilities.md` is a pin
  record, not a watch list. `zig fetch` needs the PEELED commit
  (`git rev-parse 'vX.Y.Z^{}'`). Clone: `~/PP/referential-projects/zwasm`.
- **MAINTAINED FORK.** Upstream (chaploud) stopped at v1.10.1 and invited forks
  (EPL-2.0); `origin` is this fork. The `clojurewasm` remote is hobbled
  (`no_push`, `--no-tags`) because **`v1.10.1` names TWO commits** (ours
  `50b85214`, what the tap installs; upstream's `8fa46d97`). Never fetch
  upstream tags.
- **Release path**: a push to `main` whose `.version` HAS shipped cuts the next
  patch (preflight bumps `build.zig.zon`, stamps `[Unreleased]`, tags, builds
  both artifacts, bumps the tap). A `.version` that has NOT shipped (hand
  minor/major) ships VERBATIM and is NOT stamped, so stamp CHANGELOG yourself in
  the `chore(release): target vX.Y.0` commit. An EMPTY `[Unreleased]` is never
  stamped. Never cut the GitHub release by hand before the tag workflow.
- **PERF CAMPAIGN (D-450) stays stopped** — findings remain in the row.

## Current state (details = CHANGELOG + git log)

- **Issues, PRs and Discussions are OPEN here** (CONTRIBUTING exempts outside
  contributors from the loop's conventions). **Shipped through v1.14.3.**
- **Wasm FFI is measured; the initial-thread penalty is gone (ADR-0195).**
  `wasm/call` is ~400 ns on `:engine :interp`, ~1.15 us on the `.auto` JIT. The
  old 48x was zwasm/D-584 (D-586); residual 2.8x is zwasm/D-585 + a per-call
  `exportSig` re-resolve. Write-up `.dev/wasm_percall_findings.md`. zwasm ids
  are cited `zwasm/D-NNN`; a bare `D-NNN` is cljw.
- **`bench/` is stratified and noise-guarded** (shell measures / YAML datum /
  Python renders). Every wasm workload loops INSIDE the module, so per-call cost
  is invisible to it: `[CLJW-WASM-BENCH-BLIND]`.
- **ADR-0198 / D-587: a redefined deftype/defrecord no longer corrupts memory.**
  A displaced TypeDescriptor is RETIRED, not freed; `rt.types` is keyed by the
  QUALIFIED name; `serialize` VERSION 10 -> 11. Residue, both filed and neither
  a regression: bare names are still last-wins (`[CLJW-CTOR-ANALYZE-TIME]`
  `20260909231443-1ba4303c`) and `instance?` still conflates same-simple-name
  types, which is a DECISION not a patch (`[CLJW-INSTANCE-SIMPLE-NAME]`
  `20260909215222-775ed21c`).
- **bash e2e → cljw-native suites (Layer 5b)**: `test/clj/run_suites.clj`
  discovers `test/clj/suites/*_test.clj`, gated in SMOKE_CORE as
  `test_clj_suites`. 317 shells / ~2160 spawns remain. Method + backlog:
  `[CLJW-E2E-SWEEP]` (`20260909231443-121d741e`); why it is worth doing (the
  bash tier's error assertions were largely VACUOUS): memory
  `20260909231325-26ddceab`.
- **Test layers 6/7/8** (ADR-0186): golden (gated), properties, mutation (on
  demand); `cljw -M:laws`. Card `20260906173600-1ac2d42b`.
- **Lazy boundary (ADR-0197)**: GC roots A8-A13, native suites + process probes.
  ALLOC=1 loader failures: harness card `20260907094157-082f659e` (nREPL workers
  skip allocation torture; use the CLI probe).

## What was left unfinished (`.dev/debt.yaml` is the SSOT)

- **D-565** residuals (7)/(8) unreachable. **Perf campaign (§9.2.S) PAUSED**
  (D-520/D-386/D-005/006); **D-513** (1); **D-548** (b). Open cards:
  `[CLJW-JSON-REEXPORT]` (`20260831194114-196afd4a`),
  `[CLJW-ENTRYPOINT-FLAKE]` (`20260831192937-1e3c4ed0`). Follow-ups: reload
  `20260907101833-277f7039`, golden root `20260907101837-067780ad`.

## North star (ACTIVE, distal) + reading order

cljw's differentiator = **Wasm interop (gap II) × VM-perf fusion→JIT (gap III)**.
zwasm JIT is the default; remaining = components-through-the-JIT (D-500),
distal, needs a user nod. ADR-0177: "edge execution" is an AIM owned by D-552.
Resume reading: handover → `yq` the live `active:` list → ADR-0166 → ROADMAP
§9.0. Memories: `verify_against_releasesafe_binary` /
`smoke_first_batch_full_gate` / `external-publish-payload-guard`.
