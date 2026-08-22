#!/usr/bin/env bash
# test/e2e/phase15_macro_heaplong.sh
#
# A macro that returns a large-magnitude i64 (|n| > the i48 fixnum window, so it
# is a heap-boxed Long — big_int tag, origin .long, D-165) must round-trip
# through macroexpansion as a Long, NOT a BigInt. valueToForm feeds the macro
# evaluator; before the fix it emitted a big_int literal for EVERY big_int tag,
# so the heap-Long came back as a BigInt and broke downstream i64-only ops
# (unsigned-bit-shift-right). This is what silently defeated test.check's
# `longify` (0x… wrapped to a negative long) even with *unchecked-math* on.

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

# test.check's `longify`: a macro that computes a wrapped negative Long from an
# out-of-range hex literal, returning it as a compile-time constant.
LONGIFY='(defmacro longify [num] (if (> num Long/MAX_VALUE) (-> num (- 18446744073709551616N) (long) (bit-or -9223372036854775808)) num))'

# The macro's result must be a Long (heap-boxed), not a BigInt.
check "$LONGIFY (class (longify 0xbf58476d1ce4e5b9))" 'Long' longify_returns_long
# ...with the correct wrapped value.
check "$LONGIFY (longify 0xbf58476d1ce4e5b9)" '-4658895280553007687' longify_value
# and it composes with a shift (the exact op that failed in random.clj) — this
# needs BOTH the round-trip fix AND *unchecked-math* wrapping.
check "$LONGIFY (set! *unchecked-math* true) (class (unsigned-bit-shift-right (* 9223372036854775807 (longify 0xbf58476d1ce4e5b9)) 11))" \
      'Long' longify_splitmix_compose_no_bigint

# A macro returning a large POSITIVE i64 (still a heap-Long) also stays Long.
check '(do (defmacro biglong [] 4658895280553007687) (class (biglong)))' 'Long' biglong_positive_stays_long
# A macro returning a genuine BigInt (out of i64 range) STAYS a BigInt.
check '(do (defmacro reallybig [] (* 99999999999999999N 99999999999999999N)) (class (reallybig)))' 'BigInt' genuine_bigint_preserved

echo "OK phase15_macro_heaplong"
