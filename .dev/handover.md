# Session handover
> ≤100 lines. Driving doc; framing per `.claude/rules/handover_framing.md`.

## Resume contract

- **HEAD**: `staging` is the WIP/integration branch (`git log` = SSOT); a
  release is cut by PR `staging`→`main` (the merge push auto-bumps the patch).
  Per-commit = smoke; commit **and** push.
- **FIRST MOVE ON RESUME: spawn a cljw nREPL and work through it**
  (`mcp__hive__code cider spawn repl_type="cljw"`, then `cider eval`). Reap by
  scoped pattern per `orphan_prevention.md` rule 4; never before a wrap.
- **First commit on resume MUST be**: the next unit of
  `[CLJW-E2E-TO-SUITES]` (`20260831204206-0eed020c`) — port the next stateless
  bash e2e to `test/clj/suites/`. That card carries the method AND the three
  hazards (state, process-bound cases, dangling pin/ledger pointers); read it
  before deleting any script.
- **Gate state 2026-08-31: FULL gate GREEN (436 passed, 0 failed, 0 skipped,
  907s); cadence counter reset.**
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

- **zwasm** = tag pin **v2.5.0** (`278587f6`, FINAL) at `github.com/zwasm/zwasm`,
  separately maintained; co-development RETIRED (`.dev/zwasm_capabilities.md`).
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
  workflow runs breaks artifact upload (zwasm #160). The matrix-leg
  `gh release view || gh release create` TOCTOU is FIXED.
- **PERF CAMPAIGN (D-450) stays stopped** — findings remain in the row.

## Current state (details = CHANGELOG + git log)

- **Issues, PRs and Discussions are all OPEN here.** CONTRIBUTING exempts
  outside contributors from the loop's conventions. Each `scripts/check_*.sh`
  header is its own SSOT.
- **Shipped through v1.13.2.** On `staging` since: `slurp` drains `System/in`;
  two silent gate verdicts made honest; `clojure.walk/macroexpand-all`
  implemented; `when-not` now wraps its body in `(do …)` like clj.
- **Active unit — bash e2e → cljw-native suites (Layer 5b).**
  `test/clj/run_suites.clj` runs `test/clj/suites/*_test.clj` by DISCOVERY
  (drop a file in, it runs) and is gated in SMOKE_CORE as `test_clj_suites`.
  2026-08-31: 18 scripts ported, **651 spawns removed**, suite tier 12 → **23
  suites / 195 tests / 1116 assertions**, e2e 410 → 395. What stays in bash is
  the CLI surface (exit code, stderr, argv) and anything needing the PROCESS
  (e.g. `CLJW_GC_TORTURE=1`, which is read at process start).
- **Test layers 6/7/8 OPEN** (ADR-0186): golden (`test/golden/`, gated),
  properties (`src/testing/prop_*.zig`, `-Dprop-seed`/`-Dprop-iters`), mutation
  (`scripts/mutation/run.sh`, on demand, NEVER gated; `--oracle` defaults to
  `unit` and never builds the CLI — a rendering path needs `unit+golden`).
  First task **D-577**: rule out equivalence before writing a test for a
  survivor (`.dev/mutation_equivalent.jsonl`).
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
