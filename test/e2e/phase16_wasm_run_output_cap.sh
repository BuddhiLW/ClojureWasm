#!/usr/bin/env bash
# test/e2e/phase16_wasm_run_output_cap.sh — D-349.
#
# `(wasm/run …)` buffers the guest's stdout and stderr in HOST memory, and
# neither of the other two budgets bounds that: fuel bounds instructions, and
# how many bytes an instruction writes is the guest's choice. Measured before
# the cap existed: `spam_stdout.wasm` buffered exactly 64,000,000 bytes for
# 1,000,000 fuel — 64 bytes per unit — so ~64 GB under the default fuel budget.
# A 1e8-fuel run reached ~6.4 GB RSS; with the cap it peaks at ~33 MB.
#
# The guest IGNORES fd_write's errno, so this holds against a guest that does
# not cooperate with the cap.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }

F=test/e2e/fixtures/wasm/spam_stdout.wasm
[ -f "$F" ] || fail "the spam fixture is missing"

# Low fuel throughout: this asserts the MEMORY bound, and fuel is what ends the
# run. At 1e6 fuel the uncapped guest produces 64 MB, which is the number that
# makes each capped result below mean something.
run() { # run <opts> -> byte count
    "$BIN" -e "(println (count (:out (wasm/run \"$F\" $1))))" 2>/dev/null | head -1
}

got="$(run '{:fuel 1000000 :max-output-bytes 4096}')"
[[ "$got" == "4096" ]] || fail "explicit cap not honoured: expected 4096 bytes, got '$got'"
echo "PASS explicit-cap -> $got"

got="$(run '{:fuel 1000000 :max-output-bytes 100}')"
[[ "$got" == "100" ]] || fail "small cap not honoured: expected 100 bytes, got '$got'"
echo "PASS small-cap -> $got"

# The default is finite, and well under what this guest would otherwise produce.
got="$(run '{:fuel 1000000}')"
[[ "$got" == "64000000" ]] && fail "the DEFAULT cap is not applied — the guest buffered 64 MB at 1e6 fuel, which is the pre-fix number"
[[ "$got" -le 16777216 ]] || fail "default cap exceeded: got '$got' bytes"
echo "PASS default-cap-is-finite -> $got"

# `<= 0` opts out, the same convention :fuel and :max-memory-pages use. This is
# the case that proves the cap above is the cap and not some other limit.
got="$(run '{:fuel 1000000 :max-output-bytes 0}')"
[[ "$got" == "64000000" ]] || fail "unmetered opt-out changed the result: expected 64000000, got '$got'"
echo "PASS unmetered-opt-out -> $got"

# A guest that writes a normal amount is untouched.
got="$("$BIN" -e '(println (pr-str (:out (wasm/run "test/e2e/fixtures/wasm_run_probe.wasm" {:args ["prog" "7"]}))))' 2>/dev/null | head -1)"
[[ -n "$got" && "$got" != '""' ]] || fail "an ordinary guest lost its output under the default cap: got '$got'"
echo "PASS ordinary-guest-unaffected -> $got"

echo "OK — phase16_wasm_run_output_cap (5 cases) green"
