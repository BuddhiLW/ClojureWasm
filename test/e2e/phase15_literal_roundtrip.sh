#!/usr/bin/env bash
# test/e2e/phase15_literal_roundtrip.sh — literals that must survive a macro
# expansion, plus the two literal/resolution gaps the clojure.core compliance
# suite surfaced.
#
# A macro's arguments arrive as VALUES and its expansion is re-analysed as a
# form, so every value the reader can produce needs an inverse. `#uuid` and
# `#inst` had none: any macro whose body contained one killed the whole
# namespace. `resolve` looked its prefix up as a real namespace name only, so
# an aliased `str/blank?` answered nil while the var plainly existed. And a
# BigDecimal exponent was rejected outright. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n -> $w"; }

MACRO='(defmacro m [& body] `(do ~@body))'

# --- reader literals round-trip through a macro expansion ---

assert_eq 'uuid-through-macro' \
  "$("$BIN" -e "(do $MACRO (m #uuid \"550e8400-e29b-41d4-a716-446655440000\"))" 2>&1 | tail -1)" \
  '#uuid "550e8400-e29b-41d4-a716-446655440000"'

# the value is a uuid, not a re-read string
assert_eq 'uuid-through-macro-type' \
  "$("$BIN" -e "(do $MACRO (uuid? (m #uuid \"550e8400-e29b-41d4-a716-446655440000\")))" 2>&1 | tail -1)" \
  'true'

assert_eq 'inst-through-macro' \
  "$("$BIN" -e "(do $MACRO (inst? (m #inst \"2010-11-12T13:14:15.666-05:00\")))" 2>&1 | tail -1)" \
  'true'

# the printer and the analyzer's inverse share one rule, so a value that
# prints as a reader literal reads back as the same value
assert_eq 'inst-round-trip-equal' \
  "$("$BIN" -e "(do $MACRO (= #inst \"2010-11-12T18:14:15.666-00:00\" (m #inst \"2010-11-12T13:14:15.666-05:00\")))" 2>&1 | tail -1)" \
  'true'

# --- resolve follows a require alias ---

assert_eq 'resolve-through-alias' \
  "$("$BIN" -e "(do (require '[clojure.string :as str]) (resolve 'str/blank?))" 2>&1 | tail -1)" \
  "#'clojure.string/blank?"

assert_eq 'resolve-real-ns-still-works' \
  "$("$BIN" -e "(do (require '[clojure.string :as str]) (resolve 'clojure.string/blank?))" 2>&1 | tail -1)" \
  "#'clojure.string/blank?"

# an unknown name under a known alias is still nil, not an error
assert_eq 'resolve-alias-miss' \
  "$("$BIN" -e "(do (require '[clojure.string :as str]) (resolve 'str/no-such-var))" 2>&1 | tail -1)" \
  'nil'

# ns-resolve reads the symbol's prefix in the CONTEXT of the named ns
assert_eq 'ns-resolve-through-alias' \
  "$("$BIN" -e "(do (require '[clojure.string :as str]) (ns-resolve 'user 'str/upper-case))" 2>&1 | tail -1)" \
  "#'clojure.string/upper-case"

# --- BigDecimal exponents ---
# `× 10^exp` on a (unscaled, scale) pair is a scale shift; the digits never move

assert_eq 'bigdec-positive-exponent' \
  "$("$BIN" -e '1e5M' 2>&1 | tail -1)" \
  '1E+5M'

assert_eq 'bigdec-negative-exponent' \
  "$("$BIN" -e '1E-10M' 2>&1 | tail -1)" \
  '1E-10M'

assert_eq 'bigdec-signed-mantissa-exponent' \
  "$("$BIN" -e '-1.5E-10M' 2>&1 | tail -1)" \
  '-1.5E-10M'

assert_eq 'bigdec-exponent-value' \
  "$("$BIN" -e '(= 150000M 1.5e5M)' 2>&1 | tail -1)" \
  'true'

assert_eq 'bigdec-plain-unchanged' \
  "$("$BIN" -e '123.456M' 2>&1 | tail -1)" \
  '123.456M'

# --- when-let / when-first with no body (clj returns nil either way) ---

assert_eq 'when-let-empty-body-truthy' \
  "$("$BIN" -e '(when-let [x 1])' 2>&1 | tail -1)" \
  'nil'

assert_eq 'when-let-empty-body-falsey' \
  "$("$BIN" -e '(when-let [x nil])' 2>&1 | tail -1)" \
  'nil'

assert_eq 'when-let-body-still-runs' \
  "$("$BIN" -e '(when-let [x 5] (* x 2))' 2>&1 | tail -1)" \
  '10'

assert_eq 'when-first-empty-body' \
  "$("$BIN" -e '(when-first [x [1 2]])' 2>&1 | tail -1)" \
  'nil'

assert_eq 'when-first-body-still-runs' \
  "$("$BIN" -e '(when-first [x [7 8]] (inc x))' 2>&1 | tail -1)" \
  '8'

echo "OK — phase15_literal_roundtrip (17 cases) green"
