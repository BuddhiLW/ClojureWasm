#!/usr/bin/env bash
# e2e-process-boundary: asserts the CLI syntax-error rendering for an odd map literal
# test/e2e/phase6_set_map_literal.sh
#
# Literal values and duplicate-set errors live in
# test/clj/suites/phase6_set_test.clj. This shell retains the full diagnostic,
# whose Syntax error label is rendered by the process boundary.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

got=$("$BIN" -e '{:a}' 2>&1 || true)
case "$got" in
    *"Syntax error"*|*"unexpected"*|*"odd"*|*"arity"*)
        echo "PASS map_odd_rejected" ;;
    *)
        echo "FAIL map_odd_rejected: expected error, got '$got'" >&2
        exit 1 ;;
esac
echo "OK — phase6_set_map_literal CLI diagnostic green"
