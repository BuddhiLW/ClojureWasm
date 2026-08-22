# 0193 — Compile and run cljw on wasm32-wasi

- **Status**: Proposed -> Accepted
- **Date**: 2026-08-22
- **Author**: BuddhiLW
- **Tags**: wasm, wasm32-wasi, chicory, portability, gc, atomics, single-threaded, ADR-0028, ADR-0090, ADR-0099, F-004, F-006

## Context

cljw compiled only for native targets. A consumer wants to instantiate a cljw
program **inside the JVM** (Chicory) as a sandboxed kernel — no subprocess.
That was believed to require rewriting cljw's GC (the conservative
native-stack scan cannot run on wasm), so it was filed as blocked-upstream.

The belief was wrong. cljw's GC is already **precise** (F-006): roots are
enumerated explicitly (`root_set` — operand-stack `EvalFrame`s, threadlocal
slots, pins, per-tag traces). The `setjmp` + `@frameAddress` scan is D-556, a
conservative *safety net for the tree_walk backend only* — the vm backend
(production default) never arms it.

## Decision

Support **wasm32-wasi** (not wasm64). wasm32 loads on every wasm runtime,
including Chicory whose memory64 support is experimental. Build with
`zig build -Dtarget=wasm32-wasi`; build.zig adds the `atomics` +
`bulk_memory` CPU features for a wasm32 target automatically.

## What it took (no GC rewrite)

- **gc**: compile the D-556 conservative scan only under `-Dbackend=tree_walk`,
  so vm builds never reference `extern setjmp`.
- **value repr**: the NaN-box is a `u64` box holding a ≤47-bit pointer — sound
  on a 32-bit address space; the decode path and host-type accessors take
  `@intCast` at the `u64`↔`usize` boundary. `HeapHeader` is forced `align(8)`
  so the low-3-bits-zero invariant holds when field types are 4-byte.
- **concurrency**: `atomics.zig` gives width-aware atomic ops that degrade to
  plain load/store on single-threaded builds (sound: no concurrency); the
  64-bit `std.atomic.Value` cells move to `atomics.Value`. `spawn.zig` gates
  OS-thread spawning to error on single-threaded builds; `Thread/yield` is a
  no-op there.
- **host surfaces**: net/socket, the http server (posix sockets), and the REPL
  raw-mode line editor (termios) are compiled out on wasi; the REPL uses its
  piped loop.
- **wasi specifics**: allocator-based argv iterator; the self-exe
  embedded-artifact probe is skipped (a wasm module cannot read its own
  executable); deserialize forward-declares a not-yet-created namespace so a
  bootstrap var_ref into a compiled-out host surface resolves. Running a
  filesystem-touching program needs a preopen (`--dir .`).

## Consequences

`zig build -Dtarget=wasm32-wasi` produces a module that runs full Clojure
under **wasmtime**, **Chicory 1.7.5** (pure-Java, in-JVM), and **zwasm
v2.5.0** — verified: `(reduce + (range 100))` = 4950, `defn`/map/maps/strings/
piped-stdin all correct. The native build and target are unchanged; the gate
stays green.

A custom atomic-free single-threaded `Io` (to drop the `+atomics` feature and
`std.Io.Threaded`'s futex vtable) was scoped and **dropped**: Chicory loads
and runs the `+atomics` module on non-shared memory, so it buys nothing for
the in-JVM goal. It stays available if a runtime that rejects atomic
instructions on non-shared memory ever becomes a target.

The single-threaded wasm build has no futures/agents/OS-threads and no
sockets/http; a wasm kernel is a synchronous line-oriented program (stdin ->
stdout), which is exactly the kernel-bridge use case.

## Affected files

- `build.zig` — a wasm32 target auto-adds the `atomics` + `bulk_memory` CPU
  features.
- `src/runtime/gc/mark_sweep.zig` — the D-556 conservative native-stack scan
  (`extern setjmp` + `@frameAddress`) compiles only under `-Dbackend=tree_walk`;
  the vm backend gets an empty `run`.
- `src/runtime/value/value.zig` — width-portable heap-pointer decode
  (`@intCast` at the `u64`↔`usize` boundary).
- `src/runtime/value/heap_header.zig` — `HeapHeader` forced `align(8)` so the
  NaN-box low-3-bits-zero invariant holds when field types are 4-byte.
- `src/runtime/atomics.zig` — new. Width-aware atomic ops that degrade to plain
  load/store on single-threaded builds; the 64-bit `std.atomic.Value` cells move
  here.
- `src/runtime/concurrency/spawn.zig` — new. OS-thread spawn gated to error on
  single-threaded builds.
- `src/runtime/io/stdin.zig` — new. One portable stdin-chunk read via
  `std.Io.File`, shared by `io/text_io.zig` and `io/host_stream.zig`.
- `src/runtime/{agent,atom,future,volatile,thread,type_descriptor}.zig`,
  `src/runtime/concurrency/{eval_budget,lock_tx,safepoint}.zig`,
  `src/runtime/stm/ref.zig`, `src/runtime/java/lang/Thread.zig`,
  `src/runtime/java/util/ArrayList.zig`,
  `src/runtime/java/util/concurrent/{LinkedBlockingQueue,Semaphore,atomic/_atomic}.zig`
  — the 64-bit atomic cells move to `atomics.Value`.
- `src/runtime/java/net/URI.zig`, `src/runtime/numeric/ratio.zig`,
  `src/runtime/java/util/regex/Matcher.zig`,
  `src/runtime/java/io/StringWriter.zig`,
  `src/runtime/java/lang/StringBuilder.zig` — `@intCast` at the `u64`↔`usize`
  width boundary.
- `src/runtime/cljw/_host_api.zig`, `src/runtime/cljw/net/socket.zig` — net /
  socket / http-server host surfaces compile out on wasi.
- `src/app/cli.zig` — allocator-based argv iterator on wasi; the self-exe
  embedded-artifact probe is skipped.
- `src/app/repl.zig` — the raw-mode line editor (termios) compiles out on wasi;
  the REPL uses its piped loop.
- `src/eval/bytecode/serialize.zig` — forward-declare a not-yet-created
  namespace so a bootstrap `var_ref` into a compiled-out host surface resolves.
- `.github/workflows/ci.yml` — a Linux-leg step builds `-Dtarget=wasm32-wasi`
  as a regression guard.
- `CHANGELOG.md`, `README.md` — the target.

## References

- Related ADRs: 0028, 0090 (STW GC / D-244), 0099 (the wasm FFI surface).
- F-004 (the NaN-box `u64` value), F-006 (the precise mark-sweep GC), D-556
  (the tree_walk conservative safety net).
- Chicory 1.7.5, wasmtime 48.0.0, zwasm 2.5.0 — the three runtimes verified.

## Revision history

- 2026-08-22: Status: Proposed -> Accepted (initial landing).
