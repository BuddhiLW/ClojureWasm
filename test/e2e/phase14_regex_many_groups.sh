#!/usr/bin/env bash
# test/e2e/phase14_regex_many_groups.sh
#
# Capture groups past the former inline cap. The Pike VM used to carry a fixed
# [16]i32 slot array per thread (8 slot pairs, pair 0 unused), so a pattern
# with 8+ capturing groups failed to compile with a misleading
# "backreferences / an unsupported construct" error. Slots are now sized per
# program, bounded only by compile.MAX_CAPTURE_GROUPS (1024).
#
# Pins: the Emmy complex-number pattern (emmy/complex/impl.cljc:149) through
# re-matches / re-find / re-seq / re-groups / the Matcher API; wide, nested and
# optional (unmatched -> nil) groups; and the error split (too many groups is a
# catchable resource error naming the limit, a backreference names itself).

set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null

fail() { echo "FAIL $1" >&2; exit 1; }
last_line() { awk 'END { print }' <<< "$1"; }

check() {
    local name="$1" want="$2" got
    got=$("$BIN" - 2>&1) || fail "$name: non-zero exit: $got"
    [[ "$(last_line "$got")" == "$want" ]] || fail "$name: got '$(last_line "$got")', want '$want'"
    echo "PASS $name"
}

# --- the Emmy pattern: 1+2i / -3.5e2 - 4I / 7 ---
check emmy_re_matches \
'[["1+2i" "1" nil nil "+2i" "+" "2" nil nil] ["-3.5e2 - 4I" "-3.5e2" ".5" "e2" " - 4I" "-" "4" nil nil] ["7" "7" nil nil nil nil nil nil nil]]' <<'EOF'
(def re #"([+-]?\d+(\.\d*)?([Ee][+-]?\d+)?)(\s?([+-])?\s?([+-]?\d+(\.\d*)?([Ee][+-]?\d+)?)[Ii])?")
(prn (mapv #(re-matches re %) ["1+2i" "-3.5e2 - 4I" "7"]))
EOF

check emmy_re_find_and_matcher \
'[["1+2i" "1" nil nil "+2i" "+" "2" nil nil] 8 "2" nil ["1+2i" "1" nil nil "+2i" "+" "2" nil nil]]' <<'EOF'
(def re #"([+-]?\d+(\.\d*)?([Ee][+-]?\d+)?)(\s?([+-])?\s?([+-]?\d+(\.\d*)?([Ee][+-]?\d+)?)[Ii])?")
(let [m (re-matcher re "z=1+2i")]
  (.find m)
  (prn [(re-find re "z=1+2i") (.groupCount m) (.group m 6) (.group m 8) (re-groups m)]))
EOF

# --- 12 groups: re-seq, nth on a matcher, the high group index ---
check twelve_groups_re_seq \
'[["abcdefghijkl" "a" "b" "c" "d" "e" "f" "g" "h" "i" "j" "k" "l"] 2 "l" "l"]' <<'EOF'
(def re #"(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)(k)(l)")
(let [s (re-seq re "abcdefghijkl-abcdefghijkl")
      m (doto (re-matcher re "abcdefghijkl") .matches)]
  (prn [(first s) (count s) (.group m 12) (nth m 12)]))
EOF

# --- nested + optional groups past the old cap; unmatched -> nil ---
check nested_optional \
'[["xy" "x" "x" "x" "x" "x" "x" "x" "x" "x" nil "y"] ["xzy" "x" "x" "x" "x" "x" "x" "x" "x" "x" "z" "y"]]' <<'EOF'
(def re #"(((((((((x)))))))))(z)?(y)")
(prn [(re-find re "xy") (re-find re "xzy")])
EOF

# --- replace with $N on a 9-group pattern (single-digit $9) ---
check replace_dollar_nine '"i-a"' <<'EOF'
(prn (clojure.string/replace "abcdefghi" #"(a)(b)(c)(d)(e)(f)(g)(h)(i)" "$9-$1"))
EOF

# --- 1000 groups compile and match ---
check thousand_groups '[1000 "x"]' <<'EOF'
(let [re (re-pattern (apply str (repeat 1000 "(x)")))
      m (re-matches re (apply str (repeat 1000 "x")))]
  (prn [(dec (count m)) (peek m)]))
EOF

# --- too many groups: a catchable error that names the limit ---
got=$("$BIN" - <<'EOF' 2>&1 || true
(prn (try (re-pattern (apply str (repeat 1025 "()"))) :NOT-RAISED
          (catch Exception e (.getMessage e))))
EOF
)
grep -q 'too many capturing groups (more than 1024)' <<< "$got" \
    || fail "too_many_groups: expected the group-limit message, got '$got'"
echo "PASS too_many_groups"

# --- a backreference names itself (and stays uncatchable, AD-060) ---
got=$("$BIN" - <<'EOF' 2>&1 || true
(prn (try (re-pattern "(a)\\1") :NOT-RAISED (catch Throwable _ :swallowed)))
EOF
)
grep -q 'regex backreference' <<< "$got" \
    || fail "backref_named: expected the backreference message, got '$got'"
grep -qx ':swallowed' <<< "$got" \
    && fail "backref_named: a catch swallowed the backreference raise"
echo "PASS backref_named"

echo "phase14_regex_many_groups: 8/8 cases pass"
