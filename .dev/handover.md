# Session handover
> ≤100 lines. Driving doc; framing per `.claude/rules/handover_framing.md`.

## Resume contract

- **HEAD**: `staging` = WIP branch (`git log` = SSOT); release = PR `staging`→`main`.
  Per-commit = smoke; commit **and** push. Reuse warm CIDER sessions per runtime
  and repo (include `dev` + `test/clj` roots, keep a JVM oracle, memory
  `20260907085346-4d52f45e`); stop owned sessions after use.
- **First task on resume**: drain `[CLJW-COMPLIANCE]` from the FRESH 2026-09-10
  baseline in its card, not from `private/notes/compliance/baseline-*.txt` (stale:
  a `subvec` panic they list is already fixed). Classify each failure against
  `.dev/accepted_divergences.yaml` BEFORE fixing: 15 of the 143 failed assertions
  are AD-018 on purpose. Easiest real batch = B1 (transient variadic arities).
- **Release sync**: v1.14.4 shipped; `origin/main` merged into staging at
  `11f78d77`. After a release, merge `origin/main` into staging before the next
  PR; new changelog entries stay under `[Unreleased]`.
- **carto can read AND write `.zig` now** (`20260910124023-371c75ad`): the
  `hive.shape.zig` tier was never mounted; wired in hive-mcp's untracked
  `local.deps.edn`. Caveat: `insert-form` does NOT retag the rows it shifts and
  no scan mode repairs it (`20260910130225-677f2940`).
- **Gate state**: v1.14.4 CI green both platforms; SMOKE_CORE green 2026-09-10
  (591 tests / 2874 assertions / 111 suites).
- **CPU/RAM**: minimal warm sessions, bounded heaps, ONE low-priority heavy job;
  prefer hosted CI over cold gates (`20260907100844-23a57c0f`).
- **Pick the smoke selector by COVERAGE, not topic** (`20260831212130-2668f443`),
  and spell it with the `e2e_` PREFIX or the whole slow core runs then dies on a
  FATAL selector error (`20260910133335-108874d7`). ADR-0107's 5-commit ceiling.
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
  contributors from the loop's conventions). **Shipped through v1.14.4.**
- **Compliance baseline 2026-09-10**: 201 green / 43 failing / 3 aborted of 247.
  The 43 is NOT a bug count (15 failures are AD-018 on purpose); see the card.
- **Wasm FFI is measured (ADR-0195)**: `wasm/call` ~400 ns interp, ~1.15 us JIT;
  residual 2.8x is zwasm/D-585 + a per-call `exportSig` re-resolve. Write-up
  `.dev/wasm_percall_findings.md`. A bare `D-NNN` is cljw, `zwasm/D-NNN` is not.
- **`bench/` is stratified and noise-guarded**; every wasm workload loops INSIDE
  the module, so per-call cost is invisible to it: `[CLJW-WASM-BENCH-BLIND]`.
- **ADR-0198 / D-587: a redefined deftype/defrecord no longer corrupts memory.**
  Residue, filed, neither a regression: `[CLJW-CTOR-ANALYZE-TIME]`
  (`20260909231443-1ba4303c`) and `[CLJW-INSTANCE-SIMPLE-NAME]`
  (`20260909215222-775ed21c`).
- **bash e2e → cljw-native suites (Layer 5b)**: `test/clj/run_suites.clj` gated
  in SMOKE_CORE as `test_clj_suites`; 317 shells / ~2160 spawns remain. Method:
  `[CLJW-E2E-SWEEP]` (`20260909231443-121d741e`); why (the bash tier's error
  assertions were largely VACUOUS): `20260909231325-26ddceab`.
- **Test layers 6/7/8** (ADR-0186): golden (gated), properties, mutation (on
  demand); `cljw -M:laws`. Card `20260906173600-1ac2d42b`. Its goldens are now
  ANCHORED and a missing one FAILS instead of being captured (`cljw
  -M:anchor-test`, `20260910131814-6c76500a`); `io/resource` is nil by D-359, so
  never anchor a golden through it.

## What was left unfinished (`.dev/debt.yaml` is the SSOT)

- **D-565** residuals (7)/(8) unreachable. **Perf campaign (§9.2.S) PAUSED**
  (D-520/D-386/D-005/006); **D-513** (1); **D-548** (b). Open cards:
  `[CLJW-JSON-REEXPORT]` (`20260831194114-196afd4a`),
  `[CLJW-ENTRYPOINT-FLAKE]` (`20260831192937-1e3c4ed0`),
  `[CLJW-MACRO-LITERAL-META]` (`20260910134058-1dc1665c`, high). Follow-up:
  reload `20260907101833-277f7039`. Golden root: DONE 2026-09-10.

## North star (ACTIVE, distal) + reading order

cljw's differentiator = **Wasm interop (gap II) × VM-perf fusion→JIT (gap III)**.
zwasm JIT is the default; remaining = components-through-the-JIT (D-500),
distal, needs a user nod. ADR-0177: "edge execution" is an AIM owned by D-552.
Resume reading: handover → `yq` the live `active:` list → ADR-0166 → ROADMAP
§9.0. Memories: `verify_against_releasesafe_binary` /
`smoke_first_batch_full_gate` / `external-publish-payload-guard`.
