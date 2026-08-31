# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `staging` is the WIP/integration branch (`git log` = SSOT); a
  release is cut by PR `staging`→`main` (the merge push auto-bumps the patch).
  Per-commit = smoke locally; commit **and** push. **FIRST MOVE ON RESUME:
  spawn a cljw nREPL and work through it** (`mcp__hive__code cider spawn
  repl_type="cljw"`, then `cider eval` / `clojure_eval`) — 2026-08-31 burned
  ~10 min per iteration cold-rebuilding the Zig binary to verify a change to a
  bundled `.clj`, which is backwards (memory `20260831195255-2f8e3d3e`,
  restating convention `20260812153852-55df3675`). Reap by scoped pattern per
  `orphan_prevention.md` rule 4; do not spawn one right before a wrap.
  **First task**: `[CLJW-FOLDBODY-DO]` (`20260831195302-04045c2d`) — `foldBody`
  drops the `(do …)` wrapper for a single body form, so `(when-not false 1)`
  expands to `(if false nil 1)` vs clj's `(if false nil (do 1))`; 5 call sites,
  oracle-derive each before fixing. Then `[CLJW-JSON-REEXPORT]`
  (`20260831194114-196afd4a`, verify-or-kill the hypothesis first) and
  `[CLJW-ENTRYPOINT-FLAKE]` (`20260831192937-1e3c4ed0`).
  **Gate state 2026-08-31: FULL gate green (451 passed, 0 failed, 0 skipped,
  639s); cadence counter reset to 0.** **Forbidden this
  session**: `git rebase`/`cherry-pick`/
  `commit --amend` (classifier-blocked in auto-mode — use FORWARD commits on a
  fresh branch); killing co-tenant JVMs to free build memory (see the build-OOM
  memory). **CI runs ONE configuration everywhere** — PR, push and dispatch all
  run the identical `test/run_all.sh --serial-e2e` that `scripts/run_gate.sh`
  runs; `check_gate_parity.sh` fails if a tier comes back.
- **zwasm** = tag pin **v2.5.0** (`278587f6`, FINAL) at `github.com/zwasm/zwasm`,
  separately maintained; co-development is RETIRED (see
  `.dev/zwasm_capabilities.md`).
- **This repository is a MAINTAINED FORK.** Upstream `clojurewasm/ClojureWasm`
  (chaploud) stopped at v1.10.1 and invited forks under EPL-2.0. **`origin` is
  this fork** and `main` tracks it. The archived source is the `clojurewasm`
  remote, deliberately hobbled: push URL `no_push`, and
  `remote.clojurewasm.tagOpt=--no-tags` so a fetch can never deliver its
  `v1.10.1` over ours — that ref is what the Homebrew tap resolves, and losing
  it would repoint every `brew install`. Tap = `BuddhiLW/homebrew-tap`. PERF
  CAMPAIGN (D-450) stays **stopped** — findings remain in the row as a record.
- **TAG CLASH — `v1.10.1` names two different commits.** Ours is `50b85214`
  (what `brew install buddhilw/tap/cljw` installs); upstream's is `8fa46d97`.
  Both were cut the same day from different trees, and since the upstream merge
  both are reachable in one object graph, so that NAME no longer identifies a
  commit. Do NOT fetch upstream's tags into this repo — it would overwrite the
  ref the tap resolves. Releases continue at v1.10.2 and up, which collide with
  nothing, since upstream cut nothing after v1.10.1.
- **Release path is automated and proven.** Every push to `main` that touches
  `src/**` cuts the next patch itself: `preflight` bumps `build.zig.zon`,
  stamps `## [Unreleased]` into a dated version heading, tags, builds both
  native artifacts and bumps the tap (`tap` job, deploy key `TAP_DEPLOY_KEY`).
  A patch whose `[Unreleased]` body is EMPTY is not stamped — so write the
  changelog entry in the same landing as the source.
- **Test layers 6/7/8 are OPEN** (ADR-0186): golden (`test/golden/`, gated),
  properties (`src/testing/prop_*.zig`, fixed seed — sweep with
  `-Dprop-seed`/`-Dprop-iters`), mutation (`scripts/mutation/run.sh`, on
  demand, worktree-isolated, NEVER gated). The mutation `--oracle` defaults to
  `unit`, which never builds the CLI — a file whose behaviour IS what the
  program prints needs `--oracle unit+golden` or every rendering path scores
  as unconstrained. First task **D-577**: rule out equivalence before writing
  a test for a survivor (`.dev/mutation_equivalent.jsonl` holds the proofs).
- **CI fires on push, on PRs and on tags here** — verified, not assumed.
  **Unreleased on main**: see CHANGELOG `[Unreleased]`.
- **Release-process hazard**: cutting the GitHub release BY HAND before the
  tag workflow runs breaks the artifact upload (zwasm #160). The matrix-leg
  `gh release view || gh release create` TOCTOU is FIXED — a failed create is
  accepted iff the release exists afterwards.
- **Forbidden**: bare `zig build test` without `-Dwasm`; bare `zig build` for a
  probe (use ReleaseSafe); a concurrent build during a gate (the FULL gate runs
  `--serial-e2e`, ALONE). `.claude/**` edits + cross-repo publishes may hit the
  auto-mode block — surface to the user. **D-549 is user-LOCKED**, **D-560
  trigger-gated**. External publishes need `test -s` + read-back guards.

## Current state (details = CHANGELOG + git log)

- **Issues, PRs and Discussions are all OPEN here.** CONTRIBUTING exempts
  outside contributors from the loop's own conventions: a contributed commit
  is taken as-is with authorship preserved and any missing `Smell-audited:`
  line amended in. Each `scripts/check_*.sh` header is its own SSOT.
- **Active unit — clojure.core compliance drain** (jank `clojure-test-suite`,
  248 `.cljc`; drain-plan `private/notes/compliance/drain-plan-2026-08-22.md`,
  batches B1-B8; baseline is pre-fix, re-measure via the fixed harness ADR-0191).
  Shipped through **v1.13.2**; see CHANGELOG + `git log` for the per-release
  parity fixes rather than duplicating them here. Deferred with a design memo:
  **[CLJW-DEF-NS]** (Capture-by-Var, multi-backend + AOT — memory
  `20260825160952-2e68811c`).

## What was left unfinished (`.dev/debt.yaml` is the SSOT)

- **D-565** residuals (7)/(8) unreachable (upstream gitignored `private/`).
- **Perf campaign (§9.2.S) — PAUSED** (D-520/D-386/D-005/006); **D-513** (1)
  `clojure.core.reducers` remaining. **D-548** (b) pmap wall-clock on 3-vCPU.

## North star (ACTIVE, distal)

cljw's differentiator = **Wasm interop (gap II) × VM-perf fusion→JIT (gap
III)**. zwasm JIT (ADR-0200) is the cljw default; remaining =
components-through-the-JIT (zwasm-side, D-500). Distal — needs a user nod.
NOTE ADR-0177: "edge execution" is an AIM owned by D-552, not a capability.

## Stopped — user requested

User instruction (2026-08-31): "make memories on all learnings this session, kg
connect them, sync kanban, create remaining kanban tasks if any, and `workflow
wrap` … push and commit changes made this session atomically. Then push to
`staging`."

**Session 2026-08-31 landed**: PR #11 merged → **v1.13.2** shipped to main
(release workflow cut the tag + bumped the tap). On `staging` since:
`slurp System/in` drains to EOF (the two same-altitude drain impls now agree),
two silent gate verdicts made honest (a mistyped `--smoke` selector ran ZERO
e2e and still went green; `check_entrypoint_surface` reported an empty `awk`
extraction as a source violation), and `clojure.walk/macroexpand-all`
discharged from a throw-stub to clojure.walk's own `prewalk` definition
(9 forms corpus-pinned against the clj oracle).

**A seam extraction was proposed and REFUSED on the project's own record**
(memory `20260831195256-1b380e1d`): readable families are a closed 2-set, and
the cljw convention says apply the principles to the existing structure. The
real defect was the asymmetry between two impls — a shape that then recurred
the same session in `foldBody` (memory `20260831195256-6b5a587e`).

Resume per the Resume-contract "FIRST MOVE ON RESUME".

## Reading order (resume)

handover → `yq` the live `active:` list → ADR-0166 → ROADMAP §9.0. Memories:
`verify_against_releasesafe_binary` / `smoke_first_batch_full_gate` /
`external-publish-payload-guard`.
