<p align="center">
  <img src="docs/assets/clojurewasm_logo.png" alt="ClojureWasm" width="180" />
</p>

<h1 align="center">ClojureWasm</h1>

<p align="center">
  <em>A JVM-free Clojure runtime in Zig, with a WebAssembly FFI.</em>
</p>

<p align="center">
  <a href="https://github.com/BuddhiLW/ClojureWasm/releases/latest"><img src="https://img.shields.io/github/v/release/BuddhiLW/ClojureWasm?sort=semver&display_name=tag&label=release&color=success" alt="Latest release" /></a>
  <a href="https://github.com/BuddhiLW/ClojureWasm/actions/workflows/ci.yml"><img src="https://github.com/BuddhiLW/ClojureWasm/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="https://github.com/BuddhiLW/homebrew-tap"><img src="https://img.shields.io/badge/brew-buddhilw%2Ftap%2Fcljw-F9A03C?logo=homebrew&logoColor=white" alt="Homebrew tap" /></a>
  <a href="https://ziglang.org/"><img src="https://img.shields.io/badge/Zig-0.16.0-f7a41d?logo=zig&logoColor=white" alt="Zig 0.16.0" /></a>
  <a href="https://clojure.org/"><img src="https://img.shields.io/badge/Clojure-runtime-5881d8?logo=clojure&logoColor=white" alt="Clojure runtime" /></a>
  <a href="./LICENSE"><img src="https://img.shields.io/badge/License-EPL_2.0-blue.svg" alt="License: EPL 2.0" /></a>
</p>

> [!IMPORTANT]
> **This is the maintained continuation of ClojureWasm.** The original
> project by [@chaploud](https://github.com/chaploud) —
> [clojurewasm/ClojureWasm](https://github.com/clojurewasm/ClojureWasm) —
> stopped at **v1.10.1**, its final release, and its author invited forks
> under EPL-2.0. Development continues here from that tree, with the gate,
> the ADR record and the release process intact.
>
> [Issues](https://github.com/BuddhiLW/ClojureWasm/issues), Pull Requests and
> [Discussions](https://github.com/BuddhiLW/ClojureWasm/discussions) are open.
> **The single most useful thing you can report is Clojure code that behaves
> differently here than on the JVM** — there is an issue template for exactly
> that.
>
> Installs and version pins move to this repository: `brew install
> buddhilw/tap/cljw`, and releases continue the `1.x` line from v1.10.0.

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
- **Persistent collections at JVM-comparable speed** — vectors, maps and sets
  trade wins with JVM Clojure op by op, and `seq` / `rest` / `next` over a
  vector are currently faster. Tight numeric loops are still the JVM's, since
  cljw interprets where the JVM JIT-compiles;
  [measured, both sides](docs/works/collection_performance.md).
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
brew install buddhilw/tap/cljw
```

The `cljw` binary is not code-signed. Homebrew installs it without a Gatekeeper
prompt on most setups; if macOS still blocks it as coming from an unidentified
developer, clear the quarantine flag once:

```sh
xattr -d com.apple.quarantine "$(which cljw)"
```

Or grab a binary straight from the
[Releases](https://github.com/BuddhiLW/ClojureWasm/releases) page. Building
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

## Pass an array to a Wasm guest

`wasm/call` marshals numbers, which is the whole interface of some guests. A
numeric guest is usually not one of them: it takes an array as a *pointer and a
length* into its linear memory, so the host has to fill the buffer before the
call and read it after.

```clojure
(def m (wasm/load "kernel.wasm"))

(wasm/mem-size m)                          ;=> 65536   (bytes, not pages)
(wasm/mem-write! m :f64 0 [1.0 2.0 3.0 4.0])
(wasm/call m "sum_f64" 0 4)                ;=> 10.0    (the guest read it)
(wasm/call m "scale_f64" 0 4 2.5)          ;=> 25.0    (scaled in place)
(wasm/mem-read m :f64 0 4)                 ;=> [2.5 5.0 7.5 10.0]
```

The element type is the guest's layout, so you state it: `:i8 :u8 :i16 :u16
:i32 :u32 :i64 :f32 :f64`. Offsets are byte offsets, and unaligned ones are
fine — whatever the guest's allocator handed you is a valid address.

## The demos (source only)

Two demos ran on Fly until August 2026. They belong to the upstream project,
which wound them down along with itself; the hosted URLs are not maintained here
and should not be relied on. The source is the most complete example of what
`cljw` does end to end, and each builds `cljw` from source in its `Dockerfile`
— so they double as a working deployment recipe.

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

[`docs/`](./docs/README.md) is the index — start there.

**Where things stand** (the state of affairs, for anyone who wants it):

- [`CHANGELOG.md`](./CHANGELOG.md) — every release and what changed in it,
  newest first. The badge above always points at the latest tag.
- [`.dev/ROADMAP.md`](./.dev/ROADMAP.md) — the mission, the phase plan, and how
  far each phase has got. The authoritative "what next".
- [`docs/clojure_vs_clojurewasm.md`](./docs/clojure_vs_clojurewasm.md) — the live
  parity picture: what matches JVM Clojure today, the intentional divergences,
  and what is not there yet.

Then the rest:

- [`docs/architecture.md`](./docs/architecture.md) — a short orientation to how the
  runtime is put together.
- [`docs/testing.md`](./docs/testing.md) — how to run the suite, what each of
  the eight test layers is for, and where a new test belongs. **Read this
  before sending a patch.**
- [`docs/works/collection_performance.md`](./docs/works/collection_performance.md)
  — measured collection performance against JVM Clojure, and the honest split
  between interpreter speed and data-structure speed.
- [`bench/README.md`](./bench/README.md) — the benchmark catalogue, the
  cross-language cold-start numbers, and the **wasm FFI measurement**: cljw's
  embedded zwasm engine against wasmtime on the same module.

## License

Eclipse Public License 2.0 — see [LICENSE](./LICENSE) and [NOTICE](./legal/NOTICE).

## Credit

ClojureWasm was created and written by [Shota Kudo
(@chaploud)](https://github.com/chaploud), who took it from nothing to a
working JVM-free Clojure runtime with a WebAssembly FFI over the life of
[clojurewasm/ClojureWasm](https://github.com/clojurewasm/ClojureWasm), through
v1.10.0. Everything this fork ships is built on that work.

---

Maintained as a fork since v1.10.0. Developed in spare time.
