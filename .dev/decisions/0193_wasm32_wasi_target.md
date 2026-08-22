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
