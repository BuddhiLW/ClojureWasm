#!/usr/bin/env bash
# test/e2e/phase14_macro_class_form.sh
#
# A macro may return a class OBJECT inside its expansion: `(defmacro m []
# [String])`, `` `(identity ~clojure.lang.Keyword) ``. On the JVM the class is
# a constant in the expansion; cljw re-analyses expansions from Forms, so
# `valueToForm` turns the class back into the class-name symbol that resolves
# to the same class. Emmy's `defgeneric` (emmy.generic) depends on it. A class
# with no name that round-trips (a reify) must fail with a precise error.

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
run() { "$BIN" - 2>&1 | tail -n 1; }

got=$(run <<'EOF'
(defmacro m [] [String])
(prn (= [String] (m)) (identical? String (first (m))))
EOF
)
assert_eq 'vector_of_class' "$got" 'true true'

got=$(run <<'EOF'
(defmacro k [] `(identity ~clojure.lang.Keyword))
(prn (identical? clojure.lang.Keyword (k)) (instance? (k) :a))
EOF
)
assert_eq 'unquoted_class_in_syntax_quote' "$got" 'true true'

got=$(run <<'EOF'
(defmacro classes [] (mapv class [1 1N 1/2 "s" :k 'a [] {} #{} \c 1.0 true]))
(prn (= (classes) (mapv class [1 1N 1/2 "s" :k 'a [] {} #{} \c 1.0 true])))
EOF
)
assert_eq 'native_value_classes' "$got" 'true'

got=$(run <<'EOF'
(defmacro hm [] {:c java.util.HashMap :e ArithmeticException})
(prn (= (hm) {:c java.util.HashMap :e ArithmeticException}))
EOF
)
assert_eq 'host_and_exception_classes_in_map' "$got" 'true'

# A user type from ANOTHER namespace returned by a macro used elsewhere.
got=$(run <<'EOF'
(ns a.types)
(defrecord Pt [x])
(deftype Box [v])
(defmacro pt-class [] Pt)
(defmacro box-class [] Box)
(ns b.user (:require [a.types :as t]))
(prn (identical? (t/pt-class) a.types.Pt)
     (identical? (t/box-class) a.types.Box)
     (instance? (t/pt-class) (t/->Pt 1)))
EOF
)
assert_eq 'cross_ns_user_types' "$got" 'true true true'

# A same-named type in the expanding ns must not capture the class.
got=$(run <<'EOF'
(ns a.types)
(defrecord Pt [x])
(defmacro pt-class [] Pt)
(ns b.user (:require [a.types :as t]))
(defrecord Pt [y])
(prn (identical? (t/pt-class) a.types.Pt) (identical? (t/pt-class) Pt))
EOF
)
assert_eq 'same_name_type_not_captured' "$got" 'true false'

# A java.lang name shadowed by a local still re-forms to the class.
got=$(run <<'EOF'
(defmacro s [] `(let [~'String 1] ~String))
(prn (identical? (s) String))
EOF
)
assert_eq 'local_shadowing_bare_class_name' "$got" 'true'

got=$(run <<'EOF'
(defmacro c [x] (class x))
(prn (= (c []) clojure.lang.PersistentVector)
     (identical? (eval `(identity ~Long)) Long))
EOF
)
assert_eq 'class_through_eval' "$got" 'true true'

got=$(run <<'EOF'
(defmacro anon [] (class (reify clojure.lang.IDeref (deref [_] 1))))
(prn (try (eval '(anon)) :no-error (catch Throwable e (ex-message e))))
EOF
)
case "$got" in
    *"macro returned class"*"cannot be re-analysed"*) echo "PASS anonymous_class_precise_error" ;;
    *) fail "anonymous_class_precise_error: got '$got'" ;;
esac

echo "phase14_macro_class_form: all PASS"
