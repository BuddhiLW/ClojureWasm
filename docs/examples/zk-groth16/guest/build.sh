#!/usr/bin/env bash
# Build the zk-groth16 guest as a zero-import component.
#   ./build.sh [GEN] [OUT]   GEN is baked into health/ to observe a swap.
#
# wasm32-unknown-unknown, not wasm32-wasip2: the wasip2 build of a std crate
# does not instantiate today (CLJW-WASIP2-STD), and a proving system needs no
# I/O anyway, so the zero-import target is both the working one and the one
# that makes the capability claim.
set -euo pipefail
cd "$(dirname "$0")"
gen="${1:-1}"
out="${2:-target/zk_groth16.gen${gen}.wasm}"
ZK_GEN="$gen" cargo build --locked --release --target wasm32-unknown-unknown --quiet
wasm-tools component new target/wasm32-unknown-unknown/release/zk_groth16.wasm -o "$out"
echo "$out"
