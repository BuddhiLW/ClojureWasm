#!/usr/bin/env bash
# test/e2e/phase16_wasm_thread_hop.sh — CLJW-WASM-INTERP-THREAD-TRAP.
# A wasm handle warmed on the runtime thread and then called from a (future ...)
# must run on every engine (:interp, :jit, :auto). zwasm's interp cached the first
# calling thread's native-stack limit on the instance, so the worker's call trapped.
#
# OPT-IN like phase16_wasm_engine_select.sh: needs the `-Dwasm` binary.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
fail() { echo "FAIL $1" >&2; exit 1; }

if [ -z "${CLJW_SKIP_BUILD:-}" ] && ! zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null 2>&1; then
  fail "zig build -Dwasm failed (zwasm dep unresolved?)"
fi
"$BIN" --version | grep -q wasm || fail "cljw is not wasm-enabled ($("$BIN" --version))"

out="$("$BIN" test/e2e/fixtures/wasm/thread_hop.clj 2>&1)" || fail "fixture exited non-zero:
$out"

for engine in interp jit auto; do
  for warm in 1 5000; do
    grep -qx "hop $engine $warm: 5" <<<"$out" || fail ":$engine handle warmed ${warm}x on the runtime thread did not run from a future:
$out"
    grep -qx "back $engine $warm: 5" <<<"$out" || fail ":$engine handle did not run back on the runtime thread after the hop:
$out"
  done
done
grep -qx "worker-first interp: 5 5" <<<"$out" || fail ":interp handle first called on a worker did not then run on the runtime thread:
$out"
grep -qx "DONE" <<<"$out" || fail "fixture did not run to completion:
$out"

echo "Phase 16 / wasm thread hop (CLJW-WASM-INTERP-THREAD-TRAP): all green."
