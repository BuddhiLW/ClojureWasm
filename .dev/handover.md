# Session handover
> ≤100 lines. Driving doc; framing per `.claude/rules/handover_framing.md`.

## Resume contract

- **HEAD**: `staging` = WIP branch (`git log` = SSOT); release = PR `staging`→`main`.
  Per-commit = smoke; commit **and** push. Reuse warm CIDER sessions per runtime and
  repo (`dev` + `test/clj` roots, keep a JVM oracle, `20260907085346-4d52f45e`);
  stop owned sessions after use.
- **First commit on resume MUST be** `[CLJW-BOX-CTORS]`
  (`20260910213321-72862a76`): 37-form sweep + settled design are on the card, so
  this is build-only. Then continue the `[CLJW-COMPLIANCE]` drain from the FRESH
  baseline in its card (NOT `private/notes/compliance/baseline-*.txt`, stale),
  classifying each failure against `.dev/accepted_divergences.yaml` BEFORE fixing:
  ~31 residual assertions are DELIBERATE (AD-018 x15, AD-004 x8, hierarchy x8).
- **Forbidden this session**: giving all 8 box classes an `<init>` (Short and Byte
  must NOT get one, they fail in clj too); a ratio-literal fix inside that push
  (`20260910225357-43640cd1` is its own unit, D-014a's sibling).
- **Release sync**: **v1.14.5 shipped** (tag `4421dcf6`, both artifacts), and
  `origin/main` is already fast-forwarded into staging, so `.version` is 1.14.5 and
  `[Unreleased]` is empty. After a release, merge `origin/main` into staging before
  the next PR; new changelog entries stay under `[Unreleased]`.
- **carto can read AND write `.zig`** (`20260910124023-371c75ad`; the
  `hive.shape.zig` tier is wired in hive-mcp's untracked `local.deps.edn`). Caveats:
  `insert-form` does NOT retag the rows it shifts (`20260910130225-677f2940`), and a
  qn colliding with a `clojure.core` name resolves to the WRONG tier.
- **Gate state**: v1.14.5 CI green both platforms at `4bf791cf`; SMOKE_CORE green
  2026-09-10 (17 steps, 112 suites). Two gate fixes rode it and BOTH read as
  runtime failures first (a sleep-held precondition `20260910230346-641e2d36`, a
  self-heal keyed to one wording `20260910230345-69f37712`): read the CI failure
  before blaming the diff.
- **CPU/RAM**: minimal warm sessions, bounded heaps, ONE low-priority heavy job;
  prefer hosted CI over cold gates (`20260907100844-23a57c0f`).
- **Pick the smoke selector by COVERAGE, not topic** (`20260831212130-2668f443`),
  and spell it with the `e2e_` PREFIX or the whole slow core runs then dies on a
  FATAL selector error (`20260910133335-108874d7`). ADR-0107's 5-commit ceiling.
- **Prefer FORWARD commits** over `rebase`/`cherry-pick`/`amend`. The push hook
  wants `Smell-audited: <0-4>: <summary>`, i.e. digit then COLON then text: a BARE
  `Smell-audited: 1` is REFUSED, and so is `depth 3` (regex is `[0-4][[:space:]]*:`).
- **Never kill co-tenant JVMs / `cljw`** (`bb-mcp.core` is normal). Under memory
  pressure shrink your OWN footprint: `nice -n 19` + `zig build -j2` survived a kill
  that default parallelism did not.
- **CI = ONE configuration** (`test/run_all.sh --serial-e2e`, same as
  `run_gate.sh`). "green" = the last dispatch/PR run's sha.
- **Forbidden**: bare `zig build test` without `-Dwasm`; a Debug probe (use
  ReleaseSafe); any build during the FULL gate (ALONE). **D-549 user-LOCKED**, **D-560
  trigger-gated**; external publishes need `test -s` + read-back guards.

## Project invariants (stable)

- **zwasm** = tag pin **v2.6.0** (`3831e68b`), separately maintained; the pin MOVES
  only on user direction (F-001). `.dev/zwasm_capabilities.md` is a pin record, not a
  watch list. `zig fetch` needs the PEELED commit; clone at `~/PP/referential-projects/zwasm`.
- **MAINTAINED FORK.** Upstream (chaploud) stopped at v1.10.1 and invited forks
  (EPL-2.0); `origin` is this fork. The `clojurewasm` remote is hobbled (`no_push`,
  `--no-tags`) because **`v1.10.1` names TWO commits** (ours `50b85214`, what the tap
  installs; upstream's `8fa46d97`). Never fetch upstream tags.
- **Release path**: a push to `main` whose `.version` HAS shipped cuts the next patch
  (preflight bumps `build.zig.zon`, stamps `[Unreleased]`, tags, builds both
  artifacts, bumps the tap). A `.version` that has NOT shipped (hand minor/major)
  ships VERBATIM and is NOT stamped, so stamp CHANGELOG yourself in the
  `chore(release): target vX.Y.0` commit. An EMPTY `[Unreleased]` is never stamped.
  Never cut the GitHub release by hand before the tag workflow.

## Current state (details = CHANGELOG + git log)

- **Issues, PRs and Discussions are OPEN here** (CONTRIBUTING exempts outside
  contributors from the loop's conventions). **Shipped through v1.14.5.**
- **Compliance**: the live baseline is on the card; the failing count is NOT a bug
  count. 66 accepted-divergence rows, every one with a `derives_from` and a pin.
- **Wasm FFI is measured (ADR-0195)**: `wasm/call` ~400 ns interp, ~1.15 us JIT;
  residual 2.8x is zwasm/D-585 + a per-call `exportSig` re-resolve
  (`.dev/wasm_percall_findings.md`). A bare `D-NNN` is cljw, `zwasm/D-NNN` is not.
  `bench/` is blind to per-call cost: `[CLJW-WASM-BENCH-BLIND]`.
- **bash e2e → cljw-native suites (Layer 5b)**: `test/clj/run_suites.clj` gated in
  SMOKE_CORE as `test_clj_suites`. Method `[CLJW-E2E-SWEEP]`
  (`20260909231443-121d741e`); why the bash tier's error assertions were largely
  VACUOUS: `20260909231325-26ddceab`.
- **Test layers 6/7/8** (ADR-0186): golden (gated), properties, mutation (on demand);
  `cljw -M:laws`; card `20260906173600-1ac2d42b`. Goldens are ANCHORED, a missing one
  FAILS (`20260910131814-6c76500a`); `io/resource` is nil by D-359, never anchor there.

## What was left unfinished (`.dev/debt.yaml` is the SSOT)

- **D-565** residuals (7)/(8) unreachable. **Perf campaign (§9.2.S) PAUSED**
  (D-520/D-386/D-005/006); **D-513** (1); **D-548** (b). Open cards:
  `[CLJW-JSON-REEXPORT]` (`20260831194114-196afd4a`), `[CLJW-ENTRYPOINT-FLAKE]`
  (`20260831192937-1e3c4ed0`), `[CLJW-MACRO-LITERAL-META]`
  (`20260910134058-1dc1665c`, high), `[CLJW-CTOR-ANALYZE-TIME]`
  (`20260909231443-1ba4303c`), `[CLJW-INSTANCE-SIMPLE-NAME]`
  (`20260909215222-775ed21c`). Follow-up reload: `20260907101833-277f7039`.

## North star (ACTIVE, distal) + reading order

cljw's differentiator = **Wasm interop (gap II) × VM-perf fusion→JIT (gap III)**.
zwasm JIT is the default; remaining = components-through-the-JIT (D-500), distal,
needs a user nod. ADR-0177: "edge execution" is an AIM owned by D-552.
Resume reading: handover → `yq` the live `active:` list → ADR-0166 → ROADMAP §9.0.
Memories: `verify_against_releasesafe_binary` / `smoke_first_batch_full_gate` /
`external-publish-payload-guard`.
