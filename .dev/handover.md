# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT). Per-commit = smoke locally; commit
  **and** push (atomic Step 6). **CI runs ONE configuration everywhere** — PR,
  push and dispatch all run the identical `test/run_all.sh --serial-e2e` that
  `scripts/run_gate.sh` runs, so "green" means the same run wherever it is
  said; `check_gate_parity.sh` fails if a tier comes back.
- **zwasm** = tag pin **v2.5.0** (`278587f6`, FINAL), living at
  `github.com/zwasm/zwasm` under separate maintainership since 2026-08-12; the
  dep URL names it directly rather than riding the transfer redirect.
  Co-development (the `dogfooding_handover` mailbox,
  `.dev/zwasm_capabilities.md`'s refresh duty) is RETIRED.
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
- **Anything built from the `v1.10.0` tag rides the zwasm transfer redirect**,
  which holds only while nothing claims the vacated `clojurewasm/zwasm` name.
  Build from v1.10.1 or later.
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
- **Active unit — clojure.core compliance drain.** cljw runs the jank
  `clojure-test-suite` (248 `.cljc` namespaces, one per core symbol) through
  its own `clojure.test`; the harness itself was fixed first under **ADR-0191**
  so the number means what it says. Baseline needs re-measuring against the
  fixed harness. First task on resume: kanban `[CLJW-CHUNKED-EQ]` — add
  `.chunked_cons` to `src/runtime/equal.zig::isSequential`; the umbrella is
  `[CLJW-COMPLIANCE]` with nine child rows carrying file, line and expected
  green-count.

## What was left unfinished (`.dev/debt.yaml` is the SSOT)

- **D-565** — external-contributor reproducibility sweep (Discussion #11).
  (1)-(6) DISCHARGED; residuals (7)/(8) point into upstream's gitignored
  `private/notes/`, which did not come with the fork — unreachable, not pending.
- **Perf campaign (§9.2.S) — PAUSED** (D-520 / D-386 / D-005/006). **D-513**
  item (1) `clojure.core.reducers` is the only remaining piece (repl + var :doc
  landed); it is IN PROGRESS — its "take up on a real consumer" deferral is the
  pattern the 2026-06-25 drain-order decision forbids.
- **D-548** — (a) DISCHARGED (ADR-0176); residual = (b) pmap wall-clock on the
  3-vCPU runner (timing envelope, still gated).

## North star (ACTIVE, distal)

cljw's differentiator = **Wasm interop (gap II) × VM-perf fusion→JIT (gap
III)**. zwasm JIT (ADR-0200) is the cljw default; remaining =
components-through-the-JIT (zwasm-side, D-500). Distal — needs a user nod.
NOTE ADR-0177: "edge execution" is an AIM owned by D-552, not a capability.

## Reading order (resume)

handover → `yq` the live `active:` list → ADR-0166 → ROADMAP §9.0. Memories:
`verify_against_releasesafe_binary` / `smoke_first_batch_full_gate` /
`external-publish-payload-guard`.
