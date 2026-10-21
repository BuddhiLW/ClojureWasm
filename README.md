<p align="center">
  <img src="docs/assets/clojurewasm_logo.png" alt="ClojureWasm" width="180" />
</p>

<h1 align="center">ClojureWasm</h1>

<p align="center">
  <em>A JVM-free Clojure runtime in Zig. One 8.1 MB binary, a Wasm FFI, and a sandbox per module.</em>
</p>

<p align="center">
  <a href="https://github.com/BuddhiLW/ClojureWasm/releases/latest"><img src="https://img.shields.io/github/v/release/BuddhiLW/ClojureWasm?sort=semver&display_name=tag&label=release&color=success" alt="Latest release" /></a>
  <a href="https://github.com/BuddhiLW/ClojureWasm/actions/workflows/ci.yml"><img src="https://github.com/BuddhiLW/ClojureWasm/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="https://github.com/BuddhiLW/homebrew-tap"><img src="https://img.shields.io/badge/brew-buddhilw%2Ftap%2Fcljw-F9A03C?logo=homebrew&logoColor=white" alt="Homebrew tap" /></a>
  <a href="https://ziglang.org/"><img src="https://img.shields.io/badge/Zig-0.16.0-f7a41d?logo=zig&logoColor=white" alt="Zig 0.16.0" /></a>
  <a href="https://clojure.org/"><img src="https://img.shields.io/badge/Clojure-runtime-5881d8?logo=clojure&logoColor=white" alt="Clojure runtime" /></a>
  <a href="./LICENSE"><img src="https://img.shields.io/badge/License-EPL_2.0-blue.svg" alt="License: EPL 2.0" /></a>
</p>

ClojureWasm (`cljw`) runs Clojure without a JVM. It is written in Zig and
Clojure, ships as one static binary, starts in milliseconds, and embeds a
WebAssembly engine so a `.wasm` compiled from Rust, Go, C or Zig can be
required like a namespace and called like a function, inside a sandbox whose
fuel and memory the caller sets.

[Install](#install) · [Quickstart](#quickstart) · [News](#news) ·
[Where it shines](#where-it-shines) · [How it is put together](#how-it-is-put-together) ·
[Wasm FFI](#the-wasm-ffi-in-one-screen) · [Numbers](#numbers) ·
[What runs](#what-runs) · [Documentation](#documentation) ·
[License](#license-and-credit)

## Install

```sh
brew install buddhilw/tap/cljw        # macOS arm64, Linux x86_64
```

Binaries are also on the [Releases](https://github.com/BuddhiLW/ClojureWasm/releases)
page. The binary is not code-signed; if macOS blocks it once, clear the
quarantine flag: `xattr -d com.apple.quarantine "$(which cljw)"`.

From source (Zig 0.16; `direnv allow` or `nix develop` provides it):

```sh
zig build -Dwasm -Doptimize=ReleaseSafe   # → ./zig-out/bin/cljw
```

## Quickstart

```sh
cljw -e '(->> (range) (filter even?) (take 5))'                            # (0 2 4 6 8)
cljw -e '(wasm/call (wasm/load "docs/examples/wasm/add.wasm") "add" 40 2)'  # 42
cljw -e '(.add (wasm/load "docs/examples/wasm/add.wasm") 40 2)'             # 42, next release
cljw script.clj                    # run a file
cljw                               # REPL
cljw nrepl --port 7888             # nREPL, CIDER-compatible
cljw build script.clj -o app       # one self-contained native binary
```

## News

**2026-10:** [@chaploud](https://github.com/chaploud) handed the project to
[@BuddhiLW](https://github.com/BuddhiLW); the fork's work is merged back into
[clojurewasm/ClojureWasm](https://github.com/clojurewasm/ClojureWasm), releases
and the Homebrew tap still publish from
[BuddhiLW/ClojureWasm](https://github.com/BuddhiLW/ClojureWasm), and install
commands and version pins are unchanged.
[Issues](https://github.com/BuddhiLW/ClojureWasm/issues) and PRs are open; the
most useful report is Clojure code that behaves differently here than on the JVM.

## Where it shines

**Sandboxed plugins and tools.** A module instantiates with an empty import
object, so a guest reaches nothing the host did not grant, and every load takes
a budget. A tool that spins burns its fuel and returns an error; the host
process keeps running. That makes `cljw` a fit for hosts where untrusted code
runs in-process: plugin systems, MCP tool servers, request handlers that
evaluate user code.

```clojure
(def k (wasm/load "docs/examples/polyglot/c/kernel.wasm" {:fuel 1000000 :max-memory-pages 16}))
(wasm/call k "buf_cap")                                          ;=> 256
(try (wasm/call (wasm/load "docs/examples/wasm/trap.wasm") "boom")
     (catch Exception e (re-find #"trapped" (ex-message e))))    ;=> "trapped"
```

**Other languages' libraries, from Clojure.** JVM Clojure calls Java;
ClojureScript calls JavaScript; here the host is a language-neutral `.wasm`.
A WIT-typed component is a namespace: records arrive as maps, lists as
vectors, `result<T, E>` as `[:ok v]` / `[:err e]`.

```clojure
(ns my.app
  (:require ["./typed_payload.wasm" :as tp]))  ; Rust + wit-bindgen, 51 KB

(tp/process {:xs [3 4 5] :label "data"})      ;; => [:ok {:xs [3 4 5 12], :label "data!"}]
(tp/process {:xs [] :label "fail"})           ;; => [:err "boom: fail"]
(:arglists (meta #'tp/process))               ;; => ([input])
```

A string path in `:require` is cljw-only; in a `.cljc`, write it as
`#?(:cljw ["./typed_payload.wasm" :as tp])`.

Each guest language has a natural shape, and cljw has an entry point for each:

| guest | built with | crosses the boundary as | entry point |
|---|---|---|---|
| C | `zig cc -target wasm32-freestanding` | scalars, arrays in a guest-owned buffer | `wasm/load`, `wasm/call`, `wasm/mem-*` |
| Zig | `zig build-exe -target wasm32-freestanding` | scalars | `wasm/load`, `wasm/call` |
| Rust, `no_std` | `rustc --target wasm32-unknown-unknown` | scalars | `wasm/load`, `wasm/call` |
| Rust, wit-bindgen | `cargo build --target wasm32-wasip2` | records, lists, strings, results | `(:require ["x.wasm" :as x])` |
| Go | `GOOS=wasip1 GOARCH=wasm go build` | argv, env, stdin, stdout, exit code | `wasm/run` |

All five run in [`docs/examples/polyglot`](./docs/examples/polyglot/README.md),
sources and build lines included; CI rebuilds them from source and runs them on
every push.

**Native tools, unchanged.** A tool that already exists as a native binary
needs no Wasm build and no bindings. `clojure.java.shell/sh`, the same API the
JVM and babashka ship, runs it by argv (never through a shell) and returns
`{:exit :out :err}`, with a non-zero exit as data.

```clojure
(require '[clojure.java.shell :refer [sh]])
(sh "echo" "hi")   ;=> {:exit 0, :out "hi\n", :err ""}
```

[AutoPDF's Clojure client](https://github.com/BuddhiLW/AutoPDF/tree/main/clients/clojure)
drives the unmodified Go `autopdf` CLI this way and renders the same PDF on
cljw, clojurust and the JVM. A child process escapes in-process containment, so
`sh` is refused under a filesystem root (`CLJW_FS_ROOT`) or inside
`cljw.eval/with-budget`.

**Short-lived processes.** One 8.1 MB binary that starts in milliseconds
([Numbers](#numbers)), and `cljw build app.clj -o app` produces a
self-contained executable. CLI tools, serverless handlers, scripts that run a
thousand times a day.

**One program, two runtimes.** `cljw` reads `.cljc` under the feature set
`{:cljw :clj :default}`, and its sibling [clojurust](https://github.com/BuddhiLW/clojurust)
(`cljrs`, Rust-hosted, Cranelift JIT) reads `{:rust}`. A host-free `.cljc`
runs unchanged on the JVM, on `cljw` and on `cljrs`
([`hosts.cljc`](./docs/examples/polyglot/hosts.cljc) prints the same map on
all three, ratios and bigints included, and CI checks that), and the same Rust
crate can serve both: as a zero-import Wasm component on `cljw`, as a native
`cdylib` on `cljrs`. The program picks confinement or speed without a rewrite.

```mermaid
flowchart LR
    P["demo.cljc<br/>one Clojure program"] --> A["cljw<br/>Wasm component, zero imports"]
    P --> B["cljrs<br/>native cdylib"]
    A --> L[("arkworks Groth16<br/>the same Rust crate")]
    B --> L
```

Measured on that exact shape (a Groth16 prover over BN254, 2026-09-12, same
crate and feature set on both sides):

| | cljrs (native) | cljw (Wasm) |
|---|---|---|
| proof | 128 bytes | 128 bytes |
| verify, correct / wrong statement | true / false | true / false |
| wall time | 1.29 s (debug build) | 9.17 s |
| env vars visible to the prover | 212 | 0 |
| file read | granted | denied |
| wall clock | granted | trap |

## How it is put together

```mermaid
flowchart LR
    S[".clj / .cljc / .cljw"] --> R["reader + analyzer"]
    R --> TW["tree-walk interpreter"]
    R --> VM["bytecode VM"]
    TW --> RT["runtime: NaN-boxed values, mark-sweep GC,<br/>persistent collections, STM, agents, nREPL"]
    VM --> RT
    RT --> Z["zwasm engine<br/>interpreter + JIT, fuel and memory budgets"]
    Z --> W[".wasm modules and WIT components<br/>from Rust, Go, C, Zig"]
```

Both backends evaluate the same analyzer output, and the test suite runs every
case on both and fails on a mismatch. That differential oracle is how a
from-scratch runtime keeps Clojure semantics honest without a reference
implementation in the process. [`docs/architecture.md`](./docs/architecture.md)
has the map.

## The Wasm FFI in one screen

```clojure
;; A core module (docs/examples/polyglot/c/kernel.c): numbers in, numbers
;; out, arrays in a buffer the guest owns and hands out by address.
(def m (wasm/load "docs/examples/polyglot/c/kernel.wasm" {:fuel 1000000 :max-memory-pages 16}))

;; Next release: list the exports before calling any.
(mapv (juxt :name :kind) (wasm/exports m))
;=> [["memory" :memory] ["buf_addr" :func] ["buf_cap" :func] ["sum_f64" :func] ["scale_f64" :func]]

(def buf (wasm/call m "buf_addr"))
(wasm/mem-write! m :f64 buf [1.0 2.0 3.0 4.0])
(wasm/call m "sum_f64" buf 4)               ;=> 10.0
(.sum_f64 m buf 4)                          ;=> 10.0, next release
(wasm/mem-read m :f64 buf 4)                ;=> [1.0 2.0 3.0 4.0]

;; A WIT component: typed, so arguments and results are plain Clojure data.
(def g "test/e2e/fixtures/wasm/greet_component.wasm")
(wasm/component-exports g)                  ;=> [{:name "greet", :params [["name" "string"]], :result "string"}]
(def c (wasm/load-component g {:fuel 100000}))
(wasm/component-call c "greet" "zwasm")     ;=> "Hello, zwasm!"

;; A fault in the guest is a catchable Clojure exception, never a host crash.
(try (wasm/call (wasm/load "docs/examples/wasm/trap.wasm") "boom")
     (catch Exception e (ex-message e)))
;=> "wasm/call: 'boom' () -> (i32) trapped on the auto (JIT-first) engine
;    (divide-by-zero, out-of-bounds, unreachable, or a call shape the engine
;    cannot dispatch)"
```

Dot interop (ADR-0203, next release): on a module handle, `(.sum_f64 m buf 4)`,
`(. m sum_f64 buf 4)` and `(. m (sum_f64 buf 4))` are `wasm/call` with the
method name as the export name, verbatim, so results, fuel and errors are the
same. It is cljw-only (use a `:cljw` reader conditional in a `.cljc`), and an
export whose name is not a valid symbol still goes through `wasm/call`.

Budgets: a missing axis keeps the engine's finite default (1e9 fuel, 4096
pages), `0` removes a cap for a trusted guest, and fuel is per instance, so an
exhausted handle stays exhausted until you load again. The engine is JIT by
default for modules (`:engine :interp` to force the interpreter); components
run on the interpreter. Element types for memory access are the guest's
layout: `:i8 :u8 :i16 :u16 :i32 :u32 :i64 :f32 :f64`.

## Numbers

Every figure below is generated from a committed measurement file under
[`bench/`](./bench/README.md), not typed by hand, and the release size is
checked against the built binary by a gate on every push.

```mermaid
xychart-beta
    title "Binary size, MB (cljw 8.14 MB, others measured 2026-07-16)"
    x-axis ["cljw", "Joker", "babashka", "jank"]
    y-axis "MB" 0 --> 140
    bar [8.14, 28.8, 71.2, 129.7]
```

```mermaid
xychart-beta
    title "Process startup, ms (Apple M4 Pro, hyperfine, 2026-07-16)"
    x-axis ["Zig", "C", "Go", "cljw", "babashka", "Python", "Java", "Ruby", "Node", "Clojure JVM"]
    y-axis "ms" 0 --> 240
    bar [1.4, 3.2, 3.2, 10.0, 13.6, 18.8, 28.0, 33.7, 46.4, 231.9]
```

Persistent collections trade wins with JVM Clojure op by op (20 000 ops at
n = 16 000, Clojure 1.12.4): `assoc` on a map is 3.9× faster on cljw, `conj`
on a vector 4.4× slower; `seq` / `rest` / `next` over a vector are O(1) views
on both and cljw's are about 2× faster. The interpreter is where the JVM wins:
an empty loop iteration costs ~45 ns here against ~2 ns under the JVM JIT, so
tight numeric Clojure loops belong in a Wasm guest or on the JVM.
[Measured, both sides.](./docs/works/collection_performance.md)

Inside a Wasm guest the embedded engine runs 2× to 3× behind wasmtime on
compute-bound loops (fib: 1.29 s vs 0.49 s, same module, 2026-09-04) and one
`wasm/call` crossing costs about 1 µs. The FFI is for keeping a hot kernel
native, not for beating a standalone runtime;
[the comparison is published as measured](./bench/README.md).

## What runs

`clojure.core` and the everyday standard library: `string`, `set`, `walk`,
`zip`, `edn`, `data.json`, `data.csv`, `math`, `pprint`, `test`, `repl`,
`template`, `tools.cli`, `spec`. STM, atoms, agents, futures, promises,
watches, real threads. Lazy and chunked seqs, transducers, protocols, records,
multimethods, `deftype` / `reify`, the full numeric tower (`Ratio`, `BigInt`,
`BigDecimal`). A `deps.edn`-aware classpath with `:local/root` and `:git`
coordinates, and a CIDER-compatible nREPL.

Real libraries that load and run today (medley, tools.cli, data.json,
core.cache, malli, hiccup, honeysql, test.check and more) are tracked in
[`docs/works/ladder.md`](./docs/works/ladder.md).

`:mvn/version` coordinates load Clojure sources from JARs in
`~/.m2/repository`, fetching missing ones from Clojars, then Maven Central;
every fetched JAR and POM must match its SHA-1 sidecar or the load fails
closed. `curl` and `unzip` must be on the host, and the
[CHANGELOG](./CHANGELOG.md) entry for 1.15.0 lists the limits.

```clojure
{:deps {metosin/malli {:mvn/version "0.20.2"}}}
```

What does not: `core.async` is not bundled, `java.time.format` is not
implemented, and `clojure.edn/read-string` reuses the permissive Clojure
reader, so some EDN-invalid input (such as `#(inc %)`) is accepted.
`(clojure-version)` reports `"1.12.0"`, the semantics target. JVM interop that
exists only to reach the JVM (`gen-class`, `proxy` over arbitrary classes,
reflection, `import` of arbitrary Java classes) is out of scope by design. The
full picture, including the intentional divergences, is
[`docs/clojure_vs_clojurewasm.md`](./docs/clojure_vs_clojurewasm.md).

## Documentation

[`docs/`](./docs/README.md) is the index. The pieces most people want:

- [`CHANGELOG.md`](./CHANGELOG.md), every release, newest first.
- [`docs/clojure_vs_clojurewasm.md`](./docs/clojure_vs_clojurewasm.md), what
  matches JVM Clojure, what deliberately does not, what is missing.
- [`docs/landscape.md`](./docs/landscape.md), where cljw sits among Clojure
  runtimes, `cljrs` included.
- [`docs/testing.md`](./docs/testing.md), the eight test layers and where a
  new test belongs. Read it before sending a patch.
- [`docs/works/demos.md`](./docs/works/demos.md), two real applications
  (a browser playground and a bookshelf with SQLite as `sqlite3.wasm`) whose
  source still builds.
- [`.dev/ROADMAP.md`](./.dev/ROADMAP.md), the plan.

## License and credit

Eclipse Public License 2.0, see [LICENSE](./LICENSE) and
[NOTICE](./legal/NOTICE).

ClojureWasm was created by [Shota Kudo (@chaploud)](https://github.com/chaploud),
who took it from nothing to a working JVM-free Clojure runtime with a Wasm FFI
through v1.10.1, and in 2026-10 handed the
[clojurewasm](https://github.com/clojurewasm) organization over to
[@BuddhiLW](https://github.com/BuddhiLW). The fork's work (v1.11 through
v1.15.0) is merged back into
[clojurewasm/ClojureWasm](https://github.com/clojurewasm/ClojureWasm), so the
original repository is active again. Everything shipped since is built on
that work. The embedded engine is [zwasm](https://github.com/zwasm/zwasm).
