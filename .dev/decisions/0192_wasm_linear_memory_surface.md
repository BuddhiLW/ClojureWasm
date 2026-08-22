# 0192 — Expose a guest's linear memory as typed reads and writes

- **Status**: Proposed -> Accepted
- **Date**: 2026-08-22
- **Author**: BuddhiLW (autonomous loop)
- **Tags**: wasm, ffi, linear-memory, marshalling, ADR-0099, security

## Context

`wasm/call` marshals **scalars only**. `marshal.zig::toWasm` / `fromWasm`
cover `i32` / `i64` / `f32` / `f64`; `v128` and reference types raise
`wasm_value_type_unsupported`. Nothing in the `wasm` namespace can read or
write the guest's linear memory.

That is not a marshalling gap, it is a whole class of guest that cannot be
called at all. The dominant calling convention for a numeric guest — from
Rust, Zig, C, or a Clojure-to-wasm compiler — passes an array as a
`(ptr, len)` pair into linear memory and returns results the same way. The
host must fill the buffer before the call and read it after. `wasm/call` can
pass the pointer; it cannot put anything at the other end of it.

So today a guest export like

```wat
(func (export "sum_f64") (param i32 i32) (result f64))
```

is reachable in the sense that it can be invoked, and useless in the sense
that its first argument can only ever address bytes nobody wrote.

The engine already has the capability. zwasm 2.5.0 exposes `Instance.memory()
?Memory` with `slice()` / `size()` / `read(T, addr)` / `write(addr, val)` /
`sliceAt(offset, len)` / `grow(delta)`, and `Memory.Error` is a
bounds-checked `{OutOfBoundsLoad, OutOfBoundsStore}`. cljw's own wrapper
(`engine.zig::Loaded`) surfaces `exportSig` and `invoke` and stops there.

Prior art within the surface: `wasm/run` (D-347) took the same shape — a
capability zwasm had, that cljw had not lifted to the Clojure surface.

## Decision

Three new fns in the `wasm` namespace, over the module's **exported** linear
memory, addressed in **bytes** and typed by an explicit element-type keyword:

```clojure
(wasm/mem-size   handle)                  ; => byte length of the memory
(wasm/mem-read   handle :f64 offset n)    ; => vector of n elements
(wasm/mem-write! handle :f64 offset data) ; => number of elements written
```

`data` is a vector; the return of `mem-write!` is its element count, so a
caller can thread it. Element types are the closed set of wasm-representable
numeric widths: `:i8 :u8 :i16 :u16 :i32 :u32 :i64 :f32 :f64`. Encoding is
little-endian, which is the wasm memory model, not a host property.

Four properties are load-bearing:

1. **Bytes, not pages.** `mem-size` answers in bytes. `memory.size` in the
   wasm spec answers in 64 KiB pages, but every caller of this surface is
   doing bounds arithmetic against a byte offset it is about to pass to
   `wasm/call`. Answering in pages would make the unit of the answer differ
   from the unit of every other number in the same expression. The name says
   `size` and the docstring says bytes; a caller wanting pages divides.

2. **No alignment requirement.** Element access goes through
   `std.mem.readInt` / `writeInt` on the byte slice, so an unaligned offset
   is read correctly rather than being either rejected or undefined. Wasm
   itself permits unaligned access, and a `(ptr, len)` ABI hands the host
   whatever offset the guest's allocator produced.

3. **Every out-of-range access raises, none panic.** Offset, element count,
   and their product are checked against the memory's byte length *before*
   any access, in `i64` arithmetic, so a negative offset and an overflowing
   `offset + n*width` are both ordinary catchable errors. This is
   `marshal.zig::coerceInt`'s existing rule (SE-10 / F-011: no silent loss,
   no host crash on caller data) applied to the memory surface: in
   ReleaseSafe — the shipped configuration — a bare `@intCast` on caller data
   is a process-killing safety panic, and the memory surface takes three
   caller-controlled integers per call.

4. **`:i64` round-trips exactly.** Reads go through
   `numeric/promote.zig::wrapI64`, which promotes past the i48 immediate
   window to a heap Long rather than to a lossy float; writes go through
   `exactI64`, which accepts a heap Long or BigInt and raises `OutOfRange`
   instead of truncating. `Value.initInteger` alone would silently demote a
   full-width `i64` to a float, which is the failure mode this surface exists
   to avoid — the caller is reading a number a guest computed, and cannot
   check it against anything.

A module with no exported memory raises `wasm_memory_absent` rather than
returning nil, because "this module exports no memory" and "this memory is
empty" are different facts and only one of them is a program error.

`mem-grow!` is deliberately **not** part of this ADR — see Alternatives.

Landing this surfaced **D-585**: zwasm's JIT traps a zero-result export outside
a narrow window (arity <= 1, or arity 2-3 with no floating-point parameter), so
most in-place numeric kernels — the exact callers this surface exists for —
trap on the default engine. It is orthogonal to the memory surface, which is
engine-independent, but it decides the fixture's shape: `mem_kernel.wat`'s
`scale_f64` returns the new sum rather than being void.

## Alternatives considered

### Alternative A — raw byte accessors only (`mem-read` returns bytes)

- **Sketch**: expose the memory as bytes; let the caller pack and unpack
  doubles in Clojure.
- **Why rejected**: it moves IEEE-754 encoding into user code, in a language
  with no byte-buffer type, for the single most common case. Every caller
  would write the same `bit-shift`/`Double/longBitsToDouble` ladder, and the
  first one to write it slightly wrong gets numbers that are merely plausible.
  `:u8` is in the dtype set, so the raw view remains available for callers
  who genuinely want bytes.

### Alternative B — infer the element type from the data

- **Sketch**: `(wasm/mem-write! m offset [1.0 2.0])` — write f64 because the
  vector holds floats.
- **Why rejected**: the element type is a property of the **guest's** layout,
  not of the host value that happens to be passed. `[1 2]` and `[1.0 2.0]`
  denote the same buffer contents for an `f64` array, and inference would
  write eight bytes for one and four or eight for the other depending on how
  the caller spelled a literal. It also makes an empty vector untypeable. The
  dtype is the ABI, so it is stated, not guessed.

### Alternative C — a `Memory` handle value, `(wasm/memory m)` then ops on it

- **Sketch**: mint a second opaque handle type wrapping `zwasm.Memory`.
- **Why rejected**: a second handle type needs its own heap tag, its own GC
  trace, its own liveness relationship to the instance that owns it (a
  `Memory` outliving its `Instance` is a dangling slice), and its own
  "used after the module was collected" error. That is a real cost for saving
  one argument. Taking the module handle per call keeps a single ownership
  story: the memory is reachable exactly as long as the handle that owns it.

### Alternative D — include `mem-grow!` now

- **Sketch**: add `(wasm/mem-grow! m pages)` alongside.
- **Why rejected**: not a refusal, a sequencing call. `grow` interacts with
  the `:max-memory-pages` budget axis (ADR-0179 / SE-1): growing is precisely
  the operation the budget bounds, so the surface has to decide whether a
  host-initiated grow spends the guest's budget, and what happens to a
  `Memory` slice the host is mid-way through. Neither question needs an
  answer to make `(ptr, len)` guests callable, and both deserve their own
  ADR. Adding the three read/write fns is additive; adding `grow` later is
  also additive.

## Consequences

- **Positive**: the `(ptr, len)` calling convention becomes expressible, which
  is most of what a numeric wasm guest is for. `wasm/call` stops being
  restricted to guests whose entire interface fits in scalars.
- **Positive**: the same three fns serve any guest language — the ABI is the
  wasm memory model, not a per-language binding.
- **Negative**: the host can now read and write the *whole* linear memory of
  a loaded module, including regions the guest considers private. This widens
  the FFI's trust surface in the host→guest direction. It is the same
  direction `wasm/call` already opens (the host chooses the arguments) and it
  does not weaken the guest's sandbox: the guest still cannot reach host
  memory, and every access is bounds-checked against the guest's own memory.
  What it does mean is that a host bug can corrupt a guest's heap, which
  previously it could not. Callers writing into a region an allocator owns
  must get the pointer from the guest, not invent it.
- **Neutral / follow-ups**: `mem-grow!` (Alternative D). Component-model
  guests (`wasm/load-component`) do their own lifting/lowering and do not
  need this surface; the two paths stay separate.

## Affected files

- `src/runtime/cljw/wasm/memory.zig` — new. The dtype enum, the little-endian
  element codec, and the bounds-checked range arithmetic. Zone 0.
- `src/runtime/cljw/wasm/engine.zig` — `Loaded.memory()` accessor.
- `src/runtime/cljw/wasm/surface.zig` — the three fns + their registration.
- `src/runtime/error/catalog.zig` — five `wasm_memory_*` Codes + entries.
- `test/e2e/phase16_wasm_memory.sh` — new e2e.
- `test/e2e/fixtures/wasm_memory_probe.clj` — new fixture.
- `test/e2e/fixtures/wasm/mem_kernel.wat` / `.wasm` — new fixture module.
- `test/run_all.sh` + `scripts/run_wasm_gate.sh` — the new e2e as a gate step
  (no `test/units.list` row needed: `check_runner_reach.sh` reaches it through
  the gate's step list).
- `.dev/debt.yaml` — D-585, the zwasm JIT zero-result gap this surfaced.
- `CHANGELOG.md`, `README.md` — the surface.

## References

- Related ADRs: 0099 (the wasm FFI surface), 0179 (per-axis runtime budget),
  0159 (resource handle identity), 0200 (per-instance engine selection).
- zwasm 2.5.0 `src/zwasm/memory.zig` — `Memory.slice/size/read/write/sliceAt`.
- `.claude/rules/error_catalog_only.md` — the five new Codes.

## Revision history

- 2026-08-22: Status: Proposed -> Accepted (initial landing).
