# One Groth16 demo, two Clojure runtimes

[`src/demo.cljc`](./src/demo.cljc) calls `zk/compute`, `zk/prove`,
`zk/verify` and `zk/ambient`. The same file runs unchanged on both hosts:

- cljrs loads a native Rust plugin from [`native/`](./native/).
- cljw uses [`cljw/run.clj`](./cljw/run.clj) to adapt the
  [Groth16 component fixture](../../../test/e2e/fixtures/wasm/README_zk_groth16.md)
  to the same `zk` namespace.

Both use arkworks Groth16 over BN254 and the statement
`x^3 + x + 5 == y`. The demo uses `x = 3`, `y = 35` and a 32-byte seed of
`7`. It asserts proof size, successful verification and rejection at `y = 36`.

## Native authority versus Wasm isolation

| observation | cljrs native (measured 2026-09-12) | cljw Wasm (measured 2026-11-14) |
|---|---|---|
| proof | 128 bytes | 128 bytes |
| verify true | true | true |
| verify false | false | false |
| wall time | 1.29 s, DEBUG | 5.65 s, ReleaseSafe |
| env-vars | 212 | 0 exposed (TRAP) |
| fs-read | GRANTED | denied |
| wall-clock | GRANTED | TRAP |

The cljrs column was measured 2026-09-12. It has not been remeasured here:
there is no compatible built DEBUG cljrs binary. The current clojurust
checkout also requires a different dependency graph from the preserved
`native/Cargo.lock`; the locked build refuses to change it.

The cljw column was measured 2026-11-14 on Linux x86_64 (Intel Core Ultra 9
185H), cljw v1.15.8, Zig 0.16.0, rustc 1.98.1. Wall time is the median of
three runs: 5.58, 5.65 and 5.76 s. Other builds were active on the host.
Measured with `/usr/bin/time -f '%e' ./zig-out/bin/cljw docs/examples/zk-dual-runtime/cljw/run.clj`.
The original cljw measurement was 9.17 s. The command includes startup,
component loading, setup, proving, two verifications and ambient probes.
It is not a release-versus-release speed comparison.

A native plugin inherits its process's authority. It is not constrained by a
Wasm import boundary. The Wasm guest imports no host functions: filesystem
operations return unsupported errors, and clock access traps. A `Throwable`
catch contains that trap; it does not terminate the host or discard the handle.
Environment iteration traps on this Rust target rather than returning a
count of zero; no host variables are exposed. The original Wasm column
reported `env-vars=0`. The current row records the observed trap.

## Run cljw from the repository root

No Rust toolchain is needed to use the committed fixture.

```sh
zig build -Dwasm -Doptimize=ReleaseSafe
./zig-out/bin/cljw docs/examples/zk-dual-runtime/cljw/run.clj
```

`cljw/run.clj` uses repository-relative paths. It unwraps WIT `[:ok value]`
results and catches guest authority traps; none of that adapter code is in the
shared `.cljc` program. `src/min.cljc`, `src/pv.cljc` and `src/amb.cljc` are
smaller native probes for compute, proof size and ambient authority.

Run the native cljw suites, including the shared demo and same-handle
post-trap checks. Proving runs in the full-only `test_clj_zk` step (tagged
`slow`), not the default smoke suite:

```sh
./zig-out/bin/cljw test/clj/zk_examples_test.clj
bash test/run_all.sh --smoke test_clj_zk
```

## Run cljrs with its DEBUG binary

**cljrs needs its DEBUG binary until its plugin release bug is fixed.** Do not
substitute the release host for these measurements or load a release plugin
into a debug host. The plugin's `regex-full` and `deps` features must match the
host: its Rust ABI exposes `Value` across the dynamic-library boundary.
Use the same clojurust revision and Rust toolchain for the host and plugin.

Cargo does not expand environment variables in dependency paths. The build
helper reads `CLJRS_HOME`, defaulting to `../../../../clojurust` relative to
this example directory, which means a clojurust checkout beside ClojureWasm.
Worktree layouts can set it explicitly. It creates a disposable manifest under
`native/target/plugin/` with resolved crate paths and the preserved lockfile.
`cljrs.edn` points there. Neither the tracked manifest nor clojurust is modified.
Python 3 and Cargo are required.

```sh
# From the repository root, using a compatible DEBUG cljrs already built:
export CLJRS_HOME="$HOME/PP/clojurust"
export CLJRS_BIN="$CLJRS_HOME/target/debug/cljrs"
bash docs/examples/zk-dual-runtime/build-native.sh
(cd docs/examples/zk-dual-runtime && "$CLJRS_BIN" run src/demo.cljc)
```

The helper uses `cargo build --locked` in DEBUG mode. `native/Cargo.lock` was
copied from the original clojurust-based demo and is load-bearing. If Cargo
requires a lockfile update, use the matching clojurust checkout or review a
new lockfile separately; do not silently resolve different dependencies.
`native/Cargo.toml` also carries relative crate paths for a sibling checkout.

## Security limits

This demo is not production cryptography. Its public deterministic setup seed
reveals the toxic waste, and its proof randomness is deterministic. Use a
secure setup and independent randomness for real proofs. The demo deliberately
prints its witness. See the [guest security limits](../zk-groth16/README.md#security-limits).
