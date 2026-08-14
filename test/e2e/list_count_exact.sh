#!/usr/bin/env bash
# test/e2e/list_count_exact.sh
#
# O-057 — (count lst) takes the stored O(1) count for a PURE .list chain and
# keeps the element walk for a MIXED chain (a .list cell whose rest leaves
# .list). The behaviour under test is that both answers stay EXACT: the
# optimisation is only sound because `COUNT_UNKNOWN` marks the chains whose
# stored count would otherwise be a prefix length presented as a total.

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

# --- pure .list chains: the O(1) path ---
assert_eq 'pure_list_literal'  "$(run '(count (list 1 2 3))')" '3'
assert_eq 'pure_quoted'        "$(run "(count '(1 2 3 4))")" '4'
assert_eq 'pure_empty'         "$(run '(count (list))')" '0'
assert_eq 'pure_empty_quoted'  "$(run "(count '())")" '0'
assert_eq 'pure_cons_chain'    "$(run '(count (cons 1 (cons 2 (list 3))))')" '3'
assert_eq 'pure_apply_list'    "$(run '(count (apply list (range 1000)))')" '1000'
assert_eq 'pure_conj_list'     "$(run '(count (conj (list 1 2) 0))')" '3'

# --- MIXED chains: a .list cell over a tail that is NOT a .list. The stored
# count can only describe the .list prefix, so these must still walk. Each
# one would report the prefix length (1 or 2) if the sentinel were missing.
assert_eq 'cons_over_lazy_map'  "$(run '(count (cons 1 (map inc [1 2 3])))')" '4'
assert_eq 'cons_over_range'     "$(run '(count (conj (range 3) 99))')" '4'
assert_eq 'cons_over_vec_seq'   "$(run '(count (cons 0 (seq [1 2 3])))')" '4'
assert_eq 'cons_over_lazy_seq'  "$(run '(count (cons 1 (lazy-seq [2 3])))')" '3'
assert_eq 'cons_over_string'    "$(run '(count (cons \a (seq "bcd")))')" '4'

# Unknown-ness must propagate head-ward: a second cons onto a mixed chain
# must not resurrect a small stored count.
assert_eq 'nested_over_mixed'   "$(run '(count (cons 1 (cons 2 (map inc [1 2 3]))))')" '5'
assert_eq 'deep_over_mixed'     "$(run '(count (cons 0 (cons 1 (cons 2 (seq [3 4 5])))))')" '6'

# --- the sentinel must not leak into anything that reads the count field ---
# Equality walks lists precisely because a Cons count is not trusted for the
# length short-circuit; that must still hold.
assert_eq 'equality_mixed_vs_pure' \
  "$(run '(= (cons 1 (lazy-seq [2 3])) (list 1 2 3))')" 'true'
assert_eq 'equality_pure_vs_pure' "$(run '(= (list 1 2 3) (list 1 2 3))')" 'true'
assert_eq 'equality_differing'    "$(run '(= (list 1 2) (list 1 2 3))')" 'false'

# Emptiness tests read the same field via `> 0` / `== 0`; a mixed chain is
# non-empty, and `seq` of one is itself.
assert_eq 'mixed_is_not_empty'  "$(run '(empty? (cons 1 (map inc [1 2])))')" 'false'
assert_eq 'mixed_seq_is_itself' "$(run '(count (seq (cons 1 (map inc [1 2]))))')" '3'
assert_eq 'mixed_first_rest'    "$(run '(let [c (cons 1 (map inc [1 2]))] [(first c) (count (rest c))])')" '[1 2]'

# with-meta shares the chain and must carry the same count classification.
assert_eq 'with_meta_pure'  "$(run "(count (with-meta '(1 2 3) {:a 1}))")" '3'
assert_eq 'with_meta_mixed' "$(run '(count (with-meta (cons 1 (map inc [1 2])) {:a 1}))')" '3'

echo "OK test/e2e/list_count_exact.sh"
