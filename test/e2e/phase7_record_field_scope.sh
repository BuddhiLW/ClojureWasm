#!/usr/bin/env bash
# e2e-process-boundary: asserts --compare runs both backends in isolated runtimes and renders the exact OK result
# test/e2e/phase7_record_field_scope.sh
#
# D-202(1) defrecord/deftype implicit field locals. The seven value assertions
# live in test/clj/suites/phase7_protocols_test.clj. This script retains only
# the original case 8: the --compare CLI's dual-backend oracle.

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
(defprotocol P (m [this]))
(defrecord R [v] P (m [this] (* v v)))
(m (->R 7))
EOF
) || fail "backend_parity: non-zero exit ($got)"
assert_eq 'backend_parity' "$(awk 'END { print }' <<< "$got")" 'OK 49'

echo "OK — phase7_record_field_scope --compare parity green"
