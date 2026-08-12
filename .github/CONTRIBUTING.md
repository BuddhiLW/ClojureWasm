# Contributing to ClojureWasm

Thanks for your interest. **Issues and Pull Requests are open.** This is a
small project, so replies can take a while — but the queue is real and it gets
read.

## The most useful thing you can do

**Report Clojure code that behaves differently here than on the JVM.**

ClojureWasm targets behavioural equivalence with JVM Clojure on the
user-observable surface. Every divergence you find is either a bug or a gap
that has not been written down yet — and finding them from the outside is worth
more than anything else, because a project cannot easily see its own blind
spots.

There is a [Clojure divergence issue template](https://github.com/BuddhiLW/ClojureWasm/issues/new?template=divergence.yml)
that asks for the three things that make such a report actionable: the
expression, what `cljw` prints, and what a JVM REPL prints.

Some differences are deliberate — check
[`docs/clojure_vs_clojurewasm.md`](../docs/clojure_vs_clojurewasm.md) first. If
one is listed there and you think the reasoning is wrong, that is a good
Discussion.

## Working on the code

```sh
direnv allow                              # one-time: load Zig 0.16.0 via Nix (or: nix develop)
zig build -Dwasm -Doptimize=ReleaseSafe   # build the Wasm-enabled `cljw` binary
bash test/run_all.sh --serial-e2e         # the full gate; must be green before a change lands
```

For a quick loop while iterating, `bash test/run_all.sh --smoke <e2e-step>`
runs the unit tests, the dual-backend differential oracle, the linter, and the
one end-to-end step you touched — tens of seconds instead of ~20 minutes. Run
the full gate before you open the PR.

Branch from `main` as `develop/<short-slug>`, open a PR, and let CI run. CI
runs the same gate on macOS and Linux; a green CI is what merges.

### What we do **not** ask of you

This repository is developed largely by an autonomous loop working under
written guardrails, and that loop follows conventions that exist to keep *it*
honest. **None of them apply to your contribution:**

- You do not need a `Smell-audited:` line in your commit message.
- You do not need to add a row to `.dev/debt.yaml`.
- You do not need to write an ADR, a per-task note, or a ROADMAP amendment.
- You do not need to match the commit-message style of the surrounding history.

Write a clear commit message, keep the gate green, and that is enough. If a
change turns out to need a design record, writing it is the maintainer's job,
not yours.

### What helps a PR land

- **One concern per PR.** A 30-line fix with a test merges; a 600-line
  refactor bundled with a fix stalls.
- **A test that fails before your change and passes after it.** The test
  taxonomy is in [`.claude/rules/test_taxonomy.md`](../.claude/rules/test_taxonomy.md);
  in short, unit tests live in `test "..."` blocks next to the code and CLI
  behaviour lives in `test/e2e/*.sh`.
- For a `clojure.core` behaviour change, **a line in the relevant corpus under
  `test/diff/clj_corpus/`**, so the behaviour stays checked against real `clj`
  from then on.

A note on provenance: much of this codebase is machine-written under human
review and direction. Contributions from people are very welcome and are
reviewed the same way — on whether the code is right, not on who wrote it.

## Design context, if you want it

Load-bearing decisions are recorded as ADRs under
[`.dev/decisions/`](../.dev/decisions/); the plan and its principles live in
[`.dev/ROADMAP.md`](../.dev/ROADMAP.md); the development loop itself is
described in [`.claude/CLAUDE.md`](../.claude/CLAUDE.md). None of this is
required reading to send a patch — it is there if you want to know why
something is the way it is.

## Getting in touch

Open-ended questions belong in
[GitHub Discussions](https://github.com/BuddhiLW/ClojureWasm/discussions);
the wider Clojure community also gathers on the
[Clojurians Slack](https://clojurians.slack.com).

Security problems should **not** be reported publicly — see
[`SECURITY.md`](./SECURITY.md).

## License

By contributing, you agree that your contributions are licensed under the
Eclipse Public License 2.0 (see [LICENSE](../LICENSE)).
