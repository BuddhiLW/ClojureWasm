#!/usr/bin/env bash
# e2e-process-boundary: asserts uncatchable :gen-class diagnostics and process exit status
# test/e2e/phase6_16_b_4_ns_macro.sh
#
# ns value and catchable error checks live in
# test/clj/suites/phase6_namespaces_test.clj. :gen-class deliberately raises
# not_implemented, which a clojure.test suite cannot catch without aborting.

set -euo pipefail
cd "$(dirname "$0")/../.."

OUT="${TMPDIR:-/tmp}/cljw-phase6-gen-class.$$.out"
trap 'rm -f "$OUT"' EXIT

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

if "$BIN" -e "(ns foo (:gen-class))" >${TMPDIR:-/tmp}/cljw-phase6-gen-class.$$.out 2>&1; then
    echo "FAIL ns_unknown_directive_raises: expected a non-zero exit" >&2
    exit 1
fi
if ! grep -q 'not supported in ClojureWasm' ${TMPDIR:-/tmp}/cljw-phase6-gen-class.$$.out; then
    echo "FAIL ns_unknown_directive_raises: missing diagnostic" >&2
    exit 1
fi
echo "PASS ns_unknown_directive_raises"
echo "OK — phase6_16_b_4_ns_macro process-boundary diagnostic green"
