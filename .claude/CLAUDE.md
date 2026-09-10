# ClojureWasm

A Clojure runtime written in Zig 0.16.0. Binary and package name: `cljw`.

> Loaded on every turn, so it holds only what is true on every turn:
> invariants, identity, the priority chain, and ids. Procedure lives in
> hive memory and is fetched when the step actually runs.
> `mcp__hive__memory get :id <id>`

## Priority chain (top-down; higher wins, lower is edited to align)

1. `.dev/project_facts.md` F-NNN, user-declared, treated as project law.
   The loop **never** amends an F-NNN on its own.
2. `.dev/ROADMAP.md` engineering plan.
3. ADRs + `.claude/rules/` implementation decisions, amendable by the loop
   autonomously (depth 2-4).
4. `.dev/principle.md` smell sensors, depth selection.
5. AI judgement fills in the rest.

Treating an F-NNN as "informational" / "tie-breaker" / "recommendation" is the
Smallest-diff bias smell and is forbidden.

**Project spirit: the finished form's cleanliness wins.** Shipping fast and
avoiding rework are second-tier. Big surgery is welcome; reservations (ADR
numbers, NaN-box slots, debt rows) are memos, not contracts; progress pressure
does not override the smell sensor. Mechanism: `.dev/principle.md`.

## Identity (verified 2026-09-10)

- **Repo**: `~/PP/ClojureWasm`.
- **origin** = `git@github.com:BuddhiLW/ClojureWasm.git`. **This fork is the
  maintained one.** The `clojurewasm` remote is deliberately hobbled
  (`no_push`, `--no-tags`) because `v1.10.1` names TWO commits. Never fetch
  upstream tags.
- **Branches**: work lands on `staging`; `main` is reached by PR
  (`staging` -> `main`), which is what cuts a release. Commit **and** push in
  the same step; local commits never accumulate.
- **Shipped through v1.14.4.** Release mechanics + the ledger of what is
  unfinished live in `.dev/handover.md`.
- **Read-only references**: cw v0 through git only (`git show v0.5.0:<path>`,
  or `git worktree add ../cw-v0 v0.5.0`). zwasm clone at
  `~/PP/referential-projects/zwasm`. The `~/Documents/OSS/{clojure,babashka,zig}`
  and `~/Documents/MyProducts/ClojureWasm` paths in older text are the
  **upstream author's machine layout**, inherited by the fork and never valid
  here. A survey that needs JVM Clojure, Babashka or the Zig stdlib must be
  pointed at a tree that exists, or clone one first.

## Language and writing style

English everywhere: code, comments, commit messages, chat, README, ROADMAP,
ADRs, `.dev/`, `.claude/`, notes. `docs/ja/archive/` stays as it is
(chaploud's authored work, cadence dormant per ADR-0025).

No em-dashes, no `...` ellipsis, no LLM padding. A comma, a colon,
parentheses, or a full stop. State the fact and stop. Long rationale goes in
an ADR or hive memory, never inline in a README.

## The only stop

**One condition: the user explicitly asks the loop to stop.** Task, phase,
commit and cluster boundaries do not stop it. A smell trigger does not stop
it (it is an interrupt). A red gate does not stop it. Choosing the next unit
is never resolved by asking the user; that is the Direction-ask smell.

Full rule + next-unit self-selection + debt-drain order: `20260910001609-5b3ea4d7`

## Procedure (fetch when the step runs, not before)

| what | id |
|---|---|
| Per-task TDD loop, Step 0 to 7 | `20260910001609-609c3c20` |
| ADR-level design inline + the DA-fork brief | `20260910001609-6e4ca074` |
| The only stop + next-unit selection | `20260910001609-5b3ea4d7` |
| Data-source SSOTs, and what each answers | `20260910001610-1d4ad7e8` |
| Always-on context budget, measured | `20260909235631-5c19c78d` |

## Knowledge lives in hive memory, not in files

All 198 ADRs and all 32 `.claude/rules/` are mirrored into memory + KG
(2026-09-09/10). The files stay on disk: ADRs are cited by commit messages
and `check_debt_id_refs`, and `.claude/rules/*.md` is auto-loaded **by path**
on its frontmatter globs, so it is executable config. Search, do not read a
directory:

```
mcp__hive__memory search :query "..."
mcp__hive__memory query  :tags ["adr" "adr-0107"]     # one ADR
mcp__hive__memory query  :tags ["cljw-rule"]          # the rule corpus
mcp__hive__memory kg traverse :start_node <id> :max_depth 2
```

Design canon distilled from reading the whole corpus at once:

| finding | id |
|---|---|
| A generated artifact with no gate is abandoned (decided 4x) | `20260909235631-6f763b58` |
| Registry for completeness; defer a seam for pluggability | `20260909235630-6096047d` |
| The dual-backend oracle cannot see a bug identical on both | `20260909235630-5ace59c5` |
| A proxy signal accepted for the fact it names | `20260910001213-63e219a4` |
| Overriding the DA fork: name the axis, not the size | `20260909235632-7a57b709` |
| Guard enforceability measured at 12 of 32 rules | `20260909235631-5ae3f445` |

## Build and test

```sh
bash test/run_all.sh --smoke <step>      # per-commit smoke (ADR-0107)
bash scripts/run_gate.sh                 # full gate, run ALONE
zig build -Dwasm -Doptimize=ReleaseSafe  # probe binary (= the gate config)
zig fmt src/
```

Never a bare `zig build test` without `-Dwasm`. Never a Debug binary for a
behaviour probe. Never a build during the full gate. Cadence SSOT:
`.claude/rules/gate_cadence.md`.

## References

- `.dev/ROADMAP.md` authoritative mission and plan. **If this file conflicts
  with the roadmap, the roadmap wins.**
- `.dev/handover.md` current state, <= 100 lines, driving doc not session log.
- `.dev/decisions/` ADRs; numbers are time-ordered, newest wins on conflict.
- `.dev/project_facts.md` the F-NNN invariants this chain starts from.
