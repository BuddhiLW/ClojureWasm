#!/usr/bin/env bash
# e2e-process-boundary: asserts --compare runs both backends in isolated runtimes and renders the exact OK result
# test/e2e/phase7_extend_native_class.sh
#
# D-203 / ADR-0072 native class extension and resolution. Value and error
# assertions live in test/clj/suites/phase7_protocols_test.clj. This script
# retains only the original case 8: the --compare CLI's dual-backend oracle.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

got=$("$BIN" --compare - <<'EOF' 2>/dev/null
(defprotocol P (q [n]))
(extend-type Long P (q [n] (* n n)))
(q 9)
EOF
) || fail "backend_parity: non-zero exit ($got)"
assert_eq 'backend_parity' "$(awk 'END { print }' <<< "$got")" 'OK 81'

echo "OK — phase7_extend_native_class --compare parity green"
