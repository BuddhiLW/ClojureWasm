<p align="center">
  <img src="docs/assets/clojurewasm_logo.png" alt="ClojureWasm" width="180" />
</p>

<h1 align="center">ClojureWasm</h1>

<p align="center">
  <em>A JVM-free Clojure runtime in Zig, with a WebAssembly FFI.</em>
</p>

<p align="center">
  <a href="https://github.com/clojurewasm/ClojureWasm/actions/workflows/ci.yml"><img src="https://github.com/clojurewasm/ClojureWasm/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="https://ziglang.org/"><img src="https://img.shields.io/badge/Zig-0.16.0-f7a41d?logo=zig&logoColor=white" alt="Zig 0.16.0" /></a>
  <a href="https://clojure.org/"><img src="https://img.shields.io/badge/Clojure-runtime-5881d8?logo=clojure&logoColor=white" alt="Clojure runtime" /></a>
  <a href="./LICENSE"><img src="https://img.shields.io/badge/License-EPL_2.0-blue.svg" alt="License: EPL 2.0" /></a>
</p>

> [!IMPORTANT]
> **ClojureWasm is no longer maintained.** A from-scratch Clojure runtime
> turned out to be more than one person can sustain, so I am stopping here
> while it still works. The code stays up under EPL-2.0 — fork it and build on
> it, no permission needed.
> [Discussions](https://github.com/clojurewasm/ClojureWasm/discussions) remain
> open, but may go unanswered.
>
> I believe ClojureWasm demonstrated what a from-scratch Clojure can be: a
> single small static binary, with a WebAssembly FFI. The hardest parts — and
> why this needs more than a solo maintainer — were keeping up JVM-Clojure
> compatibility (Java interop above all) and performance. Thanks to everyone
> who used it, reported differences, and contributed fixes.

## What it is

ClojureWasm is a Clojure runtime written from scratch in Zig and Clojure, with
no JVM. It builds to a small native binary (arm64 / amd64) that starts in
milliseconds. Its main feature is a **WebAssembly FFI**: from your Clojure code
you can load a module compiled from another language — Rust, Go, Zig, C — and
call it like an ordinary function. The idea is to stay in the Clojure world and
still use what other languages have already built.

## Features

- **Small and quick to start** — one static binary of about 7.5 MB with the
  Wasm JIT engine included (for scale: babashka's native binary is ~71 MB <!--size:other-->;
  [measured comparison](docs/works/binary_size.md)), starting in ~6 ms, which
  suits short-lived, start-and-stop workloads (CLI tools, serverless, scripts).
- **A lot of everyday Clojure runs** — `clojure.core` plus a growing set of
  standard-library namespaces (`clojure.string` / `set` / `walk` / `zip` /
  `edn` / `data.json` / `data.csv` / `math` / `pprint` / `test` / `tools.cli` …).
- **A CIDER-compatible nREPL** — `cljw nrepl` and connect your editor to
  evaluate real Clojure live.
- **WebAssembly as an FFI** — `(wasm/load "mod.wasm")` then
  `(wasm/call m "fn" …)`: a sandboxed module from any language, called like a
  namespace. The FFI runs **JIT-compiled by default** (the embedded zwasm engine),
  so a hot loop inside a module executes as native code.
- **WebAssembly components as namespaces** — `(:require ["comp.wasm" :as c])`
  pulls a WIT-typed component in like a library; its exports become ordinary Vars,
  with arguments and results as plain Clojure data (see below).
- **Single-binary builds** — `cljw build script.clj -o app` compiles your
  program (and the runtime) into one self-contained executable.

## Install

**Homebrew** (macOS arm64 / Linux x86_64):

```sh
brew install clojurewasm/tap/cljw
```

The `cljw` binary is not code-signed. Homebrew installs it without a Gatekeeper
prompt on most setups; if macOS still blocks it as coming from an unidentified
developer, clear the quarantine flag once:

```sh
xattr -d com.apple.quarantine "$(which cljw)"
```

Or grab a binary straight from the
[Releases](https://github.com/clojurewasm/ClojureWasm/releases) page. Building
from source is in [Quickstart](#quickstart) below.

## Quickstart

Build the optimized, Wasm-enabled binary (needs Zig 0.16 — `direnv allow` loads
it via Nix, or `nix develop`):

```sh
zig build -Dwasm -Doptimize=ReleaseSafe   # → ./zig-out/bin/cljw
```

Then (the examples assume `cljw` is on your `PATH`):

```sh
# Call a WebAssembly module compiled from another language, like a function
cljw -e '(wasm/call (wasm/load "docs/examples/wasm/add.wasm") "add" 40 2)'   # => 42

# Evaluate an expression
cljw -e '(->> (range) (filter even?) (take 5))'     # => (0 2 4 6 8)

# Run a file
cljw script.clj

# A REPL — and an nREPL for CIDER / your editor
cljw
cljw nrepl --port 7888

# Compile a program to a single self-contained native binary
cljw build script.clj -o app
```

## Require a Wasm component like a namespace

The headline feature. A **WebAssembly component** — a `.wasm` that carries its own
WIT type signature — can be `:require`-d like a Clojure library. Its exports become
ordinary Vars, and because the component describes its own types, arguments and
return values are plain Clojure data with no hand-written glue.

Build a component from any language that targets the component model (here Rust,
`cargo build --target wasm32-wasip2`), then require the `.wasm` by name:

```clojure
(ns my.app
  (:require ["typed_payload.wasm" :as tp]))   ; required like a lib

(tp/process {:xs [3 4 5] :label "data"})
;; => {:xs [3 4 5 12], :label "data!"}
```

The WIT `record` arrived as a map, `list` as a vector, `string` as a string — and
the parameter name survives as metadata, so the export reads like a normal fn:

```clojure
(:arglists (meta #'tp/process))   ;; => ([input])
```

JVM Clojure calls Java and ClojureScript calls JavaScript; here the host is a
language-neutral `.wasm`, so a function from Rust, Go, or C is indistinguishable
from a Clojure one.

## The demos (source only — the hosted instances are gone)

Two demos ran on Fly until August 2026. They are shut down with the project and
their repositories are archived, but the source is the most complete example of
what `cljw` did end to end, and each builds `cljw` from source in its
`Dockerfile` — so they double as a working deployment recipe.

- **Playground** ([source](https://github.com/clojurewasm/cw-playground)) — a
  browser Clojure playground. Submissions were evaluated **in-process** on the
  server's `cljw` under a per-submission budget (`cljw.eval/with-budget` —
  steps / deadline / heap), and could call sandboxed Rust and Go WebAssembly
  modules over the FFI.
- **Bookshelf** ([source](https://github.com/clojurewasm/cw-serverless-demo)) —
  a small multi-user bookshelf served end-to-end by `cljw`'s own HTTP server,
  no JVM: sessions, CRUD and persistence, with SQLite running as `sqlite3.wasm`
  and book-cover colours coming from a Rust module — both through the
  WebAssembly FFI.

## Documentation

- [`docs/architecture.md`](./docs/architecture.md) — a short orientation to how the
  runtime is put together.
- [`docs/clojure_vs_clojurewasm.md`](./docs/clojure_vs_clojurewasm.md) — what
  matches JVM Clojure, the intentional divergences, and what is not yet there.
- [`bench/README.md`](./bench/README.md) — the benchmark catalogue and
  cross-language cold-start numbers.

## License

Eclipse Public License 2.0 — see [LICENSE](./LICENSE) and [NOTICE](./legal/NOTICE).

---

Developed in spare time alongside a day job.
