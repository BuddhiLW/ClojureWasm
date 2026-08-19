#!/usr/bin/env bash
# test/e2e/phase14_float_statics.sh
#
# java.lang.Float static surface (runtime/java/lang/Float.zig), the sibling
# compat_tiers.yaml has carried as Tier A "no surface" since phase 14.
#
# Values are f64 throughout: cljw has no f32 representation, so `Float/*`
# arithmetic and parsing operate on the single-double tower exactly as
# `clojure.core/float` does (AD-004). The CONSTANTS are still Java's real
# float constants, and the bit conversions narrow to f32 because their
# signature is defined on the 32-bit pattern.

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

# --- parseFloat (trims whitespace; accepts Infinity/NaN spelling) ---
check '(Float/parseFloat "3.14")'       '3.14'   float_parseFloat_basic
check '(Float/parseFloat " 3.14 ")'     '3.14'   float_parseFloat_trim
check '(Float/parseFloat "-0.5")'       '-0.5'   float_parseFloat_negative
check '(Float/parseFloat "Infinity")'   '##Inf'  float_parseFloat_inf
check '(Float/parseFloat "-Infinity")'  '##-Inf' float_parseFloat_neg_inf
check '(Float/parseFloat "NaN")'        '##NaN'  float_parseFloat_nan

# --- NumberFormatException via the ADR-0060 bridge (malli's parse-float
#     catches exactly this, which is what made the surface load-bearing) ---
check '(try (Float/parseFloat "x") (catch NumberFormatException e :caught))'      ':caught' float_parseFloat_nfe
check '(try (Float/parseFloat "1_0.5") (catch NumberFormatException e :caught))'  ':caught' float_parseFloat_underscore_nfe

# --- predicates ---
check '(Float/isNaN (/ 0.0 0.0))'       'true'   float_isNaN_true
check '(Float/isNaN 1.0)'               'false'  float_isNaN_false
check '(Float/isInfinite (/ 1.0 0.0))'  'true'   float_isInfinite_true
check '(Float/isInfinite 1.0)'          'false'  float_isInfinite_false
check '(Float/isFinite 1.0)'            'true'   float_isFinite_true
check '(Float/isFinite (/ 1.0 0.0))'    'false'  float_isFinite_false

# --- valueOf / toString ---
check '(Float/valueOf "2.5")'           '2.5'    float_valueOf_string
check '(Float/valueOf 2.5)'             '2.5'    float_valueOf_number
check '(Float/toString 1.5)'            '"1.5"'  float_toString

# --- compare / max / min / sum ---
check '(Float/compare 1.0 2.0)'         '-1'     float_compare_lt
check '(Float/compare 2.0 1.0)'         '1'      float_compare_gt
check '(Float/compare 1.0 1.0)'         '0'      float_compare_eq
check '(Float/compare -0.0 0.0)'        '-1'     float_compare_neg_zero
check '(Float/max 1.0 2.0)'             '2.0'    float_max
check '(Float/min 1.0 2.0)'             '1.0'    float_min
check '(Float/sum 1.0 2.0)'             '3.0'    float_sum

# --- static fields: Java's real float constants ---
check 'Float/SIZE'                      '32'     float_SIZE
check 'Float/BYTES'                     '4'      float_BYTES
check 'Float/MAX_EXPONENT'              '127'    float_MAX_EXPONENT
check 'Float/MIN_EXPONENT'              '-126'   float_MIN_EXPONENT
check '(Float/isNaN Float/NaN)'         'true'   float_NaN_field
check '(Float/isInfinite Float/POSITIVE_INFINITY)' 'true' float_POSITIVE_INFINITY
check '(< 0.0 Float/NEGATIVE_INFINITY)' 'false'  float_NEGATIVE_INFINITY
check '(< 3.4e38 Float/MAX_VALUE 3.5e38)'          'true' float_MAX_VALUE
check '(< 0.0 Float/MIN_VALUE 1.5e-45)'            'true' float_MIN_VALUE
check '(< 1.17e-38 Float/MIN_NORMAL 1.18e-38)'     'true' float_MIN_NORMAL

# --- bit conversions: defined on the 32-bit pattern, so they narrow ---
check '(Float/floatToIntBits 1.0)'      '1065353216' float_floatToIntBits
check '(Float/intBitsToFloat 1065353216)' '1.0'      float_intBitsToFloat
check '(Float/floatToRawIntBits 1.0)'   '1065353216' float_floatToRawIntBits
check '(Float/hashCode 1.0)'            '1065353216' float_hashCode

# --- the malli coercion path this surface unblocks (hive-contracts rung) ---
check '(Float/parseFloat (str 42))'     '42.0'   float_parseFloat_from_str

echo "OK phase14_float_statics"
