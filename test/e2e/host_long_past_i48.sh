#!/usr/bin/env bash
# test/e2e/host_long_past_i48.sh
#
# Value.initInteger encodes an i64 outside the i48 fixnum window as an f64,
# so a host surface that hands a raw large i64 to it returns a Double that
# fails (= x Long/MAX_VALUE). 61049014 fixed Runtime.maxMemory by routing
# past-i48 values through big_int.allocFromI64(.long). This step pins every
# other host surface that can return a large integer: each one must answer
# class Long, and the past-i48 ones must round-trip their exact value.
# Detection is (str (class x)); a "Double" here is the trap.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="${CLJW_BIN:-zig-out/bin/cljw}"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}
# -e prints the value of each form; the probe is one form.
run() { "$BIN" -e "$1" 2>/dev/null; }
cls() { run "(str (class $1))"; }
# [class exact-equal?] for a surface whose exact value is known.
exact() { run "(let [x $1] [(str (class x)) (= x $2)])"; }

# --- clocks ---
assert_eq 'currentTimeMillis_is_long' "$(cls '(System/currentTimeMillis)')" '"Long"'
assert_eq 'nanoTime_is_long'          "$(cls '(System/nanoTime)')"          '"Long"'
assert_eq 'instant_toEpochMilli_is_long' \
  "$(cls '(.toEpochMilli (java.time.Instant/now))')" '"Long"'
assert_eq 'instant_getNano_is_long'   "$(cls '(.getNano (java.time.Instant/now))')" '"Long"'

# --- Duration past i48 (1e14 ms > 2^47) ---
assert_eq 'duration_toMillis_past_i48' \
  "$(exact '(.toMillis (java.time.Duration/ofSeconds 100000000000))' '100000000000000')" \
  '["Long" true]'

# --- parse paths at the i64 edge ---
assert_eq 'parseLong_max' \
  "$(exact '(Long/parseLong "9223372036854775807")' 'Long/MAX_VALUE')" '["Long" true]'
assert_eq 'valueOf_max' \
  "$(exact '(Long/valueOf "9223372036854775807")' 'Long/MAX_VALUE')" '["Long" true]'
assert_eq 'long_sum_max' \
  "$(exact '(Long/sum Long/MAX_VALUE 0)' 'Long/MAX_VALUE')" '["Long" true]'

# --- BigDecimal -> long and double -> long narrowing ---
assert_eq 'bigdec_longValue_max' \
  "$(exact '(.longValue (bigdec "9223372036854775807"))' 'Long/MAX_VALUE')" '["Long" true]'
assert_eq 'long_of_large_double' \
  "$(exact '(long 9.2e18)' '9200000000000000000')" '["Long" true]'

# --- File length and Runtime readings ---
assert_eq 'file_length_is_long' "$(cls '(.length (java.io.File. "build.zig"))')" '"Long"'
assert_eq 'runtime_maxMemory_is_long' \
  "$(exact '(.maxMemory (Runtime/getRuntime))' 'Long/MAX_VALUE')" '["Long" true]'

echo "host_long_past_i48: all host integer surfaces answer Long"
