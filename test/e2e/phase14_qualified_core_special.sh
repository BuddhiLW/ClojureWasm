#!/usr/bin/env bash
# test/e2e/phase14_qualified_core_special.sh
#
# cljw implements `defmacro`, `binding` and `ns` as analyzer special forms,
# but on the JVM they are clojure.core MACROS, so code (and macro output) may
# write them qualified: `(clojure.core/defmacro …)`. Emmy's `sci-macro` does.
# The qualified head (or one through a clojure.core alias) must reach the
# same analyzer arm instead of calling the nil-rooted marker Var
# ("macro Var 'defmacro' root binding is not callable").

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
(clojure.core/defmacro qm [x] `(inc ~x))
(prn (qm 41))
EOF
)
assert_eq 'qualified_defmacro' "$got" '42'

got=$(run <<'EOF'
(prn (try (eval '(clojure.core/defmacro qm2 [x] x)) :defined
          (catch Throwable e (str "FAIL " (ex-message e)))))
EOF
)
assert_eq 'qualified_defmacro_via_eval' "$got" ':defined'

got=$(run <<'EOF'
(require '[clojure.core :as cc])
(cc/defmacro twice [x] `(* 2 ~x))
(prn (twice 21))
EOF
)
assert_eq 'aliased_core_defmacro' "$got" '42'

got=$(run <<'EOF'
(def ^:dynamic *d* 1)
(prn (clojure.core/binding [*d* 2] *d*))
EOF
)
assert_eq 'qualified_binding' "$got" '2'

got=$(run <<'EOF'
(defmacro mk [] `(defmacro ~'gen [y#] y#))
(mk)
(prn (gen 7))
EOF
)
assert_eq 'syntax_quoted_defmacro_in_macro_output' "$got" '7'

echo "phase14_qualified_core_special: all passed"
