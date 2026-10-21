#!/usr/bin/env bash
# test/e2e/phase16_wasm_exports.sh — `(wasm/exports h)` lists a core module's
# exports in export order with runtime-probed signatures (ADR-0203 decision 1).
#
# Functions answer {:name :kind :func :params [...] :results [...]}, every other
# export {:name :kind :memory|:global|:table}. The signature comes from the same
# probe `wasm/call` uses, so a function `wasm/exports` describes is callable with
# exactly that arity. A non-handle argument raises the catalogued
# wasm_handle_invalid error, catchable like every other wasm-surface error.
#
# Reuses the shared -Dwasm binary under CLJW_SKIP_BUILD, like the other phase16
# wasm e2es; standalone it builds -Dwasm ReleaseSafe itself.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
fail() { echo "FAIL $1" >&2; exit 1; }

if [ -z "${CLJW_SKIP_BUILD:-}" ] && ! zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null 2>&1; then
  fail "zig build -Dwasm failed (zwasm dep unresolved?)"
fi
"$BIN" --version | grep -q wasm || fail "cljw is not wasm-enabled ($("$BIN" --version))"

check() { # name expected expr
  local got
  got="$("$BIN" -e "$3" 2>&1)" || fail "$1: cljw exited non-zero:
$got"
  got="$(printf '%s\n' "$got" | sed '${/^nil$/d}')" # -e echoes the prn/println result
  [ "$got" = "$2" ] || fail "$1: expected
  $2
got
  $got"
  echo "PASS $1"
}

# (1) The single-function module: the acceptance shape, verbatim.
check wasm-exports-add \
  '[{:name "add", :kind :func, :params [:i32 :i32], :results [:i32]}]' \
  '(prn (wasm/exports (wasm/load "docs/examples/wasm/add.wasm")))'

# (2) A C-compiled module: the linear memory and four functions, in export order.
check wasm-exports-c-kernel-names \
  '[["memory" :memory] ["buf_addr" :func] ["buf_cap" :func] ["sum_f64" :func] ["scale_f64" :func]]' \
  '(prn (mapv (juxt :name :kind) (wasm/exports (wasm/load "docs/examples/polyglot/c/kernel.wasm"))))'

check wasm-exports-c-kernel-sigs \
  '[["buf_addr" [] [:i32]] ["buf_cap" [] [:i32]] ["sum_f64" [:i32 :i32] [:f64]] ["scale_f64" [:i32 :i32 :f64] [:i32]]]' \
  '(prn (vec (for [e (wasm/exports (wasm/load "docs/examples/polyglot/c/kernel.wasm")) :when (= :func (:kind e))] [(:name e) (:params e) (:results e)])))'

# (3) A non-function export carries no :params / :results.
check wasm-exports-memory-has-no-sig \
  '{:name "memory", :kind :memory}' \
  '(prn (first (filter #(= :memory (:kind %)) (wasm/exports (wasm/load "docs/examples/polyglot/c/kernel.wasm")))))'

# (4) What exports describes is callable at exactly that arity.
check wasm-exports-drives-call \
  '42' \
  '(let [h (wasm/load "docs/examples/wasm/add.wasm") e (first (wasm/exports h))] (prn (apply wasm/call h (:name e) (take (count (:params e)) [40 2 99]))))'

# (5) A non-handle is the catalogued wasm_handle_invalid error, catchable.
check wasm-exports-bad-handle \
  'CAUGHT wasm/exports: the first argument must be a loaded wasm module' \
  '(try (wasm/exports 42) (catch Exception e (println "CAUGHT" (ex-message e))))'

echo
echo "Phase 16 / wasm/exports introspection: all green."
