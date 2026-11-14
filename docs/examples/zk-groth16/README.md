# Groth16 in a zero-host-import Wasm component

An arkworks Groth16 prover over BN254 runs inside cljw's component sandbox.
It proves knowledge of `x` with `x^3 + x + 5 == y`. The witness is private to
the circuit and `y` is public. For `x = 3`, `y = 35`.

The [guest](./guest/) targets `wasm32-unknown-unknown`, not WASI. It imports
no host functions, filesystem, environment, clock or randomness. The checked-in
[component fixture](../../../test/e2e/fixtures/wasm/README_zk_groth16.md) lets
the example run without Rust or wasm-tools.

## Run from the repository root

```sh
zig build -Dwasm -Doptimize=ReleaseSafe
./zig-out/bin/cljw test/clj/zk_examples_test.clj
```

The native `clojure.test` suite checks a 128-byte proof, verification against
`35`, rejection against `36`, a second witness (`x = 0`, `y = 5`) to reject
a constant prover, and a catchable clock trap followed by successful calls on
the same handle. Proving takes about 12 s under host load, so it runs in the
full-only `test_clj_zk` step, tagged `slow` in `test/units.list`. Select it
explicitly with `bash test/run_all.sh --smoke test_clj_zk`.

```clojure
(def h (wasm/load-component "test/e2e/fixtures/wasm/zk_groth16.component.wasm"))
(def iface "hive:zk-groth16/tools@0.1.0#")
(def seed (vec (repeat 32 7)))
(def proof (second (wasm/component-call h (str iface "prove") 3 seed)))
(wasm/component-call h (str iface "verify") proof 35 seed) ;=> [:ok true]
(wasm/component-call h (str iface "verify") proof 36 seed) ;=> [:ok false]

(try (wasm/component-call h (str iface "probe-clock"))
     (catch Throwable t (println (.getMessage t))))
(wasm/component-call h (str iface "compute") 3) ;=> 35
```

WIT `result<T, string>` becomes `[:ok value]` or `[:err message]`. `compute`,
`prove`, `verify` and `probe-ambient` are the main tools. `probe-one` isolates
an authority probe; `probe-clock` deliberately traps. `echo-list` is a typed
lifting control. Addon metadata exports identify the guest and its generation.

## Rebuild the fixture

Requires Cargo, the `wasm32-unknown-unknown` Rust target, and wasm-tools.
From the repository root:

```sh
rustup target add wasm32-unknown-unknown
bash docs/examples/zk-groth16/guest/build.sh
cp docs/examples/zk-groth16/guest/target/zk_groth16.gen1.wasm \
  test/e2e/fixtures/wasm/zk_groth16.component.wasm
wasm-tools validate test/e2e/fixtures/wasm/zk_groth16.component.wasm
```

`Cargo.lock` pins the dependencies. Every arkworks crate has
`default-features = false`, avoiding the default parallel feature and rayon.
The caller explicitly seeds ChaCha20Rng; the guest never depends on
`getrandom`. Setup keys are cached per instance and seed.

## Security limits

This is a runtime and isolation demo, not a production proof system. Public,
deterministic setup seeds reveal the Groth16 toxic waste, so the resulting
keys do not provide sound proofs of knowledge. Reusing deterministic proof
randomness is also unsafe. Production requires a secure setup and independent
cryptographic randomness. The examples print the witness for explanation.
`compute` saturates at `u64` limits; use small inputs to match field arithmetic.
