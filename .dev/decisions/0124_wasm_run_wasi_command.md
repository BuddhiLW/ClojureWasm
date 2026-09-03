# ADR-0124 — `(wasm/run …)`: run a WASI command module from Clojure

- **Status**: Proposed → Accepted (2026-06-09) → Amended (2026-09-03,
  D-350 command/handle split accepted as finished form)
- **Adds**: a third var to the `wasm` ns — `(wasm/run "path.wasm" opts)` — that
  runs a WASI command module (Rust / Go / … compiled to `wasm32-wasip1`),
  capturing stdout / stderr / exit. Complements `wasm/load` + `wasm/call`
  (scalar pure-compute, no WASI) from ADR-0099.
- **Extends zwasm** (F-001 co-dev, user-authorized 2026-06-08 direct edits):
  `runWasmCapturedFull` (the old `runWasmCapturedOpts` became a back-compat
  shim) + a `capture_alloc` field on the WASI `Host` so capture buffers grow
  with the caller's allocator.
- **Resolved follow-ups**: D-347 (budgets), D-348 (`:env`), D-349 (bounded
  capture), and D-350 (the command/handle split is the finished form).
- **Composes with**: F-009 (surface in `runtime/cljw/wasm/`, impl-thin),
  F-013 (preopens surfaced as the full `:dir`/`:dirs` class, not one-mount),
  ADR-0123 (FS-jail confines the module path AND every preopen `:dir`).

## Context

ADR-0099's `wasm/call` invokes an exported function with i32/i64/f32/f64
scalars — perfect for pure-compute modules (`wasm32-unknown-unknown`, no
imports). But the compelling polyglot demo is "call a real Rust/Go program,
with its full stdlib, from Clojure": JSON transforms, hashing, a sqlite-backed
store. Those compile to `wasm32-wasip1` and import `wasi_snapshot_preview1.*`
(args, env, preopens, fd I/O, clock, random). zwasm implements all 46 WASI
preview1 functions and already runs off-the-shelf Rust/Go/TinyGo wasip1
modules — but cljw's `wasm/load` path went through `Module.instantiate`, which
wires NO WASI host, so a wasip1 module failed to instantiate from Clojure.

A WASI *command* (`_start`) is single-shot by spec: it runs `main`, calls
`proc_exit`, and the instance is spent. That lifecycle does not fit `wasm/call`'s
re-invokable handle, so it gets its own one-shot surface.

## Decision

Add `(wasm/run path)` / `(wasm/run path {:args [..] :stdin ".." :dir ".." :dirs [[h g]..]})`
returning an array-map `{:out <stdout-string> :err <stderr-string> :exit <int>}`.

- **One-shot**: compile → instantiate-with-WASI → run `_start`→`main`→first
  export → capture → teardown, inside the builtin. No long-lived handle.
- **Exit is data, not an exception.** A non-zero exit — including a guest trap
  (→ exit 1) — is returned in `:exit` (a process runner's exit code is data,
  matching `clojure.java.shell/sh`'s `:exit`). Only *cljw-side* failures are
  catchable exceptions: bad path/opts type (`ClassCastException`-kind), FS-jail
  escape, unreadable file, compile/instantiate/preopen failure. Every failure
  stays a catchable `ClojureWasmError`; none is an exit-70 crash.
- **argv[0] is the program name** by convention (verbatim — cljw does not inject
  the path).
- **Preopens**: `:dir "d"` is sugar for one host dir mapped to guest `/`; `:dirs
  [["host" "/guest"] …]` maps N dirs (a read input + a write output dir is the
  common case). Every host path is FS-jail resolved (ADR-0123) — a preopen
  cannot escape `CLJW_FS_ROOT`.
- **Implementation**: `surface.zig` parses opts (arena-scratch for argv/preopen
  slices; string views into GC strings stay valid across the run since no cljw
  allocation happens during it). `engine.zig::run` calls
  `zwasm.cli.run.runWasmCapturedFull`, passing two caller-owned `ArrayList(u8)`
  capture buffers + optional stdin. The captured bytes are copied into GC
  strings for the result map.

### D-350 resolution: two lifecycles, two explicit surfaces (2026-09-03)

The split above is the finished form, not an interim API:

- `wasm/load` + `wasm/call` is a persistent, re-invokable **library-instance**
  lifecycle. `wasm/load` rejects a present `:wasi` key, including `nil`, instead
  of silently implying support.
- `wasm/run` is a single-shot, captured **command** lifecycle: start the guest,
  collect stdout/stderr/exit, then tear the instance down.
- Reusable WASI state belongs to the component path, whose open handle already
  owns a persistent WASI host and instance.

This was decided against the final zwasm v2.5.0 pin, not against the older API
assumption recorded in alternative (b). The public core-module `Linker` now has
`defineWasi` and `instantiate`, so persistent WASI imports are possible, but its
public `WasiConfig` exposes args/env/preopens only. Captured stdin/stdout/stderr
and exit remain explicitly facade-unwired. Unifying the surfaces would therefore
either discard `wasm/run`'s result contract or make cljw depend on zwasm's private
WASI `Host` state, violating the thin/stable dependency boundary (F-009).

The related D-039 responsibility choice follows directly: cljw's Tier-1
`io_interface` remains cljw-internal I/O; zwasm's WASI host remains isolated in
the Wasm integration layer. Neither implements the other.

### The zwasm extension (capture_alloc)

The WASI host's `fd_write` appends guest stdout/stderr to a caller-supplied
`ArrayList(u8)`, but grew it with the host's own allocator (`c_allocator` from
`zwasm_wasi_config_new`) while the embedder freed it with a different allocator
→ a cross-allocator invalid-free (caught immediately under the DebugAllocator).
Fix: a `capture_alloc: ?Allocator` on the `Host`; `fd.writeSlice` appends with
`host.capture_alloc orelse host.alloc`; `runWasmCapturedFull` sets it to the
allocator the caller will free with. The buffer's grow-allocator and the
caller's free-allocator now agree. This is the clean ownership model (vs.
inlining zwasm's C-API dance in cljw, which would duplicate the engine/store/
preopen/diagnostic sequence and reach across the F-009 boundary).

## Consequences

- Clojure can run any `wasm32-wasip1` command and read its output — unlocking
  Go (stdlib intact) and Rust wasip1 demos, and a preopened-dir file round-trip
  (the substrate for a sqlite-via-wasm store).
- `wasm/call` is unchanged (and its no-leak guard still passes — the
  capture_alloc change does not touch the FFI path).
- The formerly tracked command gaps are closed: `wasm/run` accepts fuel,
  memory, output, and wall-time budgets plus `:env`; D-347/D-348/D-349 are
  discharged. D-350 is discharged by the explicit lifecycle split above.

## Alternatives considered

(Verbatim from a fresh-context Devil's-advocate fork, per CLAUDE.md § ADR-level
designs. The fork read `project_facts.md` + both surface/engine layers + zwasm
`run.zig`/`host.zig`.)

### Leading finding — F-013 tension (no F-NNN violated)

No alternative violates an F-NNN, but F-013 (definition-derived comprehensive
coverage) is in genuine tension with deferring `:env` and capping at one `:dir`,
because the WASI config surface is a small closed set that zwasm already
supports underneath. Resolution: `:dirs` (the whole preopen class) was pulled
forward into this cycle; `:env` is deferred with a tracked debt row (D-348) — a
recorded gap, not a silent "make this demo pass".

### (a) Smallest-diff — return just stdout (string), throw on non-zero exit

Smaller zwasm footprint (stdout-only capture already exists; no stderr/stdin
extension). But it lands a *worse* finished form: stderr (compiler diagnostics,
panics) becomes uncapturable, and throw-on-nonzero is wrong for a process
runner (exit codes are data — `grep` exits 1 normally). Rejected on F-002
(different/worse finished form), not on diff size.

### (b) Historical leading candidate — unified `wasm/load` with `:wasi {…}`

At the 2026-06-09 decision point, one "embed a module" concept was proposed:
`(wasm/load path {:wasi {:args :env :dirs :stdin}})`
→ handle; `wasm/run`/`wasm/call` are operations on it; reusable persistent WASI
instances; `:env`/`:dirs` fall out of the config map (F-013 structural). This is
the cleaner *eventual* finished form (F-002), and is **not** downgraded on
diff-size grounds. Its blocker is a zwasm API gap: the C-API WASI run path is
one-shot; a persistent WASI instance needs zwasm to expose instantiate-with-WASI
separately from run-entry on the public Engine/Instance surface. Per **F-003**
(structural-plan deferral) this cw↔zwasm instance-lifetime split is recorded as
**D-350** and deferred to the Phase-16 owner (D-036 territory) rather than
seized in a demo-hardening cycle — so the clean form is named and owned, not
lost, while the live demo is not blocked on a zwasm rewrite. The D-350
2026-09-03 amendment above supersedes this candidate after inspection of the
final zwasm v2.5.0 facade and the two distinct lifecycles.

### (c) Wildcard — streaming process handle (deref for exit, lazy out/err)

Bounds unbounded output (real robustness gap → captured as **D-349**) and fits
the Phase-14 `cljw.edge` direction. But no streaming substrate exists in zwasm
(the run loop appends to completion); building it needs threads/async (Phase 15)
or a zwasm re-architecture — premature, and it widens FFI breadth past the
authorized demo-hardening scope (F-010 tension). Rejected as substrate-premature;
its one real insight (unbounded buffer) is tracked, not built.

### Verdicts on the five decided points

(ii) `{:out :err :exit}` map and (iv) extending zwasm with `capture_alloc` are
finished-form-clean — kept. (v) `:dir`→`:dirs` and (iii)-env were smallest-diff
seams: `:dirs` fixed in-cycle, `:env` tracked (D-348). (iii)-budgets is a real
`wasm/load`-bounded-vs-`wasm/run`-unbounded asymmetry → D-347 + a zwasm
feed-back. The 2026-09-03 D-350 amendment supersedes verdict (i): the explicit
command/handle split is the finished form.

## Revision history

- 2026-06-09: Status: Proposed → Accepted; introduced the one-shot captured
  WASI command surface.
- 2026-09-03: Status: Accepted → Amended; discharged D-350 by accepting and
  mechanically enforcing the command/handle lifecycle split, and discharged
  the resulting D-039 I/O responsibility decision.
