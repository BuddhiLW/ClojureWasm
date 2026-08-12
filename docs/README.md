# ClojureWasm documentation

Start here. Everything in this directory is versioned with the code it
describes, so a document that is wrong is a diff someone can fix in the same PR
as the behaviour — which is why these live in the repository rather than in a
GitHub wiki.

## If you are…

**…using cljw**

- [`clojure_vs_clojurewasm.md`](./clojure_vs_clojurewasm.md) — what matches JVM
  Clojure, what deliberately diverges, and what is not there yet. Read this
  first when something behaves unexpectedly; the answer is often a listed,
  intentional difference.
- [`../README.md`](../README.md) — install, quickstart, the Wasm FFI.
- [`works/ladder.md`](./works/ladder.md) — which real-world Clojure libraries
  load and run today.

**…contributing a patch**

- [`testing.md`](./testing.md) — **read before sending a patch.** How to run the
  suite, what each of the eight test layers is for, how to read each layer's
  failures, and where a new test belongs.
- [`../.github/CONTRIBUTING.md`](../.github/CONTRIBUTING.md) — what helps a PR
  land, and the list of this repository's own conventions that explicitly do
  **not** apply to outside contributions.
- [`architecture.md`](./architecture.md) — a short orientation to how the
  runtime is put together, for when a fix needs to know where it is.

**…deciding whether to depend on it**

- [`landscape.md`](./landscape.md) — where cljw sits among Clojure runtimes.
- [`works/binary_size.md`](./works/binary_size.md) — the measured size
  comparison behind the headline number.
- [`../CHANGELOG.md`](../CHANGELOG.md) — release history; the SSOT for what
  changed when.

**…debugging something specific**

- [`spec/error_format.md`](./spec/error_format.md) — the error rendering
  contract (the source excerpt, the caret, the trace).
- [`spec/formats/`](./spec/formats) — on-disk and wire formats.
- [`examples/`](./examples) — runnable examples, including the `.wasm` modules
  the docs and tests call.

## Where the rest of it lives

Not everything is in `docs/`, and the split is deliberate:

| You want | Look in |
|---|---|
| Why a design is the way it is | `.dev/decisions/` — the ADR record, one file per load-bearing decision |
| What is known-broken or deferred | `.dev/debt.yaml` — the debt ledger, with a testable barrier per row |
| What a divergence from JVM Clojure costs and why it was accepted | `.dev/accepted_divergences.yaml` |
| What a gate script checks | The script's own header in `scripts/` — each is its own SSOT |
| What the test suite covers | [`testing.md`](./testing.md) and `test/README.md` |
| Release history | `CHANGELOG.md` |

`docs/ja/` holds Japanese-language material from the project's original
maintainer. `docs/research/` holds background surveys that informed decisions
but are not themselves decisions.
