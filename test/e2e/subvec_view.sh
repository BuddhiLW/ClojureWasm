#!/usr/bin/env bash
# test/e2e/subvec_view.sh
#
# `(subvec v start end)` over a vector is an O(1) shared-structure VIEW
# (runtime/collection/sub_vector.zig, `.sub_vector` tag, D-583 / O-059), not the
# eager `(into [] (take … (drop …)))` copy it used to build.
#
# A subvec is a first-class IPersistentVector: NOTHING observable may change
# versus a materialized vector of the same elements. It must print as `[..]`, be
# `vector?`, be `=`/hash with the equal plain vector (incl. as a map key), count
# exactly, support nth/conj/assoc/pop/peek/seq/rseq/reduce, carry meta, and
# flatten when nested. A representation swap that changes any of those is a bug,
# not an optimisation — this file pins the observable surface; the timing claim
# lives in `.dev/optimizations.md` (O-059).

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
run() { "$BIN" -e "$1" 2>/dev/null; }

# --- it is a first-class VECTOR, and prints as one ---
assert_eq 'basic'          "$(run '(subvec (vec (range 10)) 2 7)')" '[2 3 4 5 6]'
assert_eq 'is_vector'      "$(run '(vector? (subvec [1 2 3] 0 2))')" 'true'
assert_eq 'not_seq'        "$(run '(seq? (subvec [1 2 3] 0 2))')"    'false'
assert_eq 'coll'           "$(run '(coll? (subvec [1 2 3] 0 2))')"   'true'
assert_eq 'counted'        "$(run '(counted? (subvec [1 2 3] 0 2))')" 'true'
assert_eq 'sequential'     "$(run '(sequential? (subvec [1 2 3] 0 2))')" 'true'
assert_eq 'associative'    "$(run '(associative? (subvec [1 2 3] 0 2))')" 'true'
assert_eq 'indexed'        "$(run '(indexed? (subvec [1 2 3] 0 2))')" 'true'
assert_eq 'reversible'     "$(run '(reversible? (subvec [1 2 3] 0 2))')" 'true'
assert_eq 'ifn'            "$(run '(ifn? (subvec [1 2 3] 0 2))')"    'true'
assert_eq 'pr_str_is_vec'  "$(run '(pr-str (subvec [1 2 3] 0 2))')" '"[1 2]"'
# clj: APersistentVector$SubVector; simple name per AD-003 (ADR-0059).
assert_eq 'class_name'     "$(run '(str (class (subvec [1 2] 0 2)))')" '"SubVector"'

# --- count / nth / read access ---
assert_eq 'count'          "$(run '(count (subvec (vec (range 10)) 2 7))')" '5'
assert_eq 'nth'            "$(run '(nth (subvec (vec (range 10)) 2 7) 1)')" '3'
assert_eq 'get'            "$(run '(get (subvec (vec (range 10)) 2 7) 1)')" '3'
assert_eq 'contains_idx'   "$(run '(contains? (subvec [1 2 3] 0 2) 1)')" 'true'
assert_eq 'contains_oob'   "$(run '(contains? (subvec [1 2 3] 0 2) 5)')" 'false'
assert_eq 'fn_invoke'      "$(run '((subvec [10 20 30] 0 2) 1)')" '20'
assert_eq 'first'          "$(run '(first (subvec [1 2 3 4] 1 3))')" '2'
assert_eq 'last'           "$(run '(last (subvec [1 2 3 4] 1 3))')"  '3'
assert_eq 'peek'           "$(run '(peek (subvec [1 2 3 4] 1 3))')"  '3'
assert_eq 'nth_oob_throws' "$(run '(try (nth (subvec [1 2 3] 0 2) 5) (catch Exception e :threw))')" ':threw'

# --- write ops stay vectors (structural sharing, parent untouched) ---
assert_eq 'conj'           "$(run '(conj (subvec (vec (range 10)) 2 7) 99)')" '[2 3 4 5 6 99]'
assert_eq 'assoc'          "$(run '(assoc (subvec (vec (range 10)) 2 7) 0 -1)')" '[-1 3 4 5 6]'
assert_eq 'assoc_append'   "$(run '(assoc (subvec (vec (range 10)) 2 7) 5 77)')" '[2 3 4 5 6 77]'
assert_eq 'pop'            "$(run '(pop (subvec (vec (range 10)) 2 7))')" '[2 3 4 5]'
assert_eq 'pop_to_empty'   "$(run '(pop (subvec [1 2 3] 1 2))')" '[]'
assert_eq 'conj_still_vec' "$(run '(vector? (conj (subvec [1 2 3] 0 2) 9))')" 'true'
assert_eq 'parent_shared_untouched' "$(run '(let [v (vec (range 5)) s (subvec v 1 4)] (conj s 99) v)')" '[0 1 2 3 4]'

# --- nested subvec flattens (parent stays a plain vector) ---
assert_eq 'nested'         "$(run '(subvec (subvec (vec (range 20)) 5 15) 2 6)')" '[7 8 9 10]'
assert_eq 'nested_vec'     "$(run '(vector? (subvec (subvec [1 2 3 4 5] 1 5) 1 3))')" 'true'

# --- seq / rseq views ---
assert_eq 'seq'            "$(run '(seq (subvec [1 2 3 4] 1 3))')" '(2 3)'
assert_eq 'rseq'           "$(run '(rseq (subvec [1 2 3 4] 0 3))')" '(3 2 1)'
assert_eq 'rest'           "$(run '(rest (subvec [1 2 3 4] 1 4))')" '(3 4)'
assert_eq 'map_over'       "$(run '(map inc (subvec [1 2 3 4] 1 3))')" '(3 4)'
assert_eq 'reduce'         "$(run '(reduce + (subvec [1 2 3 4] 1 3))')" '5'
assert_eq 'into_vec'       "$(run '(into [] (subvec [1 2 3] 0 2))')" '[1 2]'
assert_eq 'into_map'       "$(run '(into {} [(subvec [:a 1] 0 2)])')" '{:a 1}'
assert_eq 'walk'           "$(run '(clojure.walk/postwalk identity (subvec [1 2 3] 0 2))')" '[1 2]'

# --- equality / hash / map-key interop with a plain vector ---
assert_eq 'eq_plain'       "$(run '(= (subvec [1 2 3] 0 2) [1 2])')" 'true'
assert_eq 'eq_list'        "$(run '(= (subvec [1 2 3] 0 2) (list 1 2))')" 'true'
assert_eq 'hash_eq'        "$(run '(= (hash (subvec [1 2 3] 0 2)) (hash [1 2]))')" 'true'
assert_eq 'map_key_lookup' "$(run '(get {(subvec [1 2 3] 0 2) :x} [1 2])')" ':x'
assert_eq 'compare'        "$(run '(compare (subvec [1 2] 0 2) [1 2])')" '0'
assert_eq 'set_dedup'      "$(run '(count (hash-set (subvec [1 2 3] 0 2) [1 2]))')" '1'

# --- meta round-trips (IObj/IMeta) ---
assert_eq 'with_meta'      "$(run '(meta (with-meta (subvec [1 2 3] 0 2) {:m 1}))')" '{:m 1}'

# --- empty / full-range edge cases ---
assert_eq 'empty_range'    "$(run '(subvec [1 2 3] 1 1)')" '[]'
assert_eq 'empty_of'       "$(run '(empty (subvec [1 2 3] 0 2))')" '[]'
assert_eq 'full_range'     "$(run '(subvec [1 2 3] 0 3)')" '[1 2 3]'
assert_eq 'full_range_vec' "$(run '(vector? (subvec [1 2 3] 0 3))')" 'true'
assert_eq 'oob_throws'     "$(run '(try (subvec [1 2 3] 0 5) (catch Exception e :threw))')" ':threw'
assert_eq 'oob_neg_throws' "$(run '(try (subvec [1 2 3] -1 2) (catch Exception e :threw))')" ':threw'

echo "ALL PASS (subvec_view)"
