#!/usr/bin/env bash
# test/e2e/phase16_compare_comparable.sh: `compare`, `sort` and sorted collections
# accept the JVM-Comparable values clj accepts (CLJW-COMPARE-COMPARABLE):
# java.util.Date (by epoch-ms), java.util.UUID (UUID.compareTo: signed msb,
# then signed lsb), java.io.File (path String.compareTo sign), and a
# deftype/reify implementing java.lang.Comparable. Incomparable pairs still
# raise ClassCastException. Expected values were taken from JVM clj 1.12.
# Uses `cljw -`. Layer 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN="zig-out/bin/cljw"
[ -n "${CLJW_SKIP_BUILD:-}" ] || zig build -Dwasm -Doptimize="${CLJW_OPT:-ReleaseSafe}" >/dev/null
fail() { echo "FAIL $1" >&2; exit 1; }
eq() { local n="$1" g="$2" w="$3"; [[ "$g" == "$w" ]] || fail "$n: got '$g' want '$w'"; echo "PASS $n"; }
out() { "$BIN" - ; }

# --- java.util.Date orders by time
A=$(out <<'EOF' 2>&1
(def d1 (java.util.Date. 1000)) (def d2 (java.util.Date. 2000))
(println (compare d1 d2) (compare d2 d1) (compare d1 (java.util.Date. 1000)))
(println (mapv inst-ms (sort [d2 d1])))
(println (mapv inst-ms (sorted-set d2 d1)))
(println (mapv inst-ms (keys (sorted-map d2 :b d1 :a))))
EOF
)
eq 'date' "$A" $'-1 1 0\n[1000 2000]\n[1000 2000]\n[1000 2000]'

# --- java.util.UUID orders by signed msb, then signed lsb
B=$(out <<'EOF' 2>&1
(def ua #uuid "00000000-0000-0000-0000-000000000001")
(def ub #uuid "80000000-0000-0000-0000-000000000000")
(def uc #uuid "7fffffff-ffff-ffff-ffff-ffffffffffff")
(def ud #uuid "00000000-0000-0000-8000-000000000000")
(println (mapv str (sort [uc ub ua ud])))
(println (compare ua ub) (compare ub ua) (compare ua ud) (compare ua ua))
(println (mapv str (sorted-set uc ub ua)))
(println (mapv str (sort-by identity [uc ub ua])))
EOF
)
eq 'uuid' "$B" $'[80000000-0000-0000-0000-000000000000 00000000-0000-0000-8000-000000000000 00000000-0000-0000-0000-000000000001 7fffffff-ffff-ffff-ffff-ffffffffffff]\n1 -1 1 0\n[80000000-0000-0000-0000-000000000000 00000000-0000-0000-0000-000000000001 7fffffff-ffff-ffff-ffff-ffffffffffff]\n[80000000-0000-0000-0000-000000000000 00000000-0000-0000-0000-000000000001 7fffffff-ffff-ffff-ffff-ffffffffffff]'

# --- a deftype / reify implementing java.lang.Comparable
C=$(out <<'EOF' 2>&1
(deftype V [n] java.lang.Comparable (compareTo [_ o] (compare n (.-n ^V o))) Object (toString [_] (str "V" n)))
(println (map str (sort [(V. 3) (V. 1) (V. 2)])))
(println (compare (V. 1) (V. 2)))
(println (map str (keys (sorted-map (V. 3) :c (V. 1) :a))))
(println (map str (sort-by identity [(V. 3) (V. 1)])))
(println (map str (sorted-set (V. 3) (V. 1))))
(println (map (comp str :k) (sort-by :k [{:k (V. 2)} {:k (V. 1)}])))
EOF
)
eq 'comparable-deftype' "$C" $'(V1 V2 V3)\n-1\n(V1 V3)\n(V1 V3)\n(V1 V3)\n(V1 V2)'

# --- java.io.File orders by path
D=$(out <<'EOF' 2>&1
(println (pos? (compare (java.io.File. "b") (java.io.File. "a")))
         (mapv str (sort [(java.io.File. "b") (java.io.File. "a")])))
EOF
)
eq 'file' "$D" 'true [a b]'

# --- incomparable pairs still throw ClassCastException
E=$(out <<'EOF' 2>&1
(def d1 (java.util.Date. 1000))
(def ua #uuid "00000000-0000-0000-0000-000000000001")
(println (try (compare d1 ua) (catch ClassCastException e :cce))
         (try (compare ua 1) (catch ClassCastException e :cce))
         (try (sort [d1 "x"]) (catch ClassCastException e :cce))
         (try (sorted-set ua d1) (catch ClassCastException e :cce)))
EOF
)
eq 'incomparable' "$E" ':cce :cce :cce :cce'

echo "OK phase16_compare_comparable green"
