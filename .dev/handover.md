# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `main` (`git log` = SSOT). Per-commit = smoke locally;
  **CI runs ONE configuration everywhere** — PR, push and dispatch all run the
  identical `test/run_all.sh --serial-e2e` that `scripts/run_gate.sh` runs, so
  "green" means the same run wherever it is said. The nightly schedule and its
  tree_walk sweep are RETIRED (2026-08-12); `check_gate_parity.sh` fails if a
  tier comes back. Commit **and** push (atomic
  Step 6). `build.zig.zon` `.zwasm` = tag pin **v2.5.0**
  (`278587f6`, 2026-08-12, FINAL — full WASI 0.3 + the `libzwasm.a` C-API
  export fix; neither reaches cljw's Zig embedding surface). **zwasm now lives
  at `github.com/zwasm/zwasm`** — its own org since 2026-08-12, under separate
  maintainership; the dep URL names it directly rather than riding GitHub's
  transfer redirect, and the content `.hash` was unchanged by the move.
  Co-development (the `dogfooding_handover` mailbox, `.dev/zwasm_capabilities.md`'s
  per-unit refresh duty) is RETIRED. CHANGELOG is the release-history SSOT.
- **This repository is a MAINTAINED FORK.** Upstream `clojurewasm/ClojureWasm`
  (chaploud) stopped at v1.10.1, its final release, and invited forks under
  EPL-2.0; `BuddhiLW/ClojureWasm` continues from that tree. **`origin` is this
  fork** and `main` tracks it, so the plain `git push` / `git pull` do the right
  thing. The archived source is the `clojurewasm` remote, deliberately
  hobbled: its push URL is `no_push`, and `remote.clojurewasm.tagOpt=--no-tags`
  so a fetch can never deliver its `v1.10.1` over ours — that ref is what the
  Homebrew tap resolves, and losing it would repoint every `brew install`.
  Issues and PRs
  are OPEN here (so CONTRIBUTING's "branches to cherry-pick" no longer
  applies), the tap is `BuddhiLW/homebrew-tap` (`brew install
  buddhilw/tap/cljw`), and `1.x` continues from v1.10.1. PERF CAMPAIGN (D-450)
  stays **stopped** — findings remain in the row as a record.
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
- **Release path: PROVEN on v1.10.1** (2026-08-12) — artifacts built here, both
  checksums matched, binary run, `brew install buddhilw/tap/cljw` + `brew test`
  + `brew audit --strict` green. The tap bump is a `tap` job in `release.yml`
  (deploy key, secret `TAP_DEPLOY_KEY`); v1.10.1's formula was hand-written, so
  **v1.10.2 is the first release exercising the automated bump** — watch that
  job.
- **Test layers 6/7/8 are OPEN** (ADR-0186): golden snapshots (`test/golden/`,
  gated), properties (`src/testing/prop_*.zig`, in `zig build test`, fixed seed
  — sweep with `-Dprop-seed`/`-Dprop-iters`), mutation
  (`scripts/mutation/run.sh`, on demand, worktree-isolated, NEVER gated). The
  mutation runner's kill oracle is `--oracle`: `unit` (the default) never
  builds the CLI and never runs golden, so a file whose behaviour IS what the
  program prints must be swept with `--oracle unit+golden` or every rendering
  path scores as unconstrained. First task: **D-577** — rule out equivalence
  before writing a test for a survivor; `.dev/mutation_equivalent.jsonl`
  registers the unkillable ones, with proofs.
- **CI fires on push and on tags here.** Measured 2026-08-12:
  `actions/permissions` = `{enabled: true, allowed_actions: "all"}`, all three
  workflows `state: active`, push-triggered runs green on `main`. An earlier
  handover carried a HAZARD bullet claiming the opposite; it was false, and a
  stale hazard is worse than none because it teaches you to discount CI you
  actually have.
- **Unreleased on main**: see CHANGELOG `[Unreleased]`.
- **Release-process hazard** (`.github/workflows/release.yml`): cutting the
  GitHub release BY HAND before the tag workflow runs breaks the artifact
  upload (zwasm #160). The `gh release view || gh release create` TOCTOU across
  the matrix legs is **FIXED** as of upstream's v1.10.1, merged here — a failed
  create is accepted iff the release exists afterwards. Both workflows also
  clear the Zig unpack target before `tar -x`, so a re-run cannot die on
  "Cannot open: File exists".
- **Forbidden**: bare `zig build test` without `-Dwasm`; bare `zig build` for a
  probe (use ReleaseSafe). The FULL gate runs `--serial-e2e`, ALONE; never a
  concurrent build during a gate. `.claude/**` edits + cross-repo publishes may
  hit the auto-mode block — surface to the user. **D-549 (Docker/ghcr/
  notarization) is user-LOCKED**, **D-560 trigger-gated** — neither
  self-selects. External-publish payloads need `test -s` + read-back guards.

## Current state (details = CHANGELOG + git log)

- **Issues, PRs and Discussions are all OPEN here** (they were disabled
  upstream, so contributions used to arrive as branches to cherry-pick).
  CONTRIBUTING exempts outside contributors from the loop's own conventions:
  a contributed commit is taken as-is with authorship preserved and any
  missing `Smell-audited:` line amended in. Debug tooling:
  `scripts/check_*.sh` headers are each their own SSOT — read the script.
- Upstream's own wind-down (`1c8a9cbf` README notice, Sponsors + FUNDING.yml
  removed, Discussion #15) is history now; `956c34ee` replaced that notice
  with the fork's.
- 2026-08-11/12: Discussions #12/#13/#14 answered in code; each one's CLASS
  then swept and fenced (`check_repr_decode.sh`,
  `check_entrypoint_surface.sh`, `test/e2e/entrypoint_eval_parity.sh`).
  Details in CHANGELOG [1.10.0]. Endgame row = D-576.

## What was left unfinished (`.dev/debt.yaml` is the SSOT)

- **D-565** — external-contributor reproducibility sweep (Discussion #11).
  Items (1)-(6) DISCHARGED 2026-08-04; the ledger row carries what each was.
  Residuals (7)/(8) both point into upstream's gitignored `private/notes/`,
  which did not come with the fork — treat as unreachable, not pending.

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
