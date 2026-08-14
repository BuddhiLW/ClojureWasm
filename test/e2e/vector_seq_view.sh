#!/usr/bin/env bash
# test/e2e/vector_seq_view.sh
#
# `(seq v)` / `(rest v)` / `(next v)` over a vector are an `.array_seq` VIEW
# (runtime/collection/array_seq.zig, O-058), not the eager PersistentList copy
# they used to build.
#
# The point of a view is that NOTHING observable may change: it must print as a
# seq, be `=` to the list and the vector with the same elements, hash with them,
# work as a map key, count exactly, and terminate a `next` walk at the same
# place. A representation swap that changes any of those is a bug, not an
# optimisation — so this file pins the observable surface, and the timing claim
# lives in `.dev/optimizations.md` where it can be re-measured.

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

# --- it is a seq, and it prints as one (not as the vector it views) ---
assert_eq 'seq_prints_as_list'   "$(run '(seq [1 2 3])')"        '(1 2 3)'
assert_eq 'rest_prints_as_list'  "$(run '(rest [1 2 3])')"       '(2 3)'
assert_eq 'next_prints_as_list'  "$(run '(next [1 2 3])')"       '(2 3)'
assert_eq 'pr_str_is_seq_form'   "$(run '(pr-str (seq [1 2]))')" '"(1 2)"'
assert_eq 'str_is_seq_form'      "$(run '(str (seq [1 2]))')"    '"(1 2)"'
assert_eq 'is_seq'               "$(run '(seq? (seq [1 2]))')"   'true'
assert_eq 'is_sequential'        "$(run '(sequential? (seq [1 2]))')" 'true'
assert_eq 'is_coll'              "$(run '(coll? (seq [1 2]))')"  'true'
assert_eq 'not_vector'           "$(run '(vector? (seq [1 2]))')" 'false'
# AD-066: one indexed-view seq representation stands in for clj's family, so
# the class NAME diverges while everything that treats it as a seq does not.
assert_eq 'class_name'           "$(run '(str (class (seq [1 2])))')" '"ArraySeq"'

# --- IObj: a seq carries metadata on the JVM (ASeq), so the view must too ---
assert_eq 'with_meta_round_trips' \
  "$(run '(meta (with-meta (seq [1 2]) {:a 1}))')" '{:a 1}'
assert_eq 'with_meta_keeps_value' \
  "$(run '(with-meta (seq [1 2]) {:a 1})')" '(1 2)'
assert_eq 'with_meta_keeps_equality' \
  "$(run '(= (with-meta (seq [1 2]) {:a 1}) (list 1 2))')" 'true'
assert_eq 'meta_is_nil_by_default' "$(run '(nil? (meta (seq [1 2])))')" 'true'
# clj's ASeq.next() drops the receiver's meta — the tail is a fresh seq.
assert_eq 'meta_does_not_propagate_to_rest' \
  "$(run '(nil? (meta (rest (with-meta (seq [1 2 3]) {:a 1}))))')" 'true'

# --- empty: every ISeq empties to (), not just a cons chain ---
# `.range` / `.lazy_seq` / `.chunked_cons` used to reach the -empty dispatch and
# RAISE; they answer `()` like clj now, alongside the view.
assert_eq 'empty_of_view'      "$(run '(empty (seq [1 2]))')"      '()'
assert_eq 'empty_of_range'     "$(run '(empty (range 3))')"        '()'
assert_eq 'empty_of_lazy_seq'  "$(run '(empty (map inc [1 2]))')"  '()'
assert_eq 'empty_of_list'      "$(run '(empty (list 1 2))')"       '()'

# --- the empty / one-element boundaries: a view is NEVER empty ---
assert_eq 'seq_of_empty_is_nil'  "$(run '(nil? (seq []))')"      'true'
assert_eq 'next_of_one_is_nil'   "$(run '(nil? (next [1]))')"    'true'
assert_eq 'rest_of_one_is_empty' "$(run '(rest [1])')"           '()'
assert_eq 'rest_of_one_is_seq'   "$(run '(empty? (rest [1]))')"  'true'
assert_eq 'seq_of_one'           "$(run '(seq [1])')"            '(1)'
assert_eq 'next_walks_off_end'   "$(run '(nil? (next (next [1 2])))')" 'true'

# --- equality: with a list, with a vector, and with another view ---
assert_eq 'eq_to_list'      "$(run '(= (seq [1 2 3]) (list 1 2 3))')" 'true'
assert_eq 'eq_to_vector'    "$(run '(= (seq [1 2 3]) [1 2 3])')"      'true'
assert_eq 'list_eq_to_view' "$(run '(= (list 1 2 3) (seq [1 2 3]))')" 'true'
assert_eq 'eq_to_other_view' "$(run '(= (seq [1 2 3]) (seq [1 2 3]))')" 'true'
assert_eq 'rest_eq_to_list'  "$(run '(= (rest [1 2 3]) (list 2 3))')"  'true'
assert_eq 'neq_on_content'   "$(run '(= (seq [1 2 3]) (list 1 2 4))')" 'false'
# A length mismatch must lose even though the SHORTER one is a prefix — the
# O(1) count short-circuit must not read the backing vector's full length.
assert_eq 'neq_on_length'    "$(run '(= (rest [1 2 3]) (list 1 2 3))')" 'false'
assert_eq 'neq_prefix'       "$(run '(= (seq [1 2]) (list 1 2 3))')"    'false'

# --- hash agrees with =, so a view works as a map key / set member ---
assert_eq 'hash_matches_vector' "$(run '(= (hash (seq [1 2 3])) (hash [1 2 3]))')" 'true'
assert_eq 'hash_matches_list'   "$(run '(= (hash (seq [1 2 3])) (hash (list 1 2 3)))')" 'true'
assert_eq 'view_as_map_key'     "$(run '(get {(seq [1 2]) :v} (list 1 2))')" ':v'
assert_eq 'list_key_found_by_view' "$(run '(get {(list 1 2) :v} (seq [1 2]))')" ':v'
assert_eq 'set_dedups_across_reprs' "$(run '(count #{(seq [1 2]) (list 1 2) [1 2]})')" '1'

# --- count is exact at every offset (the subtraction, not the backing count) ---
assert_eq 'count_full'   "$(run '(count (seq [1 2 3 4]))')"  '4'
assert_eq 'count_rest'   "$(run '(count (rest [1 2 3 4]))')" '3'
assert_eq 'count_nested' "$(run '(count (rest (rest [1 2 3 4])))')" '2'
assert_eq 'counted'      "$(run '(counted? (seq [1 2]))')"   'true'

# --- element access ---
assert_eq 'first'         "$(run '(first (seq [1 2 3]))')"    '1'
assert_eq 'first_of_rest' "$(run '(first (rest [1 2 3]))')"   '2'
assert_eq 'second'        "$(run '(second (seq [1 2 3]))')"   '2'
assert_eq 'last'          "$(run '(last (seq [1 2 3]))')"     '3'
assert_eq 'nth'           "$(run '(nth (seq [1 2 3]) 1)')"    '2'
assert_eq 'nth_offset'    "$(run '(nth (rest [1 2 3]) 1)')"   '3'
assert_eq 'nth_default'   "$(run '(nth (seq [1 2]) 9 :d)')"   ':d'
assert_eq 'nth_oob_throws' \
  "$(run '(try (nth (seq [1 2]) 9) :no-throw (catch Exception _ :threw))')" ':threw'
assert_eq 'nth_negative_throws' \
  "$(run '(try (nth (seq [1 2]) -1) :no-throw (catch Exception _ :threw))')" ':threw'

# --- generic seq consumers see no difference ---
assert_eq 'into_set'   "$(run '(into #{} (seq [1 2 3]))')"        '#{1 2 3}'
assert_eq 'vec_round'  "$(run '(vec (seq [1 2 3]))')"             '[1 2 3]'
assert_eq 'map'        "$(run '(doall (map inc (seq [1 2 3])))')" '(2 3 4)'
assert_eq 'filter'     "$(run '(doall (filter odd? (seq [1 2 3])))')" '(1 3)'
assert_eq 'reduce'     "$(run '(reduce + (seq [1 2 3]))')"        '6'
assert_eq 'apply'      "$(run '(apply + (seq [1 2 3]))')"         '6'
assert_eq 'sort'       "$(run '(sort (seq [3 1 2]))')"            '(1 2 3)'
assert_eq 'reverse'    "$(run '(reverse [1 2 3])')"               '(3 2 1)'
assert_eq 'concat'     "$(run '(concat (seq [1 2]) (seq [3]))')"  '(1 2 3)'
assert_eq 'cons_onto'  "$(run '(cons 0 (seq [1 2]))')"            '(0 1 2)'
assert_eq 'seq_of_seq' "$(run '(seq (seq [1 2]))')"               '(1 2)'
assert_eq 'take'       "$(run '(take 2 (seq [1 2 3]))')"          '(1 2)'
assert_eq 'drop'       "$(run '(drop 2 [1 2 3 4])')"              '(3 4)'
assert_eq 'partition'  "$(run '(partition 2 [1 2 3 4])')"         '((1 2) (3 4))'

# A hand-written next-walk — the shape the eager copy actually punished — must
# visit each element exactly once and stop exactly at the end.
assert_eq 'next_walk_visits_each_once' \
  "$(run '(loop [s (seq [1 2 3 4 5]) acc []] (if s (recur (next s) (conj acc (first s))) acc))')" \
  '[1 2 3 4 5]'

# --- scale: the view arithmetic must hold on a multi-level trie ---
assert_eq 'large_count'      "$(run '(count (seq (vec (range 5000))))')" '5000'
assert_eq 'large_rest_count' "$(run '(count (rest (vec (range 5000))))')" '4999'
assert_eq 'large_last'       "$(run '(last (seq (vec (range 5000))))')"  '4999'
assert_eq 'large_walk_sum'   "$(run '(reduce + 0 (seq (vec (range 5000))))')" '12497500'
assert_eq 'large_nth'        "$(run '(nth (rest (vec (range 5000))) 4000)')" '4001'
assert_eq 'large_eq'         "$(run '(= (seq (vec (range 1000))) (apply list (range 1000)))')" 'true'

# --- the view keeps the backing vector alive (GC) ---
# The view holds its backing through a traced Value; a collect between minting
# the view and reading it must not sweep the vector out from under it.
assert_eq 'view_survives_gc' \
  "$(run '(let [s (seq (vec (range 200)))] (dotimes [_ 200] (vec (range 200))) [(count s) (first s) (last s)])')" \
  '[200 0 199]'
# The same under a collect at EVERY back-edge poll, which is what actually
# proves the trace fn reaches `backing` — without it the vector is swept while
# the view still points at it and the reads come back garbage or crash.
assert_eq 'view_survives_gc_torture' \
  "$(CLJW_GC_TORTURE=1 "$BIN" -e '(let [s (seq (vec (range 300)))] (dotimes [_ 50] (vec (range 300))) [(count s) (last s) (reduce + 0 s)])' 2>/dev/null)" \
  '[300 299 44850]'

# --- nested collections inside a view print + compare by content ---
assert_eq 'nested_print' "$(run '(seq [[1 2] {:a 1}])')" '([1 2] {:a 1})'
assert_eq 'nested_eq'    "$(run '(= (seq [[1 2]]) (list [1 2]))')" 'true'

echo "OK test/e2e/vector_seq_view.sh"
