# FFI boundary cost probes

Isolates the cost of one `wasm/call` crossing from the loop and call overhead
around it. Run each under hyperfine, take the min, subtract:

    per crossing = (wasm_call - noop) / 1e6
    per clj call = (clj_call  - noop) / 1e6

`noop` is startup plus module load, so it is the right subtrahend for both.
`clj_call` is the same loop shape and arity with a Clojure callee, which is what
separates "the crossing is expensive" from "the loop is expensive".

    P="taskset -c 0-11"   # pin: a hybrid host otherwise measures core assignment
    hyperfine --warmup 3 --runs 15 -N \
      "$P ./zig-out/bin/cljw .dev/bench/ffi_boundary/noop.clj" \
      "$P ./zig-out/bin/cljw .dev/bench/ffi_boundary/clj_call.clj" \
      "$P ./zig-out/bin/cljw .dev/bench/ffi_boundary/wasm_call.clj"

## Measured 2026-09-05, Ultra 9 185H, ReleaseSafe -Dwasm, min-of-15

    Clojure fn call                   184 ns
    wasm/call :engine interp          392 ns    (2.1x a Clojure call)
    wasm/call :engine auto (JIT)   18,875 ns    (48x the interp path)

The 18.9 us is not the cost of crossing. It is zwasm D-584: `computeStackLimit`
runs on every JIT invocation, and on Linux/glibc on the INITIAL thread glibc
answers by opening and parsing `/proc/self/maps`. Confirmed with zwasm's own
runner on this box (`zig build bench-latency`): `stack_limit_query_ns` 26,262
against `jit_ns` 27,436, so the query is ~96% of the per-call JIT cost. The
interpreter caches the same value, which is why it wins here.

Do not re-derive this from the source. An earlier pass read the call graph, found
`findExportFunc` re-parsing the module three times per call, and named that as
the cause. It is real (zwasm D-585) but sits in the ~1.2 us remainder. See hive
memory 20260905010714-4c94602c.

Follow-ups: kanban [CLJW-WASM-ENGINE-DEFAULT], [CLJW-WASM-WORKER-THREAD].
