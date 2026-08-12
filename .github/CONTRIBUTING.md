# Working on ClojureWasm

> [!IMPORTANT]
> **ClojureWasm is no longer maintained, so there is nothing to contribute
> *to*.** Issues and Pull Requests are disabled and always were — deliberately,
> because they could not be serviced. Nothing will be merged here.
>
> **Fork it.** The licence (EPL-2.0) asks no permission and the project asks no
> credit. This document is kept because everything below still works and is what
> you would otherwise have to reverse-engineer: how to build it, how to run the
> gate, and where the design is written down.

## Building and testing

Everything here is current and verified — it is the same gate the final release
was cut on.

```sh
direnv allow                              # one-time: load Zig 0.16.0 via Nix (or: nix develop)
zig build -Dwasm -Doptimize=ReleaseSafe   # build the Wasm-enabled `cljw` binary
bash test/run_all.sh --serial-e2e         # the full gate; must be green before a change lands
```

For a quick loop while iterating, `bash test/run_all.sh --smoke <e2e-step>`
runs the unit tests, the dual-backend differential oracle, the linter, and the
one end-to-end step you touched — tens of seconds instead of ~20 minutes.

CI (`.github/workflows/ci.yml`) runs that same full gate on macOS and Linux, and
runs exactly one configuration everywhere, so a green CI and a green local gate
mean the same thing.

### Where the tests live

- **Unit tests** in `test "..."` blocks next to the code they cover.
- **CLI behaviour** in `test/e2e/*.sh`.
- **`clojure.core` behaviour** additionally as a line in the relevant corpus
  under `test/diff/clj_corpus/`, which is re-checked against a real `clj`.
- The taxonomy, including which kinds of assertion are known to rot, is in
  [`.claude/rules/test_taxonomy.md`](../.claude/rules/test_taxonomy.md).

Two properties of the suite are worth knowing before you change anything, since
they are what caught most of the bugs in this project's history: every
end-to-end test runs on **both** the tree-walking interpreter and the bytecode
VM and fails if they disagree, and `clojure.core` behaviour is diffed against
real JVM Clojure rather than against hand-written expected values.

### Conventions you can ignore

Much of this repository was written by an autonomous loop under written
guardrails, and the history reflects conventions that existed to keep *it*
honest — `Smell-audited:` commit trailers, `.dev/debt.yaml` rows, ADRs,
per-task notes. **None of it binds a fork.** They are documentation of how the
work was done, not a process you inherit.

## Design context, if you want it

Load-bearing decisions are recorded as ADRs under
[`.dev/decisions/`](../.dev/decisions/); the plan and its principles live in
[`.dev/ROADMAP.md`](../.dev/ROADMAP.md); the development loop itself is
described in [`.claude/CLAUDE.md`](../.claude/CLAUDE.md). Deliberate
divergences from JVM Clojure — the ones that are decisions rather than bugs —
are catalogued in
[`docs/clojure_vs_clojurewasm.md`](../docs/clojure_vs_clojurewasm.md); read it
before treating a difference as a defect.

Nothing here is required reading. It is there so a fork does not have to
re-derive why something is the way it is, and `.dev/debt.yaml` in particular is
an honest list of what was known to be unfinished.

## Getting in touch

[GitHub Discussions](https://github.com/clojurewasm/ClojureWasm/discussions)
stays open and may go unanswered; the wider Clojure community gathers on the
[Clojurians Slack](https://clojurians.slack.com).

There are no security fixes — see [`SECURITY.md`](./SECURITY.md), which is
explicit about that.

## License

The project is under the Eclipse Public License 2.0 (see
[LICENSE](../LICENSE)), and stays that way. A fork inherits it.
