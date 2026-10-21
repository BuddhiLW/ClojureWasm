#!/usr/bin/env bash
# test/e2e/phase16_wasm_dot_interop.sh — method-call forms on a core wasm
# module handle (ADR-0203 decision 2). `(.add h 40 2)`, `(. h add 40 2)` and
# `(. h (add 40 2))` are `(wasm/call h "add" 40 2)`: the method symbol's name is
# the export name verbatim, and the call takes the SAME path as wasm/call, so a
# missing export, an arity mismatch and a trap raise the same catalogued errors.
#
# OPT-IN for the same reason as phase16_wasm_ffi.sh: it builds `-Dwasm`, so it
# resolves zwasm, which the default gate never does (F-001).
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
fail() { echo "FAIL $1" >&2; exit 1; }

if [ -z "${CLJW_SKIP_BUILD:-}" ] && ! zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null 2>&1; then
  fail "zig build -Dwasm failed (zwasm dep unresolved?)"
fi
"$BIN" --version | grep -q wasm || fail "cljw is not wasm-enabled ($("$BIN" --version)) — zwasm did not resolve"

FIX="test/e2e/fixtures/wasm_dot_interop_probe.clj"

run_probe() {
  local label="$1"; shift
  out="$("$@" "$FIX" 2>&1)" || fail "[$label] cljw exited non-zero running $FIX:
$out"
  want() {
    grep -qF "$1" <<<"$out" || fail "[$label] expected '$1' in the probe output, got:
$out"
  }

  # (1) The three method-call spellings all reach the export.
  want "dot-method 42"
  want "dot-form 42"
  want "dot-list 42"
  want "same-as-call true"
  echo "PASS wasm-dot-interop-forms [$label] -> (.add h 40 2) / (. h add 40 2) / (. h (add 40 2)) = 42"

  # (2) A C export name is used verbatim; memory written by the host is read.
  want "c-sum 10.0"
  want "c-scale 4 20.0"
  echo "PASS wasm-dot-interop-c-kernel [$label] -> (.sum_f64 m buf 4) = 10.0"

  # (3) Errors are wasm/call's, not a '<.member>' miss.
  grep -q "NOT-RAISED" <<<"$out" && fail "[$label] a wasm dot-call error was not raised:
$out"
  grep -q "<.member>.*wasm_module" <<<"$out" && fail "[$label] wasm receiver fell through to <.member> dispatch:
$out"
  want "missing-same true"
  want "missing wasm/call: no exported function named 'nope'"
  want "arity wasm/call:"
  want "trap-same true"
  want "trap wasm/call: 'boom' () -> (i32) trapped"
  echo "PASS wasm-dot-interop-errors [$label] -> missing export / arity / trap raise wasm/call's errors"

  # (4) Non-wasm receivers are unchanged.
  want "string ABC"
  want "nonwasm No implementation of method 'add' on protocol '<.member>'"
  echo "PASS wasm-dot-interop-nonwasm [$label] -> other receivers keep <.member> dispatch"

  grep -q "^DONE$" <<<"$out" || fail "[$label] the probe did not run to completion:
$out"
}

# The backend is a build option (-Dbackend, vm by default); both arms
# (VM op_method_call, TreeWalk evalInstanceMember) carry the wasm case.
run_probe "${CLJW_BACKEND:-vm}" "$BIN"

echo
echo "phase16_wasm_dot_interop: all PASS"
