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
  at `github.com/zwasm/zwasm`** — its own org since 2026-08-12, separate
  maintainership; the dep URL names it directly rather than riding the transfer
  redirect, and the content `.hash` was unchanged by the move. Co-development
  (the `dogfooding_handover` mailbox, `.dev/zwasm_capabilities.md`'s per-unit
  refresh duty) is RETIRED — see F-001's 2026-08-12 entry. Latest release:
  **v1.10.1** (2026-08-12) — **the FINAL release**. CHANGELOG is the
  release-history SSOT.
- **First task on resume**: nothing is pending — the wind-down is COMPLETE.
  README declares the project unmaintained; v1.10.1 is released (4 assets,
  verified by download + checksum + running the macOS binary incl. the Wasm FFI
  → 42); the homebrew tap is bumped (`brew fetch` resolves 1.10.1 after `brew
  update`); the announcement is Discussion #15, edited to v1.10.1 with a comment
  recording what changed (the user pins it — the API has no pinDiscussion). The
  PERF CAMPAIGN (D-450) is **stopped, not paused** — findings stay in the row.
- **The demo shutdown is COMPLETE (2026-08-12)**, so the docs' and the
  announcement's claims are now true: cw-playground / cw-serverless-demo /
  cw-arcade archived (public, forkable), both Fly apps **destroyed** —
  irreversible, and the bookshelf's 1 GB `bookshelf_data` volume went with them.
  `fly apps list` is empty; both URLs refuse connections. Stopping the machines
  would NOT have sufficed — both configs carry `auto_start_machines = true`, so
  any request would have woken them.
- **Unreleased on main**: nothing. CHANGELOG `[1.10.1]` is the SSOT.
- **Release-process hazard** (`.github/workflows/release.yml`): cutting the
  GitHub release BY HAND before the tag workflow runs breaks the artifact
  upload (zwasm #160). The `gh release view || gh release create` TOCTOU across
  the matrix legs is **FIXED** as of v1.10.1 — a failed create is accepted iff
  the release exists afterwards; all four paths were verified against real exit
  codes. Both workflows also clear the Zig unpack target before `tar -x`, so a
  re-run cannot die on "Cannot open: File exists".
- **The v1.10.0 tag names `clojurewasm/zwasm`; v1.10.1 does not.** Anything
  building from the older tag (both demo Dockerfiles pin `CLJW_REF=v1.10.0`)
  rides GitHub's transfer redirect — verified working 2026-08-12. It holds only
  while nothing claims the vacated name: **never create a repo called `zwasm`
  under the `clojurewasm` org.**
- **Forbidden**: bare `zig build test` without `-Dwasm`; bare `zig build` for a
  probe (use ReleaseSafe). The FULL gate runs `--serial-e2e`, ALONE; never a
  concurrent build during a gate. `.claude/**` edits + cross-repo publishes may
  hit the auto-mode block — surface to the user. **D-549 (Docker/ghcr/
  notarization) is user-LOCKED**, **D-560 trigger-gated** — neither
  self-selects. External-publish payloads need `test -s` + read-back guards.

## Current state (details = CHANGELOG + git log)

- **Issues are DISABLED and always were** (deliberate — the maintainer cannot
  service them). **PRs are NOT disabled and cannot be**: GitHub has no such
  setting for an unarchived repo, so anyone can open one; none ever has, and
  none will be reviewed. Say it that way — "PRs are disabled" was the wording
  used until 2026-08-12 and it was false. **Discussions is the one channel**,
  and outside contributors send branches to cherry-pick; such a commit is taken
  as-is with authorship preserved. Debug tooling: `scripts/check_*.sh` headers
  are each their own SSOT — read the script, not a list here.
- **The repo stays PUBLIC and UNARCHIVED** (user, 2026-08-12: support ends
  gradually, the repo stays open, Issues/PRs stay unaccepted). Do not archive
  ClojureWasm. The three demo repos (cw-playground / cw-serverless-demo /
  cw-arcade) ARE archived as of 2026-08-12, and stay public.
- **2026-08-12: the README declares ClojureWasm no longer maintained**
  (`1c8a9cbf`); the Sponsors badge, README footer line, and `.github/FUNDING.yml`
  are gone with it. Wind-down context + the surveyed wording/transfer research:
  memory `clojurewasm-wind-down-plan`, `private/notes/2026-08-11-{sunset-wording,
  transfer-risk}-survey.md`.
- 2026-08-11/12: Discussions #12/#13/#14 (BuddhiLW) answered in code — three
  fix branches cherry-picked with authorship preserved, each one's CLASS then
  swept and fenced. #12 repr-misread → 3 more live bugs (multimethod isa? at 9
  defmethods, http client/server 9-entry headers, error_render context) +
  `check_repr_decode.sh`; #13/#14 entry-point divergence → `cljw repl`'s
  `[-cp][-A]` surface, `cljw build`'s missing top-level-`do` unroll,
  `check_entrypoint_surface.sh` + `test/e2e/entrypoint_eval_parity.sh` (a
  6-entry-point differential oracle). D-374's discharge was a listed-not-probed
  claim; corrected in place. Endgame row = D-576.

## What was left unfinished (`.dev/debt.yaml` is the SSOT)

The ledger is the honest list for a fork; nothing in it is scheduled. The
notable open ends: the perf campaign (D-520 / D-386 / D-513) stopped with its
baseline recorded; D-565 residuals (7)(8); D-548(b) pmap timing envelope; and
the north star — Wasm interop × VM-perf fusion→JIT — reached JIT-by-default but
not components-through-the-JIT, which was always upstream's call (D-500) and is
now another project's entirely.

## Reading order (resume)

handover → `yq` the live `active:` list → ADR-0166 → ROADMAP §9.0. Memories:
`verify_against_releasesafe_binary` / `smoke_first_batch_full_gate` /
`external-publish-payload-guard`.
