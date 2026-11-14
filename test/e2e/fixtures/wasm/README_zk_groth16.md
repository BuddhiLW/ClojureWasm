# zk_groth16.component.wasm

An arkworks Groth16 component over BN254, proving knowledge of `x` with
`x^3 + x + 5 == y`. The compressed proof is 128 bytes.

## Provenance and rebuild

Sources copied from `hive-addon-wasm/guest/zk-groth16`, licensed MIT, live in
[`docs/examples/zk-groth16/guest/`](../../../../docs/examples/zk-groth16/guest/).
No Cargo target directory is tracked. From the repository root:

```sh
bash docs/examples/zk-groth16/guest/build.sh 1
cp docs/examples/zk-groth16/guest/target/zk_groth16.gen1.wasm \
  test/e2e/fixtures/wasm/zk_groth16.component.wasm
wasm-tools validate test/e2e/fixtures/wasm/zk_groth16.component.wasm
wasm-tools component wit test/e2e/fixtures/wasm/zk_groth16.component.wasm
```

Requires Cargo, `rustup target add wasm32-unknown-unknown` and wasm-tools.
Built with rustc 1.98.1, wasm-tools 1.262.0 and the committed `Cargo.lock`.
The fixture is 325,786 bytes. SHA-256:

```text
f05a28e96b1fe074f4bdf3fbae5964351e654d8915165f390147e2a99ff9dbb3
```

`build.sh [generation] [output]` uses a locked release build and wraps the
core module with `wasm-tools component new`. The default generation is `1`;
`health` reports it. Every arkworks dependency disables default features to
avoid rayon. ChaCha20Rng is explicitly seeded. Neither `getrandom` nor rayon
is in the guest dependency graph.

## Imports and capabilities

The core module has zero imports. The component imports no host functions.
Its top-level `tool-doc` import is a record type; shim function imports are
wired internally to the guest's own exports. No WASI adapter is used.

`hive:zk-groth16/tools@0.1.0` exports `compute`, `prove`, `verify`,
`probe-ambient`, `echo-list`, `probe-one` and `probe-clock`. Addon metadata
exports are `addon-id`, `capabilities`, `tool-docs` and `health`.

`probe-ambient` reports filesystem denials and zero arguments. Environment
iteration and wall-clock access panic on this Rust target. `probe-clock`
turns that panic into a guest trap, catchable by cljw as `Throwable`. The
same component handle remains usable after the trap.

## Tests and limits

`test/clj/zk_examples_test.clj` checks real verification, rejection
of a false public input, two distinct witnesses, proof size and calls after
a guest trap.

The deterministic setup and proof seed make this reproducible, not secure.
Anyone who knows the setup seed knows the toxic waste. Do not use these keys
or this randomness policy for production proofs.
