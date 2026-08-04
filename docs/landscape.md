# Where ClojureWasm sits — a map, not a scoreboard

Clojure runs in a lot of places now. Each runtime below was built for a
different job and is excellent at it. This page is a map of where they sit, not
a ranking — ClojureWasm is one young entry exploring the WebAssembly
corner, and the only numbers it claims are its own measured ones.

| Runtime            | Host / where it shines                                                            | Distribution                            |
|--------------------|-----------------------------------------------------------------------------------|-----------------------------------------|
| **Clojure (JVM)**  | The JVM. Mature, complete, an enormous ecosystem.                                 | Runs on a JVM.                          |
| **Babashka / SCI** | GraalVM native / JS. Fast-starting scripting, glue.                               | Self-contained binary.                  |
| **ClojureScript**  | JavaScript. Front-end and the Node ecosystem.                                     | JS host.                                |
| **jank**           | LLVM / C++. Native code and seamless C++ interop.                                 | Native.                                 |
| **ClojureDart**    | Dart / Flutter. Mobile and cross-platform UI.                                     | App bundles.                            |
| **ClojureWasm**    | Zig. Embeds a Wasm engine so Clojure calls modules from Rust/Go/C (polyglot FFI). | ~7.5 MB native binary, starts in ~6 ms. |

The other rows are respectful summaries of what each runtime is known for, not
evaluations. The ClojureWasm row lists only its own
[measured figures](../bench/RELEASE_METRICS.md); it does not claim to beat
anything.

## What "the WebAssembly corner" means here

Two things, which are easy to conflate — and only the first one is shipped:

1. **ClojureWasm embeds a WebAssembly engine.** A Clojure program can load a
   sandboxed module compiled from Rust, Go, Zig, or C and call it like a
   namespace. WebAssembly becomes an FFI: other languages' libraries become
   callable from Clojure, in-process and sandboxed. (See
   [`docs/examples/wasm/`](../docs/examples/wasm/).) This is the angle
   ClojureWasm is exploring, and it has no obvious equivalent in the other
   runtimes.
2. **ClojureWasm does not compile *itself* to WebAssembly.** There is no
   `wasm32` build of the runtime, and `cljw build` produces a native binary
   with an embedded bytecode payload — not a `.wasm`. The runtime is plain
   Zig, so the target is reachable in principle, but the value representation
   and garbage collector are designed for linear memory, so such a build would
   not interoperate with WasmGC-based languages. It is tracked as future
   research, not a feature.

Compiling *Clojure source* into a WebAssembly component is a separate project:
[ClojureWit](https://github.com/clojurewasm/ClojureWit), in the same org.

## A note on respect

Babashka and SCI made JVM-free Clojure scripting fast and ordinary; jank is
doing the hard work of native Clojure with C++ interop; ClojureDart put Clojure
on Flutter; ClojureScript has carried Clojure on the front-end for over a
decade; and the JVM remains the complete, production-proven home of the
language. ClojureWasm exists because of the path those projects cleared, and it
is exploring one more corner — not competing for the others' ground.

## Sources

- Runtime descriptions: each project's own README / site
  ([Clojure](https://clojure.org), [Babashka](https://babashka.org),
  [ClojureScript](https://clojurescript.org), [jank](https://jank-lang.org),
  [ClojureDart](https://github.com/Tensegritics/ClojureDart)).
- ClojureWasm figures: [`bench/RELEASE_METRICS.md`](../bench/RELEASE_METRICS.md)
  (reproduce with `bash bench/release_metrics.sh`).
- ClojureWasm compatibility detail:
  [`docs/clojure_vs_clojurewasm.md`](./clojure_vs_clojurewasm.md) and
  [`data/compat_tiers.yaml`](../data/compat_tiers.yaml).
