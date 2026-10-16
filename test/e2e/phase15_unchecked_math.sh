#!/usr/bin/env bash
# test/e2e/phase15_unchecked_math.sh
#
# *unchecked-math* honoring (CLJW-UNCHECKED-MATH). cljw's checked +/-/*/inc/dec
# AUTO-PROMOTE i64 overflow to BigInt; JVM Clojure WRAPS when *unchecked-math* is
# truthy at compile time. The analyzer reproduces that: while the flag is truthy
# it rewrites a pristine core +/-/*/inc/dec call to nested wrapping unchecked-*
# ops. This is what lets clojure.test.check.random's SplitMix64 run on cljw.
#
# The flag is a COMPILE-time property: a top-level (set! *unchecked-math* …)
# affects the analysis of SUBSEQUENT top-level forms (cljw -e evaluates
# form-by-form), not siblings inside one already-analyzed form — JVM parity.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }

check() { # check <expr> <expected> <label>
    local out
    set +e
    out=$("$BIN" -e "$1" 2>&1 | tail -n 1)
    set -e
    [[ "$out" == "$2" ]] || fail "$3: expected '$2', got '$out'"
    echo "PASS $3 -> $2"
}

ON='(set! *unchecked-math* true)'

# --- default (flag off): checked math PROMOTES on overflow ---
check '(* 9223372036854775807 2)'            '18446744073709551614N' checked_mul_promotes
check '(class (* 9223372036854775807 2))'    'BigInt'  checked_mul_class_bigint

# --- flag on: +/-/*/inc/dec WRAP at 64 bits ---
check "$ON (* 9223372036854775807 2)"        '-2'                    unchecked_mul_wraps
check "$ON (class (* 9223372036854775807 2))" 'Long'    unchecked_mul_class_long
check "$ON (+ 9223372036854775807 1)"        '-9223372036854775808' unchecked_add_wraps
check "$ON (inc 9223372036854775807)"        '-9223372036854775808' unchecked_inc_wraps
check "$ON (dec -9223372036854775808)"       '9223372036854775807'  unchecked_dec_wraps

# --- arity parity: the rewrite folds n-ary and handles unary/nullary ---
check "$ON (+ 1 2 3 4)"                       '10'                   unchecked_add_nary
check "$ON (* 2 3 4)"                         '24'                   unchecked_mul_nary
check "$ON (- 10 3 2)"                        '5'                    unchecked_sub_nary
check "$ON (- 5)"                             '-5'                   unchecked_negate
check "$ON (+)"                               '0'                    unchecked_add_identity
check "$ON (*)"                               '1'                    unchecked_mul_identity

# --- n-ary overflow wraps through the fold (not promoted midway) ---
check "$ON (class (* 1000000000000 1000000000 1000000000))" 'Long' unchecked_nary_wraps

# --- the SplitMix64 shape that blocked test.check.random ---
check "$ON (unsigned-bit-shift-right (* 9223372036854775807 7) 11)" '4503599627370495' unchecked_splitmix_shape

# --- value position is NOT rewritten (JVM parity: (reduce + xs) stays checked) ---
check "$ON (class (reduce + [9223372036854775807 2]))" 'BigInt' value_position_still_checked

echo "OK phase15_unchecked_math"
