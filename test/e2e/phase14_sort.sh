#!/usr/bin/env bash
# test/e2e/phase14_sort.sh
#
# Phase 14 §9.16 row 14.13 — D-134 sort cluster, unblocked by D-137
# (general compare). sort / sort-by via a STABLE merge sort in .clj
# (ADR-0053 D3 mandates stability — Clojure sort is stable). Uses the
# now-general `compare`, so strings/keywords sort too.
#
# Layer 2 (e2e CLI) per ADR-0021.

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
assert_eq() {
    local name="$1"; local got="$2"; local want="$3"
    [[ "$got" == "$want" ]] || fail "$name: got '$got', want '$want'"
    echo "PASS $name -> $want"
}

assert_eq 'sort_int'    "$("$BIN" -e '(into [] (sort [3 1 2]))')"                 '[1 2 3]'
assert_eq 'sort_str'    "$("$BIN" -e '(into [] (sort ["c" "a" "b"]))')"           '["a" "b" "c"]'
assert_eq 'sort_kw'     "$("$BIN" -e '(into [] (sort [:c :a :b]))')"              '[:a :b :c]'
assert_eq 'sort_empty'  "$("$BIN" -e '(into [] (sort []))')"                      '[]'
assert_eq 'sort_dup'    "$("$BIN" -e '(into [] (sort [2 1 2 1]))')"               '[1 1 2 2]'
assert_eq 'sort_by_len' "$("$BIN" -e '(into [] (sort-by count ["aa" "b" "ccc"]))')" '["b" "aa" "ccc"]'
# stability: a constant key must preserve original order
assert_eq 'sort_stable' "$("$BIN" -e '(into [] (sort-by (fn* [x] 0) [3 1 2]))')"  '[3 1 2]'
# D-159: explicit comparator (boolean predicate or numeric) for sort / sort-by
assert_eq 'sort_gt'     "$("$BIN" -e '(into [] (sort > [3 1 2]))')"               '[3 2 1]'
assert_eq 'sort_lt'     "$("$BIN" -e '(into [] (sort < [3 1 2]))')"               '[1 2 3]'
assert_eq 'sort_numcmp' "$("$BIN" -e '(into [] (sort (fn [a b] (- b a)) [1 2 3]))')" '[3 2 1]'
assert_eq 'sortby_gt'   "$("$BIN" -e '(into [] (sort-by count > ["aa" "b" "ccc"]))')" '["ccc" "aa" "b"]'
# large sort must not blow the stack (-merge-sorted is loop/recur, was a
# non-tail recursion that segfaulted at a few thousand elements)
assert_eq 'sort_large'  "$("$BIN" -e '(count (sort (reverse (range 5000))))')" '5000'
assert_eq 'sort_large_min' "$("$BIN" -e '(first (sort (reverse (range 5000))))')" '0'
assert_eq 'sort_large_max' "$("$BIN" -e '(last (sort (reverse (range 5000))))')" '4999'
# sort / sort-by return a SEQ, not a vector (JVM parity, clj-verified)
assert_eq 'sort_seq'    "$("$BIN" -e '(sort [3 1 2])')"            '(1 2 3)'
assert_eq 'sort_isseq'  "$("$BIN" -e '(seq? (sort [3 1 2]))')"     'true'
assert_eq 'sortby_seq'  "$("$BIN" -e '(sort-by - [3 1 2])')"       '(3 2 1)'
# CLJW-SORT-NAN: a NaN operand must not panic the native sort. NaN compares .eq
# to every number (clj compare rule) so a stable sort preserves input order.
# int+NaN exercises the cross-category numSign path; float+NaN the same-category
# floating arm. Exact tie-order for 3+ mixed-magnitude elements is not asserted
# (block sort vs clj TimSort under a non-transitive comparator) — cardinality is.
assert_eq 'sort_nan_int'  "$("$BIN" -e '(into [] (sort [1 ##NaN]))')"          '[1 ##NaN]'
assert_eq 'sort_nan_flt'  "$("$BIN" -e '(into [] (sort [2.0 ##NaN]))')"        '[2.0 ##NaN]'
assert_eq 'sort_nan_cnt'  "$("$BIN" -e '(count (sort [3 ##NaN 1]))')"          '3'
assert_eq 'sort_nan_fcnt' "$("$BIN" -e '(count (sort [2.0 ##NaN 1.0 3.0]))')"  '4'
assert_eq 'sortby_nan'    "$("$BIN" -e '(into [] (sort-by identity [1 ##NaN]))')" '[1 ##NaN]'

echo "ALL phase14_sort PASS"
