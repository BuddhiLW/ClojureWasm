#!/usr/bin/env bash
# test/e2e/string_seq_view.sh
#
# `(seq s)` over a string is an O(1)-per-step byte-offset VIEW
# (runtime/collection/string_seq.zig, `.string_seq` tag, D-179 / O-060), not the
# eager n-cell codepoint cons chain it used to build. The old path asked
# `codepointAt(s, i)` per element, restarting a UTF-8 walk from byte 0 each time
# — O(n^2) overall (89,910 ms for a 146,670-char string; bb-mcp paid 79 s/boot).
#
# A StringSeq is an ordinary seq of characters: NOTHING observable may change
# versus the eager char list of the same string. It must print as `(\a \b)`, be
# `seq?`/`sequential?`, be `=`/hash with the equal char list AND char vector
# (incl. as a map key), count exactly (codepoints, not bytes), and decode UTF-8
# in place. A representation swap that changes any of those is a bug, not an
# optimisation — this file pins the observable surface; the timing claim lives in
# `.dev/optimizations.md` (O-060). Golden values verified against clj 1.11.

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

# --- it is a SEQ of characters, and prints as one ---
assert_eq 'basic'        "$(run '(seq "hello")')"           '(\h \e \l \l \o)'
assert_eq 'is_seq'       "$(run '(seq? (seq "ab"))')"       'true'
assert_eq 'sequential'   "$(run '(sequential? (seq "ab"))')" 'true'
assert_eq 'coll'         "$(run '(coll? (seq "ab"))')"      'true'
assert_eq 'not_string'   "$(run '(string? (seq "ab"))')"    'false'
assert_eq 'not_vector'   "$(run '(vector? (seq "ab"))')"    'false'
assert_eq 'pr_str'       "$(run '(pr-str (seq "ab"))')"     '"(\\a \\b)"'
# clj: clojure.lang.StringSeq; simple name per AD-003 (ADR-0059).
assert_eq 'class_name'   "$(run '(str (class (seq "ab")))')" '"StringSeq"'

# --- UTF-8: count is CODEPOINTS, decode is in place ---
assert_eq 'utf8_count'   "$(run '(count (seq "héllo"))')"   '5'
assert_eq 'utf8_first'   "$(run '(first (seq "café"))')"    '\c'
assert_eq 'utf8_rest'    "$(run '(rest (seq "café"))')"     '(\a \f \é)'
assert_eq 'utf8_nth'     "$(run '(nth (vec (seq "wörld")) 1)')" '\ö'
assert_eq 'utf8_last'    "$(run '(last (seq "wörld"))')"    '\d'

# --- read access ---
assert_eq 'first'        "$(run '(first (seq "café"))')"    '\c'
assert_eq 'second'       "$(run '(second (seq "abc"))')"    '\b'
assert_eq 'last'         "$(run '(last (seq "abcd"))')"     '\d'
assert_eq 'rest'         "$(run '(rest (seq "café"))')"     '(\a \f \é)'
assert_eq 'next'         "$(run '(next (seq "ab"))')"       '(\b)'
assert_eq 'next_single'  "$(run '(next (seq "a"))')"        'nil'
assert_eq 'fnext'        "$(run '(fnext (seq "abc"))')"     '\b'
assert_eq 'nthrest'      "$(run '(nthrest (seq "abcde") 2)')" '(\c \d \e)'
assert_eq 'count'        "$(run '(count (seq "abc"))')"     '3'
assert_eq 'count_rest'   "$(run '(count (rest (seq "abc")))')" '2'

# --- = / hash interop with the equal char list AND char vector ---
assert_eq 'eq_list'      "$(run '(= (seq "ab") (list \a \b))')" 'true'
assert_eq 'eq_vector'    "$(run '(= (seq "ab") [\a \b])')"  'true'
assert_eq 'hash_vector'  "$(run '(= (hash (seq "ab")) (hash [\a \b]))')" 'true'
assert_eq 'hash_list'    "$(run '(= (hash (seq "ab")) (hash (list \a \b)))')" 'true'
assert_eq 'map_key'      "$(run '(get {(seq "ab") :x} (list \a \b))')" ':x'
assert_eq 'set_dedup'    "$(run '(count (hash-set (seq "ab") [\a \b]))')" '1'
assert_eq 'neq_short'    "$(run '(= (seq "ab") (seq "abc"))')" 'false'

# --- seq operations produce the same values as over the eager char list ---
assert_eq 'vec'          "$(run '(vec (seq "abc"))')"       '[\a \b \c]'
assert_eq 'into'         "$(run '(into [] (seq "ab"))')"    '[\a \b]'
assert_eq 'apply_str'    "$(run '(apply str (seq "abc"))')" '"abc"'
assert_eq 'reverse'      "$(run '(reverse (seq "abc"))')"   '(\c \b \a)'
assert_eq 'take'         "$(run '(take 2 (seq "abcde"))')"  '(\a \b)'
assert_eq 'drop'         "$(run '(drop 2 (seq "abcde"))')"  '(\c \d \e)'
assert_eq 'cons'         "$(run '(cons \x (seq "ab"))')"    '(\x \a \b)'
assert_eq 'concat'       "$(run '(concat (seq "ab") (seq "cd"))')" '(\a \b \c \d)'

# --- higher-order over the view ---
assert_eq 'map_int'      "$(run '(map int (seq "AB"))')"    '(65 66)'
assert_eq 'map_map'      "$(run '(map inc (map int (seq "AB")))')" '(66 67)'
assert_eq 'filter'       "$(run '(filter #(not= % \b) (seq "abc"))')" '(\a \c)'
assert_eq 'reduce'       "$(run '(reduce str "" (seq "abc"))')" '"abc"'

# --- empty edge: (seq "") is nil, per clj ---
assert_eq 'empty_nil'    "$(run '(seq "")')"                'nil'
assert_eq 'empty_pred'   "$(run '(empty? (seq "a"))')"      'false'
assert_eq 'drop_past'    "$(run '(first (drop 3 (seq "abcde")))')" '\d'

# --- correctness AT SCALE (the O(n^2)→O(n) fix; timing lives in O-060) ---
assert_eq 'scale_count'  "$(run '(count (seq (apply str (repeat 20000 "x"))))')" '20000'
assert_eq 'scale_utf8'   "$(run '(count (seq (apply str (repeat 10000 "é"))))')" '10000'

echo "=== string_seq_view: all assertions passed ==="
